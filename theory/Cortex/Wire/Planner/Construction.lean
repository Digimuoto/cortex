import Cortex.Wire.Planner
import Mathlib.Data.List.Basic

/-!
## Overview

Runtime-shaped construction for Wire rewrite admission.

## Context

`Cortex.Wire.Planner` names the proof contract established by executable
planning. This module moves one step closer to the runtime: it defines a
concrete namespaced-node model, constructs a proof-side planned delta from
the relation-level planner model, and proves that the constructed delta
supplies the bulk of `RuntimePlannerConstruction`.

The theorem surface remains denotational. The constructed graph topology is a
non-extractable `Graph` representative for the finite planned relation;
correctness is stated as `denote topology = plannedFinalRelation ...`, not
raw AST equality. The executable runtime computes its own topology and must
establish denotational equality to this representative.

## Theorem Split

The page first records relation endpoint-closure lemmas needed to realize
planned relations as graphs. It then defines runtime-style namespaced node ids
and finally constructs planned deltas whose topology, diff sets, definitions,
entry/exit sets, and costs are definitionally tied to the planner model.
-/

namespace Cortex.Wire

open Cortex.Graph

/-! ## Runtime-Style Node Namespacing -/

/-- `RuntimeNodeId` models executable node ids as namespace segments.

The Haskell runtime serializes the same shape as colon-delimited `Text`.
Keeping segments structured in Lean makes delimiter-freedom explicit: a local
inserted id is a single non-empty segment containing no reserved delimiter, and
namespacing appends that segment below the anchor path. Fixed-anchor
injectivity is the only namespace theorem carried by the policy; disjointness
across different anchors is established by per-rewrite freshness against the
current topology. -/
structure RuntimeNodeId where
  /-- Namespace path segments. -/
  segments : List String
  deriving DecidableEq, Repr

namespace RuntimeNodeId

/-- Runtime namespace delimiter mirrored from the Haskell `NodeId` encoding. -/
def namespaceDelimiter : Char :=
  ':'

/-- `segmentAllowed segment` mirrors the executable local-node syntax check. -/
def segmentAllowed (segment : String) : Prop :=
  segment.isEmpty = false ∧ segment.contains namespaceDelimiter = false

/-- A local inserted node id is one non-empty segment with no namespace delimiter. -/
def localAllowed (node : RuntimeNodeId) : Prop :=
  ∃ segment, node.segments = [segment] ∧ segmentAllowed segment

/-- Namespace a local inserted node under an anchor. -/
def namespaceNode (anchor localNode : RuntimeNodeId) : RuntimeNodeId :=
  { segments := anchor.segments ++ localNode.segments }

/-- Fixed-anchor namespacing is injective. -/
theorem namespaceNode_injective (anchor : RuntimeNodeId) :
    Function.Injective (namespaceNode anchor) := by
  intro left right hNamespaced
  cases left with
  | mk leftSegments =>
      cases right with
      | mk rightSegments =>
          cases anchor with
          | mk anchorSegments =>
              have hSegments :
                  anchorSegments ++ leftSegments = anchorSegments ++ rightSegments :=
                congrArg RuntimeNodeId.segments hNamespaced
              have hLocalSegments : leftSegments = rightSegments :=
                List.append_right_injective anchorSegments hSegments
              cases hLocalSegments
              rfl

/-- The concrete runtime namespace policy for structured node ids. -/
def namespacePolicy : RuntimeNamespacePolicy RuntimeNodeId :=
  { namespaceNode := namespaceNode
    localAllowed := localAllowed
    namespaceNode_injective := namespaceNode_injective }

end RuntimeNodeId

/-! ## Relation Endpoint Closure -/

section EndpointClosure

variable {node : Type}
variable [DecidableEq node]

/-- Relation overlay preserves endpoint closure. -/
theorem relation_edgeEndpoints_overlay
    {left right : Relation node}
    (hLeft : Relation.EdgeEndpointsInVertices left)
    (hRight : Relation.EdgeEndpointsInVertices right) :
    Relation.EdgeEndpointsInVertices (Relation.overlay left right) := by
  intro edge hEdge
  simp only [Relation.overlay, Finset.mem_union] at hEdge ⊢
  rcases hEdge with hEdge | hEdge
  · exact ⟨Or.inl (hLeft edge hEdge).1, Or.inl (hLeft edge hEdge).2⟩
  · exact ⟨Or.inr (hRight edge hEdge).1, Or.inr (hRight edge hEdge).2⟩

/-- Relation connect preserves endpoint closure. -/
theorem relation_edgeEndpoints_connect
    {left right : Relation node}
    (hLeft : Relation.EdgeEndpointsInVertices left)
    (hRight : Relation.EdgeEndpointsInVertices right) :
    Relation.EdgeEndpointsInVertices (Relation.connect left right) := by
  intro edge hEdge
  simp only [Relation.connect, Relation.cross, Finset.mem_union, Finset.mem_product] at hEdge ⊢
  rcases hEdge with hOldEdge | hCross
  · rcases hOldEdge with hEdge | hEdge
    · exact ⟨Or.inl (hLeft edge hEdge).1, Or.inl (hLeft edge hEdge).2⟩
    · exact ⟨Or.inr (hRight edge hEdge).1, Or.inr (hRight edge hEdge).2⟩
  · exact ⟨Or.inl hCross.1, Or.inr hCross.2⟩

/-- Denotations of graph expressions are endpoint-closed relations. -/
theorem denote_edgeEndpointsInVertices (g : Graph node) :
    Relation.EdgeEndpointsInVertices (denote g) := by
  induction g with
  | empty =>
      intro edge hEdge
      simp only [denote_empty, Relation.empty, Finset.notMem_empty] at hEdge
  | vertex vertex =>
      intro edge hEdge
      simp only [denote_vertex, Relation.vertex, Finset.notMem_empty] at hEdge
  | overlay left right left_ih right_ih =>
      rw [denote_overlay]
      exact relation_edgeEndpoints_overlay left_ih right_ih
  | connect left right left_ih right_ih =>
      rw [denote_connect]
      exact relation_edgeEndpoints_connect left_ih right_ih

/-- Removing one vertex and its incident edges preserves endpoint closure. -/
theorem relation_edgeEndpoints_removeVertex
    {relation : Relation node}
    {vertex : node}
    (hRelation : Relation.EdgeEndpointsInVertices relation) :
    Relation.EdgeEndpointsInVertices (removeVertexFromRelation relation vertex) := by
  intro edge hEdge
  simp only [removeVertexFromRelation, Finset.mem_filter, Finset.mem_erase] at hEdge ⊢
  rcases hEdge with ⟨hOldEdge, hSourceNe, hTargetNe⟩
  exact ⟨⟨hSourceNe, (hRelation edge hOldEdge).1⟩, ⟨hTargetNe, (hRelation edge hOldEdge).2⟩⟩

