---
title: "ADR 0079 — Wire Admission Artifact as Haskell-to-Lean Proof-Witness Exchange Schema"
description:
  "Fixes the schema-versioned Wire admission artifact as the Haskell-to-Lean proof-witness exchange
  contract and names the Lean executable validator as its validation authority."
sidebar:
  label: "0079. Admission witness schema"
  order: 79
status: proposed
date: 2026-06-27
superseded_by: null
related:
  - docs/Architecture/03-formalism-stack.md
  - docs/Architecture/05-wire-language.md
  - docs/Reference/proof-status.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0038-wire-proof-track-theorem-ledger.md
  - docs/ADRs/0039-wire-node-boundary-transform-normal-form.md
  - docs/ADRs/0053-executor-catalog-manifests-and-pulse-bindings.md
  - docs/ADRs/0091-lean-hosted-freestanding-wire-c-backend.md
---

# ADR 0079 — Wire Admission Artifact as Haskell-to-Lean Proof-Witness Exchange Schema

## Status

Proposed — this ADR records the contract shape and validation-authority direction for the Wire
admission artifact. The schema and both validators exist in code; designating Lean as the runtime
validation authority is partially realized and carried as an obligation, not a finished guarantee.

## Context

[ADR 0038](./0038-wire-proof-track-theorem-ledger.md) names the Wire proof-track theorem targets and
splits them into mechanized Lean surfaces, Lean targets, Haskell correspondence targets, and
deferred semantic targets. It deliberately defers two questions that the ledger rows depend on but
does not itself settle: what the _data contract_ is that carries a compiler lowering decision across
the Haskell/Lean boundary, and which side is _authoritative_ when that contract is checked. ADR
0038's own "Wire Admission Artifact Notes" describe behaviour of a `WireAdmissionArtifact` and a
`validatorReady` predicate without ever fixing them as a governed contract.

Today the substrate has a concrete answer in code, but no ADR records it as a decision:

- The Haskell compiler emits a `WireAdmissionArtifact` (`src/Cortex/Wire/AdmissionArtifact.hs`) — a
  deterministic, JSON-serializable evidence record of its lowering decisions (summary nodes, binding
  references, boundary entry/exit ports, raw connections, a postorder primitive trace, generated
  `make`/`makeEach` rows, phantom-adapter `*` rows, and `select(...)` admission rows). The module
  header is explicit that it carries _evidence_, not Lean proof terms.
- The record is schema-versioned. `wireAdmissionCurrentSchemaVersion = 4`, and the `FromJSON`
  instance hard-fails any other version with `unsupported wire admission schema version`. Version 4
  carries closure mode and endpoint-use witnesses on top of the phantom-adapter record aggregate
  contract added in version 3.
- Both sides already implement a validator over this record. Haskell decides
  `wireAdmissionArtifactValidatorReady :: WireAdmissionArtifact -> Bool` (a conjunction of ~30 row,
  uniqueness, domain-closure, frontier-backing, primitive-replay, select, and phantom checks). Lean
  mirrors the same predicate as `AdmissionArtifact.ValidatorReady` and proves the executable
  `AdmissionArtifact.validatorReadyCheck` sound against it.

What is missing is a decision that _fixes the artifact as the contract_ and _says who is
authoritative_. Without it, the schema version is an implementation detail rather than a governed
boundary; the two validators can drift; and there is no recorded direction for whether the Lean
checker — the side that can be proven sound — is the authority or merely a mirror. ADR 0038's
obligation "If the compiler-authority decision later chooses Lean as compiler spec or
implementation, this ADR should be updated or superseded" makes the authority question live but does
not answer it for the _artifact_.

## Decision

The schema-versioned `WireAdmissionArtifact` is the canonical Haskell-to-Lean proof-witness exchange
contract for Wire admission, and the Lean executable validator is its designated validation
authority.

Concretely:

1. **The artifact is the contract.** The Haskell compiler hands its lowering decision to the proof
   model only as a `WireAdmissionArtifact`, never as Lean proof terms or compiler-internal state.
   The record's fields and JSON encoding are the boundary surface; both sides agree on it through
   the shared schema version.
2. **The schema is versioned and version-gated.** `wireAdmissionCurrentSchemaVersion = 4` is the
   single current version. Decoding rejects any other version rather than best-effort parsing it.
   Schema changes bump this number; an artifact tagged with a version a reader does not understand
   is a hard decode failure, not a silent partial read.
