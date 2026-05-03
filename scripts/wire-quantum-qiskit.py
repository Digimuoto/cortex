#!/usr/bin/env python3
"""Run Wire-authored quantum circuits through a local Qiskit simulator.

This is a consumer-side bridge. Cortex/Wire still owns parsing and typed
topology; this script owns the quantum backend interpretation for the
`@quantum.*` executor vocabulary used by the examples.
"""

from __future__ import annotations

import argparse
import heapq
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


JSON = dict[str, Any]


class WireQuantumError(Exception):
    """User-facing error for unsupported or invalid quantum Wire artifacts."""


@dataclass(frozen=True)
class QuantumValue:
    kind: str
    wire: int | None
    contract: str
    source_node: str
    source_port: str


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run a compiled Wire quantum circuit on Qiskit Aer.",
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
        default="aer_simulator",
        help="Qiskit backend. Only 'aer_simulator' is enabled by this local runner.",
    )
    parser.add_argument("--shots", type=positive_int, default=1024)
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument(
        "--emit-plan",
        action="store_true",
        help="Print the backend-neutral quantum plan without executing Qiskit.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="json_output",
        help="Print machine-readable JSON instead of the human summary.",
    )
    args = parser.parse_args()

    try:
        compiled = load_compiled_circuit(args.input, args.wire_bin, args.wire_return)
        plan = build_quantum_plan(compiled)
        if args.emit_plan:
            if args.json_output:
                print_json(plan)
            else:
                print_plan_summary(args.input, plan)
            return 0
        result = execute_qiskit_plan(
            plan,
            backend_name=args.backend,
            shots=args.shots,
            seed=args.seed,
        )
        if args.json_output:
            print_json(result)
        else:
            print_run_summary(args.input, result)
        return 0
    except WireQuantumError as exc:
        print(f"wire-quantum-qiskit: {exc}", file=sys.stderr)
        return 1


def positive_int(raw: str) -> int:
    value = int(raw)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return value


def print_json(value: JSON) -> None:
    print(json.dumps(value, indent=2, sort_keys=True))


def print_plan_summary(input_path: str, plan: JSON) -> None:
    measurements = plan["measurements"]
    print("Wire quantum plan")
    print(f"source: {input_path}")
    print("execution: not run")
    print("backend family: Qiskit")
    runtime_config = plan.get("runtime_config")
    if isinstance(runtime_config, dict):
        print(
            "runtime config: "
            f"{runtime_config['node']} -> {runtime_config['path']}"
        )
    print(f"qubits: {plan['num_qubits']}")
    print(f"measurements: {format_measurements(measurements)}")
    print()
    print("Operations:")
    for operation in plan["operations"]:
        print(f"  - {format_operation(operation)}")
    print()
    print("This only inspected the compiled Wire graph; no simulator or hardware job ran.")


def print_run_summary(input_path: str, result: JSON) -> None:
    plan = result["plan"]
    measurements = plan["measurements"]
    shots = result["shots"]

    print("Wire quantum run")
    print(f"source: {input_path}")
    print("execution: local simulation (not real hardware)")
    print(f"backend: Qiskit Aer {result['backend']}")
    print(f"shots: {shots}")
    print(f"seed: {result['seed'] if result['seed'] is not None else 'random'}")
    print(f"qiskit: {result['qiskit_version']} / aer: {result['qiskit_aer_version']}")
    print(f"qubits: {plan['num_qubits']}")
    print(f"measurements: {format_measurements(measurements)}")
    print()
    print("What happened:")
    print("Wire compiled the graph into typed quantum executor nodes.")
    print("The runner mapped the admitted @quantum.* gates into one Qiskit circuit.")
    print("It sampled that circuit on the local Aer simulator.")
    print("No provider account was used and no real quantum hardware job was queued.")
    print()
    print("Result:")
    print(format_result_table(result["counts"], measurements, shots))


def format_measurements(measurements: list[JSON]) -> str:
    if not measurements:
        return "none"
    return ", ".join(
        f"{measurement['output']}=q[{measurement['wire']}]"
        for measurement in measurements
    )


