#!/usr/bin/env python3
"""Run a Wire-authored delayed-choice quantum eraser analogue."""

from __future__ import annotations

import argparse
import importlib.util
import json
import math
import os
import sys
import tempfile
from fractions import Fraction
from pathlib import Path
from typing import Any


JSON = dict[str, Any]
DEFAULT_CONFIG = "examples/wire/quantum-ibm-runtime.local.json"
DEFAULT_PHASES = "0,1/4,1/2"
DEFAULT_MODES = "open,which_path,eraser"
HALF_PI = math.pi / 2


class EraserError(Exception):
    """User-facing error for the Wire quantum eraser runner."""


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run a Wire quantum eraser analogue through simulation or IBM hardware.",
    )
    parser.add_argument(
        "--wire-bin",
        default=os.environ.get("WIRE_BIN", "wire"),
        help="Wire CLI used to compile generated circuit sources.",
    )
    parser.add_argument(
        "--phases",
        default=DEFAULT_PHASES,
        help="Comma-separated phase turns in [0,1), e.g. 0,1/4,1/2.",
    )
    parser.add_argument(
        "--modes",
        default=DEFAULT_MODES,
        help="Comma-separated modes: open, which_path, eraser.",
    )
    parser.add_argument("--shots", type=positive_int, default=256)
    parser.add_argument("--seed", type=int, default=11)
    parser.add_argument(
        "--hardware",
        action="store_true",
        help="Run on IBM Quantum hardware instead of the local Aer simulator.",
    )
    parser.add_argument(
        "--config",
        default=DEFAULT_CONFIG,
        help="IBM Quantum config path embedded into generated Wire circuits.",
    )
    parser.add_argument(
        "--backend",
        help="IBM backend override. Use 'least_busy' to auto-select online hardware.",
    )
    parser.add_argument(
        "--confirm-hardware",
        action="store_true",
        help="Required with --hardware unless --dry-run is also set.",
    )
    parser.add_argument(
        "--poll-interval",
        type=positive_int,
        help="Hardware polling interval in seconds.",
    )
    parser.add_argument(
        "--timeout",
        type=positive_int,
        help="Hardware polling timeout in seconds.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Generate and compile circuits without simulation or hardware submission.",
    )
    parser.add_argument(
        "--emit-wire",
        help="Directory where generated .wire files should be written.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="json_output",
        help="Print machine-readable JSON instead of the human summary.",
    )
    args = parser.parse_args()

    try:
        scripts_dir = Path(
            os.environ.get("WIRE_QUANTUM_SCRIPTS_DIR", str(Path(__file__).resolve().parent))
        )
        quantum = load_module(scripts_dir / "wire-quantum-qiskit.py", "wire_quantum_qiskit")
        ibm = load_module(scripts_dir / "wire-quantum-ibm-rest.py", "wire_quantum_ibm_rest")
        phases = parse_phase_list(args.phases)
        modes = parse_mode_list(args.modes)
        if args.hardware and not args.dry_run and not args.confirm_hardware:
            raise EraserError(
                "refusing to submit IBM Quantum jobs without --confirm-hardware; "
                "use --dry-run to inspect generated circuits"
            )

        emit_dir = Path(args.emit_wire).resolve() if args.emit_wire else None
        if emit_dir is not None:
            emit_dir.mkdir(parents=True, exist_ok=True)

        hardware = prepare_hardware(args, ibm, quantum) if args.hardware and not args.dry_run else None
        result = run_eraser(args, phases, modes, quantum, ibm, emit_dir, hardware)
        if args.json_output:
            print(json.dumps(result, indent=2, sort_keys=True))
        else:
            print_summary(result)
        return 0
    except (EraserError, quantum_error()) as exc:
        print(f"wire-quantum-eraser: {exc}", file=sys.stderr)
        return 1


def quantum_error() -> type[Exception]:
    try:
        module = sys.modules["wire_quantum_qiskit"]
        return module.WireQuantumError
    except KeyError:
        return EraserError


