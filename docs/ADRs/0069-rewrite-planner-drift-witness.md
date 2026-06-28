---
title: "ADR 0069 — Haskell-Lean Rewrite Planner Correspondence and Drift Witness"
description:
  "A self-auditing Haskell harness recomputes the rewrite planner equations from the same inputs and
  fails loudly with a typed witness-error taxonomy when the planned/admitted delta drifts from the
  Lean-named PlanGraphRewriteChecks facts."
sidebar:
  label: "0069. Planner drift witness"
  order: 69
status: proposed
date: 2026-06-27
superseded_by: null
related:
  - docs/Architecture/07-rewrites-and-materialization.md
  - docs/Reference/rewrites.md
  - docs/Reference/proof-status.md
  - docs/Reference/feature-status.md
  - docs/ADRs/0005-budgeted-rewrite-admission-and-materialization.md
  - docs/ADRs/0009-rewrite-provenance-and-topology-integrity.md
  - docs/ADRs/0038-wire-proof-track-theorem-ledger.md
---

# ADR 0069 — Haskell-Lean Rewrite Planner Correspondence and Drift Witness

## Status

Proposed — the drift witness and its error taxonomy are implemented in the rewrite substrate, but no
prior ADR mandated the correspondence checker that keeps the Haskell planner aligned with the
Lean-named `PlanGraphRewriteChecks` facts. This ADR records that decision.

## Context

[ADR 0005](./0005-budgeted-rewrite-admission-and-materialization.md) makes graph evolution legal
only through admitted rewrite deltas that fit a finite budget, and
[ADR 0009](./0009-rewrite-provenance-and-topology-integrity.md) makes the materialized topology
carry its own integrity witness. The Lean proof track then states the runtime planning contract as a
structure: `PlanGraphRewriteChecks` in `theory/Cortex/Wire/Admission.lean` is "the Lean-side runtime
planning contract", and `runtimePlannerConstruction_planGraphRewriteChecks` in
`theory/Cortex/Wire/Planner.lean` derives those checks for the runtime planner rewrite, which
`planGraphRewriteChecks_admissible` and `runtimePlannerConstruction_admissible` then turn into an
abstract admissible rewrite. [ADR 0038](./0038-wire-proof-track-theorem-ledger.md) names these facts
in the proof-track ledger.

The gap is that those are Lean facts. The Haskell planner (`planGraphRewrite`) computes the planned
delta independently; nothing in the runtime forces the executable planner to keep producing the same
field values the Lean contract assumes. Haskell cannot prove `PlanGraphRewriteChecks`, but it can be
made to _re-derive_ the same planner equations from the same inputs and compare them against the
delta it actually produced. Without such a checker, an edit to topology projection, cost accounting,
anchor disposition, or budget debiting could silently diverge from the proof model, and the
divergence would only surface — if at all — as a later materialization or recovery anomaly far from
its cause.

Several substrate facts make a typed checker worthwhile rather than ad hoc assertions: the planned
delta has many independent fields (topology, inserted vertices and edges, entry and exit nodes,
anchor disposition, new/removed nodes, added edges, definition-domain update and coverage, cost),
the budget debit is mode-aware (gassed deltas debit every dimension; witnessed deltas are
gas-neutral), and each mismatch needs a stable, greppable identity for observability rather than a
collapsed boolean pass/fail.

## Decision

Mandate a self-auditing planner drift witness in the rewrite substrate. The witness recomputes the
planner equations from the same inputs `planGraphRewrite` consumes and reports every divergence as a
distinct, typed error; it is the canonical Haskell-side correspondence surface for the Lean
`PlanGraphRewriteChecks` and `AdmittedRewriteDelta` contracts.

Concretely, in `src/Cortex/Pulse/Rewrite.hs`:

- `plannedRewriteWitnessErrors` re-derives the expected delta from the raw rewrite, current
  topology, and definitions — the same inputs `planGraphRewrite` uses — via the shared planner
  helpers (`runtimePlannerRewrite`, `plannedFinalTopology`, `plannedFinalDefinitionKeys`,
  `plannedRewriteCost`, `relationDiff`) and compares each field of the produced
  `PlannedRewriteDelta` against its recomputed expectation. The final topology is independently
  re-validated as a DAG. Each mismatch becomes a `RewriteWitnessError`.
- `validateAdmittedRewriteDelta` checks the budget side: a gassed delta must debit exactly what
  `consumeRewriteBudget` computes, a witnessed delta must leave the budget unchanged, and any other
  remaining-budget value is a `RewriteWitnessRemainingBudgetMismatch` (or
  `RewriteWitnessBudgetRejected` when the debit itself is refused).
