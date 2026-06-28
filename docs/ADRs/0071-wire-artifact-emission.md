---
title: "ADR 0071 — Artifact-Emission Boundary Node and Durable Artifact-Reference Contract"
description:
  "A Wire node that names a durable artifact kind and a qualified target compiles to a distinct
  artifact-emission boundary node; artifact_ref is a first-class, contract-typed payload kind. Both
  are substrate-generic, carrying no reasoning or report semantics."
sidebar:
  label: "0071. Artifact emission"
  order: 71
status: proposed
date: 2026-06-27
superseded_by: null
related:
  - docs/Architecture/08-artifacts-and-provenance.md
  - docs/Architecture/05-wire-language.md
  - docs/ADRs/0006-compiled-workflow-artifact-boundary.md
  - docs/ADRs/0002-cortex-downstream-ownership-boundary.md
  - docs/ADRs/0039-wire-node-boundary-transform-normal-form.md
  - docs/ADRs/0040-logos-owned-reasoning-surfaces.md
  - docs/Reference/feature-status.md
---

# ADR 0071 — Artifact-Emission Boundary Node and Durable Artifact-Reference Contract

## Status

Proposed — names the in-graph artifact-emission boundary node and the `artifact_ref` payload kind as
a single substrate decision. The mechanism is already partially implemented; this ADR records the
boundary it draws, not a new capability.

## Context

Cortex already has a compiled-artifact boundary for whole workflows:
[ADR 0006 — Compiled Workflow Artifact Boundary](./0006-compiled-workflow-artifact-boundary.md)
makes _the workflow itself_ a first-class compiled artifact between product intent and Pulse
lowering. That decision governs the circuit-as-artifact, not a value a running graph emits.

A second, distinct construct exists in the Wire compiler with no governing ADR: an **in-graph
artifact-emission node** and a **durable artifact-reference payload kind**. Concretely, three pieces
are implemented and entangled:

- A node whose configured executor call carries an `artifactKind` (canonical) or `kind` (deprecated
  alias) field and/or a `to` target field is dispatched away from the ordinary executor-task path
  and lowered into a dedicated artifact boundary. This is the `@…{ artifactKind: …; to: … }` form;
  the conventional executor identity placed in that position is `artifact.store`. The dispatch in
  `loweredNodeFromExecutorCall` (`src/Cortex/Wire/Compile.hs`) keys on the _presence of the fields_,
  not on the executor name.
- An `artifact_ref` member of `WirePayloadKind` (`src/Cortex/Wire/Value.hs`) — a contract-typed
  payload kind with media type `application/vnd.cortex.artifact-ref+json` whose shape is validated
  as "a JSON object".
- A `to` target written as a qualified reference. The conventional sink namespace is `artifacts.*`,
  but the target is parsed and stored as an arbitrary `QualifiedRef`.

This construct is absent from the ADR canon. ADR 0006 governs only the compiled-workflow boundary.
The historical Cortex report-artifact IR — the only prior place an "artifact you emit" was described
— was moved out of Cortex entirely by
[ADR 0040 — Logos-Owned Reasoning Surfaces](./0040-logos-owned-reasoning-surfaces.md), which
relocated report artifact IR to Logos. That left the generic emission mechanism in the substrate
with no decision recording why it is substrate-generic and where the downstream line falls. The risk
is that the absence is read as license to re-grow report-shaped semantics inside Cortex, which
[ADR 0002 — Cortex and Downstream Ownership Boundary](./0002-cortex-downstream-ownership-boundary.md)
forbids.

The substrate vocabulary for value envelopes, contract-owned payload meaning, and provenance is
described in
[Chapter 08 — Artifacts and Provenance](../Architecture/08-artifacts-and-provenance.md), which
already states that downstream report-specific presentation is _not_ owned by this layer. This ADR
pins the emission node and the reference payload kind to that boundary.

## Decision

A Wire node that names a durable artifact **kind** and a qualified **target** is a distinct
artifact-emission boundary node, and `artifact_ref` is a first-class, contract-typed payload kind.
Both are substrate-generic: the kind and the target are opaque to Cortex, and neither carries
reasoning, report, or any downstream product shape.

Specifically:

- **Field-driven dispatch.** In `loweredNodeFromExecutorCall` (`src/Cortex/Wire/Compile.hs`), a
  configured executor call is lowered as an artifact-emission node when it carries
  `artifactKind`/`kind` _or_ `to`. `artifactKind` is the canonical field; `kind` remains an accepted
  deprecated alias because "kind" is already a Wire language concept. Once on the artifact path,
  both `artifactKind` and `to` are mandatory: a missing kind fails with
  `WireMissingRequiredField nodeRef "artifactKind"`, and `to` is read through
  `requireQNameField nodeRef "to"`. This dispatch sits _after_ the signal-node (`on`) check, so a
  node cannot be both a signal and an artifact node.
- **A dedicated node-boundary body.** The node lowers through `artifactNodeBoundaryNormalForm`
  (`src/Cortex/Wire/NodeBoundary.hs`) to a `NodeBoundaryArtifactBody` carrying
  `artifactBodyKind :: Text` and `artifactBodyTarget :: QualifiedRef`, paired with executor ingress.
  `validateNodeBoundaryNormalForm` admits the executor-ingress / artifact-body pairing and rejects a
  CorePure-ingress / artifact-body pairing, so the artifact body is structurally a runtime-egress
  body, not a pure-output body.
- **A distinct compiled circuit node.** The result is a `CircuitArtifactBoundary`
  (`src/Cortex/Wire/Circuit/IR.hs`) — its own `CircuitArtifact` constructor in `CircuitExpr`, with
  `circuitArtifactKind :: Text`, a label, and a JSON metadata object emitted by `emitMetadata`
  (`{ kind, to, ports, timeoutSeconds? }`). It is not a `CircuitTaskNode`.
- **`artifact_ref` is contract-typed, not report-typed.** `WirePayloadArtifactRef`
  (`src/Cortex/Wire/Value.hs`) is one member of the closed `WirePayloadKind` set alongside `json`,
  `markdown`, `text`, and `table`. Its only structural obligation is that the carried value is a
  JSON object; it asserts nothing about reasoning, reports, or any field schema.
- **The substrate owns the contract shape; the host binder owns persistence.** Lowering a
  `CircuitArtifactBoundary` to a Pulse stage goes through the injected `bindCircuitArtifactBoundary`
  hook (`src/Cortex/Wire/Circuit/Lowering.hs`). Cortex ships no concrete artifact-persistence
  interpreter; what happens at the `to` target is the host's responsibility, consistent with
  ADR 0002.

This is the canonical boundary for a value a running graph durably emits, the way ADR 0006 is the
canonical boundary for a compiled workflow. The two do not overlap: 0006 makes the workflow an
artifact; this ADR makes _emitting a durable artifact reference_ a typed node inside a workflow.

## Boundary Rules

The emission node and the reference payload kind are substrate-generic. The following are hard
edges, per ADR 0002.

- **The artifact kind is opaque `Text`.** `artifactBodyKind` / `circuitArtifactKind` is a free
  string. Cortex does not enumerate or interpret kinds. `report` is a downstream-chosen kind string,
  not a substrate concept; where it appears in Cortex it is test or fixture data only.
- **The target is an opaque `QualifiedRef`.** The `to` field is converted by `qnameToQualifiedRef`
  to an arbitrary qualified reference. The `artifacts.*` namespace is a convention for the sink, not
  a compiler-enforced prefix; nothing in the compiler validates that the target begins with
  `artifacts`.
- **`artifact_ref` carries no schema.** Validation is structural only ("a JSON object"). Any
  reasoning- or report-shaped schema for the referenced artifact is downstream (Logos) and out of
  scope for this ADR.
- **No persistence semantics in substrate.** Cortex defines the node shape, the payload kind, and
  the metadata; it does not define, and must not grow, where or how the artifact is stored.

## Alternatives considered

- **Fold emission into ADR 0006's compiled-artifact boundary.** Rejected — 0006 governs the
  workflow-as-artifact (the circuit), a structurally different object from a value emitted by a node
  inside a circuit. Reusing one ADR for both would conflate the compiled circuit with the durable
  references it produces.
