---
title: "ADR 0088 — Externally-Driven Step Admission"
description:
  "A fourth topology-admission row beside witnessed, gassed, and iteration-capped: gas-neutral
  self-append of a certified kernel whose bounding resource is one journaled durable-signal delivery
  per step, enforced by a delivery-entry law, persisted as the admission mode 'external', and
  re-gated on replay."
sidebar:
  label: "0088. Externally-driven steps"
  order: 88
status: proposed
date: 2026-07-05
superseded_by: null
related:
  - docs/Architecture/06-pulse-runtime.md
  - docs/Architecture/07-rewrites-and-materialization.md
  - docs/Reference/rewrites.md
  - docs/Reference/Pulse/schema.md
  - docs/ADRs/0005-budgeted-rewrite-admission-and-materialization.md
  - docs/ADRs/0055-pulse-runtime-bounded-iteration.md
  - docs/ADRs/0056-admission-modes-witnessed-and-gas.md
  - docs/ADRs/0082-pulse-durable-signals.md
  - docs/ADRs/0002-cortex-downstream-ownership-boundary.md
  - docs/ADRs/0040-logos-owned-reasoning-surfaces.md
---

# ADR 0088 — Externally-Driven Step Admission

## Status

Proposed — refines ADR 0056 by adding a fourth admission row, composes ADR 0055's certified
self-append machinery with ADR 0082's durable signal primitive. ADR 0005 remains canon: open
proposals stay gassed; this mode never applies to producer-authored topology.

## Context

A long-lived interactive run grows by one admitted `AppendAfter` per external event: a host delivers
a durable signal, the parked run wakes, one certified kernel instance is appended, and the run parks
again. The downstream motivation is a conversational session (one turn per delivered user message),
but the mechanic is substrate-generic: any run whose growth is caused by outside events rather than
by the graph's own decisions has the same shape.

Neither existing admission row fits:

- **Open rewrite gas** (ADR 0005/0056) is finite and fail-fast per run, so an externally-driven run
  is forced into segment rollover on a safety rail designed for a different threat — the shape of
  each step here is not producer-authored, it is a byte-identical instance of a registered,
  digest-certified kernel. Gassed admission also namespaces appended ids under the anchor, growing
  ids O(steps) in an anchored chain.
- **Runtime-bounded iteration** (ADR 0055) has the right per-step discipline — certified kernel
  digest, flat `iter_<i>` namespace, size envelope, self-append law, gas-neutral admission — but
  demands a finite compile/runtime iteration cap. An externally-driven run has no meaningful total
  cap; imposing one re-creates rollover with a different counter.

ADR 0056's discriminator is provenance and boundary: only author/compiler provenance makes structure
witnessed, and its mental model has exactly three rows (witnessed, open gas, iteration budget). An
externally-driven step's _shape_ has exactly the witnessed provenance — the appended definitions
resolve against the compiled stage-template registry with action-id fingerprints, and the instance
is pinned to a registered kernel digest — but its _count_ is bounded by neither a compiler witness
nor a per-run cap. That is a genuinely new admission category and must not be squeezed into
`witnessed` (whose journal rows claim "bounded by a compile-witnessed finite cap").

## Decision

Pulse admits **externally-driven steps**: gas-neutral self-appends of a registered, certified kernel
whose bounding resource is **one journaled durable-signal delivery per step**, persisted with the
admission mode **`external`** and re-validated through the same security gate on replay.

Mechanically, the ADR 0055 loop machinery is generalized rather than duplicated:

- `LoopPolicy` carries a **bound source**: `BoundIterationCap` (ADR 0055, unchanged) or
  `BoundExternalDelivery` with an `ExternalDeliveryPolicy` — the **delivery entry** (the kernel's
  single entry segment, which parks on a durable signal), a set of **bootstrap producers** (static
  node ids permitted to mint step index 0 exactly once; Wire source cannot author `:`-bearing ids,
  so the first append is proposed by an ordinary static node), and an optional **operator step
  valve** (`Nothing` = bounded by external causation alone).
- The proposer is the existing `StageLoopStep` result; the registration's bound source decides the
  admission mode inside persistence. Registrations are host-injected beside the plan
  (`circuitPulseLoopRegistrations` on the lowering config), carrying the same author/compiler
  provenance that authorizes witnessed shapes. An unregistered `StageLoopStep` still falls back to
  the gassed path, fail-closed.
