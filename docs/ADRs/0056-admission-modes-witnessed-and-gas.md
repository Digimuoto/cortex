---
title: "ADR 0056 - Admission Modes: Witnessed Materialization and Open Rewrite Gas"
description:
  "Splits topology admission into compile-witnessed materialization (asserted, never
  operator-gassed) and open rewrite gas (tunable, rejectable), discriminated by provenance and the
  admission boundary at which the shape is fixed."
sidebar:
  label: "0056. Witnessed vs gas admission"
  order: 56
status: proposed
date: 2026-06-14
superseded_by: null
related:
  - docs/Architecture/06-pulse-runtime.md
  - docs/Architecture/07-rewrites-and-materialization.md
  - docs/Reference/rewrites.md
  - docs/ADRs/0005-budgeted-rewrite-admission-and-materialization.md
  - docs/ADRs/0009-rewrite-provenance-and-topology-integrity.md
  - docs/ADRs/0036-wire-latent-branch-budget-recovery.md
  - docs/ADRs/0037-wire-latent-structural-control.md
  - docs/ADRs/0048-wire-make-bounded-node-generation.md
  - docs/ADRs/0050-wire-corepure-output-residue.md
  - docs/ADRs/0055-pulse-runtime-bounded-iteration.md
  - docs/ADRs/0057-wire-latent-branch-witnessing-and-closure-charging.md
---

# ADR 0056 - Admission Modes: Witnessed Materialization and Open Rewrite Gas

## Status

Proposed - refines ADR 0005. ADR 0005 remains canon; this ADR narrows the meaning of rewrite gas and
introduces a second admission mode beside it. It does not edit ADR 0005.

## Context

Rewrite gas (ADR 0005) was introduced to bound runtime topology proposed by an executor — originally
an LLM/planner node — so an agent cannot grow the graph without limit. That is a real and wanted
safety feature.

Since then the same five-dimensional gas account has become the _universal_ admission gate. Every
runtime materialization — including structure whose worst-case shape is already fixed before the run
— flows through `admitRewriteDelta` against one shared, operator-tunable pool. Consequences observed
in the live system:

- A `select` whose branch family is compile-bounded still debits the shared pool when its chosen arm
  actualizes (`lowerConditionNode`), so operators can be forced to raise gas just to let a provably
  finite graph run, and a statically valid shape can fail with `rewrite_budget_exceeded`.
- Admission is asymmetric by accident: an absent `else` arm completes for free (`StageComplete`),
  while every productive arm debits gas — "do nothing" is free only via one code path.
- Runtime-bounded iteration (ADR 0055) would multiply the conflation: a `select` inside a fixed
  kernel would redraw structural budget every turn for a shape that is fixed per turn.

The underlying error is using a _gate_ (which can reject) for shapes that need only a _metric_
(which reports). The right discriminator is not static-vs-runtime, and not bare knowability either;
it is **provenance and the admission boundary**: who fixes the worst-case shape — the compiler, or
an open producer — and at which boundary.

## Decision

Topology admission has two modes, chosen by **provenance and the boundary at which the shape is
fixed** — not by bare knowability. An open proposal also becomes knowable once the producer returns
it, yet it is still gassed; only author/compiler provenance makes structure witnessed.

**Witnessed materialization.** Structure whose worst-case shape is fixed by the compiler carries a
`StructuralWitness`. Materialization _asserts_ its cost is within the witness; it cannot be rejected
by operator gas. Its cost is recorded and surfaced as an operator metric, never as an admission
gate. Covers author-static graphs, `make(N, K)` and forms (ADR 0048), and author-written `select`
branch families (charging detailed in ADR 0057). The witnessed substructure inside an admitted open
proposal is also asserted this way — after the proposal's one-time gas charge has already paid for
it.

**Open rewrite gas.** Structure whose shape is unknowable before run — executor/planner/LLM topology
proposals — is admitted against the operator-tunable five-dimensional gas of ADR 0005. Fail-fast and
rejectable. This is exactly, and only, what gas is for.

The two modes are joined by one invariant:

> Gas is charged **once, at the admission boundary, over the static/witnessed closure already fixed
> in the admitted structure** — the directly added topology plus the worst-case witness of any
> witnessed sub-structure (e.g. selects) the compiled structure already contains. After that single
> charge, witnessed actualization is **gas-neutral**. The charge does **not** reach through nodes
> that carry open rewrite authority: those are themselves open producers, gas-admitted again at
> their own boundaries. Open authority chains across boundaries, each charged once for its own
> static closure.

This is what keeps witnessed mode from becoming a laundering hole (an open proposal smuggling heavy
latent branches in cheaply) without overreaching into unknowable future proposals (which cannot be
priced up front). The closure rule for the `select` case is specified in ADR 0057.

## Mental Model

The discriminator is **provenance and boundary**, not bare knowability — an open proposal also
becomes knowable once the producer returns it, but it is still gassed.

| Who fixes the shape, and where              | Mechanism                   | Owner         | Can operator gas reject it? |
| ------------------------------------------- | --------------------------- | ------------- | --------------------------- |
| author source / compiler-minted             | structural witness          | Wire compiler | no — asserted, metered      |
| an open producer, at its admission boundary | open rewrite gas            | Pulse         | yes — fail-fast             |
| repeated execution under a cap              | iteration budget (ADR 0055) | Pulse         | yes — exhaustion            |