/-- Removing outgoing edges preserves endpoint closure. -/
theorem relation_edgeEndpoints_removeOutgoing
    {relation : Relation node}
    {vertex : node}
    (hRelation : Relation.EdgeEndpointsInVertices relation) :
    Relation.EdgeEndpointsInVertices (removeOutgoingFromRelation relation vertex) := by
  intro edge hEdge
  simp only [removeOutgoingFromRelation, Finset.mem_filter] at hEdge ⊢
  exact hRelation edge hEdge.1

/-- Adding edges while also adding their endpoints preserves endpoint closure. -/
theorem relation_edgeEndpoints_addEdges
    {relation : Relation node}
    {edges : Finset (node × node)}
    (hRelation : Relation.EdgeEndpointsInVertices relation) :
    Relation.EdgeEndpointsInVertices (addEdgesToRelation relation edges) := by
  intro edge hEdge
  simp only [addEdgesToRelation, Finset.mem_union] at hEdge ⊢
  rcases hEdge with hOldEdge | hAddedEdge
  · exact
      ⟨ Or.inl (Or.inl (hRelation edge hOldEdge).1)
      , Or.inl (Or.inl (hRelation edge hOldEdge).2)
      ⟩
  · exact
      ⟨ Or.inl (Or.inr (Finset.mem_image.mpr ⟨edge, hAddedEdge, rfl⟩))
      , Or.inr (Finset.mem_image.mpr ⟨edge, hAddedEdge, rfl⟩)
      ⟩

/-- The relation-level planner construction always produces an endpoint-closed relation. -/
theorem plannedFinalRelation_edgeEndpointsInVertices
    (context : Graph node)
    (rewrite : GraphRewrite node) :
    Relation.EdgeEndpointsInVertices (plannedFinalRelation context rewrite) := by
  cases rewrite with
  | expandNode anchor mode spec =>
      cases mode with
      | replaceNode =>
          simp only
            [ plannedFinalRelation
            , GraphRewrite.anchor
            , GraphRewrite.spec
            , GraphRewrite.anchorDisposition
            ]
          exact
            relation_edgeEndpoints_addEdges
              (relation_edgeEndpoints_addEdges
                (relation_edgeEndpoints_overlay
                  (relation_edgeEndpoints_removeVertex (denote_edgeEndpointsInVertices context))
                  (denote_edgeEndpointsInVertices spec.topology)))
      | retainNodeAsEnvelope =>
          simp only
            [ plannedFinalRelation
            , GraphRewrite.anchor
            , GraphRewrite.spec
            , GraphRewrite.anchorDisposition
            ]
          exact
            relation_edgeEndpoints_addEdges
              (relation_edgeEndpoints_addEdges
                (relation_edgeEndpoints_overlay
                  (relation_edgeEndpoints_removeOutgoing (denote_edgeEndpointsInVertices context))
                  (denote_edgeEndpointsInVertices spec.topology)))
  | appendAfter anchor spec =>
      simp only
        [ plannedFinalRelation
        , GraphRewrite.anchor
        , GraphRewrite.spec
        , GraphRewrite.anchorDisposition
        ]
      exact
        relation_edgeEndpoints_addEdges
          (relation_edgeEndpoints_addEdges
            (relation_edgeEndpoints_overlay
              (relation_edgeEndpoints_removeOutgoing (denote_edgeEndpointsInVertices context))
              (denote_edgeEndpointsInVertices spec.topology)))

end EndpointClosure

/-! ## Anchor Membership -/

section AnchorMembership

variable {node : Type}
variable [DecidableEq node]

/-- Acyclic source topologies have no direct self-loop at the rewrite anchor. -/
theorem anchor_noSelfLoop_of_acyclic
    {context : Graph node}
    {anchor : node}
    (hSourceAcyclic : Acyclic context) :
    (anchor, anchor) ∉ (denote context).edges := by
  intro hLoop
  exact hSourceAcyclic anchor (GraphPath.direct hLoop)

/-- Without a self-loop, an anchor is not its own direct predecessor. -/
theorem anchor_not_mem_predecessorsOf_of_noSelfLoop
    {relation : Relation node}
    {anchor : node}
    (hNoSelfLoop : (anchor, anchor) ∉ relation.edges) :
    anchor ∉ predecessorsOf relation anchor := by
  intro hPred
  simp only [predecessorsOf, Finset.mem_image, Finset.mem_filter] at hPred
  rcases hPred with ⟨edge, hEdge, hSource⟩
  rcases edge with ⟨source, target⟩
  simp only at hSource
  subst source
  simp only at hEdge
  rw [hEdge.2] at hEdge
  exact hNoSelfLoop hEdge.1

/-- Without a self-loop, an anchor is not its own direct successor. -/
theorem anchor_not_mem_successorsOf_of_noSelfLoop
    {relation : Relation node}
    {anchor : node}
    (hNoSelfLoop : (anchor, anchor) ∉ relation.edges) :
    anchor ∉ successorsOf relation anchor := by
  intro hSucc
  simp only [successorsOf, Finset.mem_image, Finset.mem_filter] at hSucc
  rcases hSucc with ⟨edge, hEdge, hTarget⟩
  rcases edge with ⟨source, target⟩
  simp only at hTarget
  subst target
  simp only at hEdge
  rw [hEdge.2] at hEdge
  exact hNoSelfLoop hEdge.1

/-- Direct predecessors of a denoted graph node are vertices of the denoted graph. -/
theorem predecessorsOf_mem_vertices
    {context : Graph node}
    {target predecessor : node}
    (hPredecessor : predecessor ∈ predecessorsOf (denote context) target) :
    predecessor ∈ (denote context).vertices := by
  simp only [predecessorsOf, Finset.mem_image, Finset.mem_filter] at hPredecessor
  rcases hPredecessor with ⟨edge, hEdge, hSource⟩
  rcases edge with ⟨source, target⟩
  simp only at hSource
  subst source
  exact (denote_edgeEndpointsInVertices context (predecessor, target) hEdge.1).1

/-- Direct successors of a denoted graph node are vertices of the denoted graph. -/
theorem successorsOf_mem_vertices
    {context : Graph node}
    {target successor : node}
    (hSuccessor : successor ∈ successorsOf (denote context) target) :
    successor ∈ (denote context).vertices := by
  simp only [successorsOf, Finset.mem_image, Finset.mem_filter] at hSuccessor
  rcases hSuccessor with ⟨edge, hEdge, hTarget⟩
  rcases edge with ⟨source, target⟩
  simp only at hTarget
  subst target
  exact (denote_edgeEndpointsInVertices context (source, successor) hEdge.1).2