- The step gate runs everything the witnessed gate runs — AppendAfter-only, self-append anchor,
  per-append size envelope, canonical flat `iter_<n>` ids, certified kernel digest, frontier-shape
  witness — plus two external-only laws:
  - **Delivery-entry law**: the minted instance's entry set must be exactly the registered
    delivery-entry node under the minted step's namespace. `AppendAfter` routes every anchor
    successor edge through the entry set, so the next step's proposer cannot execute before one
    durable signal (ADR 0082) is delivered to this instance — growth rate is bounded by host
    deliveries, and the graph is finite at every instant.
  - **Step-count law**: the next admissible index equals the count of admitted steps under the root
    (reconstructed from the journal on resume, exactly like the loop index); a bootstrap append is
    admissible only while that count is zero.
- The **bounding-resource argument** ADR 0055 demands of any uncapped repetition: each step consumes
  a journaled delivered-signal row; between any two admitted steps there is at least one external
  delivery; the host retains kill authority (cancellation at between-iterations and parked-await
  points, run-terminal signals, and the optional valve). Growth without external cause is
  structurally impossible, which is the property rewrite gas exists to guarantee for open proposals.
- **Journal honesty and recovery**: rows persist `admission_mode = 'external'` with an
  `external_step` metadata envelope (policy version, steps before/after, step witness). Replay never
  trusts the tag: every external row re-runs the control-aware gate plus a registration/bound-source
  cross-check (an `external` row resolving to a capped registration — or a `witnessed` row resolving
  to an external registration — is rejected). Readers that predate the mode decode unknown values as
  `gassed` and fail closed on budget re-debit. Budget reconstruction is unchanged: external rows are
  gas-neutral in the lineage fold.

The extended ADR 0056 mental model:

| Who fixes the shape, and where               | What bounds repetition          | Mechanism          | Can operator gas reject it? |
| -------------------------------------------- | ------------------------------- | ------------------ | --------------------------- |
| author source / compiler-minted              | shape is the structure          | structural witness | no — asserted, metered      |
| an open producer, at its admission boundary  | five-dimensional gas            | open rewrite gas   | yes — fail-fast             |
| compiler-certified kernel, repeated          | finite iteration cap (ADR 0055) | iteration budget   | yes — exhaustion            |
| compiler-certified kernel, externally driven | one durable delivery per step   | delivery-entry law | no — valve/cancel only      |

## Boundary Rules

- **No downstream vocabulary.** The substrate names are externally-driven step, delivery entry,
  bootstrap producer (ADR 0002/0040). Chat, session, and turn semantics stay downstream; what a
  delivered payload means is not a Cortex concern.
- **Registration is author/host provenance.** External registrations enter through the lowering
  config beside the rewrite budget, are validated against the lowered topology (bootstrap producers
  must exist; the namespace root must not prefix-collide with static ids), and pin one kernel digest
  per `(template, root)` key. A bootstrap producer is a static instance of the kernel's producer
  stage template — the same relationship ADR 0055's static `iter_0` seed has to its kernel — which
  the registration key enforces by construction.
- **The delivery entry is structural, not behavioral.** Pulse does not inspect the entry stage's
  opaque action; the trust anchor is template provenance (hydration resolves appended definitions
  against the compiled registry with action-id fingerprints), the same anchor witnessed admission
  relies on. A registered kernel whose entry does not actually park defeats only its own bound — the
  registration is host authority, exactly like handing out rewrite budget.
- **Flat namespace, one discipline.** External steps reuse the `iter_<n>` namespace, parser, and
  freshness law verbatim; there is no second id scheme.
- **Modes never blur.** Capped registrations admit `witnessed`, external registrations admit
  `external`, replay cross-checks the pairing both ways, and gassed admission is untouched.

## Alternatives considered

- **Unbounded (or huge) witnessed cap.** Register the kernel under ADR 0055 with an effectively
  infinite `lpMaxIterations`. Rejected: it dilutes the witnessed row's journal claim, gives recovery
  a bound it cannot check, and offers no bounding-resource argument — exactly the "repeat forever"
  shape ADR 0055 rejects.
- **Per-row signal linkage.** Record the consumed delivered-signal row id on each `external` rewrite
  row and verify delivered-and-unconsumed at admission. Strongest journal audit, but it needs a new
  `graph_rewrites` column, a consume transition for ordinary signals (ADR 0082 has none), and IO in
  the resume replay fold. Recorded as a future strengthening, not v1; the structural delivery-entry
  law already gives the growth bound.
