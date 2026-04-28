import Cortex.Graph.Relation

/-!
## Overview

Denotational laws for Mokhov's graph algebra over the raw graph
expression syntax.

## Context

The paper laws do not hold as kernel equality over the raw AST:
`overlay g empty` and `g` are different constructor trees. They do hold
modulo the finite relation denotation defined in
`Cortex.Graph.Relation`. This module therefore exposes the law surface as
`GraphEq`, a denotational equality relation over expressions.

## Theorem Split

The page defines denotational graph equality, proves Mokhov's unit and
algebraic laws as theorems, and restates selected laws for the `+` and
`*` operator surface. `Cortex.Graph.Quotient` packages this relation as
the setoid for the `AlgGraph` quotient carrier.

## Status

| Law                                    | Status        |
|----------------------------------------|---------------|
| `overlay_empty`                        | theorem       |
| `connect_empty_left`                   | theorem       |
| `connect_empty_right`                  | theorem       |
| `overlay_comm`                         | theorem       |
| `overlay_assoc`                        | theorem       |
| `connect_assoc`                        | theorem       |
| `connect_distrib_overlay_left`         | theorem       |
| `connect_distrib_overlay_right`        | theorem       |
| `connect_decomposition`                | theorem       |

The quotient law surface lives in `Cortex.Graph.Quotient`.

## References

- Mokhov, "Algebraic Graphs with Class", §3 (Theorems 1–8).
- Cortex `src/Cortex/Graph/Core.hs` — the laws are exercised but not
  proven on the Haskell side.
-/

namespace Cortex.Graph

variable {α : Type} [DecidableEq α]

/-! ## Denotational Equality -/

/-- `GraphEq g h` means two graph expressions have the same finite relation denotation. -/
def GraphEq (g h : Graph α) : Prop :=
  denote g = denote h

/-! ## Unit Laws -/

/-- `overlay_empty` states that `empty` is a denotational identity for `overlay`. -/
theorem overlay_empty (g : Graph α) :
    GraphEq (Graph.overlay Graph.empty g) g ∧
      GraphEq (Graph.overlay g Graph.empty) g := by
  constructor
  · simp [GraphEq]
  · simp [GraphEq]

/-- `connect_empty_left` states that `connect empty g` is a denotational identity. -/
theorem connect_empty_left (g : Graph α) :
    GraphEq (Graph.connect Graph.empty g) g := by
  simp [GraphEq]

/-- `connect_empty_right` states that `connect g empty` is a denotational identity. -/
theorem connect_empty_right (g : Graph α) :
    GraphEq (Graph.connect g Graph.empty) g := by
  simp [GraphEq]

/-! ## Algebraic Laws -/

/-- `overlay_comm` states that overlay is denotationally commutative. Mokhov Theorem 1. -/
theorem overlay_comm (g h : Graph α) :
    GraphEq (Graph.overlay g h) (Graph.overlay h g) := by
  exact Relation.overlay_comm (denote g) (denote h)

/-- `overlay_assoc` states that overlay is denotationally associative. Mokhov Theorem 2. -/
theorem overlay_assoc (g h k : Graph α) :
    GraphEq
      (Graph.overlay (Graph.overlay g h) k)
      (Graph.overlay g (Graph.overlay h k)) := by
  exact Relation.overlay_assoc (denote g) (denote h) (denote k)

/-- `connect_assoc` states that connect is denotationally associative. Mokhov Theorem 4. -/
theorem connect_assoc (g h k : Graph α) :
    GraphEq
      (Graph.connect (Graph.connect g h) k)
      (Graph.connect g (Graph.connect h k)) := by
  exact Relation.connect_assoc (denote g) (denote h) (denote k)

/-- `connect_distrib_overlay_left` states left denotational distribution.

Mokhov Theorem 6. -/
theorem connect_distrib_overlay_left (g h k : Graph α) :
    GraphEq
      (Graph.connect g (Graph.overlay h k))
      (Graph.overlay (Graph.connect g h) (Graph.connect g k)) := by
  exact
    Relation.connect_distrib_overlay_left
      (denote g)
      (denote h)
      (denote k)

/-- `connect_distrib_overlay_right` states right denotational distribution. -/
theorem connect_distrib_overlay_right (g h k : Graph α) :
    GraphEq
      (Graph.connect (Graph.overlay g h) k)
      (Graph.overlay (Graph.connect g k) (Graph.connect h k)) := by
  exact
    Relation.connect_distrib_overlay_right
      (denote g)
      (denote h)
      (denote k)

/-- `connect_decomposition` states decomposition denotationally.

Mokhov Theorem 8. The law distinguishes Mokhov's algebra from a plain
semiring; load-bearing for circuit simplification. -/
theorem connect_decomposition (g h k : Graph α) :
    GraphEq
      (Graph.connect (Graph.connect g h) k)
      (Graph.overlay
        (Graph.overlay (Graph.connect g h) (Graph.connect g k))
        (Graph.connect h k)) := by
  exact Relation.connect_decomposition (denote g) (denote h) (denote k)

/-! ## Operator Restatements

Same denotational laws re-expressed against the Lean operator surface
(`+`, `*`) for downstream proofs that prefer the compact algebraic
notation.
-/

theorem overlay_comm_add {α : Type} [DecidableEq α] (g h : Graph α) :
    GraphEq (g + h) (h + g) :=
  overlay_comm g h

theorem connect_assoc_mul {α : Type} [DecidableEq α] (g h k : Graph α) :
    GraphEq (g * h * k) (g * (h * k)) :=
  connect_assoc g h k

theorem connect_decomposition_mul {α : Type} [DecidableEq α] (g h k : Graph α) :
    GraphEq (g * h * k) ((g * h) + (g * k) + (h * k)) :=
  connect_decomposition g h k

end Cortex.Graph
