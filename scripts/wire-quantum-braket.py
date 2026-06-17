#!/usr/bin/env python3
"""Submit Wire-authored quantum circuits to Amazon Braket.

This runner is intentionally separate from the local Qiskit Aer bridge and
the IBM Runtime REST bridge. It uses AWS CLI v2 so the Cortex dev shell does
not need the Amazon Braket Python SDK.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import math
import os
import subprocess
import sys
import time
from collections import Counter
from datetime import datetime
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path
from typing import Any


JSON = dict[str, Any]
DEFAULT_DEVICE_ARN = "arn:aws:braket:::device/quantum-simulator/amazon/sv1"
DEFAULT_REGION = "us-east-1"
DEFAULT_PREFIX = "cortex/dev"
DEFAULT_PROFILE = "cortex-braket"
TERMINAL_TASK_STATUSES = {"COMPLETED", "FAILED", "CANCELLED", "CANCELED"}
RUNNING_TASK_STATUSES = {"CREATED", "QUEUED", "RUNNING"}
TASK_STATUS_LABELS = {
    "COMPLETED": "Completed",
    "FAILED": "Failed",
    "CANCELLED": "Cancelled",
    "CANCELED": "Cancelled",
    "CREATED": "Created",
    "QUEUED": "Queued",
    "RUNNING": "Running",
}
MIN_SIMULATOR_BILLING_SECONDS = Decimal("3")
QPU_TASK_PRICE_USD = Decimal("0.30000")
QPU_SHOT_PRICES_USD = {
    "qpu/aqt/ibex": Decimal("0.02350"),
    "qpu/aqt/ibex-q1": Decimal("0.02350"),
    "qpu/ionq/forte": Decimal("0.08000"),
    "qpu/iqm/emerald": Decimal("0.00160"),
    "qpu/iqm/garnet": Decimal("0.00145"),
    "qpu/quera/aquila": Decimal("0.01000"),
    "qpu/rigetti/cepheus": Decimal("0.000425"),
}
SIMULATOR_MINUTE_PRICES_USD = {
    "quantum-simulator/amazon/sv1": Decimal("0.075"),
}


def main() -> int:
    quantum = load_quantum_support()
    parser = argparse.ArgumentParser(
        description="Run a Wire quantum circuit on Amazon Braket through AWS CLI.",
    )
    parser.add_argument(
        "input",
        help="Wire source file, compiled Wire JSON artifact, or '-' for compiled JSON on stdin.",
    )
    parser.add_argument(
        "--wire-bin",
        default=os.environ.get("WIRE_BIN", "wire"),
        help="Wire CLI to use when the input is a .wire source file.",
    )
    parser.add_argument(
        "--return",
        dest="wire_return",
        help="Compile the named Wire file-return or graph binding from a .wire source file.",
    )
    parser.add_argument(
        "--backend",
        help="Braket backend alias or device ARN. 'sv1' is the default.",
    )
    parser.add_argument(
        "--device-arn",
        default=os.environ.get("CORTEX_BRAKET_DEVICE_ARN"),
        help="Braket device ARN. Defaults to SV1 unless --backend is provided.",
    )
    parser.add_argument(
        "--s3-bucket",
        default=os.environ.get("CORTEX_BRAKET_BUCKET"),
        help="S3 bucket where Braket writes task results.",
    )
    parser.add_argument(
        "--s3-prefix",
        default=os.environ.get("CORTEX_BRAKET_PREFIX", DEFAULT_PREFIX),
        help="S3 key prefix for Braket task results.",
    )
    parser.add_argument(
        "--region",
        default=default_region(),
        help="AWS region used for Braket API calls.",
    )
    parser.add_argument(
        "--profile",
        default=os.environ.get("AWS_PROFILE", DEFAULT_PROFILE),
        help="AWS CLI profile. Use an empty string to rely on ambient AWS credentials.",
    )
    parser.add_argument(
        "--aws-bin",
        default=os.environ.get("AWS_BIN", "aws"),
        help="AWS CLI executable.",
    )
    parser.add_argument("--shots", type=positive_int, default=100)
    parser.add_argument(
        "--poll-interval",
        type=positive_int,
        default=5,
        help="Polling interval in seconds.",
    )
    parser.add_argument(
        "--timeout",
        type=positive_int,
        default=900,
        help="Polling timeout in seconds.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Build the Braket task request locally without queueing a task.",
    )
    parser.add_argument(
        "--emit-request",
        action="store_true",
        help="Include the Braket action payload in dry-run output.",
    )
    parser.add_argument(
        "--submit-only",
        action="store_true",
        help="Submit the task and print its ARN without polling for results.",
    )
    parser.add_argument(
        "--confirm-hardware",
        action="store_true",
        help="Required before this runner can queue a paid Braket task.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="json_output",
        help="Print machine-readable JSON instead of the human summary.",
    )
    args = parser.parse_args()

    try:
        compiled = quantum.load_compiled_circuit(args.input, args.wire_bin, args.wire_return)
        plan = quantum.build_quantum_plan(compiled)
        plan["backend_family"] = "amazon_braket"
        device_arn = resolve_device_arn(args.backend, args.device_arn)
        qasm = build_openqasm3(plan, quantum, device_arn)
        action = build_action_payload(qasm)
        will_submit = not args.dry_run and not args.emit_request
        if will_submit and not args.confirm_hardware:
            raise quantum.WireQuantumError(
                "refusing to submit an Amazon Braket task without "
                "--confirm-hardware; use --dry-run to inspect the request locally"
            )
        if args.dry_run or args.emit_request:
            cost_estimate = estimate_task_cost(device_arn, args.shots, task=None)
            result = {
                "execution": "dry_run",
                "source": args.input,
                "backend": device_label(device_arn),
                "backend_family": "amazon_braket",
                "device_arn": device_arn,
                "region": args.region,
                "profile": args.profile or None,
                "s3_bucket": args.s3_bucket,
                "s3_prefix": args.s3_prefix,
                "shots": args.shots,
                "plan": plan,
                "openqasm3": qasm,
                "estimated_cost_usd": cost_estimate["estimated_cost_usd"],
                "cost_estimate": cost_estimate,
                "request_payload": (
                    request_payload(device_arn, args.s3_bucket, args.s3_prefix, args.shots, action)
                    if args.emit_request
                    else None
                ),
            }
            if args.json_output:
                quantum.print_json(result)
            else:
                print_request_summary(args.input, result, qasm, include_request=args.emit_request)
            return 0

        result = execute_braket_plan(
            plan,
            qasm,
            source=args.input,
            device_arn=device_arn,
            s3_bucket=required_s3_bucket(args.s3_bucket, quantum),
            s3_prefix=args.s3_prefix,
            region=args.region,
            profile=args.profile,
            aws_bin=args.aws_bin,
            shots=args.shots,
            poll_interval=args.poll_interval,
            timeout_seconds=args.timeout,
            submit_only=args.submit_only,
            quiet=args.json_output,
            quantum=quantum,
        )
        if args.json_output:
            quantum.print_json(result)
        elif args.submit_only:
            print_submission_summary(args.input, result)
        else:
            print_hardware_run_summary(args.input, result, quantum)
        return 0
    except quantum.WireQuantumError as exc:
        print(f"wire-quantum-braket: {exc}", file=sys.stderr)
        return 1


def load_quantum_support() -> Any:
    scripts_dir = Path(
        os.environ.get("WIRE_QUANTUM_SCRIPTS_DIR", str(Path(__file__).resolve().parent))
    )
    module_path = scripts_dir / "wire-quantum-qiskit.py"
    spec = importlib.util.spec_from_file_location("wire_quantum_qiskit_support", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load quantum support module from {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def positive_int(raw: str) -> int:
    value = int(raw)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return value


def default_region() -> str:
    return (
        os.environ.get("CORTEX_BRAKET_REGION")
        or os.environ.get("AWS_REGION")
        or os.environ.get("AWS_DEFAULT_REGION")
        or DEFAULT_REGION
    )


def resolve_device_arn(backend: str | None, device_arn: str | None) -> str:
    if device_arn:
        return device_arn
    if backend:
        normalized = backend.strip().lower()
        if normalized == "sv1":
            return DEFAULT_DEVICE_ARN
        if normalized == "tn1":
            return "arn:aws:braket:::device/quantum-simulator/amazon/tn1"
        if normalized == "dm1":
            return "arn:aws:braket:::device/quantum-simulator/amazon/dm1"
        if backend.startswith("arn:"):
            return backend
    return DEFAULT_DEVICE_ARN


def device_label(device_arn: str) -> str:
    return device_arn.rsplit("/", maxsplit=1)[-1]


def required_s3_bucket(bucket: str | None, quantum: Any) -> str:
    if bucket:
        return bucket
    raise quantum.WireQuantumError(
        "Amazon Braket execution needs CORTEX_BRAKET_BUCKET or --s3-bucket"
    )


def build_openqasm3(plan: JSON, quantum: Any, device_arn: str) -> str:
    measurements = plan["measurements"]
    if not measurements:
        raise quantum.WireQuantumError("Amazon Braket execution requires at least one measurement")

    last_gate_use_by_wire = last_non_measure_use_by_wire(plan["operations"])
    lower_cnot_via_cz = uses_iqm_cz_entangler(device_arn)
    measured_wires = {int(measurement["wire"]) for measurement in measurements}
    extra_measurements = [
        wire for wire in sorted(plan["qubits"]) if int(wire) not in measured_wires
    ]
    classical_bits = len(measurements) + len(extra_measurements)

    lines = [
        "OPENQASM 3;",
        f"qubit[{plan['num_qubits']}] q;",
        f"bit[{classical_bits}] c;",
    ]
    deferred_measurements: list[JSON] = []
    for ix, operation in enumerate(plan["operations"]):
        gate = operation["gate"]
        if gate == "prepare_zero":
            continue
        if gate == "h":
            lines.append(f"h q[{operation['wire']}];")
        elif gate == "rz":
            if not math.isclose(operation["angle"], 0.0, abs_tol=1e-15):
                lines.append(f"rz({operation['angle']}) q[{operation['wire']}];")
        elif gate == "sx":
            lines.append(f"v q[{operation['wire']}];")
        elif gate == "x":
            lines.append(f"x q[{operation['wire']}];")
        elif gate == "cnot":
            append_cnot(
                lines,
                operation["control"],
                operation["target"],
                lower_cnot_via_cz,
            )
        elif gate == "cz":
            lines.append(f"cz q[{operation['control']}], q[{operation['target']}];")
        elif gate == "rzz":
            append_rzz_decomposition(
                lines,
                operation["angle"],
                operation["control"],
                operation["target"],
                lower_cnot_via_cz,
            )
        elif gate == "measure_z":
            wire = int(operation["wire"])
            if ix >= last_gate_use_by_wire.get(wire, -1):
                deferred_measurements.append(operation)
            else:
                lines.append(measurement_line(operation))
        else:
            raise quantum.WireQuantumError(f"unsupported planned gate {gate}")

    if can_measure_full_register(plan, deferred_measurements, extra_measurements):
        lines.append("c = measure q;")
    else:
        for operation in sorted(deferred_measurements, key=lambda item: int(item["classical_bit"])):
            lines.append(measurement_line(operation))

        offset = len(measurements)
        for ix, wire in enumerate(extra_measurements):
            lines.append(f"c[{offset + ix}] = measure q[{wire}];")

    return "\n".join(lines) + "\n"


def uses_iqm_cz_entangler(device_arn: str) -> bool:
    return "/qpu/iqm/" in device_arn.lower()


def can_measure_full_register(
    plan: JSON,
    deferred_measurements: list[JSON],
    extra_measurements: list[int],
) -> bool:
    measurements = plan["measurements"]
    if extra_measurements:
        return False
    if len(deferred_measurements) != len(measurements):
        return False
    if len(measurements) != int(plan["num_qubits"]):
        return False
    for measurement in measurements:
        if int(measurement["classical_bit"]) != int(measurement["wire"]):
            return False
    return True


def last_non_measure_use_by_wire(operations: list[JSON]) -> dict[int, int]:
    last_use: dict[int, int] = {}
    for ix, operation in enumerate(operations):
        gate = operation["gate"]
        if gate == "measure_z":
            continue
        for wire in operation_wires(operation):
            last_use[wire] = ix
    return last_use


def operation_wires(operation: JSON) -> list[int]:
    gate = operation["gate"]
    if gate in {"prepare_zero", "h", "rz", "sx", "x", "measure_z"}:
        return [int(operation["wire"])]
    if gate in {"cnot", "cz", "rzz"}:
        return [int(operation["control"]), int(operation["target"])]
    return []


def measurement_line(operation: JSON) -> str:
    return f"c[{operation['classical_bit']}] = measure q[{operation['wire']}];"


def append_cnot(lines: list[str], control: int, target: int, via_cz: bool) -> None:
    if not via_cz:
        lines.append(f"cnot q[{control}], q[{target}];")
        return
    append_self_inverse_h(lines, target)
    lines.append(f"cz q[{control}], q[{target}];")
    append_self_inverse_h(lines, target)


def append_self_inverse_h(lines: list[str], wire: int) -> None:
    line = f"h q[{wire}];"
    if lines and lines[-1] == line:
        lines.pop()
    else:
        lines.append(line)


def append_rzz_decomposition(
    lines: list[str],
    angle: float,
    control: int,
    target: int,
    lower_cnot_via_cz: bool,
) -> None:
    append_cnot(lines, control, target, lower_cnot_via_cz)
    lines.append(f"rz({angle}) q[{target}];")
    append_cnot(lines, control, target, lower_cnot_via_cz)


def build_action_payload(qasm: str) -> JSON:
    return {
        "braketSchemaHeader": {
            "name": "braket.ir.openqasm.program",
            "version": "1",
        },
        "source": qasm,
    }


def request_payload(
    device_arn: str,
    s3_bucket: str | None,
    s3_prefix: str,
    shots: int,
    action: JSON,
) -> JSON:
    return {
        "deviceArn": device_arn,
        "shots": shots,
        "outputS3Bucket": s3_bucket,
        "outputS3KeyPrefix": s3_prefix,
        "action": action,
    }


def execute_braket_plan(
    plan: JSON,
    qasm: str,
    source: str,
    device_arn: str,
    s3_bucket: str,
    s3_prefix: str,
    region: str,
    profile: str | None,
    aws_bin: str,
    shots: int,
    poll_interval: int,
    timeout_seconds: int,
    submit_only: bool,
    quiet: bool,
    quantum: Any,
) -> JSON:
    action = build_action_payload(qasm)
    run_prefix = run_s3_prefix(s3_prefix)
    task_arn = create_quantum_task(
        device_arn,
        s3_bucket,
        run_prefix,
        shots,
        action,
        aws_bin,
        profile,
        region,
        quantum,
    )
    pending_cost_estimate = estimate_task_cost(device_arn, shots, task=None)
    if submit_only:
        return {
            "execution": "submitted",
            "source": source,
            "backend": device_label(device_arn),
            "backend_family": "amazon_braket",
            "device_arn": device_arn,
            "task_arn": task_arn,
            "region": region,
            "profile": profile or None,
            "s3_bucket": s3_bucket,
            "s3_prefix": run_prefix,
            "shots": shots,
            "plan": plan,
            "estimated_cost_usd": pending_cost_estimate["estimated_cost_usd"],
            "cost_estimate": pending_cost_estimate,
        }

    task = poll_task(
        task_arn,
        aws_bin,
        profile,
        region,
        poll_interval,
        timeout_seconds,
        quiet,
        quantum,
    )
    result_uri = task_result_uri(task, quantum)
    raw_result = fetch_s3_json(result_uri, aws_bin, profile, region, quantum)
    counts = extract_counts(raw_result, plan["measurements"])
    if counts is None:
        raise quantum.WireQuantumError(
            f"Braket task {task_arn} returned an unsupported result shape"
        )
    complete_counts = quantum.complete_counts(counts, len(plan["measurements"]))
    cost_estimate = estimate_task_cost(device_arn, shots, task)
    return {
        "execution": "hardware",
        "source": source,
        "backend": device_label(device_arn),
        "backend_family": "amazon_braket",
        "device_arn": device_arn,
        "task_arn": task_arn,
        "status": public_task_status(task),
        "shots": shots,
        "plan": plan,
        "counts": counts,
        "complete_counts": complete_counts,
        "labeled_counts": quantum.labeled_counts(counts, plan["measurements"]),
        "complete_labeled_counts": quantum.labeled_counts(
            complete_counts,
            plan["measurements"],
        ),
        "output_counts": quantum.output_counts(counts, plan["measurements"]),
        "complete_output_counts": quantum.output_counts(
            complete_counts,
            plan["measurements"],
        ),
        "region": region,
        "profile": profile or None,
        "s3_bucket": s3_bucket,
        "s3_prefix": run_prefix,
        "result_s3_uri": result_uri,
        "qpu_usage_seconds": None,
        "estimated_cost_usd": cost_estimate["estimated_cost_usd"],
        "cost_estimate": cost_estimate,
    }


def run_s3_prefix(prefix: str) -> str:
    clean = prefix.strip("/")
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    return f"{clean}/wire-openqasm-{stamp}" if clean else f"wire-openqasm-{stamp}"


def estimate_task_cost(device_arn: str, shots: int, task: JSON | None) -> JSON:
    override = override_qpu_cost_estimate(shots)
    if override is not None:
        return override

    normalized = device_arn.lower()
    if "device/qpu/" in normalized:
        return estimate_qpu_task_cost(normalized, shots, task)
    if "quantum-simulator/amazon/" in normalized:
        return estimate_simulator_task_cost(normalized, task)
    return unavailable_cost_estimate(
        "unknown_device_pricing",
        "No embedded Braket pricing rule matched this device ARN.",
    )


def override_qpu_cost_estimate(shots: int) -> JSON | None:
    task_price = decimal_env("CORTEX_BRAKET_TASK_PRICE_USD")
    shot_price = decimal_env("CORTEX_BRAKET_SHOT_PRICE_USD")
    if task_price is None and shot_price is None:
        return None
    if task_price is None or shot_price is None:
        return unavailable_cost_estimate(
            "incomplete_price_override",
            "Set both CORTEX_BRAKET_TASK_PRICE_USD and CORTEX_BRAKET_SHOT_PRICE_USD.",
        )
    return qpu_cost_estimate(
        task_price,
        shot_price,
        shots,
        "environment_override",
        [
            "Estimated from CORTEX_BRAKET_TASK_PRICE_USD and "
            "CORTEX_BRAKET_SHOT_PRICE_USD.",
            "Excludes S3, taxes, discounts, credits, reservations, and other AWS charges.",
        ],
    )


def estimate_qpu_task_cost(normalized_device_arn: str, shots: int, task: JSON | None) -> JSON:
    shot_price = None
    for device_key, price in QPU_SHOT_PRICES_USD.items():
        if device_key in normalized_device_arn:
            shot_price = price
            break
    if shot_price is None:
        return unavailable_cost_estimate(
            "unknown_qpu_pricing",
            "No embedded per-shot price is available for this QPU.",
        )
    successful_shots = task_successful_shots(task)
    priced_shots = successful_shots if successful_shots is not None else shots
    return qpu_cost_estimate(
        QPU_TASK_PRICE_USD,
        shot_price,
        priced_shots,
        "embedded_public_braket_qpu_pricing",
        [
            "Estimated from public Amazon Braket QPU per-task and per-shot pricing.",
            "Excludes S3, taxes, discounts, credits, reservations, and other AWS charges.",
        ],
    )


def qpu_cost_estimate(
    task_price: Decimal,
    shot_price: Decimal,
    priced_shots: int,
    pricing_source: str,
    notes: list[str],
) -> JSON:
    amount = task_price + (shot_price * Decimal(priced_shots))
    return cost_estimate_result(
        amount,
        "qpu_task_and_shot",
        pricing_source,
        {
            "task_count": 1,
            "priced_shots": priced_shots,
            "task_price_usd": decimal_text(task_price),
            "shot_price_usd": decimal_text(shot_price),
        },
        notes,
    )


def estimate_simulator_task_cost(normalized_device_arn: str, task: JSON | None) -> JSON:
    override_rate = decimal_env("CORTEX_BRAKET_SIMULATOR_MINUTE_PRICE_USD")
    simulator_key = None
    minute_price = override_rate
    for device_key, price in SIMULATOR_MINUTE_PRICES_USD.items():
        if device_key in normalized_device_arn:
            simulator_key = device_key.rsplit("/", maxsplit=1)[-1]
            minute_price = minute_price if minute_price is not None else price
            break
    if minute_price is None:
        return unavailable_cost_estimate(
            "unknown_simulator_pricing",
            "No embedded per-minute price is available for this managed simulator.",
        )
    if task is None:
        return unavailable_cost_estimate(
            "simulator_duration_unavailable_before_completion",
            "Managed simulator estimates require task start/end metadata after completion.",
        )
    duration = task_wall_clock_seconds(task)
    if duration is None:
        return unavailable_cost_estimate(
            "simulator_duration_unavailable",
            "The Braket task metadata did not include parseable createdAt and endedAt values.",
        )
    billed_seconds = max(duration, MIN_SIMULATOR_BILLING_SECONDS)
    amount = minute_price * billed_seconds / Decimal(60)
    source = (
        "environment_override"
        if override_rate is not None
        else f"embedded_public_braket_{simulator_key}_pricing"
    )
    return cost_estimate_result(
        amount,
        "managed_simulator_duration",
        source,
        {
            "duration_seconds": decimal_text(duration),
            "billed_duration_seconds": decimal_text(billed_seconds),
            "minute_price_usd": decimal_text(minute_price),
        },
        [
            "Estimated from task createdAt/endedAt metadata and public managed-simulator pricing.",
            "Braket bills managed simulators by execution duration with a minimum duration; "
            "createdAt/endedAt may include non-billable service overhead.",
            "Excludes S3, taxes, discounts, credits, free-tier credits, and other AWS charges.",
        ],
    )


def task_successful_shots(task: JSON | None) -> int | None:
    if task is None:
        return None
    value = task.get("numSuccessfulShots")
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value


def task_wall_clock_seconds(task: JSON) -> Decimal | None:
    created = parse_task_time(task.get("createdAt"))
    ended = parse_task_time(task.get("endedAt"))
    if created is None or ended is None:
        return None
    seconds = Decimal(str((ended - created).total_seconds()))
    return seconds if seconds > 0 else None


def parse_task_time(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def decimal_env(name: str) -> Decimal | None:
    value = os.environ.get(name)
    if value is None or value == "":
        return None
    try:
        parsed = Decimal(value)
    except InvalidOperation:
        return None
    return parsed if parsed >= 0 else None


def cost_estimate_result(
    amount: Decimal,
    pricing_model: str,
    pricing_source: str,
    detail: JSON,
    notes: list[str],
) -> JSON:
    rounded = amount.quantize(Decimal("0.0000000001"), rounding=ROUND_HALF_UP)
    return {
        "status": "estimated",
        "currency": "USD",
        "estimated_cost_usd": float(rounded),
        "estimated_cost_usd_text": decimal_text(rounded),
        "pricing_model": pricing_model,
        "pricing_source": pricing_source,
        **detail,
        "notes": notes,
    }


def unavailable_cost_estimate(reason: str, note: str) -> JSON:
    return {
        "status": "unavailable",
        "currency": "USD",
        "estimated_cost_usd": None,
        "estimated_cost_usd_text": None,
        "pricing_model": None,
        "pricing_source": None,
        "reason": reason,
        "notes": [note],
    }


def decimal_text(value: Decimal) -> str:
    return format(value.normalize(), "f")


def create_quantum_task(
    device_arn: str,
    s3_bucket: str,
    s3_prefix: str,
    shots: int,
    action: JSON,
    aws_bin: str,
    profile: str | None,
    region: str,
    quantum: Any,
) -> str:
    command = aws_command(
        aws_bin,
        profile,
        region,
        [
            "braket",
            "create-quantum-task",
            "--device-arn",
            device_arn,
            "--shots",
            str(shots),
            "--output-s3-bucket",
            s3_bucket,
            "--output-s3-key-prefix",
            s3_prefix,
            "--action",
            json.dumps(action),
            "--query",
            "quantumTaskArn",
            "--output",
            "text",
        ],
    )
    task_arn = run_text(command, quantum).strip()
    if not task_arn.startswith("arn:aws:braket:"):
        raise quantum.WireQuantumError("Braket task creation did not return a task ARN")
    return task_arn


def poll_task(
    task_arn: str,
    aws_bin: str,
    profile: str | None,
    region: str,
    poll_interval: int,
    timeout_seconds: int,
    quiet: bool,
    quantum: Any,
) -> JSON:
    deadline = time.monotonic() + timeout_seconds
    last_task: JSON | None = None
    while True:
        task = get_quantum_task(task_arn, aws_bin, profile, region, quantum)
        last_task = task
        status = str(task.get("status", "UNKNOWN"))
        if status in TERMINAL_TASK_STATUSES:
            if status != "COMPLETED":
                detail = task_failure_detail(task)
                suffix = f": {detail}" if detail else ""
                raise quantum.WireQuantumError(
                    f"Braket task {task_arn} ended with status {status}{suffix}"
                )
            return task
        if status not in RUNNING_TASK_STATUSES:
            raise quantum.WireQuantumError(
                f"Braket task {task_arn} returned unexpected status {status}"
            )
        if time.monotonic() >= deadline:
            last_status = last_task.get("status", "UNKNOWN") if last_task else "UNKNOWN"
            raise quantum.WireQuantumError(
                f"timed out waiting for Braket task {task_arn}; "
                f"last status was {last_status}"
            )
        if not quiet:
            sys.stderr.write(f"Braket task status={status}; polling again.\n")
        time.sleep(poll_interval)


def get_quantum_task(
    task_arn: str,
    aws_bin: str,
    profile: str | None,
    region: str,
    quantum: Any,
) -> JSON:
    command = aws_command(
        aws_bin,
        profile,
        region,
        [
            "braket",
            "get-quantum-task",
            "--quantum-task-arn",
            task_arn,
            "--output",
            "json",
        ],
    )
    return run_json(command, quantum)


def task_result_uri(task: JSON, quantum: Any) -> str:
    bucket = task.get("outputS3Bucket")
    directory = task.get("outputS3Directory")
    if not isinstance(bucket, str) or not bucket:
        raise quantum.WireQuantumError("Braket task metadata did not include outputS3Bucket")
    if not isinstance(directory, str) or not directory:
        raise quantum.WireQuantumError("Braket task metadata did not include outputS3Directory")
    return f"s3://{bucket}/{directory.rstrip('/')}/results.json"


def fetch_s3_json(
    uri: str,
    aws_bin: str,
    profile: str | None,
    region: str,
    quantum: Any,
) -> Any:
    command = aws_command(aws_bin, profile, region, ["s3", "cp", uri, "-"])
    return json.loads(run_text(command, quantum))


def aws_command(
    aws_bin: str,
    profile: str | None,
    region: str,
    args: list[str],
) -> list[str]:
    command = [aws_bin, *args]
    if profile:
        command.extend(["--profile", profile])
    if region:
        command.extend(["--region", region])
    return command


def run_json(command: list[str], quantum: Any) -> JSON:
    text = run_text(command, quantum)
    try:
        value = json.loads(text)
    except json.JSONDecodeError as exc:
        raise quantum.WireQuantumError(
            f"command returned non-JSON output: {display_command(command)}"
        ) from exc
    if not isinstance(value, dict):
        raise quantum.WireQuantumError(
            f"command did not return a JSON object: {display_command(command)}"
        )
    return value


def run_text(command: list[str], quantum: Any) -> str:
    proc = subprocess.run(
        command,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip()
        suffix = f": {detail}" if detail else ""
        raise quantum.WireQuantumError(
            f"command failed ({proc.returncode}): {display_command(command)}{suffix}"
        )
    return proc.stdout


def display_command(command: list[str]) -> str:
    return " ".join(command[:4] + (["..."] if len(command) > 4 else []))


def public_task_status(task: JSON) -> str:
    status = str(task.get("status", "UNKNOWN"))
    return TASK_STATUS_LABELS.get(status, "Unknown")


def task_failure_detail(task: JSON) -> str | None:
    value = task.get("failureReason")
    if isinstance(value, str) and value:
        return " ".join(value.split())[:500]
    return None


def extract_counts(raw_result: Any, measurements: list[JSON]) -> dict[str, int] | None:
    width = len(measurements)
    rows = find_measurement_rows(raw_result)
    if rows is not None:
        return counts_from_rows(rows, measurements)
    direct = find_direct_counts(raw_result, width)
    if direct is not None:
        return direct
    return None


def find_measurement_rows(value: Any) -> list[Any] | None:
    if isinstance(value, dict):
        measurements = value.get("measurements")
        if isinstance(measurements, list):
            return measurements
        for child in value.values():
            found = find_measurement_rows(child)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find_measurement_rows(child)
            if found is not None:
                return found
    return None


def counts_from_rows(rows: list[Any], measurements: list[JSON]) -> dict[str, int] | None:
    width = len(measurements)
    if width <= 0:
        return None
    counter: Counter[str] = Counter()
    classical_bits = [int(measurement["classical_bit"]) for measurement in measurements]
    for row in rows:
        if not isinstance(row, list):
            return None
        if any(bit_index >= len(row) for bit_index in classical_bits):
            return None
        try:
            selected = [int(row[bit_index]) for bit_index in classical_bits]
        except (TypeError, ValueError):
            return None
        if any(bit not in (0, 1) for bit in selected):
            return None
        counter["".join(str(bit) for bit in selected)[::-1]] += 1
    return dict(sorted(counter.items()))


def find_direct_counts(value: Any, width: int) -> dict[str, int] | None:
    if isinstance(value, dict):
        for key in ("measurementCounts", "measurement_counts", "counts"):
            candidate = normalize_counts(value.get(key), width)
            if candidate is not None:
                return candidate
        for child in value.values():
            found = find_direct_counts(child, width)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = find_direct_counts(child, width)
            if found is not None:
                return found
    return None


def normalize_counts(value: Any, width: int) -> dict[str, int] | None:
    if not isinstance(value, dict) or not value:
        return None
    counts: dict[str, int] = {}
    for raw_bits, raw_count in value.items():
        if not isinstance(raw_bits, str):
            return None
        bits = raw_bits.replace(" ", "")
        if len(bits) != width or set(bits) - {"0", "1"}:
            return None
        if isinstance(raw_count, bool) or not isinstance(raw_count, (int, float)):
            return None
        if isinstance(raw_count, float) and not raw_count.is_integer():
            return None
        counts[bits] = int(raw_count)
    return dict(sorted(counts.items()))


def print_request_summary(
    source: str,
    result: JSON,
    openqasm3: str,
    include_request: bool,
) -> None:
    print("Wire Amazon Braket request")
    emit_field("source", source)
    print("execution: dry run (not submitted)")
    emit_field("device", result["device_arn"])
    emit_field("region", result["region"])
    emit_field("profile", result["profile"] or "ambient")
    emit_field("s3", f"s3://{result['s3_bucket']}/{result['s3_prefix']}")
    emit_field("shots", result["shots"])
    emit_cost_estimate(result["cost_estimate"])
    emit_field("qubits", result["plan"]["num_qubits"])
    emit_field("measurements", format_measurements(result["plan"]))
    print()
    print("What would happen:")
    print("Wire compiles the graph into typed quantum executor nodes.")
    print("This runner lowers those nodes into one Braket OpenQASM 3 task.")
    print("No Braket task was queued.")
    print()
    print("OpenQASM 3:")
    emit_block(openqasm3)
    if include_request:
        print()
        print("Braket payload:")
        emit_line(json.dumps(result["request_payload"], indent=2, sort_keys=True))


def print_submission_summary(source: str, result: JSON) -> None:
    print("Wire Amazon Braket task")
    emit_field("source", source)
    print("execution: submitted (not polled)")
    emit_field("device", result["device_arn"])
    emit_field("task", result["task_arn"])
    emit_field("region", result["region"])
    emit_field("s3", f"s3://{result['s3_bucket']}/{result['s3_prefix']}")
    emit_field("shots", result["shots"])
    emit_cost_estimate(result["cost_estimate"])
    print()
    print("The task is now queued with Amazon Braket.")


def print_hardware_run_summary(source: str, result: JSON, quantum: Any) -> None:
    plan = result["plan"]
    print("Wire Amazon Braket run")
    emit_field("source", source)
    print("execution: Amazon Braket OpenQASM")
    emit_field("device", result["device_arn"])
    emit_field("task", result["task_arn"])
    emit_field("status", result["status"])
    emit_field("region", result["region"])
    emit_field("result", result["result_s3_uri"])
    emit_field("shots", result["shots"])
    emit_cost_estimate(result["cost_estimate"])
    emit_field("qubits", plan["num_qubits"])
    emit_field("measurements", format_measurements(plan))
    print()
    print("What happened:")
    print("Wire compiled the graph into typed quantum executor nodes.")
    print("The runner lowered the admitted gates into Braket OpenQASM 3 and")
    print("submitted that circuit through AWS CLI.")
    print()
    print("Result:")
    emit_line(quantum.format_result_table(result["counts"], plan["measurements"], result["shots"]))


def format_measurements(plan: JSON) -> str:
    measurements = plan["measurements"]
    if not measurements:
        return "none"
    return ", ".join(
        f"{measurement['output']}=q[{measurement['wire']}]" for measurement in measurements
    )


def emit_field(label: str, value: Any) -> None:
    emit_raw(f"{label}: {value}\n")


def emit_cost_estimate(cost_estimate: JSON) -> None:
    if cost_estimate.get("status") == "estimated":
        emit_field("estimated cost", f"${cost_estimate['estimated_cost_usd_text']} USD")
    else:
        emit_field("estimated cost", f"unavailable ({cost_estimate.get('reason')})")


def emit_line(value: str) -> None:
    emit_raw(value)
    if not value.endswith("\n"):
        emit_raw("\n")


def emit_block(value: str) -> None:
    emit_raw(value)


def emit_raw(value: str) -> None:
    sys.stdout.flush()
    os.write(sys.stdout.fileno(), value.encode("utf-8"))


if __name__ == "__main__":
    raise SystemExit(main())
