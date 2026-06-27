---
title: "ADR 0057 - Latent Branch Witnessing and Proposal Closure Charging"
description:
  "Applies ADR 0056's admission modes to select/latent branches: author selects are witnessed at the
  componentwise max of the planned actualization delta and asserted per-site; open proposals charge
  their static branch closure to gas at admission. Proposes to supersede ADR 0036 on acceptance."
sidebar:
  label: "0057. Latent witness & closure charge"
  order: 57
status: proposed
date: 2026-06-14
superseded_by: null
related:
  - docs/ADRs/0056-admission-modes-witnessed-and-gas.md
  - docs/ADRs/0005-budgeted-rewrite-admission-and-materialization.md
  - docs/ADRs/0007-latent-branch-conditional-lowering.md
  - docs/ADRs/0009-rewrite-provenance-and-topology-integrity.md
  - docs/ADRs/0033-wire-select-guarded-affine-collapse.md
  - docs/ADRs/0034-wire-pure-select-actualization-authority.md
  - docs/ADRs/0036-wire-latent-branch-budget-recovery.md
  - docs/ADRs/0038-wire-proof-track-theorem-ledger.md
  - docs/Architecture/07-rewrites-and-materialization.md
  - docs/Reference/Wire/conditionality.md
  - docs/Reference/rewrites.md
  - "GitHub #99"
---

# ADR 0057 - Latent Branch Witnessing and Proposal Closure Charging

## Status

Proposed - depends on ADR 0056. Proposes to supersede ADR 0036, which documented the current
selected-branch gas policy and explicitly deferred the capacity question; this ADR answers it. The
supersession takes effect only on acceptance of this ADR; until then ADR 0036 remains the active
policy.

## Context

ADR 0036 (proposed) records today's behavior: a selected branch actualizes through an ordinary
admitted rewrite and consumes shared gas; unselected branches are free; no compiled branch is
guaranteed admissible, because earlier rewrites can exhaust the pool first.

Under ADR 0056, author-written selects are compile-bounded and belong in _witnessed_ mode, not gas.
But selects are not always author-written: an open proposal (LLM/planner) can introduce a condition
node whose branches are LLM-authored Wire. Verified current behavior:

- A proposal is fully compiled to a `CompiledCircuit` before admission
  (`compileWireAppendProposalWithEnv`); the closure is therefore computable from existing data, no
  new compile stage.
- The proposal's gas cost counts the condition node as one node; its latent then/else fragments
  materialize _later_ via the condition's own `StageRewrite ... AppendAfter` (`lowerConditionNode`),
  so they are not in the proposal's admitted delta.

So a blanket "selects are witnessed/free" rule would let an open proposal add a cheap condition and
actualize an arbitrarily heavy branch for free — a gas-laundering hole that defeats the feature gas
exists for. Provenance must decide.

## Decision