def format_operation(operation: JSON) -> str:
    gate = operation["gate"]
    node = operation["node"]
    if gate == "prepare_zero":
        return f"{node}: prepare_zero q[{operation['wire']}]"
    if gate == "h":
        return f"{node}: h q[{operation['wire']}]"
    if gate == "rz":
        return f"{node}: rz({operation['angle']}) q[{operation['wire']}]"
    if gate == "sx":
        return f"{node}: sx q[{operation['wire']}]"
    if gate == "x":
        return f"{node}: x q[{operation['wire']}]"
    if gate == "cnot":
        return f"{node}: cnot q[{operation['control']}], q[{operation['target']}]"
    if gate == "cz":
        return f"{node}: cz q[{operation['control']}], q[{operation['target']}]"
    if gate == "rzz":
        return (
            f"{node}: rzz({operation['angle']}) "
            f"q[{operation['control']}], q[{operation['target']}]"
        )
    if gate == "measure_z":
        return (
            f"{node}: measure_z q[{operation['wire']}] "
            f"-> {operation['output']} (c[{operation['classical_bit']}])"
        )
    return f"{node}: {gate}"


def format_result_table(counts: dict[str, int], measurements: list[JSON], shots: int) -> str:
    rows = []
    for bits, count in sorted(counts.items()):
        label = label_bits(bits, measurements)
        percent = (count / shots * 100) if shots else 0
        rows.append((bits, label, str(count), f"{percent:.2f}%"))
    if not rows:
        return "  (no measurement counts)"

    headers = ("bits", "outputs", "shots", "percent")
    widths = [
        max([len(headers[0]), *(len(row[0]) for row in rows)]),
        max([len(headers[1]), *(len(row[1]) for row in rows)]),
        max([len(headers[2]), *(len(row[2]) for row in rows)]),
        max([len(headers[3]), *(len(row[3]) for row in rows)]),
    ]
    lines = [
        "  "
        + f"{headers[0]:<{widths[0]}}  "
        + f"{headers[1]:<{widths[1]}}  "
        + f"{headers[2]:>{widths[2]}}  "
        + f"{headers[3]:>{widths[3]}}"
    ]
    for bits, label, count, percent in rows:
        lines.append(
            "  "
            + f"{bits:<{widths[0]}}  "
            + f"{label:<{widths[1]}}  "
            + f"{count:>{widths[2]}}  "
            + f"{percent:>{widths[3]}}"
        )
    return "\n".join(lines)


