# Quantum Extension Design

Status: draft design note.

This is not a Cortex ADR. It is an in-repo downstream extension design for a quantum capability
library and Braket runtime binding. The generic manifest and authority rules are defined by ADR
0060; this document is only the first downstream-style consumer of that mechanism. The goal is to
prove the extension model inside the monorepo first, with tests and showcase examples, while
preserving the same dependency direction an out-of-tree downstream project would have.

## Placement

Use:

```text
extensions/quantum/
```

Do not use `plugins/quantum/` for this first shape. "Plugin" suggests that Cortex core has a runtime
plugin loader or that importing the extension grants executable authority. The design we want is
more precise:

- Wire packages provide inert compile-time vocabulary.
- Host binding packs provide runtime authority.
- Pulse receives already-bound actions and does not know quantum semantics.

`extensions/quantum/` makes the repo role clear: this is a Cortex extension hosted in-tree for
development, review, and examples. It should be movable into a separate repository without changing
the Cortex substrate contract.

## Proposed Tree

This is the target layout, not the current on-disk state. Today `extensions/quantum/` contains
`DESIGN.md`, `packages/{quantum-core,quantum-qec,quantum-braket}/cortex.toml`, and `src/` — the
`cortex-quantum` library that holds the Braket host binding pack and depends on Cortex core, not the
other way round. The `wire/`, `binding-packs/`, `examples/`, and `test/` entries below are planned
additions.

```text
extensions/quantum/
  DESIGN.md
  src/
    Cortex/Capability/BindingPack/Braket.hs   (the cortex-quantum library)
  packages/
    quantum-core/
      wire/
      cortex.toml
    quantum-qec/
      wire/
      cortex.toml
    quantum-braket/
      wire/
      cortex.toml
  binding-packs/
    braket/
      cortex.toml
      config.example.json
  examples/
    qec-repetition/
      qec-repetition-realize.wire
      braket.config.example.json
  test/
```

The package manifest format is `cortex.toml`: author-facing TOML metadata, not an internal JSON
encoding. The important naming split should not change:

- `packages/` contains inert Wire package material.
- `binding-packs/` contains host authority and backend bindings.
- `examples/` contains downstream examples that consume those packages.

## Relationship To ADR 0060

The quantum extension must not define a quantum-specific package system. Its manifests are ordinary
ADR 0060 manifests:

- `quantum.core`, `quantum.qec`, and `quantum.braket` are Wire package manifests. They register
  namespaces, contracts, and executor projections (`WireExecutorProjection`). Capability requirement
  slots are a later ADR 0060 slice; no quantum manifest declares one yet. They do not register
  credentials, SDK clients, queues, or Pulse actions.
- `binding-packs/braket/cortex.toml` is the target host runtime material: it will resolve the
  capability requirements declared by the package manifests into an AWS Braket `StageAction`,
  runtime binding record, authority fingerprints, and compatibility policy. Today that resolution is
  a hand-built stub in the `cortex-quantum` extension library (`extensions/quantum/src`, module
  `Cortex.Capability.BindingPack.Braket`), pending the binding-manifest slice.
- `use quantum.*` is therefore the same operation as `use logos.*` or any future downstream
  namespace: it imports compile-time vocabulary only.

This distinction is especially important for `quantum.braket`. It may export Braket-specific source
vocabulary, such as a provider-specific `@realize` leaf, but the exported executor remains inert
until the host selects a Braket binding pack.

## Package Boundary

The quantum extension should publish at least three Wire packages.

### `quantum.core`

Generic quantum circuit vocabulary:

- contracts: `Qubit`, `Bit`, `ShotCount`, `QuantumResult`, `MeasurementCounts`, `BackendConfig`
- target executor alphabet: `@prepare_zero`, `@x`, `@h`, `@rz`, `@sx`, `@cnot`, `@cz`, `@measure_z`.
  The current `quantum-core/cortex.toml` declares the subset `@prepare_zero`, `@x`, `@h`, `@rz`,
  `@cnot`, `@measure_z`; `@sx` and `@cz` are not yet declared.
- no AWS, Braket, Qiskit, credentials, queue policy, or Pulse action

`Bit` is a symbolic measurement token before realization. It is not a realized multi-shot value by
itself.

### `quantum.qec`

Reusable QEC vocabulary and pure decoders:

- contracts for syndrome/result records where useful
- reusable Wire modules for repetition-code circuits
- pure decoder/report helpers that consume `QuantumResult`

This package should stay backend-neutral.

### `quantum.braket`

Braket-specific realization vocabulary:

- `@realize`, or a Braket-specialized exported alias for `@quantum.realize`
- Braket-specific config contract names if they are needed at Wire admission time

This package still has no AWS credentials and no SDK authority. Importing it with `use` only brings
names into scope.

## Binding Pack Boundary

