import Cortex.Graph.Quotient

/-!
## Overview

Safety-facing graph facts for the Cortex proof stack.

## Context

`Cortex.Graph.Relation` gives Mokhov graph expressions their finite relation
denotation. Track 2 and Track 3 need more than the algebraic laws: they need a
shared path, acyclicity, and endpoint-closure vocabulary that can bridge the
relation model into Pulse DAGs and Wire rewrite validity.

This module deliberately stays inside `Cortex.Graph.*`. It does not import
Pulse or Wire; downstream tracks consume these declarations to avoid duplicating
reachability and topology-validity definitions.

## Theorem Split

The page defines relation-level paths and acyclicity, proves endpoint closure
for Mokhov relation constructors and denoted graph expressions, and lifts the
acyclicity predicate through raw graph equality and the quotient carrier.
-/

namespace Cortex.Graph

/-! ## Relation Reachability -/

namespace Relation

variable {α : Type}

/-- `Path relation source target` is non-empty reachability through relation edges. -/
inductive Path (relation : Relation α) : α → α → Prop where
  | direct {source target : α} :
      (source, target) ∈ relation.edges → Path relation source target
  | trans {source middle target : α} :
      Path relation source middle →
        Path relation middle target →
          Path relation source target

/-- `Acyclic relation` rules out non-empty paths from a node back to itself. -/
def Acyclic (relation : Relation α) : Prop :=
  ∀ node : α, ¬ Path relation node node

namespace Path

/-- `Path.source_mem` keeps a reachable source inside an endpoint-closed relation. -/
theorem source_mem
    {relation : Relation α}
    (hEndpoints : EdgeEndpointsInVertices relation)
    {source target : α}
    (hPath : Path relation source target) :
    source ∈ relation.vertices := by
  induction hPath with
  | direct hEdge =>
      exact (hEndpoints _ hEdge).1
  | trans _ _ ihLeft _ =>
      exact ihLeft

/-- `Path.target_mem` keeps a reachable target inside an endpoint-closed relation. -/
theorem target_mem
    {relation : Relation α}
    (hEndpoints : EdgeEndpointsInVertices relation)
    {source target : α}
    (hPath : Path relation source target) :
    target ∈ relation.vertices := by
  induction hPath with
  | direct hEdge =>
      exact (hEndpoints _ hEdge).2
  | trans _ _ _ ihRight =>
      exact ihRight

end Path

/-! ## Runtime-Style Edge Predicate -/

section RuntimeEdgePredicate

variable [DecidableEq α]

/-- `edgeBool relation source target` is the boolean edge predicate for a finite relation. -/
def edgeBool (relation : Relation α) (source target : α) : Bool :=
  decide ((source, target) ∈ relation.edges)

/-- `edgeBool_true_iff` relates the boolean edge predicate to relation membership. -/
theorem edgeBool_true_iff
    (relation : Relation α)
    (source target : α) :
    edgeBool relation source target = true ↔ (source, target) ∈ relation.edges := by
  simp [edgeBool]

/-- `Path.of_edgeBool_true` turns a true runtime-style edge into relation reachability. -/
theorem Path.of_edgeBool_true
    {relation : Relation α}
    {source target : α}
    (hEdge : edgeBool relation source target = true) :
    Path relation source target :=
  Path.direct ((edgeBool_true_iff relation source target).1 hEdge)

/-- `edgeBool_source_mem` keeps runtime-style edge sources inside endpoint-closed relations. -/
theorem edgeBool_source_mem
    {relation : Relation α}
    (hEndpoints : EdgeEndpointsInVertices relation)
    {source target : α}
    (hEdge : edgeBool relation source target = true) :
    source ∈ relation.vertices := by
  have hMember : (source, target) ∈ relation.edges :=
    (edgeBool_true_iff relation source target).1 hEdge
  exact (hEndpoints _ hMember).1

/-- `edgeBool_target_mem` keeps runtime-style edge targets inside endpoint-closed relations. -/
theorem edgeBool_target_mem
    {relation : Relation α}
    (hEndpoints : EdgeEndpointsInVertices relation)
    {source target : α}
    (hEdge : edgeBool relation source target = true) :
    target ∈ relation.vertices := by
  have hMember : (source, target) ∈ relation.edges :=
    (edgeBool_true_iff relation source target).1 hEdge
  exact (hEndpoints _ hMember).2

end RuntimeEdgePredicate

/-! ## Endpoint Closure -/

/-- `empty_edgeEndpointsInVertices` says the empty relation is endpoint-closed. -/
theorem empty_edgeEndpointsInVertices :
    EdgeEndpointsInVertices (empty : Relation α) := by
  intro edge hEdge
  simp [empty] at hEdge

/-- `vertex_edgeEndpointsInVertices` says a singleton vertex relation is endpoint-closed. -/
theorem vertex_edgeEndpointsInVertices (vertexValue : α) :
    EdgeEndpointsInVertices (vertex vertexValue) := by
  intro edge hEdge
  simp [vertex] at hEdge

section EndpointConstructors

variable [DecidableEq α]

/-- `overlay_edgeEndpointsInVertices` preserves endpoint closure under overlay. -/
theorem overlay_edgeEndpointsInVertices
    {left right : Relation α}
    (hLeft : EdgeEndpointsInVertices left)
    (hRight : EdgeEndpointsInVertices right) :
    EdgeEndpointsInVertices (overlay left right) := by
  intro edge hEdge
  have hCases : edge ∈ left.edges ∨ edge ∈ right.edges := by
    simpa [overlay] using hEdge
  rcases hCases with hLeftEdge | hRightEdge
  · rcases hLeft edge hLeftEdge with ⟨hSource, hTarget⟩
    exact
      ⟨ Finset.mem_union_left right.vertices hSource
      , Finset.mem_union_left right.vertices hTarget
      ⟩
  · rcases hRight edge hRightEdge with ⟨hSource, hTarget⟩
    exact
      ⟨ Finset.mem_union_right left.vertices hSource
      , Finset.mem_union_right left.vertices hTarget
      ⟩