def load_compiled_circuit(
    input_path: str,
    wire_bin: str,
    wire_return: str | None = None,
) -> JSON:
    if input_path == "-":
        if wire_return is not None:
            raise WireQuantumError("--return cannot be used when reading compiled JSON from stdin")
        return json.load(sys.stdin)

    path = Path(input_path)
    if path.suffix == ".wire":
        command = [wire_bin, "build"]
        if wire_return is not None:
            command.extend(["--return", wire_return])
        command.append(str(path))
        proc = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if proc.returncode != 0:
            raise WireQuantumError(
                "wire build failed for "
                f"{path}:\n{proc.stderr.strip() or proc.stdout.strip()}"
            )
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            raise WireQuantumError(f"wire build did not return JSON: {exc}") from exc

    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def build_quantum_plan(compiled: JSON) -> JSON:
    nodes = compiled.get("compiledCircuitNodes")
    topology = compiled.get("compiledCircuitTopology")
    if not isinstance(nodes, dict) or not isinstance(topology, dict):
        raise WireQuantumError("input is not a compiled Wire circuit artifact")

    edges = parse_edges(topology)
    order = topological_order(sorted(nodes), edges)
    validate_qubit_linearity(nodes, edges)

    node_outputs: dict[str, dict[str, QuantumValue]] = {}
    operations: list[JSON] = []
    measurements: list[JSON] = []
    qubit_wires: set[int] = set()
    allocated_qubits: dict[int, str] = {}
    runtime_config: JSON | None = None

    for node_ref in order:
        metadata = task_metadata(nodes, node_ref)
        target = executor_target(metadata)
        inputs = resolve_inputs(node_ref, metadata, predecessors(node_ref, edges), node_outputs)
        output_ports = metadata_ports(metadata, "outputs")
        config = metadata.get("config", {})
        if not isinstance(config, dict):
            raise WireQuantumError(f"node {node_ref} has non-object config")

        if target == "quantum.ibm_runtime_config":
            if inputs:
                raise WireQuantumError(f"{node_ref}: ibm_runtime_config expects no inputs")
            output = single_output(
                node_ref,
                output_ports,
                "IBMQuantumConfig",
                "quantum.ibm_runtime_config",
            )
            if runtime_config is not None:
                raise WireQuantumError(
                    "quantum plan declares more than one IBM runtime config node"
                )
            runtime_config = {
                "node": node_ref,
                "path": string_config(node_ref, config, "path"),
                "output": output["name"],
            }
            node_outputs[node_ref] = {
                output["name"]: QuantumValue(
                    "config",
                    None,
                    "IBMQuantumConfig",
                    node_ref,
                    output["name"],
                )
            }
        elif target == "quantum.prepare_zero":
            allow_only_config_inputs(node_ref, inputs, "quantum.prepare_zero")
            if len(output_ports) != 1:
                raise WireQuantumError(f"{node_ref}: prepare_zero expects exactly one Qubit output")
            output = output_ports[0]
            require_contract(node_ref, output, "Qubit")
            wire = int_config(node_ref, config, "index")
            allocate_qubit(node_ref, wire, allocated_qubits)
            qubit_wires.add(wire)
            node_outputs[node_ref] = {
                output["name"]: QuantumValue("qubit", wire, "Qubit", node_ref, output["name"])
            }
            operations.append(
                {
                    "node": node_ref,
                    "executor": target,
                    "gate": "prepare_zero",
                    "wire": wire,
                    "output": output["name"],
                }
            )
        elif target == "quantum.h":
            input_value = single_qubit_input(node_ref, inputs, "quantum.h")
            output = single_output(node_ref, output_ports, "Qubit", "quantum.h")
            input_wire = require_wire(node_ref, input_value)
            qubit_wires.add(input_wire)
            node_outputs[node_ref] = {
                output["name"]: QuantumValue(
                    "qubit",
                    input_wire,
                    "Qubit",
                    node_ref,
                    output["name"],
                )
            }
            operations.append(
                {
                    "node": node_ref,
                    "executor": target,
                    "gate": "h",
                    "wire": input_wire,
                }
            )
        elif target == "quantum.rz":
            input_value = single_qubit_input(node_ref, inputs, "quantum.rz")
            output = single_output(node_ref, output_ports, "Qubit", "quantum.rz")
            input_wire = require_wire(node_ref, input_value)
            qubit_wires.add(input_wire)
            node_outputs[node_ref] = {
                output["name"]: QuantumValue(
                    "qubit",
                    input_wire,
                    "Qubit",
                    node_ref,
                    output["name"],
                )
            }
            operations.append(
                {
                    "node": node_ref,
                    "executor": target,
                    "gate": "rz",
                    "wire": input_wire,
                    "angle": number_config(node_ref, config, "angle"),
                }
            )
        elif target == "quantum.sx":
            input_value = single_qubit_input(node_ref, inputs, "quantum.sx")
            output = single_output(node_ref, output_ports, "Qubit", "quantum.sx")
            input_wire = require_wire(node_ref, input_value)
            qubit_wires.add(input_wire)
            node_outputs[node_ref] = {
                output["name"]: QuantumValue(
                    "qubit",
                    input_wire,
                    "Qubit",
                    node_ref,
                    output["name"],
                )
            }
            operations.append(
                {
                    "node": node_ref,
                    "executor": target,
                    "gate": "sx",
                    "wire": input_wire,
                }
            )
        elif target == "quantum.x":
            input_value = single_qubit_input(node_ref, inputs, "quantum.x")
            output = single_output(node_ref, output_ports, "Qubit", "quantum.x")
            input_wire = require_wire(node_ref, input_value)
            qubit_wires.add(input_wire)
            node_outputs[node_ref] = {
                output["name"]: QuantumValue(
                    "qubit",
                    input_wire,
                    "Qubit",
                    node_ref,
                    output["name"],
                )
            }
            operations.append(
                {
                    "node": node_ref,
                    "executor": target,
                    "gate": "x",
                    "wire": input_wire,
                }
            )
        elif target == "quantum.cnot":
            control = named_qubit_input(node_ref, inputs, "control", "quantum.cnot")
            target_qubit = named_qubit_input(node_ref, inputs, "target", "quantum.cnot")
            require_output_names(
                node_ref,
                output_ports,
                ["control", "target"],
                "Qubit",
                "quantum.cnot",
            )
            control_wire = require_wire(node_ref, control)
            target_wire = require_wire(node_ref, target_qubit)
            if control_wire == target_wire:
                raise WireQuantumError(f"{node_ref}: cnot control and target must be distinct")
            qubit_wires.update([control_wire, target_wire])
            node_outputs[node_ref] = {
                "control": QuantumValue("qubit", control_wire, "Qubit", node_ref, "control"),
                "target": QuantumValue("qubit", target_wire, "Qubit", node_ref, "target"),
            }
            operations.append(
                {
                    "node": node_ref,
                    "executor": target,
                    "gate": "cnot",
                    "control": control_wire,
                    "target": target_wire,
                }
            )
        elif target == "quantum.cz":
            control = named_qubit_input(node_ref, inputs, "control", "quantum.cz")
            target_qubit = named_qubit_input(node_ref, inputs, "target", "quantum.cz")
            require_output_names(
                node_ref,
                output_ports,
                ["control", "target"],
                "Qubit",
                "quantum.cz",
            )
            control_wire = require_wire(node_ref, control)
            target_wire = require_wire(node_ref, target_qubit)
            if control_wire == target_wire:
                raise WireQuantumError(f"{node_ref}: cz control and target must be distinct")
            qubit_wires.update([control_wire, target_wire])
            node_outputs[node_ref] = {
                "control": QuantumValue("qubit", control_wire, "Qubit", node_ref, "control"),
                "target": QuantumValue("qubit", target_wire, "Qubit", node_ref, "target"),
            }
            operations.append(
                {
                    "node": node_ref,
                    "executor": target,
                    "gate": "cz",
                    "control": control_wire,
                    "target": target_wire,
                }
            )
        elif target == "quantum.rzz":
            control = named_qubit_input(node_ref, inputs, "control", "quantum.rzz")
            target_qubit = named_qubit_input(node_ref, inputs, "target", "quantum.rzz")
            require_output_names(
                node_ref,
                output_ports,
                ["control", "target"],
                "Qubit",
                "quantum.rzz",
            )
            control_wire = require_wire(node_ref, control)
            target_wire = require_wire(node_ref, target_qubit)
            if control_wire == target_wire:
                raise WireQuantumError(f"{node_ref}: rzz qubits must be distinct")
            qubit_wires.update([control_wire, target_wire])
            node_outputs[node_ref] = {
                "control": QuantumValue("qubit", control_wire, "Qubit", node_ref, "control"),
                "target": QuantumValue("qubit", target_wire, "Qubit", node_ref, "target"),
            }
            operations.append(
                {
                    "node": node_ref,
                    "executor": target,
                    "gate": "rzz",
                    "control": control_wire,
                    "target": target_wire,
                    "angle": number_config(node_ref, config, "angle"),
                }
            )
        elif target == "quantum.measure_z":
            input_value = single_qubit_input(node_ref, inputs, "quantum.measure_z")
            output = single_output(node_ref, output_ports, "Bit", "quantum.measure_z")
            qubit_wire = require_wire(node_ref, input_value)
            classical_bit = len(measurements)
            measurement = {
                "node": node_ref,
                "executor": target,
                "gate": "measure_z",
                "wire": qubit_wire,
                "classical_bit": classical_bit,
                "output": output["name"],
            }
            measurements.append(measurement)
            operations.append(measurement)
            node_outputs[node_ref] = {
                output["name"]: QuantumValue("bit", None, "Bit", node_ref, output["name"])
            }
        else:
            raise WireQuantumError(f"node {node_ref} uses unsupported quantum executor @{target}")

    if not qubit_wires:
        raise WireQuantumError("quantum plan did not allocate any qubits")

    plan = {
        "backend_family": "qiskit",
        "topological_order": order,
        "num_qubits": max(qubit_wires) + 1,
        "qubits": sorted(qubit_wires),
        "operations": operations,
        "measurements": measurements,
    }
    if runtime_config is not None:
        plan["runtime_config"] = runtime_config
    return plan


