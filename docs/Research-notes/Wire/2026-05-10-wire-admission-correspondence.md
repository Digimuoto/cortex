---
title: "Wire Admission Correspondence After PR 189"
description:
  Research synthesis on Haskell admission artifacts, Lean ValidatorReady mirrors, Wire boundary
  resource semantics, and the remaining proof-producing validator decision.
date: 2026-05-10
status: research
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/conditionality.md
  - docs/Reference/proof-status.md
  - docs/ADRs/0038-wire-proof-track-theorem-ledger.md
  - docs/ADRs/0048-wire-make-bounded-node-generation.md
  - docs/ADRs/0049-wire-fan-phantom-adapter.md
  - docs/ADRs/0052-wire-bounded-indexed-boundary-products.md
  - theory/Cortex/Wire/AdmissionArtifact.lean
  - src/Cortex/Wire/AdmissionArtifact.hs
---

# Wire Admission Correspondence After PR 189

**Date:** 2026-05-10 **Scope:** PR 189 / `174-wire-admission-witness-artifacts`, Wire admission
artifacts, Haskell-to-Lean correspondence, and post-run design synthesis. **Layers examined:**
Haskell implementation, Lean theory, Wire docs, ADRs 0038/0048/0049/0052, proof-status docs, PR
metadata, and journal excerpts. **Layers skipped:** external literature and a full GitHub issue
sweep; this memo records hot-context synthesis rather than a broad literature review. **Method:**
research synthesis through the seven archetype lenses.

---

## Executive Summary

The overall design direction was validated: Wire can stay Haskell-first while emitting a
proof-shaped admission artifact that Lean can mirror as a `ValidatorReady` contract. The most
important discovery is that compiler correctness is not the next single leap; the tractable middle
layer is a certifying artifact boundary: Haskell emits and checks structured evidence, Lean names
exactly what that evidence must imply.

The biggest design risk is that this boundary creates infinite useful-looking proof work. Once the
validator is coherent, more accessor theorems become increasingly optional. The next real design
move is not "one more theorem"; it is deciding the authority model for witness production: Haskell
validator as oracle, proof-producing checker, Lean executable spec, or some hybrid.

On Wire itself, the core primitives were mostly validated. `=>` as scalar leaf matching, `*` as
explicit finite-product adapter, `make`/`makeEach` as fresh bounded generation, and `select(...)` as
latent exclusive-output reduction all survived stress. The places to revisit are not the primitives
themselves, but their profiles and names: make-supportable kind, shallow finite product, zero-count
product, and artifact-valid versus proof-producing correspondence.

## Archetype Synthesis

| Lens     | One-line read                                                                                                      |
| -------- | ------------------------------------------------------------------------------------------------------------------ |
| Episteme | Haskell has an executable artifact validator; Lean has a mirrored `ValidatorReady`; docs separate proof layers.    |
| Logos    | The load-bearing claim is now proof-shaped artifact validity, not a full compiler-correctness theorem.             |
| Kritikos | The sharpest remaining counterexample is process-level: every valid predicate can produce another accessor.        |
| Themis   | Layering is mostly right: Cortex owns artifacts and validation; Lean owns proof contracts; proof production waits. |
| Techne   | The next concrete artifact should be a proof-producing-validator ADR or issue, not another broad accessor pass.    |
| Poiesis  | Wire is converging on boundary resource algebra: generation, products, select, and recovery transform boundaries.  |
| Sophia   | Ship/squash this PR after cleanup; move remaining correspondence work into named follow-up slices.                 |

## Key Findings

### 1. The admission artifact is the right intermediate abstraction.

**Category:** Novel Idea / Missed Abstraction **Status:** Observed **Confidence:** High **Primary
evidence:** `wireAdmissionArtifactValidatorReady` in `src/Cortex/Wire/AdmissionArtifact.hs`; Lean
`ValidatorReady` in `theory/Cortex/Wire/AdmissionArtifact.lean`; proof-status separation in
`docs/Reference/proof-status.md`.

The run validated a concrete middle ground between trusting Haskell and rewriting the compiler in
Lean. Haskell emits structured artifacts and checks them with `wireAdmissionArtifactValidatorReady`;
Lean mirrors the same contract as `WireAdmissionArtifact.ValidatorReady`.

This is a real architectural seam. It lets the Haskell compiler remain the implementation while
making proof obligations explicit and inspectable.

**Why it matters:** Compiler/proof correspondence becomes a data contract. That is easier to test,
review, version, and evolve than a monolithic compiler-correctness theorem.

**Next step:** Write a short ADR or issue defining the certifying artifact boundary: what Haskell
owns, what Lean owns, and what proof-producing validation would mean.

### 2. Wire's endpoint-resource model was validated.