/-- Replacement rewrites have exactly old-minus-anchor plus inserted final vertices. -/
theorem plannedFinalRelation_vertices_replace
    {context : Graph node}
    {anchor : node}
    {spec : SubgraphSpec node}
    (hNoSelfLoop : (anchor, anchor) ∉ (denote context).edges)
    (hEntryInside : NodesInside spec.entryNodes spec.topology)
    (hExitInside : NodesInside spec.exitNodes spec.topology) :
    (plannedFinalRelation context
      (GraphRewrite.expandNode anchor ExpansionMode.replaceNode spec)).vertices =
        (denote context).vertices.erase anchor ∪ (denote spec.topology).vertices := by
  apply Finset.ext
  intro node
  constructor
  · intro hFinal
    simp only
      [ plannedFinalRelation
      , GraphRewrite.anchor
      , GraphRewrite.spec
      , GraphRewrite.anchorDisposition
      , removeVertexFromRelation
      , addEdgesToRelation
      , Relation.overlay
      , Finset.mem_union
      , Finset.mem_erase
      , Finset.mem_image
      , Finset.mem_product
      ] at hFinal ⊢
    rcases hFinal with (((hBaseOrInserted | hEntrySource) | hEntryTarget) | hExitSource) |
      hExitTarget
    · rcases hBaseOrInserted with hBase | hInserted
      · exact Or.inl hBase
      · exact Or.inr hInserted
    · rcases hEntrySource with ⟨edge, hEdge, hSource⟩
      rcases edge with ⟨source, _entry⟩
      simp only at hSource
      have hPredecessor : node ∈ predecessorsOf (denote context) anchor := by
        simpa only [hSource] using hEdge.1
      have hNodeNeAnchor : node ≠ anchor := by
        intro hNodeEq
        rw [hNodeEq] at hPredecessor
        exact anchor_not_mem_predecessorsOf_of_noSelfLoop hNoSelfLoop hPredecessor
      exact Or.inl ⟨hNodeNeAnchor, predecessorsOf_mem_vertices hPredecessor⟩
    · rcases hEntryTarget with ⟨edge, hEdge, hEntry⟩
      rcases edge with ⟨_source, entry⟩
      simp only at hEntry
      rw [← hEntry]
      exact Or.inr (hEntryInside entry hEdge.2)
    · rcases hExitSource with ⟨edge, hEdge, hExit⟩
      rcases edge with ⟨exit, _successor⟩
      simp only at hExit
      rw [← hExit]
      exact Or.inr (hExitInside exit hEdge.1)
    · rcases hExitTarget with ⟨edge, hEdge, hSuccessor⟩
      rcases edge with ⟨_exit, successor⟩
      simp only at hSuccessor
      have hSuccessorMem : node ∈ successorsOf (denote context) anchor := by
        simpa only [hSuccessor] using hEdge.2
      have hNodeNeAnchor : node ≠ anchor := by
        intro hNodeEq
        rw [hNodeEq] at hSuccessorMem
        exact anchor_not_mem_successorsOf_of_noSelfLoop hNoSelfLoop hSuccessorMem
      exact Or.inl ⟨hNodeNeAnchor, successorsOf_mem_vertices hSuccessorMem⟩
  · intro hUnion
    simp only
      [ plannedFinalRelation
      , GraphRewrite.anchor
      , GraphRewrite.spec
      , GraphRewrite.anchorDisposition
      , removeVertexFromRelation
      , addEdgesToRelation
      , Relation.overlay
      , Finset.mem_union
      , Finset.mem_erase
      , Finset.mem_image
      , Finset.mem_product
      ] at hUnion ⊢
    rcases hUnion with hBase | hInserted
    · exact Or.inl (Or.inl (Or.inl (Or.inl (Or.inl hBase))))
    · exact Or.inl (Or.inl (Or.inl (Or.inl (Or.inr hInserted))))

/-- Retained-envelope rewrites have old plus inserted final vertices. -/
theorem plannedFinalRelation_vertices_retain
    {context : Graph node}
    {anchor : node}
    {spec : SubgraphSpec node}
    (hAnchorInTopology : anchor ∈ (denote context).vertices)
    (hEntryInside : NodesInside spec.entryNodes spec.topology)
    (hExitInside : NodesInside spec.exitNodes spec.topology) :
    (plannedFinalRelation context
      (GraphRewrite.expandNode anchor ExpansionMode.retainNodeAsEnvelope spec)).vertices =
        (denote context).vertices ∪ (denote spec.topology).vertices := by
  apply Finset.ext
  intro node
  constructor
  · intro hFinal
    simp only
      [ plannedFinalRelation
      , GraphRewrite.anchor
      , GraphRewrite.spec
      , GraphRewrite.anchorDisposition
      , removeOutgoingFromRelation
      , addEdgesToRelation
      , Relation.overlay
      , Finset.mem_union
      , Finset.mem_singleton
      , Finset.mem_image
      , Finset.mem_product
      ] at hFinal ⊢
    rcases hFinal with (((hBaseOrInserted | hEntrySource) | hEntryTarget) | hExitSource) |
      hExitTarget
    · rcases hBaseOrInserted with hBase | hInserted
      · exact Or.inl hBase
      · exact Or.inr hInserted
    · rcases hEntrySource with ⟨edge, hEdge, hSource⟩
      rcases edge with ⟨source, _entry⟩
      simp only at hSource
      have hSourceAnchor : source = anchor := by
        simpa only [Finset.mem_singleton] using hEdge.1
      rw [← hSource]
      rw [hSourceAnchor]
      exact Or.inl hAnchorInTopology
    · rcases hEntryTarget with ⟨edge, hEdge, hEntry⟩
      rcases edge with ⟨_source, entry⟩
      simp only at hEntry
      rw [← hEntry]
      exact Or.inr (hEntryInside entry hEdge.2)
    · rcases hExitSource with ⟨edge, hEdge, hExit⟩
      rcases edge with ⟨exit, _successor⟩
      simp only at hExit
      rw [← hExit]
      exact Or.inr (hExitInside exit hEdge.1)
    · rcases hExitTarget with ⟨edge, hEdge, hSuccessor⟩
      rcases edge with ⟨_exit, successor⟩
      simp only at hSuccessor
      have hSuccessorMem : node ∈ successorsOf (denote context) anchor := by
        simpa only [hSuccessor] using hEdge.2
      exact Or.inl (successorsOf_mem_vertices hSuccessorMem)
  · intro hUnion
    simp only
      [ plannedFinalRelation
      , GraphRewrite.anchor
      , GraphRewrite.spec
      , GraphRewrite.anchorDisposition
      , removeOutgoingFromRelation
      , addEdgesToRelation
      , Relation.overlay
      , Finset.mem_union
      , Finset.mem_singleton
      , Finset.mem_image
      , Finset.mem_product
      ] at hUnion ⊢
    rcases hUnion with hBase | hInserted
    · exact Or.inl (Or.inl (Or.inl (Or.inl (Or.inl hBase))))
    · exact Or.inl (Or.inl (Or.inl (Or.inl (Or.inr hInserted))))

