/-!
## Overview

Mechanization of Mokhov's algebra of graphs. The four constructors
(`empty`, `vertex`, `overlay`, `connect`) generate every directed graph
and support the small law set stated in `Cortex.Graph.Laws`.

## Context

This is the abstract syntax tree of a graph. Lightweight syntax helpers
live next to the type; the homomorphism into the relational model is
given in `Cortex.Graph.Relation`.

## Theorem Split

This page defines the graph syntax, a few structural helpers used by
later proofs, and the canonical operator notation that makes theorem
statements read like Mokhov's algebra.

## References

- Andrey Mokhov, "Algebraic Graphs with Class (Functional Pearl)",
  Haskell Symposium 2017.
- Cortex `src/Cortex/Graph/Core.hs` — the executable counterpart this
  module mirrors.
- ADR 0010 — closed authority and the three-layer stack.
-/

namespace Cortex.Graph

/-! ## Free Graph Syntax -/

/-- `Graph α` is the free graph algebra over a vertex type `α`.

Four constructors:
- `empty`: the empty graph
- `vertex v`: a single isolated vertex
- `overlay g h`: disjoint union of graph expressions
- `connect g h`: `g` plus `h` plus every edge from `g`'s vertices to `h`'s -/
inductive Graph (α : Type) : Type where
  | empty   : Graph α
  | vertex  : α → Graph α
  | overlay : Graph α → Graph α → Graph α
  | connect : Graph α → Graph α → Graph α
  deriving Repr

variable {α : Type}

/-! ## Structural Helpers -/

/-- `vertexSet g` lists the vertices appearing in a graph expression. -/
def vertexSet [DecidableEq α] : Graph α → List α
  | Graph.empty       => []
  | Graph.vertex v    => [v]
  | Graph.overlay g h => vertexSet g ++ vertexSet h
  | Graph.connect g h => vertexSet g ++ vertexSet h

/-- `size g` counts constructors and is useful as a structural recursion measure. -/
def size : Graph α → Nat
  | Graph.empty       => 1
  | Graph.vertex _    => 1
  | Graph.overlay g h => 1 + size g + size h
  | Graph.connect g h => 1 + size g + size h

/-- `IsEdgeFree g` means `g` can be expressed without using `connect`. -/
inductive IsEdgeFree : Graph α → Prop where
  | empty   : IsEdgeFree Graph.empty
  | vertex  : ∀ v, IsEdgeFree (Graph.vertex v)
  | overlay : ∀ {g h}, IsEdgeFree g → IsEdgeFree h → IsEdgeFree (Graph.overlay g h)

/-- `edge u v` is the graph containing the directed edge `u → v`. -/
def edge (u v : α) : Graph α :=
  Graph.connect (Graph.vertex u) (Graph.vertex v)

/-! ## Canonical Operators

Mokhov's paper uses `+` (overlay) and `*` (connect). In Lean we keep
the surface exactly that small:

- `g + h`     — overlay, via `Add (Graph α)`
- `g * h`     — connect, via `Mul (Graph α)`

We intentionally do not introduce extra graph-specific glyphs or
append-style aliases. The proof surface should read like the algebra
itself, not a parallel notation layer.
-/

instance : Add (Graph α) where
  add := Graph.overlay

instance : Mul (Graph α) where
  mul := Graph.connect

end Cortex.Graph