- **Segment rollover as the permanent answer.** Keep finite gas and split long runs into linked
  segments. Works (it is the shipped workaround) but splits single-lineage provenance across runs
  and forces a policy choice (segment size) that exists only to serve the wrong safety rail.
- **A parallel admission stack.** A new `StageResult` constructor, a separate registration carrier,
  and a `step_<n>` namespace. Rejected: it duplicates ~900 lines of security-audited
  gate/persistence/replay machinery whose only semantic difference is what bounds the step.

## Consequences

### Positive

- A long-lived interactive run grows one certified step per external event indefinitely — no per-run
  gas ceiling, no segment rollover, constant-size flat ids — while every step stays
  admission-checked, journaled, and replay-re-gated.
- The journal distinguishes "bounded by a finite cap" from "bounded by external causation" honestly,
  and old readers fail closed rather than misreading new rows.
- Gas returns to exactly its ADR 0056 scope: bounding open, producer-authored topology.

### Negative

- A third persisted admission mode: one more branch at every mode dispatch, one more CHECK value
  (forward migration 0003), and one more row in the operator's mental model.
- The external-causation guarantee is structural rather than per-row evidenced until the signal
  linkage strengthening lands.
- `LoopPolicy`/`LoopControl` carry bound-source-dependent fields (`lpMaxIterations` and the
  remaining-iteration counter are inert under external delivery), a modest carrier widening.

### Obligations

- Wire source-level declaration of step roots (loop and external registrations both enter through
  the lowering config today) remains the ADR 0055 follow-up; this ADR adds no new syntax.
- The per-row signal-linkage strengthening, if wanted, is a separate decision amending the
  `graph_rewrites` schema and the ordinary-signal state machine.
- Lean mechanization is deferred exactly as for ADR 0055/0056; the step-count and delivery-entry
  laws join the same theorem backlog.
- Keep `docs/Reference/rewrites.md` and Architecture 06/07 aligned with the three-mode journal.

## Traceability

- Feature keys: `pulse.external_step_admission`
- Public surface: `Cortex.Pulse`, [`docs/Reference/rewrites.md`](../Reference/rewrites.md)
- Implementation: `src/Cortex/Pulse/Rewrite.hs` (`AdmissionExternal`, `admitExternalDelta`),
  `src/Cortex/Pulse/Iteration.hs` (`LoopBoundSource`, `ExternalDeliveryPolicy`,
  `externalLoopRegistration`, `checkDeliveryEntry`, `planExternalStep`),
  `src/Cortex/Pulse/Materialization.hs` (`ExternalReplayMetadata`,
  `authorizeExternalReplayWithControl`), `src/Cortex/Pulse/Executor/Persistence.hs` (bound-source
  dispatch in the loop-step path), `src/Cortex/Pulse/Executor/Resume.hs` (mode-aware replay),
  `src/Cortex/Wire/Circuit/Lowering.hs` (`circuitPulseLoopRegistrations`,
  `validateLoopRegistrations`), `migrations/0003_graph_rewrites_admission_mode_external.sql`
- Tests: `test/Cortex/Pulse/IterationSpec.hs` (externally-driven gate suite),
  `test/Cortex/Pulse/ExecutorSpec.hs` (gas-neutral growth past the ops budget; park, deliver,
  resume)
- Theory/proof: none (deferred with the ADR 0055/0056 backlog)

## Related

- [ADR 0005 — Budgeted Rewrite Admission and Materialization](0005-budgeted-rewrite-admission-and-materialization.md)
- [ADR 0055 — Pulse Runtime-Bounded Iteration](0055-pulse-runtime-bounded-iteration.md)
- [ADR 0056 — Admission Modes: Witnessed Materialization and Open Rewrite Gas](0056-admission-modes-witnessed-and-gas.md)
- [ADR 0082 — Pulse Durable Signal Primitive](0082-pulse-durable-signals.md)
- [ADR 0002 — Cortex and Downstream Ownership Boundary](0002-cortex-downstream-ownership-boundary.md)
- [ADR 0040 — Logos-Owned Reasoning Surfaces](0040-logos-owned-reasoning-surfaces.md)
- [Architecture 06 — Pulse Runtime](../Architecture/06-pulse-runtime.md)
- [Architecture 07 — Rewrites and Materialization](../Architecture/07-rewrites-and-materialization.md)

## Tracking

- #366 — externally-driven append admission for long-lived interactive runs (downstream Logos ADR
  0019 / logos#115).