/-- Append-after rewrites have old plus inserted final vertices. -/
theorem plannedFinalRelation_vertices_append
    {context : Graph node}
    {anchor : node}
    {spec : SubgraphSpec node}
    (hAnchorInTopology : anchor ∈ (denote context).vertices)
    (hEntryInside : NodesInside spec.entryNodes spec.topology)
    (hExitInside : NodesInside spec.exitNodes spec.topology) :
    (plannedFinalRelation context (GraphRewrite.appendAfter anchor spec)).vertices =
        (denote context).vertices ∪ (denote spec.topology).vertices := by
  apply Finset.ext
  intro node
  constructor
  · intro hFinal
    simp only
      [ plannedFinalRelation
      , GraphRewrite.anchor
      , GraphRewrite.spec
      , GraphRewrite.anchorDisposition
      , removeOutgoingFromRelation
      , addEdgesToRelation
      , Relation.overlay
      , Finset.mem_union
      , Finset.mem_singleton
      , Finset.mem_image
      , Finset.mem_product
      ] at hFinal ⊢
    rcases hFinal with (((hBaseOrInserted | hEntrySource) | hEntryTarget) | hExitSource) |
      hExitTarget
    · rcases hBaseOrInserted with hBase | hInserted
      · exact Or.inl hBase
      · exact Or.inr hInserted
    · rcases hEntrySource with ⟨edge, hEdge, hSource⟩
      rcases edge with ⟨source, _entry⟩
      simp only at hSource
      have hSourceAnchor : source = anchor := by
        simpa only [Finset.mem_singleton] using hEdge.1
      rw [← hSource]
      rw [hSourceAnchor]
      exact Or.inl hAnchorInTopology
    · rcases hEntryTarget with ⟨edge, hEdge, hEntry⟩
      rcases edge with ⟨_source, entry⟩
      simp only at hEntry
      rw [← hEntry]
      exact Or.inr (hEntryInside entry hEdge.2)
    · rcases hExitSource with ⟨edge, hEdge, hExit⟩
      rcases edge with ⟨exit, _successor⟩
      simp only at hExit
      rw [← hExit]
      exact Or.inr (hExitInside exit hEdge.1)
    · rcases hExitTarget with ⟨edge, hEdge, hSuccessor⟩
      rcases edge with ⟨_exit, successor⟩
      simp only at hSuccessor
      have hSuccessorMem : node ∈ successorsOf (denote context) anchor := by
        simpa only [hSuccessor] using hEdge.2
      exact Or.inl (successorsOf_mem_vertices hSuccessorMem)
  · intro hUnion
    simp only
      [ plannedFinalRelation
      , GraphRewrite.anchor
      , GraphRewrite.spec
      , GraphRewrite.anchorDisposition
      , removeOutgoingFromRelation
      , addEdgesToRelation
      , Relation.overlay
      , Finset.mem_union
      , Finset.mem_singleton
      , Finset.mem_image
      , Finset.mem_product
      ] at hUnion ⊢
    rcases hUnion with hBase | hInserted
    · exact Or.inl (Or.inl (Or.inl (Or.inl (Or.inl hBase))))
    · exact Or.inl (Or.inl (Or.inl (Or.inl (Or.inr hInserted))))

/-- A replacement rewrite removes the anchor when the old topology has no anchor self-loop. -/
theorem anchor_not_mem_plannedFinalRelation_replace
    {context : Graph node}
    {anchor : node}
    {spec : SubgraphSpec node}
    (hAnchorIn : anchor ∈ (denote context).vertices)
    (hNoSelfLoop : (anchor, anchor) ∉ (denote context).edges)
    (hFresh :
      ∀ mappedNode,
        mappedNode ∈ (denote spec.topology).vertices →
          mappedNode ∉ (denote context).vertices)
    (hEntryInside : NodesInside spec.entryNodes spec.topology)
    (hExitInside : NodesInside spec.exitNodes spec.topology) :
    anchor ∉
      (plannedFinalRelation context
        (GraphRewrite.expandNode anchor ExpansionMode.replaceNode spec)).vertices := by
  intro hFinal
  simp only
    [ plannedFinalRelation
    , GraphRewrite.anchor
    , GraphRewrite.spec
    , GraphRewrite.anchorDisposition
    , removeVertexFromRelation
    , addEdgesToRelation
    , Relation.overlay
    , Finset.mem_union
    , Finset.mem_erase
    , Finset.mem_image
    , Finset.mem_product
    ] at hFinal
  rcases hFinal with (((hBaseOrInserted | hEntrySource) | hEntryTarget) | hExitSource) |
    hExitTarget
  · rcases hBaseOrInserted with hBase | hInserted
    · exact hBase.1 rfl
    · exact hFresh anchor hInserted hAnchorIn
  · rcases hEntrySource with ⟨edge, hEdge, hSource⟩
    rcases edge with ⟨source, _entry⟩
    simp only at hSource
    have hPred : anchor ∈ predecessorsOf (denote context) anchor := by
      simpa only [hSource] using hEdge.1
    exact anchor_not_mem_predecessorsOf_of_noSelfLoop hNoSelfLoop hPred
  · rcases hEntryTarget with ⟨edge, hEdge, hEntry⟩
    rcases edge with ⟨_source, entry⟩
    simp only at hEntry
    have hEntryOld : entry ∈ (denote context).vertices := by
      rw [hEntry]
      exact hAnchorIn
    exact hFresh entry (hEntryInside entry hEdge.2) hEntryOld
  · rcases hExitSource with ⟨edge, hEdge, hExit⟩
    rcases edge with ⟨exit, _successor⟩
    simp only at hExit
    have hExitOld : exit ∈ (denote context).vertices := by
      rw [hExit]
      exact hAnchorIn
    exact hFresh exit (hExitInside exit hEdge.1) hExitOld
  · rcases hExitTarget with ⟨edge, hEdge, hSuccessor⟩
    rcases edge with ⟨_exit, successor⟩
    simp only at hSuccessor
    have hSucc : anchor ∈ successorsOf (denote context) anchor := by
      simpa only [hSuccessor] using hEdge.2
    exact anchor_not_mem_successorsOf_of_noSelfLoop hNoSelfLoop hSucc

