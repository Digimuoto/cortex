import Cortex.Graph.Laws

/-!
## Overview

Quotient carrier for Mokhov's algebraic graph laws.

## Context

`Cortex.Graph.Core.Graph` is the raw expression syntax. Its constructors
remember how a graph was written, so algebraic identities such as
`overlay empty g = g` are false as raw AST equality. `Cortex.Graph.Laws`
therefore exposes the law surface through `GraphEq`, equality of finite
relation denotations.

This module packages that relation as a quotient carrier, `AlgGraph`.
On `AlgGraph`, Mokhov's laws hold as ordinary Lean equality while raw
`Graph` remains available for syntax-directed recursion, compilation,
and expression metrics.

The module is intentionally proof infrastructure. Existing Pulse and
Wire modules continue to use raw `Graph` and `GraphEq` until a proof
needs quotient-level rewriting.

## Theorem Split

The page first proves `GraphEq` is an equivalence and that `overlay` and
`connect` respect it. It then defines the quotient carrier, lifts the
graph operations, and restates Mokhov's law set with `=`.
-/

namespace Cortex.Graph

variable {α : Type} [DecidableEq α]

/-! ## GraphEq Setoid -/

namespace GraphEq

/-- `GraphEq` is reflexive. -/
theorem refl (g : Graph α) :
    GraphEq g g :=
  rfl

/-- `GraphEq` is symmetric. -/
theorem symm {g h : Graph α}
    (hEq : GraphEq g h) :
    GraphEq h g :=
  Eq.symm hEq

/-- `GraphEq` is transitive. -/
theorem trans {g h k : Graph α}
    (hLeft : GraphEq g h)
    (hRight : GraphEq h k) :
    GraphEq g k :=
  Eq.trans hLeft hRight