The Braket binding pack is the first authority-bearing runtime pack:

- resolves `quantum.realize` to a Pulse `StageAction`
- injects AWS profile, region, device ARN, S3 bucket, and prefix
- lowers the admitted fused quantum plan to OpenQASM
- submits to Amazon Braket
- parks and resumes long-running tasks through the durable external-call protocol
- fetches results and maps them into `QuantumResult`
- reports task ARN, S3 result URI, backend metadata, shot count, and a cost estimate

The binding pack is host/runtime material. A Wire package must not depend on it.

The package side declares only the requirement for a quantum backend capability. The binding side
satisfies that requirement by choosing AWS Braket and recording the concrete authority fingerprints.
If the package is present but the Braket binding pack is absent, Wire compilation may still succeed;
Pulse lowering must fail with a missing runtime binding.

## Native Wire Shape

The target authoring style is native Wire topology plus an explicit realization frontier:

```wire
use quantum.core.{Qubit, Bit, QuantumResult};
use quantum.core.{@prepare_zero, @x, @cnot, @measure_z};
use quantum.braket.{@realize};

node prepare_d0
  -> d0: Qubit = @prepare_zero {} (null);

node prepare_d1
  -> d1: Qubit = @prepare_zero {} (null);

node prepare_s01
  -> s01_qubit: Qubit = @prepare_zero {} (null);

node force_x
  <- d1: Qubit;
  -> d1: Qubit = @x {} (d1);

node check_01
  <- d0: Qubit;
  <- s01_qubit: Qubit;
  -> d0: Qubit;
  -> s01_qubit: Qubit = @cnot ({ inherit d0; inherit s01_qubit; });

node measure_d0
  <- d0: Qubit;
  -> final_d0: Bit = @measure_z {} (d0);

node measure_s01
  <- s01_qubit: Qubit;
  -> s01: Bit = @measure_z {} (s01_qubit);

node run_hardware
  <- final_d0: Bit;
  <- s01: Bit;
  -> result: QuantumResult
  = @realize { shots = 100 } ({ inherit final_d0; inherit s01; });
```

The realization output should be one correlated `QuantumResult`, not one independent output per
measurement. QEC needs joint shot correlations such as `final_d0, final_d1, final_d2, s01, s12`;
per-bit marginals are projections from the aggregate result.

## Runtime Flow

1. Wire compiles against `quantum.*` packages without any provider credentials.
2. A Pulse run selects the Braket binding pack and local config.
3. The lowerer finds `@quantum.realize`.
4. The lowerer walks the upstream symbolic quantum frontier feeding the realization node.
5. The lowerer admits only a same-authority quantum frontier and rejects mixed backend/non-backend
   collection.
6. The lowerer emits a canonical fused plan and idempotency key.
7. The Braket stage action submits, parks, resumes, fetches, and returns `QuantumResult`.
8. Pure downstream Wire/Pulse nodes decode QEC syndromes and render reports.

Future command shape:

```sh
wire pulse run extensions/quantum/examples/qec-repetition/qec-repetition-realize.wire \
  --wire-package extensions/quantum/packages/quantum-core \
  --wire-package extensions/quantum/packages/quantum-qec \
  --wire-package extensions/quantum/packages/quantum-braket \
  --binding-pack extensions/quantum/binding-packs/braket \
  --config extensions/quantum/examples/qec-repetition/braket.local.json
```

The exact CLI flags can change, but the separation cannot: package imports are compile-time
vocabulary; binding packs are runtime authority.

## Compatibility With Current Bridges

The existing Python/runner bridge can remain as compatibility and development tooling while this
extension grows. It should not be the reviewed native shape for the QEC showcase. The native shape
is `use quantum.*` plus `@realize`, with Pulse owning durable scheduling and the Braket binding pack
owning provider execution.

## Open Design Points

- Whether `@realize` should live canonically as `quantum.realize` with `quantum.braket` exporting a
  provider-specific alias, or whether Braket should own the only initial realization executor id.
  The implementation has provisionally settled this as the core-shaped id `quantum.realize` (bound
  by the Braket pack and exported by `quantum-braket/cortex.toml`). Because the host binding lookup
  keys on the bare executor id, a second backend (e.g. `quantum.qiskit`) binding the same
  `quantum.realize` would collide; resolving this open point — provider-namespaced realize ids
  and/or version-keyed binding lookup — is a prerequisite for a second realization backend.
- The first minimal `QuantumResult` schema that supports QEC without overfitting to Braket.
- The host binding-pack manifest format for Braket runtime authority, following ADR 0060's generic
  binding-manifest shape rather than a quantum-only configuration file.
- The CLI/project-discovery path for selecting package manifests explicitly. The current showcase
  can rely on repo-local defaults while the extension is in-tree, but the stable shape should use
  explicit package selection or project-level discovery.