- `RewriteWitnessError` is a closed sum (nineteen variants) carrying the offending data — most
  through an `ExpectedActual` expected/actual pair. `renderRewriteWitnessError` produces a human
  message, and `rewriteWitnessErrorType` maps each variant to a stable `snake_case` type string
  explicitly marked as not to be renamed casually, so the drift signal is durable for diagnostics.
- `planGraphRewriteWithAdmissionWitness` is the self-auditing entry point: it plans the delta, runs
  the planned-delta drift check, admits against the budget, runs the admitted-delta budget check,
  and bundles a `RewriteAdmissionWitness` on success. Any drift surfaces as
  `RewriteAdmissionWitnessInvalid [RewriteWitnessError]` rather than a silent acceptance.

The witness is a drift detector, not a proof: it asserts that the executable planner still satisfies
the equations the Lean contract names, so divergence "fails loudly in tests or runtime debug paths".

## Alternatives considered

- **Rely on the Lean theorems alone.** Rejected — the Lean proofs constrain the proof model, not the
  Haskell planner. Nothing extracts the planner from Lean, so the executable code can drift away
  from a true theorem with no signal.
- **Assert correspondence with scattered boolean checks at each call site.** Rejected — it would
  duplicate the planner equations inconsistently, lose the per-field identity needed to localize a
  regression, and give observability nothing stable to key on. A single closed `RewriteWitnessError`
  taxonomy with stable type strings is the auditable form.
- **Collapse the whole check into one pass/fail witness.** Rejected — a boolean cannot say _which_
  equation drifted (topology vs cost vs budget vs anchor disposition), which is exactly what a
  regression triage and the proof-status correspondence row need.
- **Wire the checker into the hot admission path unconditionally.** Not decided here — the live
  planner and admission paths (`planGraphRewrite`, `admitRewriteDelta`) do not currently route
  through the witness; it is a self-audit harness for tests and debug paths. Promoting it to a
  mandatory runtime gate is left open below.

## Consequences

### Positive

- An edit that diverges the Haskell planner from the Lean-named planning contract fails loudly,
  per-field, instead of surfacing later as a materialization or recovery anomaly.
- The nineteen-variant taxonomy plus stable `rewriteWitnessErrorType` strings give regressions and
  observability a durable identity, and give the proof-status "Rewrite admission" row a concrete
  executable hook rather than an asserted correspondence.
- Budget-debit correctness (gassed vs witnessed) is checked against the same `consumeRewriteBudget`
  the runtime uses, so mode-aware accounting drift is caught.

### Negative

- The checker recomputes the planner equations, so the planner's expected-value logic now lives in
  two places that must stay in step; changing a planner equation means changing its witness
  expectation too.
- It is a drift detector, not a proof. It does not establish that Haskell produces every
  `RuntimeConstructionInputs` field the Lean witness consumes; full field-by-field witness
  production remains an open correspondence target.

### Obligations

- Keep `RewriteWitnessError` a closed, exhaustively matched sum and keep `rewriteWitnessErrorType`
  strings stable; treat a rename as a breaking observability change.
- When a planner equation changes, update the corresponding witness recomputation and the
  proof-status row in the same change.
- Keep the witness aligned with the Lean `PlanGraphRewriteChecks` / `AdmittedRewriteDelta` facts
  named in the proof-track ledger; if those facts move, move the checker.

## Traceability

- Feature keys: `rewrite.planner_drift_witness`
- Public surface: `Cortex.Pulse`, [`docs/Reference/rewrites.md`](../Reference/rewrites.md)
- Implementation: `src/Cortex/Pulse/Rewrite.hs`
- Tests: `test/Cortex/Pulse/GraphRewriteSpec.hs`
- Theory/proof: [Rewrite admission correspondence — `proof-status.md`](../Reference/proof-status.md)

## Related

- [ADR 0005 — Budgeted Rewrite Admission and Materialization](./0005-budgeted-rewrite-admission-and-materialization.md)
- [ADR 0009 — Rewrite Provenance and Topology Integrity](./0009-rewrite-provenance-and-topology-integrity.md)
- [ADR 0038 — Wire Proof-Track Theorem Ledger](./0038-wire-proof-track-theorem-ledger.md) — names
  the Lean planner facts this checker keeps Haskell in correspondence with.
- [Chapter 07 — Rewrites and Materialization](../Architecture/07-rewrites-and-materialization.md)
- [Cortex Rewrites Reference](../Reference/rewrites.md)
- [Cortex Proof Status](../Reference/proof-status.md)
- [Cortex Feature Status](../Reference/feature-status.md)
