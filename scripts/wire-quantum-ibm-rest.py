#!/usr/bin/env python3
"""Submit Wire-authored quantum circuits to IBM Quantum Runtime REST.

This runner is intentionally separate from the local Qiskit Aer bridge. It
requires an explicit credentials config path and an explicit hardware
confirmation flag before it can queue a provider job.
"""

from __future__ import annotations

import argparse
import base64
import importlib.util
import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path
from typing import Any


JSON = dict[str, Any]
IBM_API_BASE_URL = "https://quantum.cloud.ibm.com/api/v1"
IBM_IAM_TOKEN_URL = "https://iam.cloud.ibm.com/identity/token"
IBM_API_VERSION = "2026-03-15"
IAM_API_KEY_GRANT = "urn:ibm:params:oauth:grant-type:apikey"
PLACEHOLDER_MARKERS = ("REPLACE_WITH", "YOUR_", "<")
BITSTRING_RE = re.compile(r"^[01][01 ]*$")
USER_AGENT = "cortex-wire-quantum/0.1"


def main() -> int:
    quantum = load_quantum_support()
    parser = argparse.ArgumentParser(
        description="Run a Wire quantum circuit on IBM Quantum Runtime through REST.",
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
        "--config",
        help="Override the config path carried by @quantum.ibm_runtime_config.",
    )
    parser.add_argument(
        "--backend",
        help="Override the config backend. Use 'least_busy' to auto-select online hardware.",
    )
    parser.add_argument("--shots", type=positive_int, default=100)
    parser.add_argument(
        "--poll-interval",
        type=positive_int,
        help="Polling interval in seconds. Defaults to the config file value or 10.",
    )
    parser.add_argument(
        "--timeout",
        type=positive_int,
        help="Polling timeout in seconds. Defaults to the config file value or 900.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Build the REST request locally without requesting credentials or queueing a job.",
    )
    parser.add_argument(
        "--emit-request",
        action="store_true",
        help="Include the REST sampler payload in the output without submitting it.",
    )
    parser.add_argument(
        "--submit-only",
        action="store_true",
        help="Submit the job and print its id without polling for results.",
    )
    parser.add_argument(
        "--confirm-hardware",
        action="store_true",
        help="Required before this runner can queue an IBM Quantum hardware job.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="json_output",
        help="Print machine-readable JSON instead of the human summary.",
    )
    args = parser.parse_args()

    try:
        compiled = quantum.load_compiled_circuit(args.input, args.wire_bin)
        plan = quantum.build_quantum_plan(compiled)
        config_path = select_config_path(args.input, args.config, plan, quantum)
        will_submit = not args.dry_run and not args.emit_request
        if will_submit and not args.confirm_hardware:
            raise quantum.WireQuantumError(
                "refusing to submit an IBM Quantum hardware job without "
                "--confirm-hardware; use --dry-run to inspect the request locally"
            )
        config = load_runtime_config(
            config_path,
            require_credentials=will_submit,
            quantum=quantum,
        )
        qasm = build_openqasm3(plan, quantum)
        backend_request = args.backend or config["backend"]
        payload = build_sampler_payload(backend_request, qasm, args.shots)

        if args.dry_run or args.emit_request:
            result = {
                "execution": "dry_run",
                "source": args.input,
                "config_path": str(config_path),
                "backend_request": backend_request,
                "shots": args.shots,
                "plan": plan,
                "openqasm3": qasm,
                "request_payload": payload,
            }
            if args.json_output:
                quantum.print_json(result)
            else:
                print_request_summary(result, include_payload=args.emit_request)
            return 0

        token = fetch_iam_token(config, quantum)
        backend = resolve_backend(backend_request, config, token, plan, quantum)
        payload = build_sampler_payload(backend, qasm, args.shots)
        submitted = submit_job(config, token, payload, quantum)
        job_id = submitted["job_id"]

        if args.submit_only:
            result = {
                "execution": "submitted",
                "source": args.input,
                "config_path": str(config_path),
                "backend": backend,
                "job_id": job_id,
                "shots": args.shots,
                "plan": plan,
                "submission": submitted["response"],
            }
            if args.json_output:
                quantum.print_json(result)
            else:
                print_submission_summary(result)
            return 0

        poll_interval = args.poll_interval or config["poll_interval_seconds"]
        timeout_seconds = args.timeout or config["timeout_seconds"]
        final_job = poll_job(
            config,
            token,
            job_id,
            poll_interval,
            timeout_seconds,
            quiet=args.json_output,
            quantum=quantum,
        )
        raw_result = fetch_job_results(config, token, job_id, quantum)
        metrics = fetch_job_metrics(config, token, job_id, quantum)
        counts = extract_counts(raw_result, plan["measurements"])
        result = {
            "execution": "hardware",
            "source": args.input,
            "config_path": str(config_path),
            "backend": backend,
            "backend_family": "ibm_quantum_runtime_rest",
            "job_id": job_id,
            "status": job_status(final_job),
            "shots": args.shots,
            "plan": plan,
            "counts": counts,
            "labeled_counts": (
                quantum.labeled_counts(counts, plan["measurements"]) if counts else None
            ),
            "metrics": metrics,
            "raw_result": raw_result,
        }
        if args.json_output:
            quantum.print_json(result)
        else:
            print_hardware_run_summary(result, quantum)
        return 0
    except quantum.WireQuantumError as exc:
        print(f"wire-quantum-ibm-rest: {exc}", file=sys.stderr)
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


