---
title: "ADR 0080 — Wire Binder Construction and the Contract-Typing Boundary"
description:
  "Bounds the near-term Wire binder-construction helper to a minimal label-only hook, and draws the
  boundary between it, the deferred contract-typing layer, and binder composition (ADR 0054)."
sidebar:
  label: "0080. Binder construction boundary"
  order: 80
status: proposed
date: 2026-06-28
superseded_by: null
related:
  - docs/ADRs/0017-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0033-wire-select-guarded-affine-collapse.md
  - docs/ADRs/0053-executor-catalog-manifests-and-pulse-bindings.md
  - docs/ADRs/0054-downstream-wire-packages-and-host-bindings.md
  - docs/ADRs/0062-typed-effect-variant-output-boundaries.md
  - docs/Reference/Wire/conditionality.md
---

# ADR 0080 — Wire Binder Construction and the Contract-Typing Boundary

## Status

Proposed — a boundary/design decision. Per ADR 0063 a boundary ADR carries no feature-status row;
the committed-variant binder capability it scopes belongs to `wire.typed_effect_variant_outputs`
(ADR 0062) and is implemented behind this decision.

## Context

The binder-construction work proposed a public `committedVariantBinder` smart constructor so
downstreams can build a `CircuitPulseBinder` without re-deriving the committed-variant wiring.
Before adding public surface, we audited the substrate against our contract/type-system aspirations
to avoid both overengineering the helper and entrenching a shape that fights the contract direction.

**What is built today.** The lowering binder surface is real: `CircuitPulseBinder` (five binder
fields), `committedVariantConditionBinding`, and the production entrypoint `Cortex.Pulse.Circuit`
(ADR 0062). The executor-catalog metadata is real but inert as far as binding goes:
`HostBindingPack` is an executor-id → `RuntimeBindingRecord` lookup; `ExecutorManifest` and
`AdmissionProjection` are static descriptors.

**What is deliberately deferred.** No production code constructs a `CircuitPulseBinder` (only tests
do) — the proposed helper would be the first production construction site. There is no binder
composition over the `CircuitPulseBinder` surface (an ADR 0054 obligation). There is no
`HasContract`/`WireCodec` codec layer (illustrative in ADR 0017; deferred to the contract-typing
follow-up). Payload validation is Layer-1 only (`WirePayloadKind` shape); the `WireContractSpec`
`schema` field and `ExecutorCodecBoundary` exist but are inert. These are intentional deferrals, not
missing scaffolding: the hooks for contract schemas and codecs already exist, so filling them later
does not force a boundary redesign.

**Two aspirations frame the choice.** Contract typing: `ContractId → ContractDefinition` with
schema, versioned identity, and compatibility — but ADR 0017 deliberately decided **contracts are
values, not Haskell types** (so a contract catalog stays portable across process, language, and
replay logs). So "contracts as types" must mean richer _value-level_ nominal types with schemas,
never phantom host types. Binder composition (ADR 0054): deterministic composition of binder hooks
over `CircuitPulseBinder`, owned by host binding packs — a large, mostly unbuilt surface.

## Key questions weighed

**Q1 — Is the helper a one-off, or the first instance of the ADR-0054 composition layer?** The
composition layer is unbuilt and epic-sized; defining a composition _algebra_ now is
overengineering. A single helper shaped as a binder _hook_ (a task-node binding lifted into a
`CircuitPulseBinder` with the condition fixed) is consistent with ADR 0054 and composes later. No
downstream needs it today — the entrypoint already exports `committedVariantConditionBinding` — so
the helper's only value is removing a "remember to wire the condition" footgun. **Decision:** a
minimal, label-only hook; no composition algebra.

**Q2 — Contract-as-name versus contract-as-type: how much to commit now?** ADR 0017 rejects
phantom-typed contracts; the contract-typing follow-up wants schema/version on the value-level
contract; the `schema` field already exists but is inert. Committing schema validation now pre-empts
the contract-typing follow-up. **Decision:** the binder commits nothing to contract typing — it is
purely structural label routing. Contract typing stays value-level and lives in the contract-typing
follow-up, reconciled to ADR 0017 (no host-type identity).

