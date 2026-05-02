---
title: Quantum Consumer Binding Example
description:
  How a quantum host can bind Wire circuits to PennyLane, Qiskit, Cirq, or another backend without
  making Cortex own quantum semantics.
sidebar:
  label: Quantum
  order: 3
status: draft
---

# Quantum Consumer Binding Example

This page is a consumer binding example. It shows how a quantum host can use Wire to author circuit
topology while keeping quantum semantics, simulator choice, hardware access, and job policy outside
the Cortex substrate.

The important boundary is the same as every Wire executor boundary:

| Cortex owns                                                                                  | Quantum host owns                                                                                                |
| -------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Wire parsing, graph composition, typed ports, executor projection admission, and Pulse runs. | Quantum contracts, gate vocabulary, backend binding, provider credentials, queue policy, shots, and result data. |
| Projection data structures and registry admission checks.                                    | Runtime implementations for `@quantum.*`, for example through PennyLane, Qiskit, Cirq, or a hardware provider.   |

Wire source can reference quantum gates exactly because they are ordinary registered executors:

```wire
contract Qubit;
contract Bit;

node hadamard_control
  <- control: Qubit;
  -> control: Qubit = @quantum.h {} (control);

node entangle
  <- control: Qubit;
  <- target: Qubit;
  -> control: Qubit;
  -> target: Qubit;
  = @quantum.cnot ({ inherit control; inherit target; });
```

`@quantum.h` and `@quantum.cnot` are not Wire keywords. A host registers them in the executor
projection registry, binds `Qubit` and `Bit` contracts to host codecs, and supplies the runtime
interpreter that turns admitted nodes into backend operations.

## Minimal Shape

A useful first vocabulary is:

| Executor                | Port shape                                        | Host behavior                                 |
| ----------------------- | ------------------------------------------------- | --------------------------------------------- |
| `@quantum.prepare_zero` | zero inputs, one `Qubit` output                   | Introduce a backend qubit initialized to `0`. |
| `@quantum.h`            | one `Qubit` input, one `Qubit` output             | Apply a Hadamard gate.                        |
| `@quantum.rx`           | `Qubit` plus `RotationAngle`, one `Qubit` output  | Apply a parameterized X rotation.             |
| `@quantum.cnot`         | `control` and `target` `Qubit` inputs and outputs | Apply a controlled-not gate.                  |
| `@quantum.measure_z`    | one `Qubit` input, one `Bit` output               | Measure in the Z basis.                       |

The example circuit at
[`../../examples/wire/quantum-bell-state.wire`](../../examples/wire/quantum-bell-state.wire) authors
a Bell-state topology with this model.

## Runtime Binding

A Python-backed consumer can compile Wire with strict executor projections, then bind the admitted
nodes to a backend-specific circuit builder:

1. The host registers `@quantum.*` executor projections and `Qubit`, `Bit`, and `RotationAngle`
   contracts.
2. Wire compiles the source to a validated Circuit with typed node boundaries.
3. The host interpreter walks the materialized nodes and appends operations to the selected quantum
   backend circuit.
4. Measurement nodes return `Bit` payloads or structured result records through ordinary Wire output
   ports.

This keeps PennyLane/Qiskit/Cirq APIs out of Cortex. Cortex sees executor IDs, config records,
ports, contracts, and run results.

## Local Qiskit Runner

The repository includes a Nix-backed local simulator bridge for the example vocabulary:

```sh
nix run .#wire-quantum-qiskit -- examples/wire/quantum-bell-state.wire --shots 1024 --seed 7
```

The runner:

- compiles `.wire` input with the flake's `wire` executable;
- carries `Qubit` ports as symbolic Qiskit wire indices;
- builds one `QuantumCircuit`;
- executes it on Qiskit Aer `aer_simulator`;
- returns JSON counts and label-decoded counts.

Plan inspection without simulator execution is also available:

```sh
nix run .#wire-quantum-qiskit -- examples/wire/quantum-bell-state.wire --emit-plan
```

The runner intentionally supports only the local Aer simulator. It refuses non-local backend names
so an account or provider credentials cannot accidentally queue hardware jobs. Hardware execution
should be added as a separate explicit binding with provider, credential, queue, cost, and audit
policy in its own config path.

## Linearity Caveat

Current Wire admission validates typed ports and cardinality-one inputs, but it does not make a
generic "one output may have only one consumer" guarantee. A real quantum host must reject illegal
`Qubit` fan-out in its projection/admission layer or introduce a Cortex-level linear-resource
decision before treating `Qubit` as a no-cloning resource.

Mid-circuit measurement with adaptive classical feedback is also a separate design question. It
would need to state how measurement results authorize later topology, likely through the existing
rewrite and `select(...)` surfaces rather than through hidden backend callbacks.

## Related

- [../Architecture/02-ownership-and-boundaries.md](../Architecture/02-ownership-and-boundaries.md)
- [../Architecture/05-wire-language.md](../Architecture/05-wire-language.md)
- [../Reference/Wire/executors-and-alphabet.md](../Reference/Wire/executors-and-alphabet.md)
- [../Reference/Wire/configured-executors-and-execution-boundary.md](../Reference/Wire/configured-executors-and-execution-boundary.md)