def parse_edges(topology: JSON) -> list[tuple[str, str]]:
    raw_edges = topology.get("relEdges", [])
    if not isinstance(raw_edges, list):
        raise WireQuantumError("compiled topology relEdges must be a list")
    edges = []
    for raw in raw_edges:
        if not isinstance(raw, list) or len(raw) != 2:
            raise WireQuantumError(f"invalid topology edge: {raw!r}")
        edges.append((str(raw[0]), str(raw[1])))
    return edges


def topological_order(node_refs: list[str], edges: list[tuple[str, str]]) -> list[str]:
    successors: dict[str, list[str]] = {node: [] for node in node_refs}
    indegree: dict[str, int] = {node: 0 for node in node_refs}
    for src, dst in edges:
        if src not in successors or dst not in indegree:
            raise WireQuantumError(f"topology references unknown node in edge {src} -> {dst}")
        successors[src].append(dst)
        indegree[dst] += 1

    ready = [node for node in node_refs if indegree[node] == 0]
    heapq.heapify(ready)
    order = []
    while ready:
        node = heapq.heappop(ready)
        order.append(node)
        for dst in sorted(successors[node]):
            indegree[dst] -= 1
            if indegree[dst] == 0:
                heapq.heappush(ready, dst)

    if len(order) != len(node_refs):
        raise WireQuantumError("compiled topology is cyclic")
    return order