def select_config_path(
    input_path: str,
    override: str | None,
    plan: JSON,
    quantum: Any,
) -> Path:
    runtime_config = plan.get("runtime_config")
    if override is not None:
        return resolve_cli_config_path(override)
    if not isinstance(runtime_config, dict):
        raise quantum.WireQuantumError(
            "hardware execution requires @quantum.ibm_runtime_config { path = ...; } "
            "as the first Wire node, or an explicit --config override"
        )
    topological_order = plan.get("topological_order", [])
    if not topological_order or topological_order[0] != runtime_config.get("node"):
        raise quantum.WireQuantumError(
            "@quantum.ibm_runtime_config must be the first topological node in the "
            "hardware Wire graph"
        )
    return resolve_config_path(input_path, str(runtime_config["path"]))


def resolve_cli_config_path(raw_path: str) -> Path:
    path = Path(raw_path).expanduser()
    if path.is_absolute():
        return path
    return path.resolve()


def resolve_config_path(input_path: str, raw_path: str) -> Path:
    path = Path(raw_path).expanduser()
    if path.is_absolute():
        return path
    if input_path != "-":
        source_path = Path(input_path)
        if source_path.suffix == ".wire":
            return (source_path.resolve().parent / path).resolve()
    return path.resolve()


def load_runtime_config(path: Path, require_credentials: bool, quantum: Any) -> JSON:
    if not path.exists():
        raise quantum.WireQuantumError(
            f"IBM Quantum config file not found: {path}. "
            "Use an ignored *.local.json config for credentials."
        )
    try:
        with path.open("r", encoding="utf-8") as handle:
            raw = json.load(handle)
    except json.JSONDecodeError as exc:
        raise quantum.WireQuantumError(f"invalid IBM Quantum config JSON at {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise quantum.WireQuantumError(f"IBM Quantum config must be a JSON object: {path}")

    api_key, api_key_source = resolve_api_key(raw)
    instance_crn = optional_string(raw, "instance_crn")
    if is_placeholder(instance_crn):
        instance_crn = None

    if require_credentials and not api_key:
        raise quantum.WireQuantumError(
            "IBM Quantum config needs an api_key field or an api_key_env field "
            "that points at an environment variable"
        )
    if require_credentials and not instance_crn:
        raise quantum.WireQuantumError(
            "IBM Quantum config needs instance_crn for Runtime REST requests"
        )

    return {
        "api_key": api_key,
        "api_key_source": api_key_source,
        "instance_crn": instance_crn,
        "api_base_url": string_or_default(raw, "api_base_url", IBM_API_BASE_URL),
        "iam_token_url": string_or_default(raw, "iam_token_url", IBM_IAM_TOKEN_URL),
        "api_version": string_or_default(raw, "api_version", IBM_API_VERSION),
        "backend": string_or_default(raw, "backend", "least_busy"),
        "poll_interval_seconds": int_or_default(raw, "poll_interval_seconds", 10),
        "timeout_seconds": int_or_default(raw, "timeout_seconds", 900),
    }


def resolve_api_key(raw: JSON) -> tuple[str | None, str]:
    env_name = optional_string(raw, "api_key_env")
    if env_name:
        env_value = os.environ.get(env_name)
        if env_value and not is_placeholder(env_value):
            return env_value, f"env:{env_name}"

    api_key = optional_string(raw, "api_key")
    if api_key and not is_placeholder(api_key):
        return api_key, "config:api_key"

    if env_name:
        return None, f"env:{env_name} (unset)"
    return None, "missing"


def optional_string(raw: JSON, field: str) -> str | None:
    value = raw.get(field)
    return value if isinstance(value, str) and value else None


def string_or_default(raw: JSON, field: str, default: str) -> str:
    value = optional_string(raw, field)
    return value if value and not is_placeholder(value) else default


def int_or_default(raw: JSON, field: str, default: int) -> int:
    value = raw.get(field)
    if isinstance(value, int) and value > 0:
        return value
    return default


def is_placeholder(value: str | None) -> bool:
    if value is None:
        return False
    return any(marker in value for marker in PLACEHOLDER_MARKERS)


def build_openqasm3(plan: JSON, quantum: Any) -> str:
    if not plan["measurements"]:
        raise quantum.WireQuantumError("IBM sampler execution requires at least one measurement")
    lines = [
        "OPENQASM 3.0;",
        'include "stdgates.inc";',
        f"qubit[{plan['num_qubits']}] q;",
        f"bit[{len(plan['measurements'])}] c;",
    ]
    for operation in plan["operations"]:
        gate = operation["gate"]
        if gate == "prepare_zero":
            continue
        if gate == "h":
            lines.append(f"h q[{operation['wire']}];")
        elif gate == "cnot":
            lines.append(f"cx q[{operation['control']}], q[{operation['target']}];")
        elif gate == "measure_z":
            lines.append(
                f"c[{operation['classical_bit']}] = measure q[{operation['wire']}];"
            )
        else:
            raise quantum.WireQuantumError(f"unsupported planned gate {gate}")
    return "\n".join(lines) + "\n"


def build_sampler_payload(backend: str, qasm: str, shots: int) -> JSON:
    return {
        "program_id": "sampler",
        "backend": backend,
        "params": {
            "pubs": [[qasm, {}, shots]],
            "shots": shots,
            "version": 2,
            "support_qiskit": False,
        },
        "tags": ["cortex", "wire", "quantum-example"],
    }


def fetch_iam_token(config: JSON, quantum: Any) -> str:
    form = urllib.parse.urlencode(
        {"grant_type": IAM_API_KEY_GRANT, "apikey": config["api_key"]}
    ).encode("utf-8")
    response = request_json(
        "POST",
        config["iam_token_url"],
        {
            "Accept": "application/json",
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": USER_AGENT,
        },
        data=form,
        quantum=quantum,
    )
    token = response.get("access_token")
    if not isinstance(token, str) or not token:
        raise quantum.WireQuantumError("IBM IAM token response did not include access_token")
    return token


def resolve_backend(
    backend_request: str,
    config: JSON,
    token: str,
    plan: JSON,
    quantum: Any,
) -> str:
    if backend_request != "least_busy":
        return backend_request

    response = request_json(
        "GET",
        api_url(config, "backends"),
        runtime_headers(config, token),
        quantum=quantum,
    )
    devices = response.get("devices") if isinstance(response, dict) else response
    if not isinstance(devices, list):
        raise quantum.WireQuantumError("IBM backends response did not include a devices list")

    candidates = []
    for device in devices:
        if not isinstance(device, dict):
            continue
        name = device.get("name")
        if not isinstance(name, str) or not name:
            continue
        if bool(device.get("is_simulator")):
            continue
        if status_name(device) != "online":
            continue
        if qubit_count(device) < int(plan["num_qubits"]):
            continue
        candidates.append(device)

    if not candidates:
        raise quantum.WireQuantumError(
            "no online IBM Quantum hardware backend has enough qubits for this plan"
        )

    selected = min(candidates, key=backend_sort_key)
    return str(selected["name"])


def submit_job(config: JSON, token: str, payload: JSON, quantum: Any) -> JSON:
    response = request_json(
        "POST",
        api_url(config, "jobs"),
        runtime_headers(config, token, content_type="application/json"),
        payload=payload,
        quantum=quantum,
    )
    job_id = first_string(response, ["id", "job_id", "jobId"])
    if job_id is None:
        raise quantum.WireQuantumError("IBM job submission response did not include a job id")
    return {"job_id": job_id, "response": response}


def poll_job(
    config: JSON,
    token: str,
    job_id: str,
    poll_interval: int,
    timeout_seconds: int,
    quiet: bool,
    quantum: Any,
) -> JSON:
    deadline = time.monotonic() + timeout_seconds
    while True:
        job = fetch_job(config, token, job_id, quantum)
        status = job_status(job)
        normalized = status.lower()
        if normalized in {"completed", "failed", "cancelled", "canceled"}:
            if normalized != "completed":
                raise quantum.WireQuantumError(f"IBM job {job_id} ended with status {status}")
            return job
        if time.monotonic() >= deadline:
            raise quantum.WireQuantumError(
                f"timed out waiting for IBM job {job_id}; last status was {status}"
            )
        if not quiet:
            print(f"IBM job {job_id}: {status}; polling again in {poll_interval}s", file=sys.stderr)
        time.sleep(poll_interval)


def fetch_job(config: JSON, token: str, job_id: str, quantum: Any) -> JSON:
    return request_json(
        "GET",
        api_url(config, f"jobs/{urllib.parse.quote(job_id, safe='')}"),
        runtime_headers(config, token),
        quantum=quantum,
    )


def fetch_job_results(config: JSON, token: str, job_id: str, quantum: Any) -> Any:
    return request_json(
        "GET",
        api_url(config, f"jobs/{urllib.parse.quote(job_id, safe='')}/results"),
        runtime_headers(config, token),
        quantum=quantum,
    )


def fetch_job_metrics(config: JSON, token: str, job_id: str, quantum: Any) -> JSON | None:
    try:
        return request_json(
            "GET",
            api_url(config, f"jobs/{urllib.parse.quote(job_id, safe='')}/metrics"),
            runtime_headers(config, token),
            quantum=quantum,
        )
    except quantum.WireQuantumError:
        return None


def request_json(
    method: str,
    url: str,
    headers: dict[str, str],
    quantum: Any,
    payload: Any | None = None,
    data: bytes | None = None,
) -> Any:
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise quantum.WireQuantumError(
            f"IBM Runtime REST {method} {url} failed with HTTP {exc.code}: {body}"
        ) from exc
    except urllib.error.URLError as exc:
        raise quantum.WireQuantumError(
            f"IBM Runtime REST {method} {url} failed: {exc.reason}"
        ) from exc
    if not body:
        return {}
    try:
        return json.loads(body)
    except json.JSONDecodeError as exc:
        raise quantum.WireQuantumError(
            f"IBM Runtime REST {method} {url} returned non-JSON response"
        ) from exc


def api_url(config: JSON, path: str) -> str:
    return config["api_base_url"].rstrip("/") + "/" + path.lstrip("/")


def runtime_headers(
    config: JSON,
    token: str,
    content_type: str | None = None,
) -> dict[str, str]:
    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {token}",
        "IBM-API-Version": config["api_version"],
        "Service-CRN": config["instance_crn"] or "",
        "User-Agent": USER_AGENT,
    }
    if content_type is not None:
        headers["Content-Type"] = content_type
    return headers