/-- `overlay` respects denotational equality in both arguments. -/
theorem overlay {g g' h h' : Graph α}
    (hLeft : GraphEq g g')
    (hRight : GraphEq h h') :
    GraphEq (Graph.overlay g h) (Graph.overlay g' h') := by
  show
    Cortex.Graph.denote (Graph.overlay g h) =
      Cortex.Graph.denote (Graph.overlay g' h')
  simp only [denote_overlay]
  rw [
    show Cortex.Graph.denote g = Cortex.Graph.denote g' from hLeft,
    show Cortex.Graph.denote h = Cortex.Graph.denote h' from hRight,
  ]

/-- `connect` respects denotational equality in both arguments. -/
theorem connect {g g' h h' : Graph α}
    (hLeft : GraphEq g g')
    (hRight : GraphEq h h') :
    GraphEq (Graph.connect g h) (Graph.connect g' h') := by
  show
    Cortex.Graph.denote (Graph.connect g h) =
      Cortex.Graph.denote (Graph.connect g' h')
  simp only [denote_connect]
  rw [
    show Cortex.Graph.denote g = Cortex.Graph.denote g' from hLeft,
    show Cortex.Graph.denote h = Cortex.Graph.denote h' from hRight,
  ]

end GraphEq

/-- `graphSetoid α` identifies raw graph expressions with the same denotation. -/
def graphSetoid (α : Type) [DecidableEq α] : Setoid (Graph α) where
  r := GraphEq
  iseqv :=
    { refl := GraphEq.refl
      symm := GraphEq.symm
      trans := GraphEq.trans }

/-! ## Quotient Carrier -/

/-- `AlgGraph α` is the algebraic graph carrier modulo denotational equality. -/
def AlgGraph (α : Type) [DecidableEq α] : Type :=
  Quotient (graphSetoid α)

namespace AlgGraph

/-- Embed a raw graph expression into the quotient carrier. -/
def ofGraph (g : Graph α) : AlgGraph α :=
  Quotient.mk (graphSetoid α) g

/-- Raw `GraphEq` is exactly equality after embedding into `AlgGraph`. -/
theorem ofGraph_eq_iff {g h : Graph α} :
    ofGraph g = ofGraph h ↔ GraphEq g h :=
  Quotient.eq

/-- Turn a raw `GraphEq` proof into quotient equality. -/
theorem eq_of_graphEq {g h : Graph α}
    (hEq : GraphEq g h) :
    ofGraph g = ofGraph h :=
  Quotient.sound hEq

/-- Recover raw `GraphEq` from quotient equality between embedded expressions. -/
theorem graphEq_of_eq {g h : Graph α}
    (hEq : ofGraph g = ofGraph h) :
    GraphEq g h :=
  Quotient.exact hEq

/-- Denote a quotient graph by lifting `Cortex.Graph.denote` from raw graph syntax. -/
def denote : AlgGraph α → Relation α :=
  Quotient.lift Cortex.Graph.denote (fun _ _ hEq => hEq)

@[simp]
theorem denote_ofGraph (g : Graph α) :
    denote (ofGraph g) = Cortex.Graph.denote g :=
  rfl

/-- Quotient equality is equality of denotations. -/
theorem eq_iff_denote_eq (g h : AlgGraph α) :
    g = h ↔ denote g = denote h := by
  refine Quotient.inductionOn₂ g h ?_
  intro rawG rawH
  change ofGraph rawG = ofGraph rawH ↔ Cortex.Graph.denote rawG = Cortex.Graph.denote rawH
  exact ofGraph_eq_iff

/-! ## Lifted Operations -/

/-- Empty algebraic graph. -/
def empty : AlgGraph α :=
  ofGraph Graph.empty

/-- Singleton-vertex algebraic graph. -/
def vertex (v : α) : AlgGraph α :=
  ofGraph (Graph.vertex v)

/-- Algebraic overlay, lifted from raw graph expressions. -/
def overlay : AlgGraph α → AlgGraph α → AlgGraph α :=
  Quotient.lift₂
    (fun g h => ofGraph (Graph.overlay g h))
    (fun _ _ _ _ hLeft hRight =>
      Quotient.sound (GraphEq.overlay hLeft hRight))

/-- Algebraic connect, lifted from raw graph expressions. -/
def connect : AlgGraph α → AlgGraph α → AlgGraph α :=
  Quotient.lift₂
    (fun g h => ofGraph (Graph.connect g h))
    (fun _ _ _ _ hLeft hRight =>
      Quotient.sound (GraphEq.connect hLeft hRight))

instance : Add (AlgGraph α) where
  add := overlay

instance : Mul (AlgGraph α) where
  mul := connect

@[simp]
theorem overlay_ofGraph (g h : Graph α) :
    overlay (ofGraph g) (ofGraph h) = ofGraph (Graph.overlay g h) :=
  rfl

@[simp]
theorem connect_ofGraph (g h : Graph α) :
    connect (ofGraph g) (ofGraph h) = ofGraph (Graph.connect g h) :=
  rfl

@[simp]
theorem denote_empty :
    denote (α := α) empty = Relation.empty :=
  rfl

@[simp]
theorem denote_vertex (v : α) :
    denote (vertex v) = Relation.vertex v :=
  rfl

@[simp]
theorem denote_overlay (g h : AlgGraph α) :
    denote (overlay g h) = Relation.overlay (denote g) (denote h) := by
  refine Quotient.inductionOn₂ g h ?_
  intro rawG rawH
  rfl

@[simp]
theorem denote_connect (g h : AlgGraph α) :
    denote (connect g h) = Relation.connect (denote g) (denote h) := by
  refine Quotient.inductionOn₂ g h ?_
  intro rawG rawH
  rfl

/-! ## Mokhov Laws as Quotient Equality -/

/-- `empty` is a left identity for quotient overlay. -/
theorem overlay_empty_left (g : AlgGraph α) :
    overlay empty g = g := by
  apply (eq_iff_denote_eq _ _).2
  simp only [denote_overlay, denote_empty]
  exact Relation.overlay_empty_left (denote g)

/-- `empty` is a right identity for quotient overlay. -/
theorem overlay_empty_right (g : AlgGraph α) :
    overlay g empty = g := by
  apply (eq_iff_denote_eq _ _).2
  simp only [denote_overlay, denote_empty]
  exact Relation.overlay_empty_right (denote g)

/-- `empty` is a two-sided identity for quotient overlay. -/
theorem overlay_empty (g : AlgGraph α) :
    overlay empty g = g ∧ overlay g empty = g :=
  ⟨overlay_empty_left g, overlay_empty_right g⟩

/-- `empty` is a left identity for quotient connect. -/
theorem connect_empty_left (g : AlgGraph α) :
    connect empty g = g := by
  apply (eq_iff_denote_eq _ _).2
  simp only [denote_connect, denote_empty]
  exact Relation.connect_empty_left (denote g)

/-- `empty` is a right identity for quotient connect. -/
theorem connect_empty_right (g : AlgGraph α) :
    connect g empty = g := by
  apply (eq_iff_denote_eq _ _).2
  simp only [denote_connect, denote_empty]
  exact Relation.connect_empty_right (denote g)

/-- `empty` is a two-sided identity for quotient connect. -/
theorem connect_empty (g : AlgGraph α) :
    connect empty g = g ∧ connect g empty = g :=
  ⟨connect_empty_left g, connect_empty_right g⟩

/-- Quotient overlay is commutative. Mokhov Theorem 1. -/
theorem overlay_comm (g h : AlgGraph α) :
    overlay g h = overlay h g := by
  apply (eq_iff_denote_eq _ _).2
  simp only [denote_overlay]
  exact Relation.overlay_comm (denote g) (denote h)

/-- Quotient overlay is associative. Mokhov Theorem 2. -/
theorem overlay_assoc (g h k : AlgGraph α) :
    overlay (overlay g h) k = overlay g (overlay h k) := by
  apply (eq_iff_denote_eq _ _).2
  simp only [denote_overlay]
  exact Relation.overlay_assoc (denote g) (denote h) (denote k)

/-- Quotient connect is associative. Mokhov Theorem 4. -/
theorem connect_assoc (g h k : AlgGraph α) :
    connect (connect g h) k = connect g (connect h k) := by
  apply (eq_iff_denote_eq _ _).2
  simp only [denote_connect]
  exact Relation.connect_assoc (denote g) (denote h) (denote k)

/-- Quotient connect distributes over overlay on the left. Mokhov Theorem 6. -/
theorem connect_distrib_overlay_left (g h k : AlgGraph α) :
    connect g (overlay h k) =
      overlay (connect g h) (connect g k) := by
  apply (eq_iff_denote_eq _ _).2
  simp only [denote_connect, denote_overlay]
  exact
    Relation.connect_distrib_overlay_left
      (denote g)
      (denote h)
      (denote k)

/-- Quotient connect distributes over overlay on the right. -/
theorem connect_distrib_overlay_right (g h k : AlgGraph α) :
    connect (overlay g h) k =
      overlay (connect g k) (connect h k) := by
  apply (eq_iff_denote_eq _ _).2
  simp only [denote_connect, denote_overlay]
  exact
    Relation.connect_distrib_overlay_right
      (denote g)
      (denote h)
      (denote k)

/-- Quotient connect decomposition. Mokhov Theorem 8. -/
theorem connect_decomposition (g h k : AlgGraph α) :
    connect (connect g h) k =
      overlay
        (overlay (connect g h) (connect g k))
        (connect h k) := by
  apply (eq_iff_denote_eq _ _).2
  simp only [denote_connect, denote_overlay]
  exact Relation.connect_decomposition (denote g) (denote h) (denote k)

/-! ## Operator Restatements -/

/-- Quotient overlay commutativity through the `+` notation. -/
theorem overlay_comm_add (g h : AlgGraph α) :
    g + h = h + g :=
  overlay_comm g h

/-- Quotient connect associativity through the `*` notation. -/
theorem connect_assoc_mul (g h k : AlgGraph α) :
    g * h * k = g * (h * k) :=
  connect_assoc g h k

/-- Quotient connect decomposition through the `+` and `*` notation. -/
theorem connect_decomposition_mul (g h k : AlgGraph α) :
    g * h * k = (g * h) + (g * k) + (h * k) :=
  connect_decomposition g h k

end AlgGraph

end Cortex.Graph