**Category:** Novel Idea **Status:** Observed/Inferred **Confidence:** High **Primary evidence:**
`docs/Architecture/05-wire-language.md`, ADR 0052, and `docs/Reference/Wire/conditionality.md`.

The strongest language insight is that Wire is not an edge language. It is a boundary-obligation
language. The run repeatedly reinforced this:

- `=>` consumes compatible leaf endpoints.
- `*` adapts product boundaries into leaf endpoints.
- `make`/`makeEach` creates fresh nodes, not copied ports.
- `select(...)` promotes one latent continuation, not ordinary fan-out.

This should become core explanatory vocabulary for Wire: boundary resources, adapters, and
reductions.

**Why it matters:** It prevents bad syntax pressure. If users want aggregation, routing, product
folding, or conditionality, the answer should not be "make edges smarter." It should be "use the
correct boundary adapter or reduction."

**Next step:** Teach `=>`, `*`, `make`, and `select` as one boundary-resource family in future Wire
docs.

### 3. The next real gap is proof-producing validation, not more proof accessors.

**Category:** Evidence Gap / Design Tension **Status:** Observed **Confidence:** High **Primary
evidence:** `ValidatorReady` docstring in `theory/Cortex/Wire/AdmissionArtifact.lean`, proof-status
wording in `docs/Reference/proof-status.md`, and ADR 0038's note that Haskell correspondence remains
testing/oracle work until a stronger authority model is chosen.

The current system checks the artifact in Haskell and mirrors the contract in Lean. It does not yet
produce Lean proof terms, and it does not yet run a Lean validator over serialized artifacts.

That is fine, but it should be named honestly. The next big correspondence question is authority:

1. Haskell is authoritative, tests guard drift.
2. Lean is an executable spec, Haskell must match it.
3. Haskell emits artifacts, Lean independently validates them.
4. Haskell emits proof objects or proof traces that Lean checks.

**Why it matters:** Without choosing this, the project can keep adding evidence fields forever while
never crossing from proof-shaped to proof-producing.

**Next step:** Open or design the Wire admission artifact validator authority issue or ADR.

### 4. `ValidatorReady` is becoming a dense theorem API, not just a predicate.

**Category:** Design Tension / Missed Abstraction **Status:** Observed **Confidence:** High
**Primary evidence:** Haskell validator aggregate in `src/Cortex/Wire/AdmissionArtifact.hs`, Lean
`ValidatorReady` in `theory/Cortex/Wire/AdmissionArtifact.lean`, and the dense theorem ledger in
`theory/README.md`.

The predicate is doing two jobs:

- defining what a valid artifact is;
- acting as a gateway to many reusable proof facts.

That is workable, but the API surface is growing by accretion. The run ended with smaller and
smaller theorem slices because every part of `ValidatorReady` can be projected into more convenient
facts.

**Why it matters:** This is where accessor churn starts. The design is good, but it needs a
principle for when to add a theorem.

**Next step:** Split future work into required witness bridge versus ergonomic accessor. A theorem
is required only if it rules out forged artifacts or discharges a named downstream witness
obligation.

### 5. `make`/`makeEach` are not general kind instantiation, and that should be explicit.

**Category:** Design Tension / Terminology Gap **Status:** Observed **Confidence:** High **Primary
evidence:** rich kind parameters in `docs/Reference/Wire/grammar.md`; narrow `make(count, ident)`
grammar; `KindSupportsMake` and `KindSupportsMakeEach` in Lean.

The design is coherent, but the language story can mislead: a kind is general, while `make(N, K)` is
not a generic "instantiate this arbitrary kind N times." It works for a narrow profile of kinds
whose labels and optional value parameter can be supplied by generation.

That is probably correct. But it needs vocabulary. Kind is broad; make-supportable kind is a
constrained kind profile.

**Why it matters:** Without this distinction, users will expect `make` to work with arbitrary
executor authorities, contracts, values, and labels. The compiler and proof side correctly reject
more than the syntax visually suggests.

**Next step:** Add reference docs or an ADR note: `make` and `makeEach` operate on a generated-kind
profile, not arbitrary kind applications.

### 6. `[T; 0]` exposed an important finite-product choice.

**Category:** Design Tension / Novel Idea **Status:** Inferred **Confidence:** Medium **Primary
evidence:** Haskell accepts non-negative bounded indexed counts in `src/Cortex/Wire/Syntax.hs` and
parser paths; ADR 0052 explains finite indexed products but does not foreground zero.

The `[T; 0]` question was productive. It forced the distinction between bounded product as source
ergonomics and finite product as algebraic object. Allowing zero is plausible if `[T; 0]` is the
empty product. Disallowing it is plausible if Wire wants to avoid unit-like topology surprises.

The current implementation leans toward allowing it. That can be okay, but it should become explicit
language semantics, not an accidental consequence of `Natural`.