def status_name(device: JSON) -> str:
    status = device.get("status")
    if isinstance(status, dict):
        name = status.get("name")
    else:
        name = status
    return str(name).lower() if name is not None else ""


def qubit_count(device: JSON) -> int:
    for key in ("qubits", "num_qubits", "n_qubits"):
        value = device.get(key)
        if isinstance(value, int):
            return value
        if isinstance(value, list):
            return len(value)
    return 0


def backend_sort_key(device: JSON) -> tuple[float, float, str]:
    return (
        numeric_value(device.get("queue_length"), default=math.inf),
        numeric_value(device.get("wait_time_seconds"), default=math.inf),
        str(device.get("name")),
    )


def numeric_value(value: Any, default: float) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, dict):
        numeric_values = [
            float(item) for item in value.values() if isinstance(item, (int, float))
        ]
        if numeric_values:
            return min(numeric_values)
    return default


def first_string(value: Any, fields: list[str]) -> str | None:
    if not isinstance(value, dict):
        return None
    for field in fields:
        found = value.get(field)
        if isinstance(found, str) and found:
            return found
    return None


def job_status(job: Any) -> str:
    if not isinstance(job, dict):
        return "unknown"
    state = job.get("state")
    if isinstance(state, dict):
        status = state.get("status") or state.get("name")
        if status is not None:
            return str(status)
    if state is not None and not isinstance(state, dict):
        return str(state)
    status = job.get("status")
    return str(status) if status is not None else "unknown"


