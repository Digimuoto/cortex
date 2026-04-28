# Model Soundness Checks

Use these checks when Lean declarations are intended to justify a runtime, recovery, safety,
determinism, topology, or rewrite claim.

## Contract Coverage

Build a matrix before judging the theorem:

| Obligation | Formal carrier | Establishing theorem | Preservation theorem | Gap |
| ---------- | -------------- | -------------------- | -------------------- | --- |

An obligation is not covered merely because the surrounding prose names it. It must appear in a
type, constructor, predicate, field law, theorem hypothesis, or theorem conclusion.

## Free Data Audit

Inspect every free component:

- Relations: are they derived from constructors or constrained by exactness laws?
- Functions: are off-domain inputs constrained or excluded?
- Predicates: do their names overclaim compared to their definitions?
- Sets and maps: are keys/endpoints tied to the intended domain?
- Status values: do all constructors have explicit semantics?
- Optional payloads: is ownership tied to status and lifecycle?

Free data is acceptable only when the theorem is explicitly parametric in that freedom. It is
suspicious when a runtime-derived concept is modeled as an arbitrary field.

## Domain Closure

For each graph-like or state-like model, check:

- Direct relation endpoints are in the finite domain.
- Derived relation endpoints are in the finite domain.
- State keys outside the domain are impossible or normalized away.
- Theorems that quantify over the ambient type guard with domain membership where needed.
- Validity predicates mention domain exactness when they are used as recovered-state or
  persisted-state safety claims.

## Exactness

If a declaration says "derived from", "closure of", "frontier for", "valid state", "ready nodes", or
"well formed", require both directions:

- Every constructed witness satisfies the predicate.
- Every predicate witness corresponds to the intended construction.

One-way implications often prove an implementation convenience instead of the intended model
property.

## Runtime Correspondence

For each modeled runtime concept:

- Identify the Haskell module, docs page, ADR, or issue claim it mirrors.
- Check whether the Lean abstraction erases data safely.
- Check whether erased payloads leave behind ownership or lifecycle obligations.
- Distinguish "runtime never writes this" from "the Lean model forbids this".
- Treat persisted/recovered state as adversarial input unless a theorem proves normalization.

## Preservation

Every invariant added to a validity predicate should have preservation or establishment lemmas for
the transitions that claim to maintain it. If the theorem proves only the final validity predicate,
inspect whether the proof assumes the hardest invariant instead of deriving it.

## Red Flags

- A relation field has transitivity/acyclicity laws but no link to the edge relation.
- A validity predicate name includes "well formed", "safe", "recovered", or "closed" but omits
  domain or payload constraints.
- A status predicate allows payloads for statuses whose runtime behavior cannot produce or consume
  them safely.
- A theorem's hypotheses include the theorem's advertised conclusion in renamed form.
- A model uses total functions over a larger type but has no off-domain normalization predicate.
- A proof succeeds because definitions are too weak, not because the property is true.