- **Treat the emission node as an ordinary executor task with a magic executor named
  `artifact.store`.** Rejected — the compiler already dispatches on the presence of `artifactKind` /
  `to` and produces a distinct `CircuitArtifactBoundary` with its own metadata and node-boundary
  body. Pretending it is a plain task would hide a real node kind and lose the typed boundary.
- **Make `artifact_ref` a report-shaped payload kind with a fixed schema.** Rejected as a direct
  violation of ADR 0002 and ADR 0040: report artifact IR is Logos-owned. The substrate keeps
  `artifact_ref` as a contract-typed reference whose meaning lives in the contract registry, exactly
  as Chapter 08 specifies for payload kinds.

## Consequences

### Positive

- The substrate has a named, single-decision home for the artifact-emission node and the
  `artifact_ref` payload kind, instead of an undocumented mechanism that looks like report IR
  residue.
- The downstream line is explicit: kind and target are opaque, so Logos can build report (or any
  other) artifact surfaces above this boundary without Cortex acquiring product semantics.
- The emission node is a typed first-class circuit node (`CircuitArtifact`), so topology, lowering,
  and provenance treat it uniformly with other node kinds rather than as a tagged task.

### Negative

- Two artifact-flavoured boundaries now coexist (compiled-workflow artifact in ADR 0006, emitted
  artifact reference here); readers must keep them distinct.
- The capability is partial: the `to` target namespace is unenforced, `artifact_ref` validates only
  object-ness, and the substrate ships no persistence interpreter, so an authored emission node is
  honest about intent but not end-to-end durable on its own.

### Obligations

- Keep `artifactBodyKind` / `circuitArtifactKind` and the `to` target opaque; do not enumerate kinds
  or hard-code the `artifacts.*` prefix into report-specific behavior.
- Keep any artifact-reference schema or persistence binding downstream (Logos / host), per ADR 0002
  and ADR 0040.
- If target-namespace validation or a substrate-level `artifact_ref` schema is later wanted, raise
  it as a separate decision rather than extending this one (see open questions in the tracking
  issue).

## Traceability

- Feature keys: `wire.artifact_emission`
- Public surface: `Cortex.Wire`,
  [Chapter 08 — Artifacts and Provenance](../Architecture/08-artifacts-and-provenance.md)
- Implementation: `src/Cortex/Wire/Compile.hs` (`loweredNodeFromExecutorCall` artifact dispatch,
  `emitMetadata`), `src/Cortex/Wire/NodeBoundary.hs` (`ArtifactBody`,
  `artifactNodeBoundaryNormalForm`, `validateNodeBoundaryNormalForm`),
  `src/Cortex/Wire/Circuit/IR.hs` (`CircuitArtifactBoundary`, `CircuitArtifact`),
  `src/Cortex/Wire/Value.hs` (`WirePayloadArtifactRef`), `src/Cortex/Wire/Circuit/Lowering.hs`
  (`bindCircuitArtifactBoundary`)
- Tests: `test/Cortex/Wire/Circuit/IRSpec.hs`, `test/Cortex/Wire/Circuit/CompilerSpec.hs`
- Theory/proof: none

## Related

- [ADR 0006 — Compiled Workflow Artifact Boundary](./0006-compiled-workflow-artifact-boundary.md) —
  the workflow-as-artifact boundary this decision sits beside, not inside.
- [ADR 0002 — Cortex and Downstream Ownership Boundary](./0002-cortex-downstream-ownership-boundary.md)
  — the ownership rule that keeps kind, target, and schema substrate-generic.
- [ADR 0040 — Logos-Owned Reasoning Surfaces](./0040-logos-owned-reasoning-surfaces.md) — relocated
  report artifact IR downstream, leaving the generic emission mechanism in Cortex.
- [ADR 0039 — Wire Node Boundary Transform Normal Form](./0039-wire-node-boundary-transform-normal-form.md)
  — the ingress/body/egress normal form the artifact body is a variant of.
- [Chapter 08 — Artifacts and Provenance](../Architecture/08-artifacts-and-provenance.md) — the
  substrate envelope, payload-kind, and provenance model.
- [Chapter 05 — Wire Language](../Architecture/05-wire-language.md)
- [Cortex Feature Status](../Reference/feature-status.md) — the `wire.artifact_emission` row.