def extract_counts(raw_result: Any, measurements: list[JSON]) -> dict[str, int] | None:
    width = len(measurements)
    direct_counts = find_direct_counts(raw_result, width)
    if direct_counts is not None:
        return direct_counts
    for tensor in iter_tensors(raw_result):
        tensor_counts = counts_from_bool_tensor(tensor, width)
        if tensor_counts is not None:
            return tensor_counts
    return None


def find_direct_counts(value: Any, width: int) -> dict[str, int] | None:
    if isinstance(value, dict):
        for key in ("counts", "quasi_dists"):
            candidate = normalize_counts(value.get(key), width)
            if candidate is not None:
                return candidate
        candidate = normalize_counts(value, width)
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
        if len(bits) != width or BITSTRING_RE.fullmatch(raw_bits) is None:
            return None
        if isinstance(raw_count, bool) or not isinstance(raw_count, (int, float)):
            return None
        if isinstance(raw_count, float) and not raw_count.is_integer():
            return None
        counts[bits] = int(raw_count)
    return dict(sorted(counts.items()))


def iter_tensors(value: Any) -> Any:
    if isinstance(value, dict):
        if {"data", "shape", "dtype"}.issubset(value):
            yield value
        for child in value.values():
            yield from iter_tensors(child)
    elif isinstance(value, list):
        for child in value:
            yield from iter_tensors(child)


