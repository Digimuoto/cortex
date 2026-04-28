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

end ConstructedDelta

end Cortex.Wire