3. **Lean is the validation authority for the contract.** `AdmissionArtifact.validatorReadyCheck` is
   the authoritative decision procedure, and `AdmissionArtifact.validatorReadyCheck_soundness` lifts
   a successful build-time check to the proof-facing `AdmissionArtifact.Sound` contract. The Haskell
   `wireAdmissionArtifactValidatorReady` predicate is the _compiler-side gate_ that mirrors it: the
   compiler must not attach an artifact that fails it. Where the two are checked over the same
   artifact and disagree, the Lean result is canonical.
4. **A differential replay oracle independently re-derives the boundary.** For each emitted fixture,
   a generated Lean differential module reconstructs the composition from the artifact's primitive
   trace and replays it through the elaboration kernel (`CertifiedGraph.elaborate`), then `#guard`s
   that the kernel's exposed input/output frontier equals the frontier the compiler recorded. This
   checks composition, not the artifact's internal shape; it is frontier-level by construction.
5. **Admission and deployment artifacts remain distinct.** ADR 0091's
   `cortex.wire.static-program/v1` is derived only after the admission artifact is bound to its
   `CompiledCircuit`. It carries dense target IDs and native executor identities for C emission; it
   neither replaces `WireAdmissionArtifact` nor carries its proof-witness trace.

The Lean-as-runtime-authority part is scoped as a recorded direction (see Obligations): the Lean
checker is proven sound and runs at build time over the emitted-fixture corpus, but the runtime gate
that decides whether a freshly compiled artifact may travel is still the Haskell predicate. No
production path decodes JSON into the Lean checker yet.

## Mental Model

The handoff is a staged pipeline with the artifact as the only thing that crosses the boundary:

1. **Emit (Haskell).** `Cortex.Wire.Compile` lowers a Wire program and builds a
   `WireAdmissionArtifact` tagged with the current schema version.
2. **Gate (Haskell).** `validateWireAdmissionArtifact` admits the artifact only if
   `wireAdmissionArtifactValidatorReady` holds, then `attachAdmissionMetadata` embeds it in the
   compiled circuit's metadata under a fixed admission key. A separate binder,
   `admissionArtifactBindsCompiledCircuit` (`src/Cortex/Wire/AdmissionBinding.hs`), checks that
   _this_ artifact and _this_ circuit describe the same graph surface — schema version, node set,
   projected topology, derived boundary, metadata attachment, and select-body reconstruction — so
   the two cannot silently drift even though they were built from the same lowering fragment.
3. **Render (Haskell → Lean).** `Cortex.Wire.LeanFixture` renders artifacts from real compilations
   into `Cortex.Wire.AdmissionArtifact.Emitted.*` Lean modules and a parallel differential-oracle
   module per fixture. The Haskell test suite re-renders and fails on drift;
   `just wire-lean-fixtures` regenerates.
4. **Validate (Lean).** Each emitted module `#guard`s `artifact.validatorReadyCheck` and packages
   the result as `artifact.Sound` via `validatorReadyCheck_soundness (by native_decide)`. The
   differential module independently replays composition onto the recorded frontier.

The schema version is the join: it is the one field every stage agrees on, and the gate that lets a
reader refuse an artifact it was not built to understand.

## Alternatives considered

- **Serialize Lean proof terms across the boundary.** Rejected — it couples the Haskell compiler to
  Lean's internal proof representation and makes every proof refactor a wire-format break. The
  artifact deliberately carries _evidence the validator can re-decide_, not proofs, which is what
  lets the soundness theorem live entirely on the Lean side.
- **Make the Haskell predicate the authority and treat Lean as a mirror.** Rejected as the _target_
  direction — only the Lean side carries `validatorReadyCheck_soundness`, so only it can connect a
  passing check to the proof-facing `Sound` contract. Haskell remains the compiler-side gate, but
  authority over what the contract _means_ belongs to the side that can prove it.
- **Leave the artifact unversioned and evolve it structurally.** Rejected — without a version gate,
  a reader silently best-effort-parses an artifact it does not fully understand, which is exactly
  the drift this contract is meant to make detectable. The hard
  `unsupported wire admission schema version` failure is the point.
- **Fold this into ADR 0038.** Rejected — 0038 is the theorem _ledger_ and is explicitly a
  non-feature ledger ADR; the contract-and-authority decision is a separate, feature-keyed decision
  that the ledger rows depend on.

## Consequences

### Positive

- The Haskell/Lean boundary for Wire admission is a single, named, versioned data contract rather
  than an implicit agreement between two code paths.
- The soundness story has a fixed home: a passing Lean `validatorReadyCheck` implies `Sound`, and
  that implication is reusable for every artifact the compiler emits, not re-argued per fixture.