/-- `connect_edgeEndpointsInVertices` preserves endpoint closure under connect. -/
theorem connect_edgeEndpointsInVertices
    {left right : Relation α}
    (hLeft : EdgeEndpointsInVertices left)
    (hRight : EdgeEndpointsInVertices right) :
    EdgeEndpointsInVertices (connect left right) := by
  intro edge hEdge
  have hCases :
      edge ∈ left.edges ∨
        edge ∈ right.edges ∨
          edge.1 ∈ left.vertices ∧ edge.2 ∈ right.vertices := by
    simpa [connect, cross, Finset.mem_product, or_assoc] using hEdge
  rcases hCases with hLeftEdge | hRest
  · rcases hLeft edge hLeftEdge with ⟨hSource, hTarget⟩
    exact
      ⟨ Finset.mem_union_left right.vertices hSource
      , Finset.mem_union_left right.vertices hTarget
      ⟩
  · rcases hRest with hRightEdge | hCross
    · rcases hRight edge hRightEdge with ⟨hSource, hTarget⟩
      exact
        ⟨ Finset.mem_union_right left.vertices hSource
        , Finset.mem_union_right left.vertices hTarget
        ⟩
    · exact
        ⟨ Finset.mem_union_left right.vertices hCross.1
        , Finset.mem_union_right left.vertices hCross.2
        ⟩

end EndpointConstructors

/-- `acyclic_of_eq` transports relation acyclicity across relation equality. -/
theorem acyclic_of_eq
    {left right : Relation α}
    (hEq : left = right)
    (hAcyclic : Acyclic left) :
    Acyclic right := by
  cases hEq
  exact hAcyclic

/-- `acyclic_iff_of_eq` states relation acyclicity is invariant under equality. -/
theorem acyclic_iff_of_eq
    {left right : Relation α}
    (hEq : left = right) :
    Acyclic left ↔ Acyclic right :=
  ⟨acyclic_of_eq hEq, acyclic_of_eq hEq.symm⟩

end Relation

/-! ## Graph Expression Safety -/

variable {α : Type} [DecidableEq α]

/-- `denote_edgeEndpointsInVertices` says every denoted graph relation is endpoint-closed. -/
theorem denote_edgeEndpointsInVertices (graph : Graph α) :
    Relation.EdgeEndpointsInVertices (denote graph) := by
  induction graph with
  | empty =>
      exact Relation.empty_edgeEndpointsInVertices
  | vertex vertexValue =>
      exact Relation.vertex_edgeEndpointsInVertices vertexValue
  | overlay left right leftIH rightIH =>
      exact Relation.overlay_edgeEndpointsInVertices leftIH rightIH
  | connect left right leftIH rightIH =>
      exact Relation.connect_edgeEndpointsInVertices leftIH rightIH

/-- `GraphPath graph source target` is reachability through the graph denotation. -/
def GraphPath (graph : Graph α) (source target : α) : Prop :=
  Relation.Path (denote graph) source target

/-- `GraphAcyclic graph` rules out non-empty denotational cycles. -/
def GraphAcyclic (graph : Graph α) : Prop :=
  Relation.Acyclic (denote graph)

/-- `graphPath_source_mem` keeps graph-path sources inside the denoted vertex set. -/
theorem graphPath_source_mem
    {graph : Graph α}
    {source target : α}
    (hPath : GraphPath graph source target) :
    source ∈ (denote graph).vertices :=
  Relation.Path.source_mem (denote_edgeEndpointsInVertices graph) hPath

/-- `graphPath_target_mem` keeps graph-path targets inside the denoted vertex set. -/
theorem graphPath_target_mem
    {graph : Graph α}
    {source target : α}
    (hPath : GraphPath graph source target) :
    target ∈ (denote graph).vertices :=
  Relation.Path.target_mem (denote_edgeEndpointsInVertices graph) hPath

namespace GraphEq

/-- `GraphEq.acyclic` transports graph acyclicity across denotational graph equality. -/
theorem acyclic
    {left right : Graph α}
    (hEq : GraphEq left right)
    (hAcyclic : GraphAcyclic left) :
    GraphAcyclic right :=
  Relation.acyclic_of_eq hEq hAcyclic

/-- `GraphEq.acyclic_iff` says graph acyclicity is invariant under `GraphEq`. -/
theorem acyclic_iff
    {left right : Graph α}
    (hEq : GraphEq left right) :
    GraphAcyclic left ↔ GraphAcyclic right :=
  ⟨acyclic hEq, acyclic hEq.symm⟩

end GraphEq

/-! ## Quotient Safety -/

namespace AlgGraph

/-- `AlgGraph.Acyclic graph` is acyclicity of a quotient graph's relation denotation. -/
def Acyclic (graph : AlgGraph α) : Prop :=
  Relation.Acyclic (denote graph)

/-- `acyclic_ofGraph` identifies quotient acyclicity with raw graph acyclicity. -/
theorem acyclic_ofGraph (graph : Graph α) :
    Acyclic (ofGraph graph) ↔ GraphAcyclic graph :=
  Iff.rfl

/-- `acyclic_congr` transports quotient acyclicity across quotient equality. -/
theorem acyclic_congr
    {left right : AlgGraph α}
    (hEq : left = right) :
    Acyclic left ↔ Acyclic right := by
  cases hEq
  exact Iff.rfl

end AlgGraph

end Cortex.Graph