def counts_from_bool_tensor(tensor: JSON, width: int) -> dict[str, int] | None:
    if tensor.get("dtype") != "bool" or width <= 0:
        return None
    shape = tensor.get("shape")
    encoded = tensor.get("data")
    if not isinstance(shape, list) or not all(isinstance(dim, int) for dim in shape):
        return None
    if not isinstance(encoded, str) or not shape:
        return None
    total = math.prod(shape)
    if total <= 0:
        return None
    if shape[-1] != width and width != 1:
        return None

    try:
        raw = base64.b64decode(encoded)
    except ValueError:
        return None

    if len(raw) == total:
        bits = [1 if item else 0 for item in raw]
    else:
        bits = []
        for byte in raw:
            for bit_index in range(8):
                bits.append((byte >> bit_index) & 1)
        bits = bits[:total]
    if len(bits) < total:
        return None

    row_width = width
    counter: Counter[str] = Counter()
    for offset in range(0, total, row_width):
        row = bits[offset : offset + row_width]
        if len(row) != row_width:
            return None
        # The shared formatter expects Qiskit's rendered bitstring convention:
        # highest classical bit on the left, classical bit 0 on the right.
        counter["".join(str(bit) for bit in row)[::-1]] += 1
    return dict(sorted(counter.items()))