/-- A retained-envelope rewrite keeps the anchor in the planned final relation. -/
theorem anchor_mem_plannedFinalRelation_retain
    {context : Graph node}
    {anchor : node}
    {spec : SubgraphSpec node}
    (hAnchorIn : anchor ∈ (denote context).vertices) :
    anchor ∈
      (plannedFinalRelation context
        (GraphRewrite.expandNode anchor ExpansionMode.retainNodeAsEnvelope spec)).vertices := by
  simp only
    [ plannedFinalRelation
    , GraphRewrite.anchor
    , GraphRewrite.spec
    , GraphRewrite.anchorDisposition
    , removeOutgoingFromRelation
    , addEdgesToRelation
    , Relation.overlay
    , Finset.mem_union
    ]
  exact Or.inl (Or.inl (Or.inl (Or.inl (Or.inl hAnchorIn))))

/-- An append-after rewrite keeps the anchor in the planned final relation. -/
theorem anchor_mem_plannedFinalRelation_append
    {context : Graph node}
    {anchor : node}
    {spec : SubgraphSpec node}
    (hAnchorIn : anchor ∈ (denote context).vertices) :
    anchor ∈
      (plannedFinalRelation context (GraphRewrite.appendAfter anchor spec)).vertices := by
  simp only
    [ plannedFinalRelation
    , GraphRewrite.anchor
    , GraphRewrite.spec
    , GraphRewrite.anchorDisposition
    , removeOutgoingFromRelation
    , addEdgesToRelation
    , Relation.overlay
    , Finset.mem_union
    ]
  exact Or.inl (Or.inl (Or.inl (Or.inl (Or.inl hAnchorIn))))

end AnchorMembership

/-! ## Constructed Planned Delta -/

section ConstructedDelta

variable {node : Type}
variable [DecidableEq node]

/-- Relation computed by the runtime-shaped planner after namespacing. -/
def constructedFinalRelation
    (policy : RuntimeNamespacePolicy node)
    (context : PlanningContext node)
    (rawRewrite : GraphRewrite node) :
    Relation node :=
  plannedFinalRelation context.topology (runtimePlannerRewrite policy rawRewrite)

/-- Graph representative for the constructed final relation. -/
noncomputable def constructedFinalTopology
    (policy : RuntimeNamespacePolicy node)
    (context : PlanningContext node)
    (rawRewrite : GraphRewrite node) :
    Graph node :=
  graphOfRelation (constructedFinalRelation policy context rawRewrite)

/-- The constructed final topology denotes the relation-level planner output. -/
theorem denote_constructedFinalTopology
    (policy : RuntimeNamespacePolicy node)
    (context : PlanningContext node)
    (rawRewrite : GraphRewrite node) :
    denote (constructedFinalTopology policy context rawRewrite) =
      constructedFinalRelation policy context rawRewrite := by
  unfold constructedFinalTopology constructedFinalRelation
  exact
    denote_graphOfRelation
      (plannedFinalRelation_edgeEndpointsInVertices
        context.topology
        (runtimePlannerRewrite policy rawRewrite))

/-- Planned delta obtained by the runtime-shaped construction equations. -/
noncomputable def constructedPlannedRewriteDelta
    (policy : RuntimeNamespacePolicy node)
    (context : PlanningContext node)
    (rawRewrite : GraphRewrite node)
    (insertedDepth : Nat) :
    PlannedRewriteDelta node :=
  let rewrite := runtimePlannerRewrite policy rawRewrite
  let finalRelation := constructedFinalRelation policy context rawRewrite
  let oldRelation := denote context.topology
  let newNodes := relationAddedNodes oldRelation finalRelation
  let addedEdges := relationAddedEdges oldRelation finalRelation
  { topology := constructedFinalTopology policy context rawRewrite
    definitions := plannedFinalDefinitions context rewrite
    newNodes := newNodes
    removedNodes := relationRemovedNodes oldRelation finalRelation
    addedEdges := addedEdges
    entryNodes := rewrite.spec.entryNodes
    exitNodes := rewrite.spec.exitNodes
    anchorNode := rawRewrite.anchor
    anchorDisposition := rewrite.anchorDisposition
    cost :=
      { addedNodes := newNodes.card
        addedEdges := addedEdges.card
        addedDepth :=
          match rewrite.anchorDisposition with
          | RewriteAnchorDisposition.removed => insertedDepth - 1
          | RewriteAnchorDisposition.retained => insertedDepth
        frontierDelta := rewrite.spec.entryNodes.card - 1
        rewriteOps := 1 } }

/-- The constructed delta records anchor identity and derives anchor membership facts. -/
theorem constructedPlannedRewriteDelta_anchorMatches
    {policy : RuntimeNamespacePolicy node}
    {context : PlanningContext node}
    {rawRewrite : GraphRewrite node}
    {insertedDepth : Nat}
    (hDiscipline :
      NamespaceDiscipline
        policy.localAllowed
        (policy.namespaceNode rawRewrite.anchor)
        context
        rawRewrite.spec)
    (hAnchorInTopology : rawRewrite.anchor ∈ (denote context.topology).vertices)
    (hSourceAcyclic : Acyclic context.topology)
    (hRawSubgraphValid : rawRewrite.spec.Valid) :
    RuntimeAnchorMatches
      policy
      rawRewrite
      (constructedPlannedRewriteDelta policy context rawRewrite insertedDepth) := by
  have hAnchorNoSelfLoop :
      (rawRewrite.anchor, rawRewrite.anchor) ∉ (denote context.topology).edges :=
    anchor_noSelfLoop_of_acyclic hSourceAcyclic
  have hNamespacedValid : (runtimePlannerRewrite policy rawRewrite).spec.Valid := by
    simp only [runtimePlannerRewrite, namespaceGraphRewrite_spec]
    exact
      namespaceSubgraphSpec_preserves_valid
        (policy.namespaceNode_injective rawRewrite.anchor)
        hRawSubgraphValid
  have hFresh :
      ∀ mappedNode,
        mappedNode ∈ (denote (runtimePlannerRewrite policy rawRewrite).spec.topology).vertices →
          mappedNode ∉ (denote context.topology).vertices := by
    rw [runtimePlannerRewrite, namespaceGraphRewrite_spec]
    exact namespaceSubgraphSpec_fresh_against_context hDiscipline
  refine
    { anchorNode_eq := by
        simp only [constructedPlannedRewriteDelta]
      anchorDisposition_eq := by
        simp only [constructedPlannedRewriteDelta]
      removed_absent := ?_
      retained_present := ?_ }
  · intro hRemoved
    simp only [constructedPlannedRewriteDelta] at hRemoved ⊢
    rw [denote_constructedFinalTopology]
    cases rawRewrite with
    | expandNode anchor mode spec =>
        cases mode with
        | replaceNode =>
            exact
              anchor_not_mem_plannedFinalRelation_replace
                hAnchorInTopology
                hAnchorNoSelfLoop
                hFresh
                hNamespacedValid.entryNodesInside
                hNamespacedValid.exitNodesInside
        | retainNodeAsEnvelope =>
            cases hRemoved
    | appendAfter anchor spec =>
        cases hRemoved
  · intro hRetained
    simp only [constructedPlannedRewriteDelta] at hRetained ⊢
    rw [denote_constructedFinalTopology]
    cases rawRewrite with
    | expandNode anchor mode spec =>
        cases mode with
        | replaceNode =>
            cases hRetained
        | retainNodeAsEnvelope =>
            exact anchor_mem_plannedFinalRelation_retain hAnchorInTopology
    | appendAfter anchor spec =>
        exact anchor_mem_plannedFinalRelation_append hAnchorInTopology