def predecessors(node_ref: str, edges: list[tuple[str, str]]) -> list[str]:
    return sorted(src for src, dst in edges if dst == node_ref)


def task_metadata(nodes: dict[str, Any], node_ref: str) -> JSON:
    node = nodes[node_ref]
    if node.get("tag") != "CompiledCircuitTask":
        raise WireQuantumError(f"node {node_ref} is not a task node")
    contents = node.get("contents", {})
    metadata = contents.get("circuitTaskNodeMetadata")
    if not isinstance(metadata, dict):
        raise WireQuantumError(f"node {node_ref} is missing task metadata")
    return metadata


def executor_target(metadata: JSON) -> str:
    executor = metadata.get("executor")
    if not isinstance(executor, dict) or executor.get("kind") != "native":
        raise WireQuantumError("quantum runner only supports native executor metadata")
    target = executor.get("target")
    if not isinstance(target, str):
        raise WireQuantumError("native executor metadata is missing target")
    return target


def metadata_ports(metadata: JSON, direction: str) -> list[JSON]:
    ports = metadata.get("ports", {})
    values = ports.get(direction)
    if not isinstance(values, list):
        raise WireQuantumError(f"metadata ports.{direction} must be a list")
    return values


def resolve_inputs(
    node_ref: str,
    metadata: JSON,
    predecessor_refs: list[str],
    node_outputs: dict[str, dict[str, QuantumValue]],
) -> dict[str, QuantumValue]:
    resolved: dict[str, QuantumValue] = {}
    for input_port in metadata_ports(metadata, "inputs"):
        input_name = input_port.get("name")
        accepts = input_port.get("accepts", [])
        if not isinstance(input_name, str) or not isinstance(accepts, list):
            raise WireQuantumError(f"node {node_ref} has invalid input port metadata")
        matches = []
        for pred in predecessor_refs:
            for output_name, value in node_outputs.get(pred, {}).items():
                if output_name == input_name and value.contract in accepts:
                    matches.append(value)
        if len(matches) != 1:
            raise WireQuantumError(
                f"node {node_ref} input {input_name} expected one "
                f"predecessor output, got {len(matches)}"
            )
        resolved[input_name] = matches[0]
    return resolved