**Author / compile-bounded selects are witnessed.** The witness of a select is the **componentwise
max, over its arms, of the fully planned actualization delta at that select site** — not merely each
branch fragment's internal nodes and edges. The planned `AppendAfter` delta for an arm includes its
anchor-to-entry edges, exit-to-successor edges, added depth, frontier delta, and rewrite op; the
witness takes the per-dimension maximum across arms of that full `RewriteCost`. Defining it on the
planned delta rather than the fragment interior is what prevents an implementation from
undercounting the wiring and reopening the laundering problem. The identity/empty arm contributes a
zero delta (already `StageComplete` today, now made principled and symmetric). Nested selects
recurse (an arm's planned delta includes the witness of any select within it); serial selects on a
path sum their per-site witnesses; statically parallel branches that both run add. Actualization
_asserts_ the chosen arm's planned delta is within the family witness and is **gas-neutral**.

**Open-introduced selects charge their static closure at admission.** When an open proposal is
admitted, its gas charge MUST include the **recursive static witness envelope of the admitted
`CompiledCircuit`** — the same rule used for a single select above, applied to the whole compiled
proposal: serial path costs add, statically parallel branches add, select alternatives take the
componentwise max, and a nested select's witness enters only through the arm or path that contains
it. This is an envelope, not a sum over select sites: mutually exclusive arms are maxed, never added
(per the sum-prepay rejection below). After that single charge, those inner selects actualize
gas-neutral. The closure is bounded to what the compiled proposal already fixes; it does **not**
reach through nodes the proposal introduces that themselves carry open rewrite authority. Such a
node is simply another open producer: any future `StageRewrite` it emits is separately gas-admitted
at its own admission boundary, charged over its own static closure. Open authority therefore chains
across boundaries — each boundary charged exactly once for its own compiled structure — and the
global bound is the sum of per-boundary charges, not a single up-front number.

**What gates vs. what reports.** Two distinct quantities, and they must not be conflated. The
**per-boundary closure envelope** of an open proposal (and each author-select's family witness)
**gates**: it is debited against the budget at its admission boundary and can reject. The
**run-wide** worst-reachable-static-path figure **reports**: it is operator-facing accounting, never
an admission object, never debited. An implementer must not treat the per-boundary open-proposal
envelope as merely informational — it is the charge that gates; only the aggregate run-wide total is
informational.

**Admission events own gas; recovery replays from them.** The durable unit of gas accounting is the
**admission event** — exactly one per admitted open boundary (one per admitted open
rewrite/proposal), written **in the same transaction** that admits the proposal and debits its
closure-envelope cost. Each admission event carries: a stable admission id, the boundary it
admitted, and the gas it debited. Witnessed actualizations (author selects, and the latent branches
a charged proposal introduced) create **no** admission event — they are gas-neutral — but every
persisted actualization/rewrite row records an `admission mode` and, for gas-charged structure, a
reference to the **owning admission event**. Recovery therefore reconstructs remaining gas by
**summing admission events**, never by re-subtracting every materialized row (the ADR 0036 model): a
witnessed actualization replayed on resume is gas-neutral and links back to the admission event that
already paid for it, so replay can neither re-debit nor lose provenance. (Implementation: the
rewrite re-admission on resume in `Executor/Resume.hs`.)

**Failure semantics.** A witnessed branch actualization can fail only on compiler/runtime drift
(stale artifact, invalid registry, single-use/owner violation), not on "operator gas too low."

## Examples

### Author select

`required_evidence_gate select(...)` has two arms compiled from source. Its witness is the heavier
arm. Whichever arm the runtime selects, materialization asserts the selected cost is within that
witness and debits no operator gas. An operator never tunes gas to let this run; raising or lowering
gas cannot change whether it admits.

### Open proposal introducing a select

An LLM append proposal compiles to a `CompiledCircuit` containing a condition node with two branch
fragments. Admission charges the static closure: the directly appended nodes plus the
componentwise-max planned actualization delta of the two arms. After that single debit, the branch
actualizes gas-neutral when the condition fires. The LLM cannot add a cheap condition now and
actualize a heavy branch for free later.

### Open proposal introducing a further open producer

A proposal introduces a node that carries propagated rewrite authority (in Portman terms,
`propagateRewriteAuthority = true`) — it may itself later propose topology. Admission charges only
this proposal's static closure; the introduced node's future proposals are not charged now, because
their shape is not yet fixed. Each such future proposal is gas-admitted at its own boundary over its
own static closure. The run-wide bound is the sum of per-boundary charges.

### Nested select on a path

`a => select(...) => select(...)`: each site asserts against its own family witness. The run-wide
metric reports the sum of the two per-site witnesses as the worst reachable static path, but
enforcement remains per-site; there is no global gas object.

## Consequences

### Positive

- A compiled author select can always actualize within its witness; no operator tuning, no
  `rewrite_budget_exceeded` on a provably finite branch family.
- The laundering hole is closed: open structure pays its full closure once, upfront.
- Answers ADR 0036's deferred capacity question: a witnessed per-family bound (the componentwise max
  of arms' planned deltas), asserted — the guarantee without escrow accounting.

### Negative

- A closure-cost pass over admitted proposals is required (cheap; data already exists).
- Persisted rewrite rows gain an admission-mode and charging-event reference; resume changes
  accordingly.

### Obligations

- Implement closure-witness folding over `CompiledCircuit` at proposal admission.
- Add admission-mode and charging-event lineage to persisted rewrites; make resume mode-aware.
- Theory: restate `Select.lean` `selectActualize_consumes_selected_cost` and siblings as "chosen-arm
  cost is within the family witness; open gas unchanged"; confirm graph-preservation,
  branch-disjointness, and namespacing theorems survive; record in ADR 0038's ledger.
- Docs: update Architecture 07, `rewrites.md`, and `conditionality.md` to witnessed semantics.

## Alternatives considered

- **Keep ADR 0036 selected-cost-gas** - rejected; it is the design debt (tuning gas for finite
  shapes).
- **Blanket-free selects** - rejected; gas-laundering via open-introduced selects.
- **Sum-prepay all branches** - rejected (per ADR 0036; charges mutually exclusive futures).
- **Max-escrow reservation of branch capacity** - deferred; witnessed assertion gives the guarantee
  without a new escrow account.

## Traceability

- Feature keys: `rewrite.closure_witness_charging`
- Public surface: `Cortex.Pulse`, [`docs/Reference/rewrites.md`](../Reference/rewrites.md)
- Implementation: `src/Cortex/Pulse/Materialization.hs` (`prAdmissionMode`,
  `WitnessedReplayMetadata`, `authorizeWitnessedReplayWithControl`),
  `src/Cortex/Pulse/Executor/Resume.hs` (mode-aware rewrite re-admission)
- Tests: `test/Cortex/Pulse/ExecutorSpec.hs`, `test/Cortex/Pulse/IterationSpec.hs`
- Theory/proof:
  [Selected branch budget / Latent recovery determinism — `proof-status.md`](../Reference/proof-status.md)
- Tracking: GitHub #99

## Related

- [0056 - Admission Modes: Witnessed Materialization and Open Rewrite Gas](0056-admission-modes-witnessed-and-gas.md)
- [0005 - Budgeted Rewrite Admission and Materialization](0005-budgeted-rewrite-admission-and-materialization.md)
- [0007 - Latent Branch Conditional Lowering](0007-latent-branch-conditional-lowering.md)
- [0033 - Wire Select as Guarded Affine Collapse](0033-wire-select-guarded-affine-collapse.md)
- [0034 - Pure Selectors and Restricted Actualization Authority](0034-wire-pure-select-actualization-authority.md)
- [0036 - Latent Branch Budget and Recovery Policy](0036-wire-latent-branch-budget-recovery.md)
- [0038 - Wire Proof-Track Theorem Ledger](0038-wire-proof-track-theorem-ledger.md)
- [Architecture 07 - Rewrites and Materialization](../Architecture/07-rewrites-and-materialization.md)
- [Wire Conditionality Reference](../Reference/Wire/conditionality.md)
