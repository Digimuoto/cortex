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
| `@quantum.rz`           | one `Qubit` input, one `Qubit` output             | Apply a Z-axis rotation.                      |
| `@quantum.sx`           | one `Qubit` input, one `Qubit` output             | Apply a square-root X gate.                   |
| `@quantum.x`            | one `Qubit` input, one `Qubit` output             | Apply an X gate.                              |
| `@quantum.h`            | one `Qubit` input, one `Qubit` output             | Apply a Hadamard gate.                        |
| `@quantum.rx`           | `Qubit` plus `RotationAngle`, one `Qubit` output  | Apply a parameterized X rotation.             |
| `@quantum.cz`           | `control` and `target` `Qubit` inputs and outputs | Apply a controlled-Z gate.                    |
| `@quantum.rzz`          | `control` and `target` `Qubit` inputs and outputs | Apply a parameterized ZZ interaction.         |
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
- prints a concise run summary with label-decoded counts.

Machine-readable output is available with `--json`:

```sh
nix run .#wire-quantum-qiskit -- examples/wire/quantum-bell-state.wire --json
```

Plan inspection without simulator execution is also available:

```sh
nix run .#wire-quantum-qiskit -- examples/wire/quantum-bell-state.wire --emit-plan
```

The runner intentionally supports only the local Aer simulator. It refuses non-local backend names
so an account or provider credentials cannot accidentally queue hardware jobs. Hardware execution
should be added as a separate explicit binding with provider, credential, queue, cost, and audit
policy in its own config path.

## IBM Quantum Runtime REST Runner

The repository also includes an explicit hardware runner that talks to IBM Quantum Runtime through
REST:

```sh
nix run .#wire-quantum-ibm-rest -- examples/wire/quantum-bell-state-ibm-rest.wire --dry-run --config examples/wire/quantum-ibm-runtime.config.example.json
```

That example starts with a config node:

```wire
node ibm_runtime_config
  -> config: IBMQuantumConfig = @quantum.ibm_runtime_config { path = "quantum-ibm-runtime.local.json"; } (null);
```

The runner treats that node as the source of the provider config path. The config path is resolved
relative to the `.wire` file. The example threads the config token into the first prepare node only
to make the Wire graph connected; the runner treats it as orchestration data, not quantum state. The
hardware example authors the Bell circuit from backend primitive gates: `h` is decomposed as
`rz(pi/2) => sx => rz(pi/2)`, and `cnot` as `h(target) => cz => h(target)`. `*.local.json` files are
ignored by git, so real credentials should live in `examples/wire/quantum-ibm-runtime.local.json`.
The tracked template at
[`../../examples/wire/quantum-ibm-runtime.config.example.json`](../../examples/wire/quantum-ibm-runtime.config.example.json)
shows the expected shape:

```json
{
  "api_key_env": "QISKIT_IBM_API_KEY",
  "instance_crn": "REPLACE_WITH_IBM_QUANTUM_RUNTIME_SERVICE_CRN",
  "backend": "least_busy"
}
```

`api_key_env` keeps the API key in the environment. A local config may instead use an `api_key`
field, but that file should remain untracked. `instance_crn` is the IBM Quantum Runtime service CRN
used in the REST `Service-CRN` header. The default API base URL is
`https://quantum.cloud.ibm.com/api/v1`; `eu-de` instances should use
`https://eu-de.quantum.cloud.ibm.com/api/v1`.

Hardware submission is opt-in:

```sh
nix run .#wire-quantum-ibm-rest -- examples/wire/quantum-bell-state-ibm-rest.wire --shots 100 --confirm-hardware
```

Without `--confirm-hardware`, the runner refuses to submit. With `--dry-run` or `--emit-request`, it
builds the OpenQASM 3 sampler request locally without requesting an IAM token and without queueing a
job. `backend = "least_busy"` asks the runner to choose an online non-simulator backend with enough
qubits; a concrete backend can be selected with the config `backend` field or the `--backend` flag.

## Iterative Phase Estimation Runner

The `wire-quantum-ipea` app demonstrates adaptive phase estimation as a sequence of fresh Wire
rounds. Each round compiles a new Wire graph, executes one quantum measurement, carries that
measured bit back into classical Python state, and uses the accumulated bits to choose the next
round's feedback angle. This is adaptive circuit authoring, not hidden mid-circuit backend feedback.