/-- `SourcePlanningContextValid` is the invariant carried by materialized planner inputs. -/
structure SourcePlanningContextValid (context : PlanningContext node) : Prop where
  /-- The current materialized topology is already a DAG. -/
  sourceAcyclic : Acyclic context.topology
  /-- Current stage definitions exactly cover the materialized topology. -/
  definitionsCover : DefinitionCoverage context.topology context.definitions

/-- Source context validity turns anchor membership into anchor-definition membership. -/
theorem SourcePlanningContextValid.anchorHasDefinition
    {context : PlanningContext node}
    {anchor : node}
    (hSource : SourcePlanningContextValid context)
    (hAnchorInTopology : anchor ∈ (denote context.topology).vertices) :
    anchor ∈ context.definitions := by
  rw [hSource.definitionsCover]
  exact hAnchorInTopology

/-- Concrete construction derives final definition coverage from source and subgraph coverage. -/
theorem constructedPlannedRewriteDelta_finalDefinitionsCover
    {policy : RuntimeNamespacePolicy node}
    {context : PlanningContext node}
    {rawRewrite : GraphRewrite node}
    {insertedDepth : Nat}
    (hSource : SourcePlanningContextValid context)
    (hAnchorInTopology : rawRewrite.anchor ∈ (denote context.topology).vertices)
    (hRawSubgraphValid : rawRewrite.spec.Valid) :
    DefinitionCoverage
      (constructedPlannedRewriteDelta policy context rawRewrite insertedDepth).topology
      (constructedPlannedRewriteDelta policy context rawRewrite insertedDepth).definitions := by
  have hAnchorNoSelfLoop :
      (rawRewrite.anchor, rawRewrite.anchor) ∉ (denote context.topology).edges :=
    anchor_noSelfLoop_of_acyclic hSource.sourceAcyclic
  have hNamespacedValid : (runtimePlannerRewrite policy rawRewrite).spec.Valid := by
    simp only [runtimePlannerRewrite, namespaceGraphRewrite_spec]
    exact
      namespaceSubgraphSpec_preserves_valid
        (policy.namespaceNode_injective rawRewrite.anchor)
        hRawSubgraphValid
  unfold DefinitionCoverage
  simp only [constructedPlannedRewriteDelta]
  rw [denote_constructedFinalTopology]
  cases rawRewrite with
  | expandNode anchor mode spec =>
      cases mode with
      | replaceNode =>
          have hNamespacedDefinitions :
              DefinitionCoverage
                (namespaceSubgraphSpec (policy.namespaceNode anchor) spec).topology
                (namespaceSubgraphSpec (policy.namespaceNode anchor) spec).definitions := by
            simpa only [runtimePlannerRewrite, namespaceGraphRewrite, GraphRewrite.spec] using
              hNamespacedValid.definitionsCover
          have hNamespacedEntries :
              NodesInside
                (namespaceSubgraphSpec (policy.namespaceNode anchor) spec).entryNodes
                (namespaceSubgraphSpec (policy.namespaceNode anchor) spec).topology := by
            simpa only [runtimePlannerRewrite, namespaceGraphRewrite, GraphRewrite.spec] using
              hNamespacedValid.entryNodesInside
          have hNamespacedExits :
              NodesInside
                (namespaceSubgraphSpec (policy.namespaceNode anchor) spec).exitNodes
                (namespaceSubgraphSpec (policy.namespaceNode anchor) spec).topology := by
            simpa only [runtimePlannerRewrite, namespaceGraphRewrite, GraphRewrite.spec] using
              hNamespacedValid.exitNodesInside
          have hNoSelfLoop :
              (anchor, anchor) ∉ (denote context.topology).edges := by
            simpa only [GraphRewrite.anchor] using hAnchorNoSelfLoop
          simp only
            [ constructedFinalRelation
            , runtimePlannerRewrite
            , namespaceGraphRewrite
            , GraphRewrite.anchor
            , GraphRewrite.spec
            , GraphRewrite.anchorDisposition
            , plannedFinalDefinitions
            ]
          rw
            [ plannedFinalRelation_vertices_replace
                hNoSelfLoop
                hNamespacedEntries
                hNamespacedExits
            , hSource.definitionsCover
            , hNamespacedDefinitions
            ]
      | retainNodeAsEnvelope =>
          have hNamespacedDefinitions :
              DefinitionCoverage
                (namespaceSubgraphSpec (policy.namespaceNode anchor) spec).topology
                (namespaceSubgraphSpec (policy.namespaceNode anchor) spec).definitions := by
            simpa only [runtimePlannerRewrite, namespaceGraphRewrite, GraphRewrite.spec] using
              hNamespacedValid.definitionsCover
          have hNamespacedEntries :
              NodesInside
                (namespaceSubgraphSpec (policy.namespaceNode anchor) spec).entryNodes
                (namespaceSubgraphSpec (policy.namespaceNode anchor) spec).topology := by
            simpa only [runtimePlannerRewrite, namespaceGraphRewrite, GraphRewrite.spec] using
              hNamespacedValid.entryNodesInside
          have hNamespacedExits :
              NodesInside
                (namespaceSubgraphSpec (policy.namespaceNode anchor) spec).exitNodes
                (namespaceSubgraphSpec (policy.namespaceNode anchor) spec).topology := by
            simpa only [runtimePlannerRewrite, namespaceGraphRewrite, GraphRewrite.spec] using
              hNamespacedValid.exitNodesInside
          have hAnchorIn :
              anchor ∈ (denote context.topology).vertices := by
            simpa only [GraphRewrite.anchor] using hAnchorInTopology
          simp only
            [ constructedFinalRelation
            , runtimePlannerRewrite
            , namespaceGraphRewrite
            , GraphRewrite.anchor
            , GraphRewrite.spec
            , GraphRewrite.anchorDisposition
            , plannedFinalDefinitions
            ]
          rw
            [ plannedFinalRelation_vertices_retain
                hAnchorIn
                hNamespacedEntries
                hNamespacedExits
            , hSource.definitionsCover
            , hNamespacedDefinitions
            ]
  | appendAfter anchor spec =>
      have hNamespacedDefinitions :
          DefinitionCoverage
            (namespaceSubgraphSpec (policy.namespaceNode anchor) spec).topology
            (namespaceSubgraphSpec (policy.namespaceNode anchor) spec).definitions := by
        simpa only [runtimePlannerRewrite, namespaceGraphRewrite, GraphRewrite.spec] using
          hNamespacedValid.definitionsCover
      have hNamespacedEntries :
          NodesInside
            (namespaceSubgraphSpec (policy.namespaceNode anchor) spec).entryNodes
            (namespaceSubgraphSpec (policy.namespaceNode anchor) spec).topology := by
        simpa only [runtimePlannerRewrite, namespaceGraphRewrite, GraphRewrite.spec] using
          hNamespacedValid.entryNodesInside
      have hNamespacedExits :
          NodesInside
            (namespaceSubgraphSpec (policy.namespaceNode anchor) spec).exitNodes
            (namespaceSubgraphSpec (policy.namespaceNode anchor) spec).topology := by
        simpa only [runtimePlannerRewrite, namespaceGraphRewrite, GraphRewrite.spec] using
          hNamespacedValid.exitNodesInside
      have hAnchorIn :
          anchor ∈ (denote context.topology).vertices := by
        simpa only [GraphRewrite.anchor] using hAnchorInTopology
      simp only
        [ constructedFinalRelation
        , runtimePlannerRewrite
        , namespaceGraphRewrite
        , GraphRewrite.anchor
        , GraphRewrite.spec
        , GraphRewrite.anchorDisposition
        , plannedFinalDefinitions
        ]
      rw
        [ plannedFinalRelation_vertices_append
            hAnchorIn
            hNamespacedEntries
            hNamespacedExits
        , hSource.definitionsCover
        , hNamespacedDefinitions
        ]

