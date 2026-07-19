---
title: "ADR 0096 - Certified NativePure Compilation"
description:
  "An opt-in v2 execution profile elaborates admitted PureWire nodes into a small intrinsically
  typed Lean kernel, constructively lowers that kernel to typed C IR, and executes the resulting
  bounded functions synchronously without host authority."
sidebar:
  label: "0096. Certified NativePure compilation"
  order: 96
status: proposed
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

Proposed. This ADR fixes the intended artifact, proof, layout, and runtime boundaries for the
NativePure epic. No NativePure execution profile is generally available yet. Each implementation
slice must retain partial status until its executable checks, differential tests, and target gates
land.

**2026-07-19 implementation note.** The Haskell admission core now derives an ephemeral,
referent-bound candidate set for individually eligible pure nodes. It enforces strict native
crossing shapes, the current certified expression allowlist, exact product/sum layouts, resource
bounds, and the 2 MiB checkpoint ceiling. This candidate set is deliberately not serializable and
does not publish an interim `NativePurePlan` or realization-artifact schema; normalized artifacts,
maximal fusion, provenance witnesses, and stable digests remain the later realization slice.

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
runtime unit to all source members and the referent identity, and maps every realized source member
back to exactly one runtime unit. NativePure v1 selects maximal connected components of eligible
pure nodes subject to exact typed crossings, acyclicity, disjointness, complete provenance, and
explicit checkpoint/select boundaries. Authored or nested realization boundaries and buffer-reuse
optimization remain deferred.

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
calculus. Its executable evaluator will be the reference semantics. Lean will validate the
normalized artifact, compute the region partition, layouts and bounds, and constructively lower the
typed plan into the shared semantic C IR. The lowering function used by the theorem is the compiler
implementation, not a parallel model. The structural and checked-i64 slice requires refinement;
unsupported operations must be rejected before emission.

Binary64 uses pinned IEEE-754 settings, finite-result checks, and bitwise differential tests; it is
not claimed by the integer refinement theorem. The C printer and native C compiler remain outside
the proof boundary and are controlled by static assertions, golden output, differential execution,
symbol/section allowlists, sanitizers, and supported-target builds.

### Bounds and storage

Types carry static capacities. Lean defines the size and step models and returns witnessed stack,
static, output, checkpoint, and step bounds, rejecting overflow or a worst-case hosted checkpoint
above 2 MiB. CorePure values stay immutable SSA values. After semantic lowering, the first profile
needs only read-only crossing inputs and fresh, disjoint output regions; it does not introduce
source-level ownership or borrowing.

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
- Authored fusion boundaries and ownership-driven no-copy optimization require a later ADR because
  they alter provenance, liveness, and checkpoint granularity beyond automatic maximal fusion.

## Alternatives considered

- **Treat Lean as a parallel validator for a Haskell C generator.** Rejected: it leaves the actual
  compiler outside the constructive theorem and creates a correspondence obligation at every
  lowering rule.
- **Mirror the whole CorePure builtin catalogue in Lean.** Rejected: helpers such as `sum`, `any`,
  `enumerate`, and Option utilities elaborate into a smaller bounded basis.
- **Realize one source node per native kernel.** Rejected as the target profile: it preserves source
  granularity but misses the static graph specialization this profile exists to certify. An unfused
  diagnostic mode remains useful for differential testing.
- **Add a source ownership calculus.** Deferred. Immutable values plus read inputs and fresh writes
  are sufficient for the first correct target; buffer reuse is an optimization witness, not source
  semantics.
- **Modify the v1 ABI.** Rejected. NativePure is additive and independently versioned.

## Traceability

- Feature keys: `wire.native_pure_compilation`
- Public surface: `Cortex.Wire.NativePure.Shape`, the experimental internal-candidate API
  `Cortex.Wire.NativePure.Admission`, `docs/Reference/Wire/contracts-ports-and-matching.md`
- Implementation: `src/Cortex/Wire/NativePure/Shape.hs` (versioned bounded shape algebra and fixed
  layout calculation), `src/Cortex/Wire/Contracts.hs` and `src/Cortex/Wire/Package/Manifest.hs`
  (additive contract projection and manifest decoding), and
  `src/Cortex/Wire/NativePure/Admission.hs` (non-serialized strict candidate admission, typed
  expression checks, storage regions, and resource bounds)
- Tests: `test/Cortex/Wire/NativeShapeSpec.hs`, `test/Cortex/Wire/PackageSpec.hs`,
  `test/Cortex/Wire/NativePureAdmissionSpec.hs`
- Theory/proof: open; the executable Lean type and layout correspondence arrives in the dedicated
  kernel slice of this epic

## Tracking

- Feature key: `wire.native_pure_compilation` (partial; bounded contract shapes, fixed layouts, and
  the non-serialized Haskell admission candidate stage are implemented)
- Current executable evidence: `test/Cortex/Wire/NativeShapeSpec.hs`, the `native_shape` manifest
  cases in `test/Cortex/Wire/PackageSpec.hs`, and `test/Cortex/Wire/NativePureAdmissionSpec.hs`
- Planned public surface: versioned `native_shape` projections, realization and NativePure plan
  artifacts, shared typed C IR, pure sum bodies, and additive v2 runtime/target interfaces
- Implementation tracker: GitHub issue #382 and the NativePure epic PR