def validate_qubit_linearity(nodes: dict[str, Any], edges: list[tuple[str, str]]) -> None:
    consumers: dict[tuple[str, str], list[str]] = {}
    for src, dst in edges:
        src_outputs = metadata_ports(task_metadata(nodes, src), "outputs")
        dst_inputs = metadata_ports(task_metadata(nodes, dst), "inputs")
        for output in src_outputs:
            if output.get("contract") != "Qubit":
                continue
            output_name = output.get("name")
            for input_port in dst_inputs:
                if (
                    input_port.get("name") == output_name
                    and "Qubit" in input_port.get("accepts", [])
                ):
                    consumers.setdefault((src, output_name), []).append(dst)

    violations = [
        (src, output, dsts)
        for (src, output), dsts in consumers.items()
        if len(dsts) > 1
    ]
    if violations:
        src, output, dsts = violations[0]
        raise WireQuantumError(
            f"Qubit output {src}.{output} fans out to {', '.join(sorted(dsts))}; "
            "this runner requires linear qubit use"
        )


def int_config(node_ref: str, config: JSON, field: str) -> int:
    value = config.get(field)
    if not isinstance(value, int) or value < 0:
        raise WireQuantumError(
            f"node {node_ref} config field {field} must be a non-negative integer"
        )
    return value


def number_config(node_ref: str, config: JSON, field: str) -> float:
    value = config.get(field)
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise WireQuantumError(f"node {node_ref} config field {field} must be a number")
    return float(value)


def string_config(node_ref: str, config: JSON, field: str) -> str:
    value = config.get(field)
    if not isinstance(value, str) or not value:
        raise WireQuantumError(f"node {node_ref} config field {field} must be a string")
    return value


def allocate_qubit(node_ref: str, wire: int, allocated_qubits: dict[int, str]) -> None:
    previous = allocated_qubits.get(wire)
    if previous is not None:
        raise WireQuantumError(
            f"node {node_ref} reuses qubit index {wire} already allocated by {previous}"
        )
    allocated_qubits[wire] = node_ref


def require_contract(node_ref: str, port: JSON, contract: str) -> None:
    if port.get("contract") != contract:
        raise WireQuantumError(
            f"node {node_ref} output {port.get('name')} must have contract {contract}"
        )


def single_qubit_input(
    node_ref: str,
    inputs: dict[str, QuantumValue],
    executor: str,
) -> QuantumValue:
    if len(inputs) != 1:
        raise WireQuantumError(f"{node_ref}: {executor} expects exactly one Qubit input")
    value = next(iter(inputs.values()))
    if value.contract != "Qubit" or value.kind != "qubit":
        raise WireQuantumError(f"{node_ref}: {executor} input must be a Qubit")
    return value


def named_qubit_input(
    node_ref: str,
    inputs: dict[str, QuantumValue],
    name: str,
    executor: str,
) -> QuantumValue:
    value = inputs.get(name)
    if value is None or value.contract != "Qubit" or value.kind != "qubit":
        raise WireQuantumError(f"{node_ref}: {executor} expects Qubit input {name}")
    return value


def allow_only_config_inputs(
    node_ref: str,
    inputs: dict[str, QuantumValue],
    executor: str,
) -> None:
    for name, value in inputs.items():
        if value.contract != "IBMQuantumConfig" or value.kind != "config":
            raise WireQuantumError(
                f"{node_ref}: {executor} input {name} must be IBMQuantumConfig "
                "when used as a hardware orchestration dependency"
            )


def single_output(node_ref: str, outputs: list[JSON], contract: str, executor: str) -> JSON:
    if len(outputs) != 1:
        raise WireQuantumError(f"{node_ref}: {executor} expects exactly one {contract} output")
    require_contract(node_ref, outputs[0], contract)
    return outputs[0]