"Gas" names only the middle row, and it is paid **once per admission boundary** over that boundary's
static closure (ADR 0057). A structure being "known after the producer returned it" does not make it
witnessed — only author/compiler provenance does. Compile-bounded shape is witnessed, not gassed.
Iteration is a distinct budget. CorePure stays total (ADR 0050) — no fourth budget is introduced
here.

## Boundary Rules

- A **witness** is derived by the compiler (or by compiling an admitted proposal) and is not
  operator-tunable. Raising or lowering operator gas never changes whether a witnessed shape admits.
- **Open authority chains; it does not nest into one charge.** A node introduced by an open producer
  that itself carries open rewrite authority is a new open producer. Its future proposals are
  gas-admitted at their own boundaries; the introducing proposal's charge covers only its own static
  closure, never structure that does not yet exist.
- **Cost is always recorded**; mode decides only whether cost _gates_. Run-wide structural cost may
  be surfaced as a metric without ever rejecting.
- **Recovery is mode-aware.** Gas is reconstructed by summing **admission events** (one per admitted
  open boundary), not by re-subtracting every materialized row. Witnessed actualizations replay
  gas-neutral. Persisted rewrite rows must carry their admission mode and, for gas-charged
  structure, a reference to the owning admission event, so replay neither re-debits nor loses
  provenance. ADR 0057 pins the admission-event contract (identity, persistence point,
  one-per-boundary, linkage).
- A **witnessed actualization** fails only on compiler/runtime drift (stale artifact, invalid
  registry, single-use/owner violation), never on "operator gas too low."

## Consequences

### Positive

- Static and compile-bounded graphs never require gas tuning to run.
- Gas returns to its original scope: bounding unknowable, agent-authored topology.
- The same witness/gas discipline is reusable by ADR 0055 iteration (the `loopRewrites` question
  becomes "does the kernel propose _open_ topology?").

### Negative

- Two admission modes instead of one uniform gate.
- Recovery becomes lineage-driven (admission events own gas debits) rather than row-subtraction.
- The proof track must restate the select-consumes-gas theorems (see ADR 0057); accounting laws that
  quantify over the budget abstractly survive.

### Obligations

- Define a `StructuralWitness` carrier and a witnessed-vs-gas admission-mode tag on persisted
  rewrites.
- Make `resume` reconstruct open gas from admission events and replay witnessed actualizations
  gas-neutral.
- Theory: restate `Select.lean` consume theorems for witnessed mode; confirm `BoundaryResource`
  accounting laws (budget-generic) are unaffected; track names in ADR 0038's ledger.
- Docs: update Architecture 07 and `rewrites.md` to distinguish witnessed cost from gas admission.

## Alternatives considered

- **Keep one universal gas gate** - rejected; it forces operators to tune a safety throttle to admit
  provably finite shapes and entangles every new budget surface.
- **Make witnessed structure free with no metric** - rejected; loses operator visibility into graph
  size.
- **Make everything witnessed** - rejected; open agent-authored topology is genuinely unknowable
  before run and must remain rejectable.

## Traceability

- Feature keys: `rewrite.admission_modes`
- Public surface: `Cortex.Pulse`, [`docs/Reference/rewrites.md`](../Reference/rewrites.md)
- Implementation: `src/Cortex/Pulse/Rewrite.hs` (`AdmissionMode`, `admitWitnessedDelta`,
  `admissionModeFromText`, `admittedAdmissionMode`), `src/Cortex/Pulse/Materialization.hs`
  (`prAdmissionMode`, `WitnessedReplayMetadata`), `src/Cortex/Pulse/Iteration.hs`
  (`authorizeWitnessedStepWithControl`)
- Tests: `test/Cortex/Pulse/IterationSpec.hs`, `test/Cortex/Pulse/ExecutorSpec.hs`
  (`runtime-bounded iteration evidence: gas-neutral cap loop`)
- Theory/proof: [Boundary resource algebra — `proof-status.md`](../Reference/proof-status.md)

## Related

- [0005 - Budgeted Rewrite Admission and Materialization](0005-budgeted-rewrite-admission-and-materialization.md)
- [0009 - Rewrite Provenance and Topology Integrity](0009-rewrite-provenance-and-topology-integrity.md)
- [0036 - Latent Branch Budget and Recovery Policy](0036-wire-latent-branch-budget-recovery.md)
- [0037 - Wire Latent Structural Control Operators](0037-wire-latent-structural-control.md)
- [0048 - Wire Compile-Time Make for Bounded Node Generation](0048-wire-make-bounded-node-generation.md)
- [0050 - Wire CorePure Output Residue](0050-wire-corepure-output-residue.md)
- [0055 - Pulse Runtime-Bounded Iteration](0055-pulse-runtime-bounded-iteration.md)
- [0057 - Latent Branch Witnessing and Proposal Closure Charging](0057-wire-latent-branch-witnessing-and-closure-charging.md)
- [Architecture 07 - Rewrites and Materialization](../Architecture/07-rewrites-and-materialization.md)
