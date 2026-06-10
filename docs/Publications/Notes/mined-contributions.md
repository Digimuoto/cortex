---
title: Mined Contributions
description:
  Inventory of contributions present in the Lean proofs and Haskell implementation but not yet
  articulated in any manuscript, with evidence, nearest literature, proposed homes, and caveats.
status: active
date: 2026-06-10
related:
  - docs/Publications/roadmap.md
  - docs/Publications/Paper-7-frontier-calculus/
  - docs/Reference/proof-status.md
---

# Mined Contributions

Findings from an adversarial mining pass (2026-06-10) over `theory/Cortex/Wire/`, the compiler, and
the research notes: things the system already contains that no paper yet claims. Ranked by potential
impact. Items 1, 2, and 8 have been integrated into Paper 7's structure and Paper 6; the rest live
here until a paper claims them.

## 1. Two-layer linear port semantics (latent/actualized) — INTEGRATED into Paper 7 §3.6

**Claim shape:** port linearity is not one invariant but two, connected by a projection. The source
layer (`LinearPortGraph.PortLinear`) governs authored composition; the actualized layer
(`ActualizedPortGraph.ClosedPortLinear`) governs the running circuit, where every input has exactly
one producer and every output exactly one consumer or terminal discharge. The source-to-actualized
projection is exact: `compiledPortUseWitness_exact_output` / `_input`
(`theory/Cortex/Wire/ActualizedBridge.lean`) prove every actualized port comes from a source port
and vice versa, and `selectActualize_preserves_closedPortLinearity` carries the discipline through
branch actualization.

**Nearest literature / delta:** two-level resource readings exist in staged metaprogramming and in
latent-vs-actual effect systems, but a latent/actualized **linearity** pair with a proved projection
exactness over executable graphs appears unclaimed.

**Caveat:** the modality framing ("latent" as a type operator) is ours to prove; the Lean has the
carriers and the projection, not a modal type system.

## 2. The certifying admission boundary — INTEGRATED into Paper 7 §5

**Claim shape:** a compiler-certification architecture strictly between proof-carrying code and
translation validation. The compiler emits proof-shaped admission artifacts (pure data, no proof
terms); mirrored executable contracts validate them on both sides of the language boundary (Haskell
`wireAdmissionArtifactValidatorReady` ↔ Lean `validatorReadyCheck` with
`validatorReadyCheck_soundness : check = true → Sound`); reconstruction theorems recover proof
witnesses from accepted artifacts (`Sound.toPrimitiveGraphReconstruction` and the
generated/phantom/select counterparts); and a structural binding check
(`Cortex.Wire.AdmissionBinding`, gated in `compileLoweredWireFile`) ties each artifact to the exact
circuit it travels with, with mutation regression tests pinning a rejection per error constructor.

**Nearest literature / delta:** PCC ships proof terms; translation validation re-checks semantic
equivalence per compilation. Here: structured evidence + contract mirroring + value-level binding,
each independently testable. The trust statement is explicit (binds values, not provenance).