def load_module(path: Path, module_name: str) -> Any:
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise EraserError(f"could not load module from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def positive_int(raw: str) -> int:
    value = int(raw)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return value


def parse_phase_list(raw: str) -> list[Fraction]:
    phases = [normalize_phase(parse_fraction(item.strip())) for item in raw.split(",") if item.strip()]
    if not phases:
        raise argparse.ArgumentTypeError("at least one phase is required")
    return phases


def parse_fraction(raw: str) -> Fraction:
    try:
        return Fraction(raw)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid phase {raw!r}") from exc


def normalize_phase(phase: Fraction) -> Fraction:
    return phase % 1


def parse_mode_list(raw: str) -> list[str]:
    modes = [item.strip() for item in raw.split(",") if item.strip()]
    valid = {"open", "which_path", "eraser"}
    unknown = sorted(set(modes) - valid)
    if unknown:
        raise argparse.ArgumentTypeError(f"unknown mode(s): {', '.join(unknown)}")
    if not modes:
        raise argparse.ArgumentTypeError("at least one mode is required")
    return modes


def prepare_hardware(args: argparse.Namespace, ibm: Any, quantum: Any) -> JSON:
    config_path = Path(args.config).expanduser().resolve()
    config = ibm.load_runtime_config(config_path, require_credentials=True, quantum=quantum)
    token = ibm.fetch_iam_token(config, quantum)
    return {"config_path": config_path, "config": config, "token": token, "backend": None}


def run_eraser(
    args: argparse.Namespace,
    phases: list[Fraction],
    modes: list[str],
    quantum: Any,
    ibm: Any,
    emit_dir: Path | None,
    hardware: JSON | None,
) -> JSON:
    circuits: list[JSON] = []
    total_qpu_usage = 0.0
    config_path = Path(args.config).expanduser().resolve()

    with tempfile.TemporaryDirectory(prefix="wire-eraser-") as tmpdir:
        tmp_path = Path(tmpdir)
        circuit_index = 0
        for mode in modes:
            for phase in phases:
                circuit_index += 1
                angle = 2 * math.pi * float(phase)
                source = render_circuit_wire(config_path, mode, phase, angle)
                circuit_path = write_circuit_source(source, tmp_path, emit_dir, circuit_index, mode, phase)
                compiled = quantum.load_compiled_circuit(str(circuit_path), args.wire_bin)
                plan = quantum.build_quantum_plan(compiled)
                qasm = ibm.build_openqasm3(plan, quantum)

                circuit_result: JSON = {
                    "mode": mode,
                    "phase": str(phase),
                    "phase_decimal": float(phase),
                    "phase_angle": angle,
                    "wire_path": str(circuit_path),
                    "openqasm3": qasm,
                    "expected": expected_for(mode, phase),
                }

                if args.dry_run:
                    circuit_result.update({"execution": "dry_run"})
                elif hardware is not None:
                    hw_result = execute_hardware_circuit(args, ibm, quantum, hardware, plan, qasm)
                    total_qpu_usage += hw_result["qpu_usage_seconds"]
                    circuit_result.update(hw_result)
                    circuit_result.update(analyze_counts(hw_result["counts"], plan["measurements"], args.shots))
                else:
                    sim_result = quantum.execute_qiskit_plan(
                        plan,
                        backend_name="aer_simulator",
                        shots=args.shots,
                        seed=args.seed + circuit_index - 1,
                    )
                    circuit_result.update(
                        {
                            "execution": "local_simulation",
                            "backend": "aer_simulator",
                            "counts": sim_result["counts"],
                            "labeled_counts": sim_result["labeled_counts"],
                            "seed": args.seed + circuit_index - 1,
                        }
                    )
                    circuit_result.update(analyze_counts(sim_result["counts"], plan["measurements"], args.shots))

                circuits.append(circuit_result)

    return {
        "algorithm": "delayed_choice_quantum_eraser_analogue",
        "execution": execution_label(args),
        "modes": modes,
        "phases": [str(phase) for phase in phases],
        "shots": args.shots,
        "circuits": circuits,
        "qpu_usage_seconds": total_qpu_usage if hardware is not None else None,
    }


def execute_hardware_circuit(
    args: argparse.Namespace,
    ibm: Any,
    quantum: Any,
    hardware: JSON,
    plan: JSON,
    qasm: str,
) -> JSON:
    config = hardware["config"]
    token = hardware["token"]
    if hardware["backend"] is None:
        backend_request = args.backend or config["backend"]
        hardware["backend"] = ibm.resolve_backend(backend_request, config, token, plan, quantum)
    payload = ibm.build_sampler_payload(hardware["backend"], qasm, args.shots)
    submitted = ibm.submit_job(config, token, payload, quantum)
    job_id = submitted["job_id"]
    final_job = ibm.poll_job(
        config,
        token,
        job_id,
        args.poll_interval or config["poll_interval_seconds"],
        args.timeout or config["timeout_seconds"],
        quiet=False,
        quantum=quantum,
    )
    raw_result = ibm.fetch_job_results(config, token, job_id, quantum)
    metrics = ibm.fetch_job_metrics(config, token, job_id, quantum)
    counts = ibm.extract_counts(raw_result, plan["measurements"])
    if counts is None:
        raise EraserError(f"IBM job {job_id} returned an unsupported result shape")
    usage = ibm.qpu_usage_seconds(metrics)
    return {
        "execution": "hardware",
        "backend": hardware["backend"],
        "job_id": job_id,
        "status": ibm.public_job_status(final_job),
        "counts": counts,
        "labeled_counts": quantum.labeled_counts(counts, plan["measurements"]),
        "qpu_usage_seconds": float(usage) if usage is not None else 0.0,
    }


def analyze_counts(counts: dict[str, int], measurements: list[JSON], shots: int) -> JSON:
    rows = decode_counts(counts, measurements)
    screen_zero = sum(count for values, count in rows if values.get("screen") == "0")
    screen_one = sum(count for values, count in rows if values.get("screen") == "1")
    analysis: JSON = {
        "screen_counts": {"0": screen_zero, "1": screen_one},
        "screen_zero_probability": probability(screen_zero, shots),
    }
    if any("marker" in values for values, _ in rows):
        branches = {}
        for marker in ("0", "1"):
            branch_total = sum(count for values, count in rows if values.get("marker") == marker)
            branch_screen_zero = sum(
                count
                for values, count in rows
                if values.get("marker") == marker and values.get("screen") == "0"
            )
            branches[marker] = {
                "shots": branch_total,
                "screen_zero_probability": probability(branch_screen_zero, branch_total),
            }
        analysis["postselected_by_marker"] = branches
    return analysis


def decode_counts(counts: dict[str, int], measurements: list[JSON]) -> list[tuple[dict[str, str], int]]:
    decoded = []
    width = len(measurements)
    for raw_bits, count in sorted(counts.items()):
        bits = raw_bits.replace(" ", "")
        if len(bits) != width:
            raise EraserError(f"unexpected bitstring width in counts: {raw_bits}")
        values = {}
        for measurement in measurements:
            classical_bit = measurement["classical_bit"]
            values[measurement["output"]] = bits[width - classical_bit - 1]
        decoded.append((values, count))
    return decoded


def probability(count: int, total: int) -> float | None:
    return (count / total) if total else None


def expected_for(mode: str, phase: Fraction) -> JSON:
    fringe = math.cos(math.pi * float(phase)) ** 2
    anti_fringe = 1.0 - fringe
    if mode == "open":
        return {"screen_zero_probability": fringe}
    if mode == "which_path":
        return {"screen_zero_probability": 0.5}
    return {
        "screen_zero_probability": 0.5,
        "postselected_by_marker": {
            "0": {"screen_zero_probability": fringe},
            "1": {"screen_zero_probability": anti_fringe},
        },
    }


def write_circuit_source(
    source: str,
    tmp_path: Path,
    emit_dir: Path | None,
    circuit_index: int,
    mode: str,
    phase: Fraction,
) -> Path:
    directory = emit_dir if emit_dir is not None else tmp_path
    phase_label = str(phase).replace("/", "_")
    path = directory / f"quantum-eraser-{circuit_index}-{mode}-phase-{phase_label}.wire"
    path.write_text(source, encoding="utf-8")
    return path


def render_circuit_wire(config_path: Path, mode: str, phase: Fraction, angle: float) -> str:
    if mode == "open":
        return render_open_wire(config_path, phase, angle)
    return render_marked_wire(config_path, mode, phase, angle)


def render_open_wire(config_path: Path, phase: Fraction, angle: float) -> str:
    return f"""# Quantum eraser control circuit: open interferometer at phase {phase}.

contract IBMQuantumConfig;
contract Qubit;
contract Bit;

node ibm_runtime_config
  -> config: IBMQuantumConfig = @quantum.ibm_runtime_config {{ path = \"{config_path}\"; }} (null);

node prepare_screen
  <- config: IBMQuantumConfig;
  -> screen: Qubit = @quantum.prepare_zero {{ index = 0; }} ({{ inherit config; }});

{h_nodes("split", "screen")}

node phase_screen
  <- screen: Qubit;
  -> screen: Qubit = @quantum.rz {{ angle = {format_angle(angle)}; }} (screen);

{h_nodes("recombine", "screen")}

node measure_screen
  <- screen: Qubit;
  -> screen: Bit = @quantum.measure_z {{}} (screen);

let split_path =
  split_rz_a
    => split_sx
    => split_rz_b;

let recombine_path =
  phase_screen
    => recombine_rz_a
    => recombine_sx
    => recombine_rz_b
    => measure_screen;

ibm_runtime_config
  => prepare_screen
  => split_path
  => recombine_path
"""


def render_marked_wire(config_path: Path, mode: str, phase: Fraction, angle: float) -> str:
    marker_readout = "marker_which_path_readout" if mode == "which_path" else "marker_eraser_readout"
    eraser_nodes = ""
    eraser_let = ""
    if mode == "eraser":
        eraser_nodes = "\n" + h_nodes("z_marker_eraser", "target")
        eraser_let = """
let marker_eraser_readout =
  z_marker_eraser_rz_a
    => z_marker_eraser_sx
    => z_marker_eraser_rz_b
    => z_measure_marker;
"""
    else:
        eraser_let = """
let marker_which_path_readout =
  z_measure_marker;
"""

    return f"""# Quantum eraser circuit: {mode} at phase {phase}.
#
# The screen marginal is the no-signalling view. In eraser mode, interference
# only appears after conditioning on the later marker-basis result.

contract IBMQuantumConfig;
contract Qubit;
contract Bit;

node ibm_runtime_config
  -> config: IBMQuantumConfig = @quantum.ibm_runtime_config {{ path = \"{config_path}\"; }} (null);

node prepare_screen
  <- config: IBMQuantumConfig;
  -> control: Qubit = @quantum.prepare_zero {{ index = 0; }} ({{ inherit config; }});

node prepare_marker
  -> target: Qubit = @quantum.prepare_zero {{ index = 1; }} (null);

{h_nodes("split", "control")}

node phase_screen
  <- control: Qubit;
  -> control: Qubit = @quantum.rz {{ angle = {format_angle(angle)}; }} (control);

{h_nodes("mark_pre", "target")}

node mark_cz
  <- control: Qubit;
  <- target: Qubit;
  -> control: Qubit;
  -> target: Qubit;
  = @quantum.cz {{}} ({{ inherit control; inherit target; }});

{h_nodes("z_mark_post", "target")}

{h_nodes("recombine", "control")}

node measure_screen
  <- control: Qubit;
  -> screen: Bit = @quantum.measure_z {{}} (control);
{eraser_nodes}

node z_measure_marker
  <- target: Qubit;
  -> marker: Bit = @quantum.measure_z {{}} (target);

let split_path =
  split_rz_a
    => split_sx
    => split_rz_b
    => phase_screen;

let mark_marker_pre =
  mark_pre_rz_a
    => mark_pre_sx
    => mark_pre_rz_b;

let mark_marker_post =
  z_mark_post_rz_a
    => z_mark_post_sx
    => z_mark_post_rz_b;

let recombine_screen =
  recombine_rz_a
    => recombine_sx
    => recombine_rz_b
    => measure_screen;
{eraser_let}
ibm_runtime_config
  => (
    (
      prepare_screen
        => split_path
        => mark_cz
        => recombine_screen
    )
    <>
    (
      prepare_marker
        => mark_marker_pre
        => mark_cz
        => mark_marker_post
        => {marker_readout}
    )
)
"""


def h_nodes(prefix: str, port: str) -> str:
    return f"""node {prefix}_rz_a
  <- {port}: Qubit;
  -> {port}: Qubit = @quantum.rz {{ angle = {format_angle(HALF_PI)}; }} ({port});

node {prefix}_sx
  <- {port}: Qubit;
  -> {port}: Qubit = @quantum.sx {{}} ({port});

node {prefix}_rz_b
  <- {port}: Qubit;
  -> {port}: Qubit = @quantum.rz {{ angle = {format_angle(HALF_PI)}; }} ({port});"""


def format_angle(angle: float) -> str:
    if abs(angle) < 1e-15:
        return "0.0"
    return format(angle, ".17g")


def execution_label(args: argparse.Namespace) -> str:
    if args.dry_run:
        return "dry_run"
    if args.hardware:
        return "ibm_quantum_hardware"
    return "local_simulation"


def print_summary(result: JSON) -> None:
    print("Wire delayed-choice quantum eraser")
    print(f"execution: {result['execution']}")
    print(f"phases: {', '.join(result['phases'])}")
    print(f"modes: {', '.join(result['modes'])}")
    print(f"shots per circuit: {result['shots']}")
    if result.get("qpu_usage_seconds") is not None:
        print(f"qpu usage: {result['qpu_usage_seconds']:.3f}s")
    print()
    print("What this demonstrates:")
    print("The open circuit shows an interference fringe on the screen qubit.")
    print("Which-path marking destroys that screen marginal fringe.")
    print("Eraser-basis readout recovers complementary fringes only after postselection.")
    print("No future choice changes the unconditional screen statistics.")
    print()
    print("Results:")
    rows = []
    for item in result["circuits"]:
        rows.append(summary_row(item))
    print_table(
        (
            "mode",
            "phase",
            "screen p0",
            "expected",
            "marker0 p0",
            "marker1 p0",
            "counts",
        ),
        rows,
    )


def summary_row(item: JSON) -> tuple[str, str, str, str, str, str, str]:
    if item.get("execution") == "dry_run":
        return (
            item["mode"],
            item["phase"],
            "dry-run",
            fmt_prob(item["expected"]["screen_zero_probability"]),
            "-",
            "-",
            "not run",
        )

    branches = item.get("postselected_by_marker", {})
    marker0 = branch_probability(branches, "0")
    marker1 = branch_probability(branches, "1")
    counts = ",".join(f"{bits}:{count}" for bits, count in sorted(item["counts"].items()))
    return (
        item["mode"],
        item["phase"],
        fmt_prob(item["screen_zero_probability"]),
        fmt_prob(item["expected"]["screen_zero_probability"]),
        marker0,
        marker1,
        counts,
    )


def branch_probability(branches: JSON, marker: str) -> str:
    branch = branches.get(marker)
    if not isinstance(branch, dict):
        return "-"
    return fmt_prob(branch.get("screen_zero_probability"))


def fmt_prob(value: Any) -> str:
    if value is None:
        return "-"
    return f"{float(value):.3f}"


def print_table(headers: tuple[str, ...], rows: list[tuple[str, ...]]) -> None:
    widths = [
        max([len(headers[index]), *(len(row[index]) for row in rows)])
        for index in range(len(headers))
    ]
    print("  " + "  ".join(f"{header:<{widths[index]}}" for index, header in enumerate(headers)))
    for row in rows:
        print("  " + "  ".join(f"{value:<{widths[index]}}" for index, value in enumerate(row)))


if __name__ == "__main__":
    raise SystemExit(main())
