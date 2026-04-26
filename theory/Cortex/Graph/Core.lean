/-
# Graph Algebra — Core

Mechanization of Mokhov's algebra of graphs. The four constructors
(`empty`, `vertex`, `overlay`, `connect`) generate every directed graph
and satisfy a small set of laws (proved in `Cortex.Graph.Laws`).

This is the abstract syntax tree of a graph. The denotation as a set of
vertices plus a set of edges is given by `vertexSet` / `edgeSet`; the
homomorphism into the relational model is given in
`Cortex.Graph.Relation` (TODO).

## References

- Andrey Mokhov, "Algebraic Graphs with Class (Functional Pearl)",
  Haskell Symposium 2017.
- Cortex `src/Cortex/Graph/Core.hs` — the executable counterpart this
  module mirrors.
- ADR 0010 — closed authority and the three-layer stack.
-/

namespace Cortex.Graph

/-- The free graph algebra over a vertex type `α`.

    Four constructors:
    - `empty`        : the empty graph
    - `vertex v`     : a single isolated vertex
    - `overlay g h`  : disjoint union — `vertexSet (overlay g h) = vertexSet g ∪ vertexSet h`
    - `connect g h`  : `g` plus `h` plus every edge from `g`'s vertices to `h`'s -/
inductive Graph (α : Type) : Type where
  | empty   : Graph α
  | vertex  : α → Graph α
  | overlay : Graph α → Graph α → Graph α
  | connect : Graph α → Graph α → Graph α
  deriving Repr

namespace Graph

variable {α : Type}

/-- Vertex set of a graph. -/
def vertexSet [DecidableEq α] : Graph α → List α
  | empty       => []
  | vertex v    => [v]
  | overlay g h => vertexSet g ++ vertexSet h
  | connect g h => vertexSet g ++ vertexSet h

/-- Number of distinct constructors used. Useful as a structural recursion measure. -/
def size : Graph α → Nat
  | empty       => 1
  | vertex _    => 1
  | overlay g h => 1 + size g + size h
  | connect g h => 1 + size g + size h

/-- A graph has *no* edges iff it can be expressed without using `connect`. -/
inductive IsEdgeFree : Graph α → Prop where
  | empty   : IsEdgeFree empty
  | vertex  : ∀ v, IsEdgeFree (vertex v)
  | overlay : ∀ {g h}, IsEdgeFree g → IsEdgeFree h → IsEdgeFree (overlay g h)

/-- Convenience: smart constructor for an edge `u → v`. -/
def edge (u v : α) : Graph α :=
  connect (vertex u) (vertex v)

end Graph

/-! ## Canonical operators

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