Local simulation is the default:

```sh
nix run .#wire-quantum-ipea -- --shots 100 --seed 7
```

The default target phase is `5/8` with `3` measured bits, so an ideal run estimates bitstring `101`.
The generated round shape is represented by
[`../../examples/wire/quantum-ipea-round.wire`](../../examples/wire/quantum-ipea-round.wire). The
Wire round uses `rz`, `sx`, `x`, and `rzz` executor nodes. For IBM Runtime REST, the OpenQASM
lowerer expands `rzz` into `rz/sx/cz` operations because IBM's current standard QASM loaders do not
define an `rzz` gate name. The Wire file binds the round fragments with graph-valued `let`s:

```wire
let h_control =
  h_control_rz_a
    => h_control_sx
    => h_control_rz_b;

let controlled_phase =
  (phase_control_rz <> phase_target_rz)
    => phase_rzz;

let feedback_and_readout =
  feedback_control_rz
    => readout_h
    => measure_phase;
```

Dry-run mode compiles every generated round and can persist the generated Wire without simulation or
provider submission:

```sh
nix run .#wire-quantum-ipea -- --dry-run --emit-round-wire /tmp/wire-ipea-rounds
```

Hardware execution uses the same ignored IBM Runtime config file as the Bell example and still
requires explicit confirmation:

```sh
nix run .#wire-quantum-ipea -- --hardware --shots 100 --confirm-hardware
```

Because each round is a separate provider job, this demo spends hardware budget per measured phase
bit. Use `--dry-run` first to inspect the generated rounds and OpenQASM 3.

## Quantum Eraser Wire Experiment

[`../../examples/wire/quantum-eraser-experiment.wire`](../../examples/wire/quantum-eraser-experiment.wire)
is the source of truth for the full delayed-choice quantum eraser sweep. It is an executable Wire
scaffold: a pure planning node builds nine `std.io.command` leaves, the topology sequences those
leaves, and a final pure node parses and summarizes the run with `fromJson`. Each command leaf
submits a checked-in Wire circuit file through the IBM Runtime REST bridge.

The example is a gate-model analogue of the delayed-choice quantum eraser, framed as a correlation
experiment rather than retrocausality: the later marker-basis choice does not change the
unconditional screen statistics. Interference is recovered only after sorting the results by the
marker outcome.

The full scaffold is a hardware sweep and queues nine IBM Runtime sampler jobs:

```sh
nix run .#wire-quantum-eraser -- --confirm-hardware
```

The app runs the Wire file through `wire run` and places `wire-quantum-ibm-rest` on `PATH` for the
command leaves. The command leaves request JSON output, and the final pure Wire analyzer renders a
compact table framed around the three-circular-polarizer analogy: path marking flattens the
unconditional screen, while eraser-basis marker slices recover complementary fringes. The experiment
executes these checked-in circuit files:

- `quantum-eraser-open-phase-{0,1_4,1_2}.wire`
- `quantum-eraser-which-path-phase-{0,1_4,1_2}.wire`
- `quantum-eraser-round.wire` for eraser phase `0`
- `quantum-eraser-eraser-phase-{1_4,1_2}.wire`

The eraser round uses graph-valued `let`s to name the screen split/recombine fragments, the marker
path-marking fragments, and the delayed eraser-basis readout:

```wire
let recombine_screen =
  recombine_rz_a
    => recombine_sx
    => recombine_rz_b
    => measure_screen;

let marker_eraser_readout =
  z_marker_eraser_rz_a
    => z_marker_eraser_sx
    => z_marker_eraser_rz_b
    => z_measure_marker;
```

To inspect an individual circuit before spending provider time, run that file through the IBM REST
bridge in dry-run mode. Dry-run compiles the Wire file and emits the OpenQASM 3 request without
provider submission:

```sh
nix run .#wire-quantum-ibm-rest -- examples/wire/quantum-eraser-round.wire --dry-run --config examples/wire/quantum-ibm-runtime.config.example.json
```

Hardware execution of an individual row submits that Wire-authored circuit as one provider job:

```sh
nix run .#wire-quantum-ibm-rest -- examples/wire/quantum-eraser-round.wire --shots 100 --confirm-hardware
```

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