- Schema drift surfaces as a hard decode failure (version gate) or a failing render test (fixture
  drift) instead of a silent misread.
- The differential oracle gives an _independent_ composition check that does not depend on the
  validator's internal shape, so a validator that is internally consistent but wrong about the
  frontier is still caught.

### Negative

- Two validators must be kept in lockstep until the runtime authority migrates to Lean; the Haskell
  predicate and the Lean check are mirror obligations, and ADR 0038's ledger already tracks this
  mirror as ongoing correspondence work.
- The emitted-fixture corpus is finite. Soundness is proven for the artifacts in the corpus; it is
  not a proof that _every_ compiler output is validator-ready.
- A schema bump is a coordinated change across the Haskell record, its JSON instances, the Lean
  carrier, and the rendered fixtures.

### Obligations

- **Realize Lean as the runtime validation authority.** Today the Lean checker runs only at build
  time over the emitted-fixture corpus; the runtime gate is still
  `wireAdmissionArtifactValidatorReady`. Direct decoding of production-emitted JSON into the Lean
  checker — so that Lean validates arbitrary runtime artifacts, not just fixtures — remains open and
  is the load-bearing step that would turn "intended authority" into "authority". Track under the
  Wire admission correspondence rows of ADR 0038.
- **Keep the two validators mirrored.** Any change to `wireAdmissionArtifactValidatorReady` must be
  reflected in `AdmissionArtifact.validatorReadyCheck` and its soundness chain, and vice versa.
- **Version every schema change.** Any field or encoding change bumps
  `wireAdmissionCurrentSchemaVersion` and regenerates the emitted fixtures.
- Preserve ADR 0091's artifact split: Haskell constructs this admission witness; the static
  deployment artifact is derived only after binding succeeds. Moving admission construction into
  Lean would require revisiting this decision.

## Traceability

- Feature keys: `proof.admission_artifact_schema`
- Public surface: `Cortex.Wire` (the `Cortex.Wire.AdmissionArtifact` record, schema version, closure
  mode, endpoint-use witness, and `wireAdmissionArtifactValidatorReady` gate)
- Implementation: `src/Cortex/Wire/AdmissionArtifact.hs`, `src/Cortex/Wire/AdmissionBinding.hs`,
  `src/Cortex/Wire/Compile.hs`, `src/Cortex/Wire/LeanFixture.hs`,
  `theory/Cortex/Wire/AdmissionArtifact/Boundary.lean`,
  `theory/Cortex/Wire/AdmissionArtifact/ValidatorCore.lean`,
  `theory/Cortex/Wire/AdmissionArtifact/ValidatorCoreCheck.lean`,
  `theory/Cortex/Wire/AdmissionArtifact/Sound.lean`
- Tests: `test/Cortex/Wire/CompileSpec.hs`, `test/Cortex/Wire/EndpointUseSpec.hs`
- Theory/proof: [Wire Admission Notes](../Reference/proof-status.md#wire-admission-notes)

## Related

- [Chapter 03 — Algebraic Foundations](../Architecture/03-formalism-stack.md)
- [Chapter 05 — Wire Language](../Architecture/05-wire-language.md)
- [ADR 0038 — Wire Proof-Track Theorem Ledger](./0038-wire-proof-track-theorem-ledger.md) — names
  the theorem targets this contract carries witnesses for, and defers the schema-as-contract and
  authority questions this ADR settles.
- [ADR 0039 — Wire Node Boundary Transform Normal Form](./0039-wire-node-boundary-transform-normal-form.md)
  — the node-boundary witness shape the artifact's frontier rows project from.
- [ADR 0010 — Wire Closed Authority and Three-Layer Stack](./0010-wire-closed-authority-and-three-layer-stack.md)
  — the Haskell/Lean layering this boundary lives inside.
- [ADR 0053 — Executor Catalog Manifests and Pulse Runtime Bindings](./0053-executor-catalog-manifests-and-pulse-bindings.md)
  — the sibling pattern of a schema-versioned Haskell-emitted artifact crossing a runtime boundary.
- [ADR 0062 — Typed Effect Variant Output Boundaries](./0062-typed-effect-variant-output-boundaries.md)
  — the runtime counterpart: emits the committed select variants whose exclusive-group provenance
  this artifact's select rows retain at the proof boundary.
- [Cortex Proof Status](../Reference/proof-status.md)

## Tracking

- ADR 0091 resolves the deployment compiler boundary while preserving this schema as the separate
  Haskell-to-Lean proof-witness contract.
