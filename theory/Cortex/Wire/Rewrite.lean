import Cortex.Graph.Relation

/-!
## Overview

Sketches the soundness obligation for runtime graph rewriting:

> Every accepted rewrite is a *type-preserving transformation* on the
> circuit. If a rewrite would introduce a cycle, exceed the budget, or
> violate a contract boundary, it is rejected.

The Haskell side (`src/Cortex/Pulse/Rewrite.hs`,
`src/Cortex/Wire/Proposal.hs`) implements an admission predicate. This
file mechanizes the proof-carrying shape expected of admitted rewrites:
an accepted rewrite must carry evidence that it preserves graph
acyclicity, preserves the contract-boundary predicate supplied by the
caller, and consumes positive budget.

## Context

This module is a tracked scaffold. It names real predicates for rewrite
admission without pretending the dynamic rewrite story is already fully
mechanized or connected to the Haskell implementation.

## Theorem Split

The page defines graph-level paths, the abstract rewrite certificate,
the admission predicate, and theorem projections from the certificate.

## Roadmap

1. Connect `Rewrite` certificates to the Haskell admission path.
2. Instantiate `contractOk` from the registry boundary model.
3. Lift the budget-consumption projection to rewrite chains.
4. Connect the graph path predicate to the runtime topology integrity
   witness from ADR 0009.

## References

- ADR 0009 — rewrite provenance and topology integrity.
- ADR 0010 — closed authority and the three-layer stack.
- `docs/architecture/07-rewrites-and-materialization.md`.
- `docs/publications/paper-3-graph-substitution-semantics/manuscript.md`.
-/

namespace Cortex.Wire

open Cortex.Graph

/-! ## Rewrite Model -/

/-- `GraphPath g a b` is non-empty reachability in the denotation of a graph. -/
inductive GraphPath {α : Type} [DecidableEq α] (g : Graph α) : α → α → Prop where
  | direct {a b : α} : (a, b) ∈ (denote g).edges → GraphPath g a b
  | trans {a b c : α} : GraphPath g a b → GraphPath g b c → GraphPath g a c

/-- `Acyclic g` rules out non-empty paths from a vertex back to itself. -/
def Acyclic {α : Type} [DecidableEq α] (g : Graph α) : Prop :=
  ∀ node : α, ¬ GraphPath g node node

/-- `Rewrite α` is a partial function on graphs. The full Haskell shape
carries provenance and concrete contract metadata; this proof shape keeps
the transformation, a positive budget cost, and the preservation evidence
that an admitted rewrite must supply. -/
structure Rewrite (α : Type) [DecidableEq α] (contractOk : Graph α → Prop) where
  /-- `apply` is the transformation. `none` means "this rewrite does not apply
      to this graph". -/
  apply : Graph α → Option (Graph α)
  /-- `cost` is the fixed budget cost of attempting this rewrite. -/
  cost  : Nat
  /-- `cost_positive` ensures every accepted rewrite consumes budget. -/
  cost_positive : 0 < cost
  /-- `preserves_acyclic` is the graph-safety certificate for this rewrite. -/
  preserves_acyclic :
    ∀ {g g' : Graph α}, apply g = some g' → Acyclic g → Acyclic g'
  /-- `preserves_contracts` is the caller-supplied boundary-safety certificate. -/
  preserves_contracts :
    ∀ {g g' : Graph α}, apply g = some g' → contractOk g → contractOk g'

/-! ## Admission Predicate -/

/-- `applicable r g` says the rewrite produces a candidate graph. -/
def applicable
    {α : Type}
    [DecidableEq α]
    {contractOk : Graph α → Prop}
    (r : Rewrite α contractOk)
    (g : Graph α) : Prop :=
  ∃ g' : Graph α, r.apply g = some g'

/-- `admissible r g budget` says a rewrite fits the remaining budget and applies.

The acyclicity and contract-boundary obligations live in the `Rewrite`
certificate, so an admissible rewrite cannot be constructed without them. -/
def admissible
    {α : Type}
    [DecidableEq α]
    {contractOk : Graph α → Prop}
    (r : Rewrite α contractOk)
    (g : Graph α)
    (budget : Nat) : Prop :=
  r.cost ≤ budget ∧ applicable r g

/-! ## Soundness Obligations -/

/-- `admissible_preserves_acyclic` projects the acyclicity certificate.

If `g` is acyclic and `r` is admissible at `g`, then `r.apply g`
(when defined) is acyclic. -/
theorem admissible_preserves_acyclic
    {α : Type}
    [DecidableEq α]
    {contractOk : Graph α → Prop}
    (r : Rewrite α contractOk)
    {g g' : Graph α}
    {budget : Nat}
    (_hAdmissible : admissible r g budget)
    (hApply : r.apply g = some g')
    (hAcyclic : Acyclic g) :
    Acyclic g' :=
  r.preserves_acyclic hApply hAcyclic

/-- `admissible_preserves_contracts` projects the contract-boundary certificate.

Admissible rewrites preserve the contract registry's boundary invariants:
every port still references a registered contract, and every cross-fragment
edge is still typed-compatible. The concrete predicate is supplied as
`contractOk` until the registry mechanization lands. -/
theorem admissible_preserves_contracts
    {α : Type}
    [DecidableEq α]
    {contractOk : Graph α → Prop}
    (r : Rewrite α contractOk)
    {g g' : Graph α}
    {budget : Nat}
    (_hAdmissible : admissible r g budget)
    (hApply : r.apply g = some g')
    (hContracts : contractOk g) :
    contractOk g' :=
  r.preserves_contracts hApply hContracts

/-- `apply_admissible_terminates` records the local budget-decrease obligation.

A full chain termination proof will induct over remaining budget; the
local fact needed for that induction is that each admissible rewrite has
positive cost bounded by the current budget. -/
theorem apply_admissible_terminates
    {α : Type}
    [DecidableEq α]
    {contractOk : Graph α → Prop}
    (r : Rewrite α contractOk)
    (g : Graph α)
    (budget : Nat)
    (hAdmissible : admissible r g budget) :
    0 < r.cost ∧ r.cost ≤ budget :=
  ⟨r.cost_positive, hAdmissible.1⟩

end Cortex.Wire