/-- Runtime validation inputs not computed by the pure construction equations. -/
structure RuntimeConstructionValidation
    (policy : RuntimeNamespacePolicy node)
    (context : PlanningContext node)
    (rawRewrite : GraphRewrite node)
    (insertedDepth : Nat) :
    Prop where
  /-- The runtime namespace validator accepted local syntax and freshness. -/
  namespaceDiscipline :
    NamespaceDiscipline
      policy.localAllowed
      (policy.namespaceNode rawRewrite.anchor)
      context
      rawRewrite.spec
  /-- The raw anchor exists in the current topology. -/
  anchorInTopology : rawRewrite.anchor ∈ (denote context.topology).vertices
  /-- The raw anchor has a current definition. -/
  anchorHasDefinition : rawRewrite.anchor ∈ context.definitions
  /-- The current topology is already a DAG before planning starts. -/
  sourceAcyclic : Acyclic context.topology
  /-- The raw inserted subgraph passed runtime subgraph validation. -/
  rawSubgraphValid : rawRewrite.spec.Valid
  /-- Runtime longest-path computation agrees with the proof-side inserted-depth witness. -/
  insertedDepthMatches :
    LongestInsertedPathNodeCount
      (runtimePlannerRewrite policy rawRewrite).spec
      insertedDepth
  /-- The final definition domain exactly covers final topology vertices. -/
  finalDefinitionsCover :
    DefinitionCoverage
      (constructedPlannedRewriteDelta policy context rawRewrite insertedDepth).topology
      (constructedPlannedRewriteDelta policy context rawRewrite insertedDepth).definitions
  /-- The runtime validated the final topology as acyclic. -/
  finalAcyclic :
    Acyclic (constructedPlannedRewriteDelta policy context rawRewrite insertedDepth).topology

/-- Runtime-shaped inputs from which construction validation is derived.

The remaining explicit fields correspond to executable checks: namespace
validation, source anchor membership, raw subgraph validation, longest-path
cost computation, and final DAG validation. Source definition coverage derives
anchor definition membership and final definition coverage. -/
structure RuntimeConstructionInputs
    (policy : RuntimeNamespacePolicy node)
    (context : PlanningContext node)
    (rawRewrite : GraphRewrite node)
    (insertedDepth : Nat) :
    Prop where
  /-- The current materialized topology and definition domain are valid. -/
  sourceValid : SourcePlanningContextValid context
  /-- The runtime namespace validator accepted local syntax and freshness. -/
  namespaceDiscipline :
    NamespaceDiscipline
      policy.localAllowed
      (policy.namespaceNode rawRewrite.anchor)
      context
      rawRewrite.spec
  /-- The raw anchor exists in the current topology. -/
  anchorInTopology : rawRewrite.anchor ∈ (denote context.topology).vertices
  /-- The raw inserted subgraph passed runtime subgraph validation. -/
  rawSubgraphValid : rawRewrite.spec.Valid
  /-- Runtime longest-path computation agrees with the proof-side inserted-depth witness. -/
  insertedDepthMatches :
    LongestInsertedPathNodeCount
      (runtimePlannerRewrite policy rawRewrite).spec
      insertedDepth
  /-- The runtime validated the final topology as acyclic. -/
  finalAcyclic :
    Acyclic (constructedPlannedRewriteDelta policy context rawRewrite insertedDepth).topology

/-- Runtime-shaped inputs derive the older construction-validation bundle. -/
theorem RuntimeConstructionInputs.toValidation
    {policy : RuntimeNamespacePolicy node}
    {context : PlanningContext node}
    {rawRewrite : GraphRewrite node}
    {insertedDepth : Nat}
    (hInputs : RuntimeConstructionInputs policy context rawRewrite insertedDepth) :
    RuntimeConstructionValidation policy context rawRewrite insertedDepth :=
  { namespaceDiscipline := hInputs.namespaceDiscipline
    anchorInTopology := hInputs.anchorInTopology
    anchorHasDefinition :=
      hInputs.sourceValid.anchorHasDefinition hInputs.anchorInTopology
    sourceAcyclic := hInputs.sourceValid.sourceAcyclic
    rawSubgraphValid := hInputs.rawSubgraphValid
    insertedDepthMatches := hInputs.insertedDepthMatches
    finalDefinitionsCover :=
      constructedPlannedRewriteDelta_finalDefinitionsCover
        hInputs.sourceValid
        hInputs.anchorInTopology
        hInputs.rawSubgraphValid
    finalAcyclic := hInputs.finalAcyclic }