**Possible standalone venue:** CPP / CC / ITP-adjacent ("Certifying compilation by artifact contract
mirroring").

**Caveat:** the Lean checker does not yet consume actual Haskell output (hand-transcribed fixture
only); a generator closes that.

## 3. Boundary resource algebra with one-slot epochs

**Claim shape:** rewrite admission carries a per-anchor resource discipline finer than budgets: each
anchor exposes one rewrite slot per epoch; no two admitted rewrites spend the same slot
(`RewriteSlot`, `SlotUnique`, `SlotUniqueTrace`, `rewriteSlot_spent_at_most_once`,
`theory/Cortex/Wire/BoundaryResource.lean`); and the three rewrite families have distinct boundary
laws — consuming substitution (`expandNode_resourceUse`), retaining append
(`appendAfter_resourceUse`), guarded-affine select actualization.

**Nearest literature / delta:** linear/affine type systems and separation logic provide the
vocabulary; the per-anchor one-slot epoch discipline for graph rewriting, with a proof-relevant
uniqueness trace, looks unclaimed.

**Proposed home:** Paper 7 §4 row (added); fuller treatment in Paper 3 or a follow-up.

**Caveat:** no fairness/liveness result; the connection to the budget algebra is stated but not
unified.

## 4. Latent branch families as guarded-affine resources

**Claim shape:** `select(...)` is neither if-then-else nor fan-out: a latent branch family is
admitted sealed (label-first resolution with unique contract fallback, total coverage —
`SelectAdmission.admitClause`), exactly one arm actualizes as a deterministic retained-anchor append
rewrite (`selectActualize_lowers_to_appendAfter`) consuming a guarded-affine boundary obligation,
unselected bodies are provably excluded (`selectActualize_unselected_not_in_selectedFragment`), and
recovery replays the same selection (`selectedBranch_recovery_deterministic`).

**Nearest literature / delta:** session-type labeled choice is the nearest neighbor; the deltas are
durability (recovery determinism from persisted admission) and the rewrite reading (actualization is
a budgeted graph rewrite, not a process step).

**Proposed home:** Paper 7 T-Select draft + a dedicated section; possibly its own workshop paper.

**Caveat:** uniqueness of actualization (no two arms simultaneously) is enforced but the single
clean theorem stating it should be named.

## 5. Five-dimensional graded rewrite budgets

**Claim shape:** rewrite costs and budgets are five-dimensional (added nodes, added edges, added
depth, frontier-width delta, rewrite operations), with per-step fit
(`ConstructedPlanningStep.boundaryResourceCost_fits_budget`) and chain-level monotonicity
(`ConstructedPlanningChain.finalBudget_le_initial`); selected-branch actualization consumes exactly
the constructed selected-fragment cost (`selectActualize_consumes_selected_cost`).

**Nearest literature / delta:** graded/coeffect type systems track one grade; structured
multi-dimensional grading over graph rewriting, with each dimension naming a distinct scarcity
(memory, depth, parallel width, scheduler work), is a tidy generalizable structure.

**Proposed home:** Paper 7 §4 row (added); generalization could be a short formal note.

**Caveat:** no completeness argument for the five dimensions; no cross-dimension trade theory.

## 6. Stage-structured causal pipelines (precedence as semantics)

**Claim shape:** binding `<>` tighter than `=>` is a semantic decision, not syntax taste: it makes
ordinary pipeline text denote stage-structured partial orders without parentheses, giving the ladder
imperative (order first) → functional (names first) → frontier (stages first, order derived).
Already half-written in
`docs/Research-notes/Foundation/2026-05-09-stage-structured-causal-pipelines.md`; absent from the
papers.

**Proposed home:** Paper 6's framing (a sentence exists), Paper 7 §1 motivation, Paper 5's paradigm
ladder.

**Caveat:** framing, not theorem; needs one crisp definition of "stage" to be more than rhetoric.

## 7. Frontier reclamation as linear resource deallocation

**Claim shape:** finished frontiers are reclaimable (`FrontierFinished`,
`frontierFinished_reclaimable`, `theory/Cortex/Wire/FrontierReclaim.lean`): once every endpoint is
consumed or discharged, the in-memory endpoint resources are structurally dead and reusable — linear
deallocation at the graph boundary, preventing frontier growth across long rewrite chains.

**Proposed home:** Paper 3 resource-management section or Paper 7 §4 footnote.

**Caveat:** runtime reclaim hooks and durable-profile retention are open; no non-conflict theorem
for reclaimed vs live endpoints yet.

## 8. Quantum circuits in the same linear frontier language — INTEGRATED into Paper 6

**Claim shape:** the same port-linear calculus that explains causal provenance in durable workflows
describes quantum circuits, where the linearity discipline coincides with the no-cloning constraint
qubit-carrying ports require: an unmatched fan-out of a qubit-typed port is exactly the static error
the calculus already rejects. Evidence: ~12 quantum examples under `examples/wire/`, including
`quantum-eraser-experiment.wire` (540 lines) executed on IBM hardware (`ibm_fez`, job
`d7rnnhst738s73cfpljg`).

**Nearest literature / delta:** the linear-logic/quantum connection is classical (Abramsky,
Selinger); the delta is one executable language spanning durable workflows and quantum circuit
description with the same admission discipline, demonstrated on hardware.

**Proposed home:** Paper 6 paragraph (done); potential standalone domain paper ("Quantum circuits as
typed linear workflows").

**Caveat:** no formal semantics of gates in the Wire model; no equivalence proof against the
Qiskit-level representation; the no-cloning correspondence is structural, not a quantum-semantics
theorem.