def print_request_summary(result: JSON, include_payload: bool) -> None:
    plan = result["plan"]
    print("Wire IBM Quantum request")
    print(f"source: {result['source']}")
    print("execution: dry run (not submitted)")
    print(f"config: {result['config_path']}")
    print(f"backend: {result['backend_request']}")
    print(f"shots: {result['shots']}")
    print(f"qubits: {plan['num_qubits']}")
    print(f"measurements: {format_measurements(plan)}")
    print()
    print("What would happen:")
    print("Wire compiles the graph into typed quantum executor nodes.")
    print("This runner lowers those nodes into one OpenQASM 3 sampler job.")
    print("No IAM token was requested and no IBM Quantum job was queued.")
    print()
    print("OpenQASM 3:")
    print(result["openqasm3"], end="")
    if include_payload:
        print()
        print("REST payload:")
        print(json.dumps(result["request_payload"], indent=2, sort_keys=True))


def print_submission_summary(result: JSON) -> None:
    print("Wire IBM Quantum job")
    print(f"source: {result['source']}")
    print("execution: submitted (not polled)")
    print(f"config: {result['config_path']}")
    print(f"backend: {result['backend']}")
    print(f"job: {result['job_id']}")
    print(f"shots: {result['shots']}")
    print()
    print("The job is now queued with IBM Quantum Runtime.")


def print_hardware_run_summary(result: JSON, quantum: Any) -> None:
    plan = result["plan"]
    print("Wire IBM Quantum run")
    print(f"source: {result['source']}")
    print("execution: IBM Quantum hardware via Runtime REST")
    print(f"config: {result['config_path']}")
    print(f"backend: {result['backend']}")
    print(f"job: {result['job_id']}")
    print(f"status: {result['status']}")
    print(f"shots: {result['shots']}")
    print(f"qubits: {plan['num_qubits']}")
    print(f"measurements: {format_measurements(plan)}")
    usage = qpu_usage_seconds(result.get("metrics"))
    if usage is not None:
        print(f"qpu usage: {usage:.3f}s")
    print()
    print("What happened:")
    print("Wire compiled the graph into typed quantum executor nodes.")
    print("The runner lowered the admitted gates into OpenQASM 3 and submitted")
    print("that circuit to IBM Quantum Runtime REST as a sampler job.")
    print("Credentials came from the config file path carried by the first Wire node.")
    print()
    print("Result:")
    counts = result.get("counts")
    if counts:
        print(quantum.format_result_table(counts, plan["measurements"], result["shots"]))
    else:
        print("  IBM returned a result shape this example decoder did not recognize.")
        print("  Re-run with --json to inspect raw_result.")


def qpu_usage_seconds(metrics: Any) -> float | None:
    if not isinstance(metrics, dict):
        return None
    usage = metrics.get("usage")
    if not isinstance(usage, dict):
        return None
    value = usage.get("qpu_charge_time_seconds")
    return float(value) if isinstance(value, (int, float)) else None


def format_measurements(plan: JSON) -> str:
    measurements = plan["measurements"]
    if not measurements:
        return "none"
    return ", ".join(
        f"{measurement['output']}=q[{measurement['wire']}]"
        for measurement in measurements
    )


if __name__ == "__main__":
    raise SystemExit(main())