def require_output_names(
    node_ref: str,
    outputs: list[JSON],
    names: list[str],
    contract: str,
    executor: str,
) -> None:
    actual = {output.get("name"): output for output in outputs}
    for name in names:
        output = actual.get(name)
        if output is None:
            raise WireQuantumError(f"{node_ref}: {executor} expects output {name}")
        require_contract(node_ref, output, contract)


def require_wire(node_ref: str, value: QuantumValue) -> int:
    if value.wire is None:
        raise WireQuantumError(f"node {node_ref} expected a qubit wire")
    return value.wire


def execute_qiskit_plan(plan: JSON, backend_name: str, shots: int, seed: int | None) -> JSON:
    if backend_name != "aer_simulator":
        raise WireQuantumError(
            "only backend 'aer_simulator' is supported by this local runner; "
            "hardware/provider backends need a separate explicit binding"
        )

    try:
        import qiskit
        import qiskit_aer
        from qiskit import QuantumCircuit, transpile
        from qiskit_aer import AerSimulator
    except ImportError as exc:
        raise WireQuantumError(
            "Qiskit is not available. Run through `nix run .#wire-quantum-qiskit`."
        ) from exc

    measurements = plan["measurements"]
    circuit = QuantumCircuit(plan["num_qubits"], len(measurements))
    for operation in plan["operations"]:
        gate = operation["gate"]
        if gate == "prepare_zero":
            continue
        if gate == "h":
            circuit.h(operation["wire"])
        elif gate == "rz":
            circuit.rz(operation["angle"], operation["wire"])
        elif gate == "sx":
            circuit.sx(operation["wire"])
        elif gate == "x":
            circuit.x(operation["wire"])
        elif gate == "cnot":
            circuit.cx(operation["control"], operation["target"])
        elif gate == "cz":
            circuit.cz(operation["control"], operation["target"])
        elif gate == "rzz":
            circuit.rzz(operation["angle"], operation["control"], operation["target"])
        elif gate == "measure_z":
            circuit.measure(operation["wire"], operation["classical_bit"])
        else:
            raise WireQuantumError(f"unsupported planned gate {gate}")

    backend_kwargs = {}
    run_kwargs = {"shots": shots}
    if seed is not None:
        backend_kwargs["seed_simulator"] = seed
        run_kwargs["seed_simulator"] = seed
    backend = AerSimulator(**backend_kwargs)
    compiled = transpile(circuit, backend)
    counts = backend.run(compiled, **run_kwargs).result().get_counts(compiled)
    complete = complete_counts(counts, len(measurements))

    return {
        "backend": backend_name,
        "backend_family": "qiskit",
        "qiskit_version": qiskit.__version__,
        "qiskit_aer_version": qiskit_aer.__version__,
        "shots": shots,
        "seed": seed,
        "plan": plan,
        "counts": dict(sorted(counts.items())),
        "complete_counts": complete,
        "labeled_counts": labeled_counts(counts, measurements),
        "complete_labeled_counts": labeled_counts(complete, measurements),
    }


def complete_counts(counts: dict[str, int], width: int) -> dict[str, int]:
    return {
        format(index, f"0{width}b"): int(counts.get(format(index, f"0{width}b"), 0))
        for index in range(2**width)
    }


def labeled_counts(counts: dict[str, int], measurements: list[JSON]) -> dict[str, int]:
    labeled: dict[str, int] = {}
    for raw_bits, count in counts.items():
        labeled[label_bits(raw_bits, measurements)] = count
    return dict(sorted(labeled.items()))


def label_bits(raw_bits: str, measurements: list[JSON]) -> str:
    bits = raw_bits.replace(" ", "")
    width = len(measurements)
    if len(bits) != width:
        raise WireQuantumError(f"unexpected Qiskit bitstring width: {raw_bits}")
    fields = []
    for measurement in measurements:
        classical_bit = measurement["classical_bit"]
        # Qiskit renders classical bit n-1 on the left and bit 0 on the right.
        bit = bits[width - classical_bit - 1]
        fields.append(f"{measurement['output']}={bit}")
    return ",".join(fields)


if __name__ == "__main__":
    raise SystemExit(main())
