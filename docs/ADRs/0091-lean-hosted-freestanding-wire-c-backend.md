---
title: "ADR 0091 — Lean-Hosted Freestanding Wire C Backend"
description:
  "Selects a hybrid compiler boundary in which Haskell lowers admitted fixed Wire circuits and a
  host-side Lean compiler validates and emits topology-specialized freestanding C."
sidebar:
  label: "0091. Freestanding Wire C backend"
  order: 91
status: accepted
date: 2026-07-17
superseded_by: null
related:
  - docs/Architecture/02-ownership-and-boundaries.md
  - docs/Architecture/05-wire-language.md
  - docs/ADRs/0021-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0078-lean-wire-elaboration-kernel.md
  - docs/ADRs/0079-wire-admission-witness-schema.md
  - docs/ADRs/0090-computable-pulse-kernel-and-extraction-boundary.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/Research-notes/Runtime/computable-pulse-kernel-and-c-extraction.md
---

# ADR 0091 — Lean-Hosted Freestanding Wire C Backend

## Status

Accepted. The normalized Haskell artifact, Lean target semantics, host compiler, generated v1 C ABI,
Nix package, host/bare-aarch64 gates, native Microkit fixtures, and cross-implementation
differential suite are implemented. `StaticC.driveEngine_*` supplies the whole-drive refinement, and
the differential corpus covers all DAGs through three nodes plus named and deterministic
representatives through 32 nodes with adversarial lifecycle cases.

**2026-07-19 implementation amendment.** The production `cortex-wire-c` compiler now builds the v1
scheduler, ABI declarations, globals, and functions as a validated structured C11 translation unit.
Source, header, and export inventory are rendered from that one representation. A validated
whitespace-only compatibility layout preserves the published v1 artifact bytes exactly; it cannot
inject, remove, or replace C tokens. The existing schemas, symbols, lifecycle behavior, target
outputs, and four pinned artifact hashes remain unchanged.

**2026-07-19 NativePure amendment.** NativePure adds a separately versioned executable scheduler
policy under `static-program/v2`, `engine/v2`, `engine-state/v2`, `host-process/v2`, and
`x86_64-linux-v2`. It specializes a witnessed realization quotient and executes pure units inside
the engine without host authority. This addition does not replace, alias, or reinterpret any v1
schema, symbol, state transition, artifact byte, or target. The v2 policy reuses the established
`Cortex.Wire.Circuit.HostProtocol` worker/cancellation/terminal-authority rules; those rules and the
TLA+ model are unchanged because this slice adds no new host-worker behavior.

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

### Why the compiler is Cortex substrate, not consumer-owned

`cortex-wire-c` and the generated ABI stay in Cortex rather than moving into wireOS or another
platform consumer's repository, by the general substrate placement test in
[Ownership and Boundaries](../Architecture/02-ownership-and-boundaries.md): a module belongs in the
Cortex substrate when it is reusable outside any one host as runtime, Wire-language, or
executor-registration infrastructure, and stays downstream when it knows about host domain
semantics, model providers, or host tool authority.

The freestanding backend is a second execution target for the same closed Wire semantics Cortex
already owns alongside the Haskell `GraphRuntime` reference driver and the Lean reference
interpreter — not a wireOS-specific capability. It imports no Microkit headers and knows nothing
about UART, board layout, or any other host domain fact (see "Authority split" above). Its entire
value is the differential obligation this ADR carries: proving that Cortex's own frontier, failure,
and completion semantics survive a from-scratch freestanding reimplementation. Only Cortex is
positioned to make that guarantee, since only Cortex has authority over, and visibility into, all
three implementations being compared; a downstream consumer re-deriving this backend would have to
re-prove Cortex's own semantics independently, per consumer, instead of once, upstream, for every
consumer.

This differs from [`extensions/quantum`](../../extensions/quantum/DESIGN.md), which sits outside
Cortex core precisely because quantum gate vocabulary and backend binding are host domain semantics
with no claim on Cortex's own execution semantics. wireOS's role here mirrors Logos's role with
respect to `Cortex.Pulse`: it is the downstream consumer of a Cortex-owned capability, not the owner
of that capability — ADR 0090 already names this relationship directly, stating that the wireOS
deployment path is this ADR's Lean-hosted static C backend.

