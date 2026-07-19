---
title: "ADR 0096 - Certified NativePure Compilation"
description:
  "An opt-in v2 execution profile elaborates admitted PureWire nodes into a small intrinsically
  typed Lean kernel, constructively lowers that kernel to typed C IR, and executes the resulting
  bounded functions synchronously without host authority."
sidebar:
  label: "0096. Certified NativePure compilation"
  order: 96
status: accepted
date: 2026-07-19
superseded_by: null
related:
  - docs/ADRs/0062-typed-effect-variant-output-boundaries.md
  - docs/ADRs/0078-lean-wire-elaboration-kernel.md
  - docs/ADRs/0079-wire-admission-witness-schema.md
  - docs/ADRs/0091-lean-hosted-freestanding-wire-c-backend.md
  - docs/ADRs/0092-circuit-engine-runtime-host-boundary.md
  - docs/ADRs/0093-versioned-circuit-state-event-control-protocol.md
---

# ADR 0096 - Certified NativePure Compilation

## Status

Accepted. The representation algebra, normalized plan, and first executable Lean kernel/refinement
slice are implemented. The v2 engine, codecs, and target integration remain gated until their
cross-runtime differential and ABI checks land. This ADR records the complete boundary; feature
status must not describe the unfinished v2 target as generally available.

## Context

CorePure is an ergonomic source language and the existing `pure` executor is a hosted reference
implementation. Mirroring that implementation in a proof file would leave two compilers whose
correspondence was assumed. Native execution also needs fixed layouts, global resource bounds,
exclusive sums, checkpoint values, and a target language narrow enough to audit.

The existing static C backend already establishes the useful division of responsibility: Haskell
elaborates Wire and emits a normalized artifact; a host-side Lean executable validates that artifact
and emits freestanding C; Lean is not linked into the target. NativePure applies this architecture
to deterministic computation while preserving the admitted `CompiledCircuit` as the referent.

## Decision

### Additive profile and artifact boundary

NativePure is opt-in. `static-program/v1`, `cortex_wire_program_v1_*`, `engine/v1`,
`engine-state/v1`, `host-process/v1`, and existing target profiles remain byte-for-byte compatible.
The new family is `cortex.wire.native-pure/v1`; its canonical exchange artifact is
`cortex.wire.native-pure-plan/v1`. Runtime integration uses separately versioned v2 program, engine,
state, process, and target interfaces.

The admitted `CompiledCircuit` remains authoritative. A versioned realization witness binds every
realized unit to its source member and referent identity. NativePure v1 deliberately realizes one
authored pure node as one certified kernel. Cross-node fusion, authored realization boundaries, and
buffer-reuse optimization are deferred; this avoids changing checkpoint and provenance semantics
while the compiler spine is established.

### Strict representation contracts

Native compilation is strict-registry-only. Every crossing contract must provide a `native_shape`:
unit, bool, checked i64, u64, binary64, bounded UTF-8 text, bounded vectors, fixed records, or
tagged sums. Option is a two-variant sum. Shapes are closed, non-recursive, bounded, and parsed
strictly; unknown fields, zero capacities, invalid labels, missing projections, and layout overflow
are rejections. The projection carries the schema identifier `cortex.wire.native-shape/v1`; value
schema validation remains separate from this representation contract.

Exclusive Wire output groups define boundary sums independently of literal enums inside a payload
schema. Ordinary outputs remain products. Exactly one declared variant and its correctly typed
payload crosses a sum boundary.

### Lean is the compiler implementation

The broad CorePure library will elaborate into a deliberately small intrinsically typed Lean
calculus once the elaboration boundary lands. Its executable evaluator is the reference semantics.
Lean constructively lowers this source calculus to a separate typed C-expression IR (currently
isomorphic to the source kernel; it diverges as C-specific semantics land) and proves the executable
source and target evaluators equal for the admitted structural and checked-i64 slice. The lowering
function used by the theorem is the compiler implementation, not a parallel model.

Binary64 uses pinned IEEE-754 settings, finite-result checks, and bitwise differential tests; it is
not claimed by the integer refinement theorem. The C printer and native C compiler remain outside
the proof boundary and are controlled by static assertions, golden output, differential execution,
symbol/section allowlists, sanitizers, and supported-target builds.

### Bounds and storage

Types carry static capacities. Lean defines the size and step models; until Lean elaboration lands,
the Haskell plan computes and enforces the stack, static, output, checkpoint, and step bounds,
rejecting overflow or a worst-case hosted checkpoint above 2 MiB. CorePure values stay immutable SSA
values. After semantic lowering, the first profile needs only read-only crossing inputs and fresh,
disjoint output regions; it does not introduce source-level ownership or borrowing.

Generated kernels are heap-free and authority-free. A pure kernel executes synchronously in the
engine and must never register a host worker or acquire executor authority.

### Runtime ordering and sums

The v2 scheduler commits and acknowledges the predecessor checkpoint before pure execution,
checkpoints an atomic pure-kernel result, and acknowledges that result before requesting a
downstream effect. Product values and selected variant tags are included in checkpoint/restore.

`select(...)` lowers to static guarded branch units. The chosen label is persisted, unselected units
are marked skipped, only the chosen branch runs, and the declared common boundary rejoins. Existing
worker registration, cancellation, deadline, and terminal-authority invariants remain unchanged.

## Consequences

- Wire remains the rich authoring and composition language; extending its helper library does not
  necessarily extend the trusted kernel.
- New semantic primitives require an evaluator case, typed lowering, bound rule, refinement proof or
  explicit validation boundary, and differential corpus.
- NativePure cannot silently fall back to permissive contracts, dynamic allocation, host calls, or
  legacy untyped CorePure arithmetic.
- The first implementation may reject valid hosted CorePure programs when their shape, operation, or
  global bound is outside this profile.
- Cross-node fusion and ownership-driven no-copy optimization require a later ADR because they alter
  provenance, liveness, and checkpoint granularity.

## Alternatives considered

- **Treat Lean as a parallel validator for a Haskell C generator.** Rejected: it leaves the actual
  compiler outside the constructive theorem and creates a correspondence obligation at every
  lowering rule.
- **Mirror the whole CorePure builtin catalogue in Lean.** Rejected: helpers such as `sum`, `any`,
  `enumerate`, and Option utilities elaborate into a smaller bounded basis.
- **Fuse maximal connected pure regions immediately.** Deferred in favor of one source node per
  certified kernel so identity, failure, and checkpoint boundaries stay transparent.
- **Add a source ownership calculus.** Deferred. Immutable values plus read inputs and fresh writes
  are sufficient for the first correct target; buffer reuse is an optimization witness, not source
  semantics.
- **Modify the v1 ABI.** Rejected. NativePure is additive and independently versioned.

## Traceability

- Feature keys: `wire.native_pure_compilation`
- Public surface: `Cortex.Wire.NativePure`, `Cortex.Wire.NativePure.Shape`, pure sum bodies,
  versioned contract `native_shape` projections, and `cortex.wire.native-pure-plan/v1`
- Representation and normalized plan: `src/Cortex/Wire/NativePure.hs`,
  `src/Cortex/Wire/NativePure/Shape.hs`
- Lean kernel, evaluator, C subset, lowering, refinement, and bounds:
  `theory/Cortex/Wire/NativePure.lean`
- Manifest and plan tests: `test/Cortex/Wire/NativePureSpec.hs`, `test/Cortex/Wire/PackageSpec.hs`
- Runtime v2, generated codecs, hosted differential tests, and supported-output gates: pending