**Q3 — Label-only versus contract-key select.** `resolveSelectArms` resolves an arm key by label
first and falls back to a unique contract name (`SelectResolvedByLabel | SelectResolvedByContract`);
the committed-variant runtime is label-only (ADR 0062). The dual namespace conflates the constructor
(label) with the payload interface (contract). **Decision:** the label is the canonical arm key;
contract-key resolution is source elaboration only, to be warned then removed in a follow-up. The
helper uses the label-based binding and entrenches nothing about contract-keying.

**Q4 — How much codec/typing to commit now?** The audit shows the Layer-1 (Pulse framing, payload
kind/shape) versus Layer-2 (host codecs, schema) split is stable: the inert `schema` slot and empty
`ExecutorCodecBoundary` are exactly the hooks the contract-typing follow-up fills, with no boundary
change. **Decision:** the split is stable; the binder stays Layer-1; all codec/schema work stays in
the contract-typing follow-up; no ABI-driver templates now.

## Decision

The substrate is sound and its layering is stable, so each concern stays at its own altitude:

1. The near-term binder helper is a **minimal, label-only binder hook** — a task-node binding lifted
   into a `CircuitPulseBinder` that fixes
   `bindCircuitConditionNode = committedVariantConditionBinding` and fails the
   signal/artifact/rewrite boundaries with an explicit typed `CircuitLoweringError`. It defines no
   composition algebra and no contract typing.
2. **Contract typing** (schema, versioned `ContractDefinition`, compatibility) stays value-level and
   is owned by the contract-typing follow-up, reconciled to ADR 0017's "contracts are values."
3. **Binder composition** over `CircuitPulseBinder` stays owned by ADR 0054 and the
   binder-composition epic.
4. The **label is the canonical select arm key**; contract-key resolution is demoted to elaboration.

## Consequences

### Positive

- Every concern is right-sized: no speculative composition algebra, no half-built contract schema.
- The contract-typing follow-up gains a sharpened target (value-level contract typing, not host
  types) and the production select entrypoint stays the integration seam.
- The select surface converges on a single discriminant (the label).

### Negative

- The binder helper is deliberately small; a host that needs custom signal/artifact/rewrite
  boundaries composes its own `CircuitPulseBinder` (reusing the exported condition binding) until
  ADR 0054 composition lands.
- Contract-key select remains accepted until a deprecation pass removes it.

### Obligations

- The contract-typing follow-up reconciles contracts-as-types with ADR 0017 (value-level
  schema/version, never host-type identity) and is the home for codec/schema work.
- A follow-up warns on, then removes, contract-key select resolution (ADR 0033 / conditionality
  reference).
- The minimal helper, when implemented, is label-only with explicit boundary failures, re-exported
  through `Cortex.Pulse.Circuit`, and is the construction site the existing select test binders
  adopt.

## Alternatives considered

- **Build the general binder-composition layer now.** Rejected: ADR 0054 binder-composition scope;
  no current consumer; defining the composition algebra ahead of need is overengineering.
- **Commit contract schema/version validation now.** Rejected: pre-empts the contract-typing
  follow-up and collides with ADR 0017's contracts-are-values decision; the inert `schema` hook
  means deferral costs no redesign.
- **Keep contract-key select as a permanent feature.** Rejected: it conflates the label
  (constructor) with the contract (payload interface) and complicates proof and contract evolution.
- **Ship no helper at all.** Viable, but a minimal hook removes a real wiring footgun at negligible
  cost and is consistent with ADR 0054's direction.

## Related

- [0017-wire-executor-and-port-catalog-boundary.md](0017-wire-executor-and-port-catalog-boundary.md)
- [0024-typed-executor-node-interface.md](0024-typed-executor-node-interface.md)
- [0033-wire-select-guarded-affine-collapse.md](0033-wire-select-guarded-affine-collapse.md)
- [0053-executor-catalog-manifests-and-pulse-bindings.md](0053-executor-catalog-manifests-and-pulse-bindings.md)
- [0054-downstream-wire-packages-and-host-bindings.md](0054-downstream-wire-packages-and-host-bindings.md)
- [0062-typed-effect-variant-output-boundaries.md](0062-typed-effect-variant-output-boundaries.md)
- [../Reference/Wire/conditionality.md](../Reference/Wire/conditionality.md)

## Tracking

- #315 — value-level contract typing and codec/schema work.
- #278 — binder-composition epic.
