import Cortex.Graph.Core

/-!
## Overview

Sketches the soundness obligation for runtime graph rewriting:

> Every accepted rewrite is a *type-preserving transformation* on the
> circuit. If a rewrite would introduce a cycle, exceed the budget, or
> violate a contract boundary, it is rejected.

The Haskell side (`src/Cortex/Pulse/Rewrite.hs`,
`src/Cortex/Wire/Proposal.hs`) implements an admission predicate; this
file mechanizes its specification and admits the soundness theorem
as an obligation.

## Context

This module is a tracked scaffold. It names the proof obligations for
rewrite admission without pretending the dynamic rewrite story is already
mechanized.

## Theorem Split

The page defines the abstract rewrite shape, states the admission
predicate, and then lists the three soundness obligations that future
work must discharge.

## Roadmap

1. Define `Rewrite` as a typed transformation on the Mokhov graph.
2. Define `admissible` matching the Haskell predicate (acyclicity +
   budget + boundary preservation).
3. Prove `admissible_preserves_acyclic`.
4. Prove `admissible_preserves_contracts`.
5. Prove `apply_admissible_terminates` (rewrite chain bounded by
   the per-run budget — connects to ADR 0009 provenance/integrity).

## References

- ADR 0009 — rewrite provenance and topology integrity.
- ADR 0010 — closed authority and the three-layer stack.
- `docs/architecture/07-rewrites-and-materialization.md`.
- `docs/publications/paper-3-graph-substitution-semantics/manuscript.md`.
-/

namespace Cortex.Wire

open Cortex.Graph

/-! ## Rewrite Model -/

/-- `Rewrite α` is a partial function on graphs. The full Haskell shape
carries provenance, a budget cost, and contract metadata; we keep just
the transformation here for the soundness sketch. -/
structure Rewrite (α : Type) where
  /-- `apply` is the transformation. `none` means "this rewrite does not apply
      to this graph". -/
  apply : Graph α → Option (Graph α)
  /-- `cost` is the fixed budget cost of attempting this rewrite. -/
  cost  : Nat

/-! ## Admission Predicate -/

/-- `admissible r g budget` says a rewrite fits the remaining budget and applies.

The full predicate also requires acyclicity preservation and contract
boundary preservation; those are stated separately as obligations below. -/
def admissible {α : Type} (r : Rewrite α) (g : Graph α) (budget : Nat) : Prop :=
  r.cost ≤ budget ∧ (r.apply g).isSome

/-! ## Soundness Obligations -/

/-- `admissible_preserves_acyclic` is the acyclicity preservation obligation.

If `g` is acyclic and `r` is admissible at `g`, then `r.apply g`
(when defined) is acyclic.

Acyclicity itself needs a concrete predicate over `Graph α` (TODO: lift
from `Cortex.Graph.Decompose.hs`). For now the statement is shape-only
and admitted. -/
axiom admissible_preserves_acyclic
    {α : Type}
    (r : Rewrite α) (g : Graph α) (budget : Nat) :
  admissible r g budget →
  -- placeholder: should read `IsAcyclic g → IsAcyclic g'`
  True

/-- `admissible_preserves_contracts` is the contract preservation obligation.

Admissible rewrites preserve the contract registry's boundary invariants:
every port still references a registered contract, and every cross-fragment
edge is still typed-compatible. Sketched here; concrete predicate pending
the registry mechanization. -/
axiom admissible_preserves_contracts
    {α : Type}
    (r : Rewrite α) (g : Graph α) (budget : Nat) :
  admissible r g budget →
  -- placeholder
  True

/-- `apply_admissible_terminates` is the bounded rewrite-chain obligation.

A sequence of admissible rewrites terminates because each consumes at
least one unit of the per-run budget. Stated as a shape; the proof reduces
to well-founded induction on the budget. -/
axiom apply_admissible_terminates
    {α : Type}
    (rs : List (Rewrite α)) (g : Graph α) (budget : Nat) :
  -- placeholder
  True

end Cortex.Wire
