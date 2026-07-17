---
title: "ADR 0091 — Lean-Hosted Freestanding Wire C Backend"
description:
  "Selects a hybrid compiler boundary in which Haskell lowers admitted fixed Wire circuits and a
  host-side Lean compiler validates and emits topology-specialized freestanding C."
sidebar:
  label: "0091. Freestanding Wire C backend"
  order: 91
status: proposed
date: 2026-07-17
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/ADRs/0021-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0078-lean-wire-elaboration-kernel.md
  - docs/ADRs/0079-wire-admission-witness-schema.md
  - docs/ADRs/0090-computable-pulse-kernel-and-extraction-boundary.md
  - docs/Research-notes/Runtime/computable-pulse-kernel-and-c-extraction.md
---

# ADR 0091 — Lean-Hosted Freestanding Wire C Backend

## Status

Proposed — the normalized Haskell artifact, two-node fixture, Lean target semantics and refinement
lemmas, host compiler, generated v1 C ABI, Nix package, host and bare-aarch64 symbol/section gates,
and native wireOS Microkit success/failure boots exist. Exhaustive cross-implementation differential
testing remains an acceptance gate.

## Context

The earlier extraction direction treated the computable Track 2 Pulse kernel as an object library to
place inside a Microkit protection domain. That boundary imports the Lean object runtime into the
deployed system. The runtime investigation in ADR 0090 found that the pinned Lean v4.29.0 object
runtime assumes mimalloc, hosted C++, TLS, process/IO initialization, and other facilities that a
native Microkit PD does not provide. A reduced runtime might still be engineered, but it is not
necessary for a fixed admitted Wire program whose topology is already known at build time.

Wick demonstrates the useful staging shape: use Lean as a build-host compiler and deploy the code it
emits, not Lean itself. Cortex needs a stricter version of that shape. The output must be
freestanding, statically sized, and tied to the admitted Wire topology; hosted allocation and an
axiomatic emitter-correctness claim are not acceptable substitutes.

This also resolves the compiler-authority question left open by ADR 0078 without moving the Wire
parser into Lean. The live Haskell compiler already owns source inclusion, parsing, elaboration,
executor projection, and `CompiledCircuit`. Lean already owns executable proof-facing validators and
the semantic model. The durable boundary is therefore a hybrid compiler pipeline, not a choice
between rewriting the front end in Lean and leaving Lean as fixture-only analysis.

## Decision

Cortex will compile the first freestanding Wire profile through this staged pipeline:

```text
Wire source
  → Haskell parser and elaborator
  → CompiledCircuit plus WireAdmissionArtifact
  → cortex.wire.static-program/v1
  → cortex-wire-c on the build host
  → program.c, program.h, program.manifest.json
  → platform adapter and final target link
```

Lean is not linked into the target. No Lean-generated object, Lean initializer, allocator, TLS
state, or runtime archive is part of the deployment artifact.

### Authority split

- Haskell remains authoritative for Wire source, `CompiledCircuit`, and `WireAdmissionArtifact`. It
  lowers only already-admitted circuits into the deployment input.
- `cortex.wire.static-program/v1` is a normalized deployment input, not another admission artifact.
  It contains the admission schema version, program identity, canonical dense node map, native
  executor identities, and canonical direct edges.
- The host-side Lean executable `cortex-wire-c` is authoritative for the static-profile checks and
  emitted target semantics. It rejects malformed dense IDs, duplicate or noncanonical edges, invalid
  endpoints, cycles, empty identities, delayed CorePure, and unsupported node kinds.
- The C pretty-printer and clang/lld are outside the proof boundary. Lean proves properties of the
  restricted target state-machine semantics; differential, compile, symbol, section, and boot tests
  cover the emitted implementation.
- A platform consumer owns its adapter, effect policy, entrypoint, and final link. Cortex output is
  platform-neutral C and does not import Microkit headers or consumer identities.

### First static profile

The v1 profile is a cold-boot, flat, fixed DAG containing only effectful task nodes. It rejects:

- delayed CorePure and any runtime expression evaluation;
- conditions, select, nested fragments, rewrites, signals, and artifacts;
- cycles, duplicate direct edges, noncanonical dense identifiers, invalid endpoints, and values that
  do not fit the fixed-width C representation; and
- runtime topology loading or durable-state import.

The Haskell lowering assigns dense `uint32_t` identifiers in durable node-reference order and emits
edges lexicographically. The manifest preserves the durable-reference and executor map so the
consumer can prove that its effect table binds exactly the compiled program it links.

### Generated representation

Each generated module owns exactly one program instance. Its storage consists of statically sized
status, opaque-output-handle, and frontier-snapshot arrays plus predecessor CSR tables and a
topological order. Empty logical tables use one inert C storage element so the generated source does
not depend on zero-length-array extensions.

The module uses only fixed-width integers and function pointers from `program.h`. It contains no
heap, C++ runtime, JSON parser, TLS, threads, dynamic topology, or persistence codec. The consumer
may place its sections according to the target linker script and can calculate the logical storage
bound directly from the manifest's node and edge counts.

### Effect ABI and drive semantics

The `cortex_wire_program_v1_*` surface is single-threaded and non-reentrant:

- `init` cold-initializes the static instance and installs a copied effect-function table;
- `drive` snapshots the current frontier, marks every member running, invokes `effect_begin` in
  ascending dense-node order, applies immediate outcomes, and repeats while local progress exists;
- `complete` accepts one asynchronous success, skipped, or failure outcome and rejects invalid,
  stale, or duplicate completion attempts;
- terminal and per-node queries expose structural state and opaque `uint64_t` output handles.