What moves to the consumer, unchanged from "Authority split" above: the platform adapter
(`effect_begin`/`effect_cancel` bindings to real hardware), entrypoint, final link, and any
consumer-owned executor IDs registered under the consumer's own namespace (see
[Executors and the Alphabet](../Reference/Wire/executors-and-alphabet.md#consumer-owned-executor-ids-in-permissive-compilation)).

### First static profile

The v1 profile is a cold-boot, flat, fixed DAG containing only effectful task nodes. It rejects:

- delayed CorePure and any runtime expression evaluation;
- conditions, select, nested fragments, rewrites, signals, and artifacts;
- cycles, duplicate direct edges, noncanonical dense identifiers, invalid endpoints, and values that
  do not fit the fixed-width C representation; and
- runtime topology loading or durable-state import through the freestanding
  `cortex_wire_program_v1_*` surface.

That freestanding ABI remains unchanged. ADR 0093 adds a separate `cortex_wire_engine_v1_*` ABI for
typed snapshot import/export, checkpoint sequencing, and cancellation; it does not widen or mutate
the v1 platform-adapter contract decided here.

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
- `drive` snapshots the current frontier, then for each member in ascending dense-node order marks
  it running immediately before invoking its `effect_begin`, applying the immediate outcome; it
  stops the pass at the first member that begins failed, leaving later members pending, and repeats
  while local progress exists;
- `complete` accepts one asynchronous success, skipped, or failure outcome and rejects invalid,
  stale, duplicate, or post-terminal completion attempts;
- terminal and per-node queries expose structural state and opaque `uint64_t` output handles.

`effect_begin` returns accepted-asynchronous, immediate success, immediate skipped, or immediate
failure. Retryable and indeterminate provider state is not represented in this ABI; it belongs to
the platform adapter. A failure propagates through pending descendants in topological order and
**latches** the run terminal: the latch cancels each still-running effect exactly once, moves it out
of the running state, and freezes further drives and completions. Because a frontier member is only
marked running immediately before its own begin, a sibling failure in the same frontier never
strands an undispatched member in the running state. Such an undispatched sibling remains `PENDING`
after the terminal-failure latch and, because the latch freezes the instance, remains so for the
lifetime of that initialization. This intentionally distinguishes “never begun” from a running
sibling that was cancelled and moved to `FAILED`; consumers must use `terminal()` for the run result
rather than infer it by requiring every per-node status to settle. Running effects return
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

`driveEngine_checkpointRequired`, `driveEngine_awaiting_refinement`, and
`driveEngine_classification_refinement` cover the whole decision split around durable
acknowledgement, running effects, and closed-state classification. `acceptCompletion_blocks_drive`
proves that an accepted completion cannot unlock another drive before acknowledgement. The generated
C topological pass and text emitter remain outside the proof boundary and are pinned by
differential, compile, symbol, section, sanitizer, and hosted-executable checks; this ADR does not
label the text emitter or C compiler as proved.

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
- The freestanding program ABI remains cold-boot-only; durable recovery uses ADR 0093's separately
  versioned engine ABI and an authority-bearing host.

### Obligations

- **Met.** Differentially compare the Lean reference interpreter, generated C, and Haskell
  `GraphRuntime` over exhaustive small DAGs and adversarial lifecycle states. Realized by
  `checks.cortex-wire-differential`: `wire differential emit` generates the shared corpus and the
  Haskell reference traces, `cortex-wire-diff` replays it through the Lean interpreter, and the
  generated C is compiled per topology and driven by a shared harness; the three trace streams must
  match byte-for-byte, and the harness additionally asserts exactly-once cancellation.
- **Met.** Cover empty, singleton, chain, diamond, independent-frontier, failure-closure, stale
  completion, duplicate completion, invalid-completion, and post-terminal cases. The static-program
  validator rejects invalid endpoint, cycle, duplicate-edge, and overflow inputs, exercised by
  `cortex-wire-c-smoke`.
- **Met.** Cover larger representative topologies. The corpus includes independent-8, chain-16,
  layered-16, and deterministic seeded DAGs through 32 nodes; the index records the bound and seeds.
- **Met.** Compile generated C for host and `aarch64-none-elf`; reject undefined `lean_*`,
  allocation, pthread, libuv, and TLS symbols and reject `.tdata`/`.tbss` sections.
- **Met.** Keep the manifest node map and the platform effect table under an exact equality gate.
- **Met.** Boot a two-node target fixture in which the first effect completes asynchronously and
  unlocks an immediate second effect. Its failure variant must show that descendants are never
  dispatched.
- **Met.** Prove the whole-drive decision split and acknowledgement gate in Lean through
  `driveEngine_*` and `acceptCompletion_blocks_drive`.
- Raise separate decisions before adding CorePure evaluation, conditions/select, signals/artifacts,
  or post-boot rewrites.

## Traceability

- Feature keys: `wire.static_c_backend`
- Public surface: `wire build --target static-program-v1`, `cortex-wire-c`, and generated
  `cortex_wire_program_v1_*` declarations
- Implementation: `src/Cortex/Wire/StaticProgram.hs`, `src/Cortex/Wire/StaticDifferential.hs`,
  `app/wire/Main.hs`, `theory/Cortex/Wire/StaticC.lean`, `theory/CortexWireC.lean`,
  `theory/Cortex/Wire/C11.lean`, `theory/Cortex/Wire/StaticCEmitter.lean`,
  `theory/Cortex/Wire/StaticCEmitter/Unit.lean`, `theory/Cortex/Wire/StaticCEmitter/Layout.lean`,
  `theory/CortexWireDiff.lean`, `theory/lakefile.lean`, and `nix/lean.nix`
- Tests: `test/Cortex/Wire/StaticProgramSpec.hs`, `test/Cortex/Wire/StaticDifferentialSpec.hs`,
  `test/fixtures/wire/static-program-v1/differential-harness.c`,
  `test/fixtures/wire/static-program-v1/program.c.golden` and sibling v1 artifact goldens,
  `examples/wire/freestanding-two-node.wire`, the `cortex-wire-differential` three-way check, Lean
  build/lint gates, generated-C compile and symbol audits, and the consumer-owned wireOS two-node
  Microkit success/failure boot fixture
- Theory/proof: `Cortex.Wire.StaticC.Program.ready_iff_directReady`,
  `applyCompletion_refines_applyNodeFact`, `closeFailures_refines_propagateFailure`,
  `interpretClosed_refines_classifyClosedGraphState`, `driveEngine_checkpointRequired`,
  `driveEngine_awaiting_refinement`, `driveEngine_classification_refinement`,
  `acceptCompletion_blocks_drive`, and `Program.nodeIndex_lt_count`

## Related

- [Ownership and Boundaries](../Architecture/02-ownership-and-boundaries.md)
- [ADR 0021 — Wire Source Elaborates to Circuits](0021-wire-source-elaborates-to-circuits.md)
- [ADR 0078 — Lean-Owned Wire Elaboration IR](0078-lean-wire-elaboration-kernel.md)
- [ADR 0079 — Wire Admission Witness Schema](0079-wire-admission-witness-schema.md)
- [ADR 0090 — Computable Circuit-Engine Decision Kernel](0090-computable-pulse-kernel-and-extraction-boundary.md)
- [ADR 0092 — Circuit Engine and Runtime-Host Boundary](0092-circuit-engine-runtime-host-boundary.md)
- [ADR 0093 — Versioned Circuit State, Event, and Control Protocol](0093-versioned-circuit-state-event-control-protocol.md)
- [Wire Reference — Executors and the Alphabet](../Reference/Wire/executors-and-alphabet.md)
- [Runtime extraction research memo](../Research-notes/Runtime/computable-pulse-kernel-and-c-extraction.md)