/-- Runtime-shaped inputs carry the source-valid invariant to the next planner context. -/
theorem RuntimeConstructionInputs.toNextSourceValid
    {policy : RuntimeNamespacePolicy node}
    {context : PlanningContext node}
    {rawRewrite : GraphRewrite node}
    {insertedDepth : Nat}
    (hInputs : RuntimeConstructionInputs policy context rawRewrite insertedDepth) :
    SourcePlanningContextValid
      { topology :=
          (constructedPlannedRewriteDelta policy context rawRewrite insertedDepth).topology
        definitions :=
          (constructedPlannedRewriteDelta policy context rawRewrite insertedDepth).definitions } :=
  { sourceAcyclic := hInputs.finalAcyclic
    definitionsCover :=
      constructedPlannedRewriteDelta_finalDefinitionsCover
        (insertedDepth := insertedDepth)
        hInputs.sourceValid
        hInputs.anchorInTopology
        hInputs.rawSubgraphValid }

/-- The concrete construction equations establish `RuntimePlannerConstruction`. -/
theorem constructedPlannedRewriteDelta_runtimePlannerConstruction
    {policy : RuntimeNamespacePolicy node}
    {context : PlanningContext node}
    {rawRewrite : GraphRewrite node}
    {insertedDepth : Nat}
    (hValidation :
      RuntimeConstructionValidation policy context rawRewrite insertedDepth) :
    RuntimePlannerConstruction
      policy
      context
      rawRewrite
      (constructedPlannedRewriteDelta policy context rawRewrite insertedDepth) := by
  refine
    { namespaceDiscipline := hValidation.namespaceDiscipline
      anchorInTopology := hValidation.anchorInTopology
      anchorHasDefinition := hValidation.anchorHasDefinition
      rawSubgraphValid := hValidation.rawSubgraphValid
      anchorMatches :=
        constructedPlannedRewriteDelta_anchorMatches
          hValidation.namespaceDiscipline
          hValidation.anchorInTopology
          hValidation.sourceAcyclic
          hValidation.rawSubgraphValid
      deltaMatches := ?_
      costMatches := ?_
      finalDefinitionsCover := hValidation.finalDefinitionsCover
      finalAcyclic := hValidation.finalAcyclic }
  · refine
      { topology_eq := ?_
        entryNodes_eq := ?_
        exitNodes_eq := ?_
        newNodes_eq := ?_
        removedNodes_eq := ?_
        addedEdges_eq := ?_
        definitions_eq := ?_ }
    · exact denote_constructedFinalTopology policy context rawRewrite
    · simp only [constructedPlannedRewriteDelta]
    · simp only [constructedPlannedRewriteDelta]
    · simp only
        [ constructedPlannedRewriteDelta
        , constructedFinalRelation
        , denote_constructedFinalTopology
        ]
    · simp only
        [ constructedPlannedRewriteDelta
        , constructedFinalRelation
        , denote_constructedFinalTopology
        ]
    · simp only
        [ constructedPlannedRewriteDelta
        , constructedFinalRelation
        , denote_constructedFinalTopology
        ]
    · simp only [constructedPlannedRewriteDelta]
  · refine
      { addedNodes_eq := ?_
        addedEdges_eq := ?_
        addedDepth_eq := ?_
        entryNodes_runtimeList := ?_
        rewriteOps_eq := ?_ }
    · simp only [constructedPlannedRewriteDelta]
    · simp only [constructedPlannedRewriteDelta]
    · refine ⟨insertedDepth, hValidation.insertedDepthMatches, ?_⟩
      rfl
    · let entryNodes :=
        (constructedPlannedRewriteDelta policy context rawRewrite insertedDepth).entryNodes
      refine ⟨entryNodes.toList, ?_, ?_⟩
      · exact
          ⟨ Finset.nodup_toList _
          , Finset.toList_toFinset _
          ⟩
      · have hEntryCard :
            entryNodes.card = entryNodes.toList.length :=
          RuntimeNodeListMatches.card_eq_length
            ⟨Finset.nodup_toList _, Finset.toList_toFinset _⟩
        change entryNodes.card - 1 = entryNodes.toList.length - 1
        rw [hEntryCard]
    · simp only [constructedPlannedRewriteDelta]

/-- Concrete construction plus budget admission gives an abstract admissible rewrite. -/
theorem constructedPlannedRewriteDelta_admissible
    {policy : RuntimeNamespacePolicy node}
    {context : PlanningContext node}
    {rawRewrite : GraphRewrite node}
    {insertedDepth : Nat}
    {budget remaining : RewriteBudget}
    {contractOk : Graph node → Prop}
    (hValidation :
      RuntimeConstructionValidation policy context rawRewrite insertedDepth)
    (hAdmitted :
      AdmittedRewriteDelta
        budget
        (constructedPlannedRewriteDelta policy context rawRewrite insertedDepth)
        remaining)
    (hContracts :
      ∀ g,
        denote g = denote context.topology →
          contractOk g →
            contractOk
              (constructedPlannedRewriteDelta
                policy
                context
                rawRewrite
                insertedDepth).topology) :
    admissible
      ((constructedPlannedRewriteDelta policy context rawRewrite insertedDepth).toRewrite
        context.topology
        (plannedRewriteSafety_of_checks
          (runtimePlannerConstruction_planGraphRewriteChecks
            (constructedPlannedRewriteDelta_runtimePlannerConstruction hValidation))
          hContracts))
      context.topology
      budget :=
  runtimePlannerConstruction_admissible
    (constructedPlannedRewriteDelta_runtimePlannerConstruction hValidation)
    hAdmitted
    hContracts

/-- Runtime-shaped construction inputs plus budget admission give an admissible rewrite. -/
theorem constructedPlannedRewriteDelta_admissible_of_inputs
    {policy : RuntimeNamespacePolicy node}
    {context : PlanningContext node}
    {rawRewrite : GraphRewrite node}
    {insertedDepth : Nat}
    {budget remaining : RewriteBudget}
    {contractOk : Graph node → Prop}
    (hInputs :
      RuntimeConstructionInputs policy context rawRewrite insertedDepth)
    (hAdmitted :
      AdmittedRewriteDelta
        budget
        (constructedPlannedRewriteDelta policy context rawRewrite insertedDepth)
        remaining)
    (hContracts :
      ∀ g,
        denote g = denote context.topology →
          contractOk g →
            contractOk
              (constructedPlannedRewriteDelta
                policy
                context
                rawRewrite
                insertedDepth).topology) :
    admissible
      ((constructedPlannedRewriteDelta policy context rawRewrite insertedDepth).toRewrite
        context.topology
        (plannedRewriteSafety_of_checks
          (runtimePlannerConstruction_planGraphRewriteChecks
            (constructedPlannedRewriteDelta_runtimePlannerConstruction
              hInputs.toValidation))
          hContracts))
      context.topology
      budget :=
  constructedPlannedRewriteDelta_admissible
    hInputs.toValidation
    hAdmitted
    hContracts

end ConstructedDelta

end Cortex.Wire