`effect_begin` returns accepted-asynchronous, immediate success, immediate skipped, or immediate
failure. Retryable and indeterminate provider state is not represented in this ABI; it belongs to
the platform adapter. A failure propagates through pending descendants in topological order and
causes best-effort cancellation of other running effects. Running effects return
`awaiting_completions`; they are not sent through the closed-state Track 2 classifier.

The adapter derives idempotency identity from the admitted runtime-plan identity and dense node ID.
The ABI does not claim that an external effect is idempotent merely because a completion is
deduplicated locally.

### Proof boundary

`Cortex.Wire.StaticC` defines the restricted `Fin n` state-machine semantics. Its current theorem
surface establishes:

- every dense node index is within the corresponding generated array bound;
- target readiness is equivalent to Track 2 `DirectReady`;
- success, skipped, and failure completion application refines Track 2 `applyNodeFact`;
- target failure closure denotes Track 2 `propagateFailure`; and
- when no effect is running, target classification is Track 2 `classifyClosedGraphState`, while a
  running effect takes the separate awaiting branch.

The generated C realizes failure closure with a topological pass. Correspondence between that
implementation and the target semantics is an explicit differential-test obligation until a verified
lowering or compiler is introduced. The ADR does not label the text emitter as proved.

## Alternatives considered

- **Deploy the extracted Track 2 object kernel with a reduced Lean runtime.** Removed from the
  wireOS path. It solves a more general dynamic-library problem but adds allocator, TLS, hosted C++,
  initialization, and runtime-closure work that a topology-specialized program does not need. ADR
  0090 retains the evidence in case another consumer requires object-level extraction.
- **Write the freestanding scheduler directly in C or Rust.** This is operationally simple but would
  duplicate readiness, failure, and classification semantics. The chosen target IR keeps those
  semantics Lean-owned while admitting that the pretty-printer remains unverified.
- **Move parsing and full Wire elaboration into Lean.** Rejected for v1. It duplicates a mature
  Haskell front end and is unnecessary at the deployment boundary. Haskell emits a deliberately
  small normalized artifact instead.
- **Generate a generic C runtime that parses topology at boot.** Rejected. Runtime parsing,
  allocation, and topology validation increase the target trusted base and erase the static memory
  advantage of an admitted fixed program.
- **Use CompCert in v1.** Deferred. The first trust boundary is the Lean target semantics plus an
  unverified emitter and clang/lld, backed by differential and native boot tests. A verified C
  lowering remains compatible with the artifact boundary.

## Consequences

### Positive

- Lean remains where its proof and executable-validator value is strongest: on the build host.
- Target code has a finite, inspectable symbol and memory surface with no object runtime.
- Haskell source authority, Lean semantic authority, and consumer effect authority have separate
  artifacts rather than being collapsed into one FFI library.
- Every deployment is specialized to the admitted topology and carries a manifest that can be
  compared exactly with the consumer's effect table.

### Negative

- The backend initially supports only a small subset of Wire.
- The pretty-printer and C compiler remain trusted and require strong differential and boot gates.
- Each topology change regenerates and relinks the program module.
- Cold-boot-only v1 does not provide durable recovery; adding it requires a versioned state contract
  and compatibility decision.

### Obligations

- Differentially compare the Lean target interpreter, generated C, and Haskell `GraphRuntime` over
  exhaustive small DAGs and adversarial lifecycle states.
- Cover empty, singleton, chain, diamond, independent-frontier, failure-closure, stale completion,
  duplicate completion, invalid endpoint, cycle, duplicate-edge, and overflow cases.
- Compile generated C for host and `aarch64-none-elf`; reject undefined `lean_*`, allocation,
  pthread, libuv, and TLS symbols and reject `.tdata`/`.tbss` sections.
- Keep the manifest node map and the platform effect table under an exact equality gate.
- Boot a two-node target fixture in which the first effect completes asynchronously and unlocks an
  immediate second effect. Its failure variant must show that descendants are never dispatched.
- Raise separate decisions before adding durable state import/export, CorePure evaluation,
  conditions/select, signals/artifacts, or post-boot rewrites.

## Traceability

- Feature keys: `wire.static_c_backend`
- Public surface: `wire build --target static-program-v1`, `cortex-wire-c`, and generated
  `cortex_wire_program_v1_*` declarations
- Implementation: `src/Cortex/Wire/StaticProgram.hs`, `app/wire/Main.hs`,
  `theory/Cortex/Wire/StaticC.lean`, `theory/CortexWireC.lean`, `theory/lakefile.lean`, and
  `nix/lean.nix`
- Tests: `test/Cortex/Wire/StaticProgramSpec.hs`, `examples/wire/freestanding-two-node.wire`, Lean
  build/lint gates, generated-C compile and symbol audits, and the consumer-owned wireOS two-node
  Microkit success/failure boot fixture
- Theory/proof: `Cortex.Wire.StaticC.Program.ready_iff_directReady`,
  `applyCompletion_refines_applyNodeFact`, `closeFailures_refines_propagateFailure`,
  `interpretClosed_refines_classifyClosedGraphState`, and `Program.nodeIndex_lt_count`

## Related

- [ADR 0021 — Wire Source Elaborates to Circuits](0021-wire-source-elaborates-to-circuits.md)
- [ADR 0078 — Lean-Owned Wire Elaboration IR](0078-lean-wire-elaboration-kernel.md)
- [ADR 0079 — Wire Admission Witness Schema](0079-wire-admission-witness-schema.md)
- [ADR 0090 — Computable Pulse Kernel and Extraction Boundary](0090-computable-pulse-kernel-and-extraction-boundary.md)
- [Runtime extraction research memo](../Research-notes/Runtime/computable-pulse-kernel-and-c-extraction.md)

## Tracking

- Acceptance requires the cross-implementation differential suite described above.
