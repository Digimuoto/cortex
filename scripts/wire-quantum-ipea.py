#!/usr/bin/env python3
"""Run iterative phase estimation as Wire-authored quantum rounds."""

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
DEFAULT_PHASE = Fraction(5, 8)
DEFAULT_CONFIG = "examples/wire/quantum-ibm-runtime.local.json"
HALF_PI = math.pi / 2


class IpeaError(Exception):
    """User-facing error for the Wire IPEA runner."""


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run iterative phase estimation through Wire quantum rounds.",
    )
    parser.add_argument(
        "--wire-bin",
        default=os.environ.get("WIRE_BIN", "wire"),
        help="Wire CLI used to compile generated round sources.",
    )
    parser.add_argument(
        "--phase",
        default=str(DEFAULT_PHASE),
        help="Target eigenphase in [0,1), as a fraction or decimal.",
    )
    parser.add_argument("--bits", type=positive_int, default=3)
    parser.add_argument("--shots", type=positive_int, default=100)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument(
        "--hardware",
        action="store_true",
        help="Run on IBM Quantum hardware instead of the local Aer simulator.",
    )
    parser.add_argument(
        "--config",
        default=DEFAULT_CONFIG,
        help="IBM Quantum config path embedded into generated Wire rounds.",
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
        help="Generate and compile rounds without simulation or hardware submission.",
    )
    parser.add_argument(
        "--emit-round-wire",
        help="Directory where generated round .wire files should be written.",
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
        phase = normalize_phase(parse_phase(args.phase))
        if args.hardware and not args.dry_run and not args.confirm_hardware:
            raise IpeaError(
                "refusing to submit IBM Quantum jobs without --confirm-hardware; "
                "use --dry-run to inspect generated rounds"
            )

        emit_dir = Path(args.emit_round_wire).resolve() if args.emit_round_wire else None
        if emit_dir is not None:
            emit_dir.mkdir(parents=True, exist_ok=True)

        hardware = prepare_hardware(args, ibm, quantum) if args.hardware and not args.dry_run else None
        result = run_ipea(args, phase, quantum, ibm, emit_dir, hardware)
        if args.json_output:
            print(json.dumps(result, indent=2, sort_keys=True))
        else:
            print_summary(result)
        return 0
    except (IpeaError, quantum_error()) as exc:
        print(f"wire-quantum-ipea: {exc}", file=sys.stderr)
        return 1


def quantum_error() -> type[Exception]:
    try:
        module = sys.modules["wire_quantum_qiskit"]
        return module.WireQuantumError
    except KeyError:
        return IpeaError


def load_module(path: Path, module_name: str) -> Any:
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise IpeaError(f"could not load module from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def positive_int(raw: str) -> int:
    value = int(raw)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return value


def parse_phase(raw: str) -> Fraction:
    try:
        return Fraction(raw)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("phase must be a fraction or decimal") from exc


def normalize_phase(phase: Fraction) -> Fraction:
    return phase % 1


def prepare_hardware(args: argparse.Namespace, ibm: Any, quantum: Any) -> JSON:
    config_path = Path(args.config).expanduser().resolve()
    config = ibm.load_runtime_config(config_path, require_credentials=True, quantum=quantum)
    token = ibm.fetch_iam_token(config, quantum)
    return {"config_path": config_path, "config": config, "token": token, "backend": None}


def run_ipea(
    args: argparse.Namespace,
    phase: Fraction,
    quantum: Any,
    ibm: Any,
    emit_dir: Path | None,
    hardware: JSON | None,
) -> JSON:
    rounds: list[JSON] = []
    measured_bits: dict[int, int] = {}
    total_qpu_usage = 0.0
    config_path = Path(args.config).expanduser().resolve()

    with tempfile.TemporaryDirectory(prefix="wire-ipea-") as tmpdir:
        tmp_path = Path(tmpdir)
        for ix, bit_position in enumerate(range(args.bits, 0, -1), start=1):
            power = 2 ** (bit_position - 1)
            feedback_fraction = lower_bit_feedback_fraction(measured_bits, bit_position, args.bits)
            feedback_angle = -2 * math.pi * float(feedback_fraction)
            theta = normalize_angle(2 * math.pi * float(phase) * power)
            wire_source = render_round_wire(
                config_path,
                theta,
                feedback_angle,
                round_index=ix,
                bit_position=bit_position,
                power=power,
            )
            round_path = write_round_source(wire_source, tmp_path, emit_dir, ix, bit_position)
            compiled = quantum.load_compiled_circuit(str(round_path), args.wire_bin)
            plan = quantum.build_quantum_plan(compiled)
            qasm = ibm.build_openqasm3(plan, quantum)

            round_result: JSON = {
                "round": ix,
                "bit_position": bit_position,
                "power": power,
                "feedback_fraction": str(feedback_fraction),
                "feedback_angle": feedback_angle,
                "controlled_phase_angle": theta,
                "wire_path": str(round_path),
                "openqasm3": qasm,
            }

            if args.dry_run:
                bit = ideal_phase_bit(phase, bit_position)
                round_result.update(
                    {
                        "execution": "dry_run",
                        "chosen_bit": bit,
                        "chosen_bit_source": "ideal_phase_for_planning",
                    }
                )
            elif hardware is not None:
                hw_result = execute_hardware_round(
                    args,
                    ibm,
                    quantum,
                    hardware,
                    plan,
                    qasm,
                )
                bit = choose_majority_bit(hw_result["counts"])
                usage = hw_result["qpu_usage_seconds"]
                total_qpu_usage += usage
                round_result.update(hw_result)
                round_result.update({"chosen_bit": bit})
            else:
                sim_result = quantum.execute_qiskit_plan(
                    plan,
                    backend_name="aer_simulator",
                    shots=args.shots,
                    seed=args.seed + ix - 1,
                )
                bit = choose_majority_bit(sim_result["counts"])
                round_result.update(
                    {
                        "execution": "local_simulation",
                        "backend": "aer_simulator",
                        "counts": sim_result["counts"],
                        "labeled_counts": sim_result["labeled_counts"],
                        "seed": args.seed + ix - 1,
                        "chosen_bit": bit,
                    }
                )

            measured_bits[bit_position] = bit
            round_result["estimate_after_round"] = float(estimate_phase(measured_bits, args.bits))
            rounds.append(round_result)

    estimated = estimate_phase(measured_bits, args.bits)
    return {
        "algorithm": "iterative_phase_estimation",
        "execution": execution_label(args),
        "phase": str(phase),
        "phase_decimal": float(phase),
        "bits": args.bits,
        "shots": args.shots,
        "estimated_bits": bit_string(measured_bits, args.bits),
        "estimated_phase": str(estimated),
        "estimated_phase_decimal": float(estimated),
        "absolute_error": abs(float(phase) - float(estimated)),
        "rounds": rounds,
        "qpu_usage_seconds": total_qpu_usage if hardware is not None else None,
    }


def execute_hardware_round(
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
        raise IpeaError(f"IBM job {job_id} returned an unsupported result shape")
    return {
        "execution": "hardware",
        "backend": hardware["backend"],
        "job_id": job_id,
        "status": ibm.public_job_status(final_job),
        "counts": counts,
        "labeled_counts": quantum.labeled_counts(counts, plan["measurements"]),
        "qpu_usage_seconds": qpu_usage_seconds(ibm, metrics),
    }


def qpu_usage_seconds(ibm: Any, metrics: Any) -> float:
    usage = ibm.qpu_usage_seconds(metrics)
    return float(usage) if usage is not None else 0.0


def write_round_source(
    source: str,
    tmp_path: Path,
    emit_dir: Path | None,
    round_index: int,
    bit_position: int,
) -> Path:
    directory = emit_dir if emit_dir is not None else tmp_path
    path = directory / f"ipea-round-{round_index}-bit-{bit_position}.wire"
    path.write_text(source, encoding="utf-8")
    return path


def render_round_wire(
    config_path: Path,
    theta: float,
    feedback_angle: float,
    round_index: int,
    bit_position: int,
    power: int,
) -> str:
    half_theta = theta / 2
    return f"""# Iterative phase estimation round {round_index}.
#
# This round measures phase bit position {bit_position} using controlled-U^{power}.
# The graph-valued lets are aliases for named fragments, not macro instantiations.

contract IBMQuantumConfig;
contract Qubit;
contract Bit;

node ibm_runtime_config
  -> config: IBMQuantumConfig = @quantum.ibm_runtime_config {{ path = \"{config_path}\"; }} (null);

node prepare_control
  <- config: IBMQuantumConfig;
  -> control: Qubit = @quantum.prepare_zero {{ index = 0; }} ({{ inherit config; }});

node prepare_target
  -> target: Qubit = @quantum.prepare_zero {{ index = 1; }} (null);

node target_x
  <- target: Qubit;
  -> target: Qubit = @quantum.x {{}} (target);

node h_control_rz_a
  <- control: Qubit;
  -> control: Qubit = @quantum.rz {{ angle = {format_angle(HALF_PI)}; }} (control);

node h_control_sx
  <- control: Qubit;
  -> control: Qubit = @quantum.sx {{}} (control);

node h_control_rz_b
  <- control: Qubit;
  -> control: Qubit = @quantum.rz {{ angle = {format_angle(HALF_PI)}; }} (control);

node phase_control_rz
  <- control: Qubit;
  -> control: Qubit = @quantum.rz {{ angle = {format_angle(half_theta)}; }} (control);

node phase_target_rz
  <- target: Qubit;
  -> target: Qubit = @quantum.rz {{ angle = {format_angle(half_theta)}; }} (target);

node phase_rzz
  <- control: Qubit;
  <- target: Qubit;
  -> control: Qubit;
  -> target: Qubit;
  = @quantum.rzz {{ angle = {format_angle(-half_theta)}; }} ({{ inherit control; inherit target; }});

node feedback_control_rz
  <- control: Qubit;
  -> control: Qubit = @quantum.rz {{ angle = {format_angle(feedback_angle)}; }} (control);

node readout_rz_a
  <- control: Qubit;
  -> control: Qubit = @quantum.rz {{ angle = {format_angle(HALF_PI)}; }} (control);

node readout_sx
  <- control: Qubit;
  -> control: Qubit = @quantum.sx {{}} (control);

node readout_rz_b
  <- control: Qubit;
  -> control: Qubit = @quantum.rz {{ angle = {format_angle(HALF_PI)}; }} (control);

node measure_phase
  <- control: Qubit;
  -> phase_bit: Bit = @quantum.measure_z {{}} (control);

let prepare_eigenstate =
  prepare_target
    => target_x;

let h_control =
  h_control_rz_a
    => h_control_sx
    => h_control_rz_b;

let controlled_phase =
  (phase_control_rz <> phase_target_rz)
    => phase_rzz;

let readout_h =
  readout_rz_a
    => readout_sx
    => readout_rz_b;

let feedback_and_readout =
  feedback_control_rz
    => readout_h
    => measure_phase;

ibm_runtime_config
  => (
    (
      prepare_control
        => h_control
        => controlled_phase
        => feedback_and_readout
    )
    <>
    (
      prepare_eigenstate
        => controlled_phase
    )
)
"""


def format_angle(angle: float) -> str:
    if abs(angle) < 1e-15:
        return "0.0"
    return format(angle, ".17g")


def normalize_angle(angle: float) -> float:
    normalized = (angle + math.pi) % (2 * math.pi) - math.pi
    if abs(normalized) < 1e-15:
        return 0.0
    return normalized


def lower_bit_feedback_fraction(
    measured_bits: dict[int, int],
    bit_position: int,
    total_bits: int,
) -> Fraction:
    total = Fraction(0, 1)
    for lower_position in range(bit_position + 1, total_bits + 1):
        bit = measured_bits.get(lower_position, 0)
        total += Fraction(bit, 2 ** (lower_position - bit_position + 1))
    return total


def ideal_phase_bit(phase: Fraction, bit_position: int) -> int:
    return int(phase * (2 ** bit_position)) % 2


def choose_majority_bit(counts: dict[str, int]) -> int:
    zero = counts.get("0", 0)
    one = counts.get("1", 0)
    if zero == 0 and one == 0:
        raise IpeaError(f"IPEA round expected one-bit counts, got {counts}")
    return 1 if one > zero else 0


def estimate_phase(measured_bits: dict[int, int], total_bits: int) -> Fraction:
    return sum(Fraction(measured_bits.get(position, 0), 2**position) for position in range(1, total_bits + 1))


def bit_string(measured_bits: dict[int, int], total_bits: int) -> str:
    return "".join(str(measured_bits.get(position, 0)) for position in range(1, total_bits + 1))


def execution_label(args: argparse.Namespace) -> str:
    if args.dry_run:
        return "dry_run"
    if args.hardware:
        return "ibm_quantum_hardware"
    return "local_simulation"


def print_summary(result: JSON) -> None:
    print("Wire iterative phase estimation")
    print(f"execution: {result['execution']}")
    print(f"target phase: {result['phase']} ({result['phase_decimal']:.6f})")
    print(f"bits: {result['bits']}")
    print(f"shots per round: {result['shots']}")
    if result.get("qpu_usage_seconds") is not None:
        print(f"qpu usage: {result['qpu_usage_seconds']:.3f}s")
    print()
    print("Rounds:")
    rows = []
    for item in result["rounds"]:
        counts = item.get("counts")
        if counts is None:
            counts_text = "dry-run"
        else:
            counts_text = ",".join(f"{bits}:{count}" for bits, count in sorted(counts.items()))
        rows.append(
            (
                str(item["round"]),
                str(item["bit_position"]),
                str(item["power"]),
                f"{item['feedback_angle']:.6f}",
                str(item["chosen_bit"]),
                counts_text,
                f"{item['estimate_after_round']:.6f}",
            )
        )
    print_table(
        ("round", "bit", "power", "feedback", "chosen", "counts", "estimate"),
        rows,
    )
    print()
    print("Result:")
    print(f"  estimated bits: {result['estimated_bits']}")
    print(
        "  estimated phase: "
        f"{result['estimated_phase']} ({result['estimated_phase_decimal']:.6f})"
    )
    print(f"  absolute error: {result['absolute_error']:.6f}")


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