**Why it matters:** Empty product semantics affect `make(0, K)`, `makeEach([])`, `*`, frontier
cardinality, and whether identity-like adapters are meaningful.

**Next step:** Add an ADR 0052 clarification: zero-count bounded products are either valid empty
products or rejected at parse/admission. The branch behavior suggests valid empty product.

### 7. `select(...)` is validated as a topology primitive, but body replay is still the frontier.

**Category:** Evidence Gap **Status:** Observed **Confidence:** High **Primary evidence:**
conditionality reference, architecture chapter 05, and the artifact-to-`LatentSelectAdmission`
projection in the Lean track.

The run validated the direction: `select(...)` should not be ordinary fan-out or value-level `if`.
Artifact work strengthened keys, fallback resolution, latent body provenance, freshness, and
disjointness.

The remaining gap is selected body replay: turning persisted latent arm rows into the executable
branch graph/witness used by recovery and actualization.

**Why it matters:** This is the difference between knowing which branch rows are allowed and being
able to replay the selected branch into runtime topology with proof correspondence.

**Next step:** Make selected-branch body replay its own issue or PR. Do not continue to add select
accessors unless they directly feed that replay proof.

### 8. Wire can plausibly describe its own autonomous development loop.

**Category:** Novel Idea **Status:** Speculative **Confidence:** Medium **Primary evidence:**
Portman workflow examples and the local sketch `examples/wire/autonomous-correspondence-cycle.wire`.

The postmortem revealed that the blessed agent workflow has a graph shape: gather evidence, run
lenses, synthesize findings, triage, implement a bounded slice, validate, publish, journal, and
either stop or append one bounded rewrite.

This is a strong fit for Wire because the hard part is frontier discipline: stop conditions, rewrite
budget, provenance, and avoiding unbounded optional work.

**Validation path:** Keep the sketch as non-compiling design material for now. Later, when the Logos
executor library exists, implement the smallest runnable subset: context -> review -> triage ->
validation -> journal, with no implementation authority at first.

## Design Issues Encountered

The main issues were not with the core primitives. They were with boundary ownership:

1. Authority model unresolved: Haskell validates artifacts; Lean mirrors predicates; no shared
   proof-producing checker yet.
2. Accessor churn: the proof API can grow forever unless tied to downstream obligations.
3. Make-kind profile not prominent enough: `make` is narrower than kind instantiation.
4. Zero product semantics implicit: `[T;0]` should be explicitly blessed or rejected.
5. Docs as theorem ledger are under pressure: `theory/README.md` is becoming a dense surface.

## What Was Validated

- `=>` should remain scalar leaf matching.
- `*` is the right place for product/record/indexed boundary adaptation.
- `make`/`makeEach` should generate fresh nodes, not clone existing topology.
- `select(...)` should remain latent exclusive-output reduction, not fan-out.
- Haskell-first plus Lean-mirrored artifact contracts is a viable near-term proof strategy.
- Public JSON/artifact tests are more valuable here than tests against hidden constructors.
- The journal plus review-lens loop is useful, but needs stop conditions.

## Recommended Actions

### Act now

- Clean branch state: either commit or drop the local raw-edge bridge, decide whether the Wire
  workflow sketch belongs in PR 189, then squash/review PR 189.
- Open a follow-up issue: define proof-producing validator authority for Wire admission artifacts.
- Stop adding optional accessors to PR 189 unless a reviewer or downstream proof requires them.

### Design next

- ADR or design note: Haskell validator versus Lean spec versus proof-producing artifact checker.
- Reference docs: name the `make`/`makeEach` supported kind profile.
- ADR 0052 clarification: `[T;0]` empty finite product semantics.
- Select body replay issue: persisted latent arm rows to executable selected branch witness.

### Write up

- Architecture note: Wire is boundary-resource algebra, not edge semantics.
- Research or blog note: proof-shaped artifacts as a compiler correspondence bridge.
- Agent workflow note: autonomous implementation loops as bounded Wire rewrites.

### Parked

- Lean extraction or running Lean as the production compiler.
- Full end-to-end Wire compiler correctness.
- General `make(N, kind(args...))` syntax.
- Executable version of the autonomous-cycle Wire sketch.

## Known Unknowns

- A full GitHub issue sweep was not performed, so some recommendations may already have issue IDs.
- External literature was not consulted in this pass.
- PR 189 metadata was sampled, not fully audited.
- The working tree included local uncommitted files when this memo was written.

## Bottom Line

The Wire design got stronger, not weaker, under stress. The primitives mostly held. The proof
strategy also held, but only if the current layer is named honestly: Haskell emits and checks
proof-shaped artifacts; Lean mirrors and reasons about the contract; a future validator must bridge
from data to proof obligations.

The next danger is not a missing theorem. It is continuing to produce locally useful theorem
accessors after the PR has already crossed its meaningful readiness boundary.
