import Cortex.Wire.Admission
import Mathlib.Data.Finset.Card

/-!
## Overview

Executable-planner correspondence support for Wire rewrites.

## Context

`Cortex.Wire.Admission` states the runtime planning contract once a
rewrite's inserted subgraph already lives in the final node namespace. The
Haskell runtime obtains that shape by applying `namespaceSubgraph` before it
constructs the final topology. This module names that proof-side boundary:
subgraph namespacing, the namespace-discipline obligation, relation-level
correspondence for the AST mapping, and the theorem that turns proof-shaped
executable planner equations into `PlanGraphRewriteChecks`.

## Theorem Split

The page defines graph/subgraph/rewrite namespacing, proves the denotation
of namespaced graph expressions, and then packages runtime construction
equations into the admission contract used by
`planGraphRewriteChecks_admissible`.
-/

namespace Cortex.Wire

open Cortex.Graph

/-! ## Namespaced Rewrite Inputs -/

section Namespacing

variable {node : Type}
variable [DecidableEq node]

/-- `RuntimeNamespacePolicy` is the proof-side model of executable namespace syntax.

For the Haskell `NodeId` planner, `namespaceNode anchor local` is
`namespaceNodeId anchor local`, while `localAllowed local` records the
reserved-delimiter check performed before namespacing. The policy carries
syntax-level facts that are independent of the current topology; freshness
against a particular graph remains a `NamespaceDiscipline` obligation. -/
structure RuntimeNamespacePolicy (node : Type) where
  /-- Namespace a local inserted node under the rewrite anchor. -/
  namespaceNode : node → node → node
  /-- The runtime syntax predicate accepted for local inserted node ids. -/
  localAllowed : node → Prop
  /-- For a fixed anchor, namespacing does not collapse distinct local node ids. -/
  namespaceNode_injective : ∀ anchor, Function.Injective (namespaceNode anchor)

/-- `mapGraph f g` maps a graph expression over its vertex labels. -/
def mapGraph (f : node → node) : Graph node → Graph node
  | Graph.empty => Graph.empty
  | Graph.vertex vertex => Graph.vertex (f vertex)
  | Graph.overlay left right => Graph.overlay (mapGraph f left) (mapGraph f right)
  | Graph.connect left right => Graph.connect (mapGraph f left) (mapGraph f right)

/-- `mapRelation f relation` is the relation-level counterpart of `mapGraph f`. -/
def mapRelation (f : node → node) (relation : Relation node) : Relation node :=
  { vertices := relation.vertices.image f
    edges := relation.edges.image (fun edge => (f edge.1, f edge.2)) }

/-- Relation mapping distributes over relation overlay. -/
theorem mapRelation_overlay
    (f : node → node)
    (left right : Relation node) :
    mapRelation f (Relation.overlay left right) =
      Relation.overlay (mapRelation f left) (mapRelation f right) := by
  apply Relation.ext
  · exact Finset.image_union left.vertices right.vertices
  · exact Finset.image_union left.edges right.edges

/-- Relation mapping distributes over relation connect. -/
theorem mapRelation_connect
    (f : node → node)
    (left right : Relation node) :
    mapRelation f (Relation.connect left right) =
      Relation.connect (mapRelation f left) (mapRelation f right) := by
  apply Relation.ext
  · exact Finset.image_union left.vertices right.vertices
  · simp only [mapRelation, Relation.connect, Relation.cross]
    rw [Finset.image_union, Finset.image_union]
    change
      left.edges.image (Prod.map f f) ∪
          right.edges.image (Prod.map f f) ∪
            (left.vertices ×ˢ right.vertices).image (Prod.map f f) =
        left.edges.image (Prod.map f f) ∪
          right.edges.image (Prod.map f f) ∪
            (left.vertices.image f ×ˢ right.vertices.image f)
    rw [Finset.prodMap_image_product]

/-- Mapping a graph expression and then denoting it equals mapping its denotation. -/
theorem denote_mapGraph (f : node → node) (g : Graph node) :
    denote (mapGraph f g) = mapRelation f (denote g) := by
  induction g with
  | empty =>
      ext x
      · simp only
          [ mapGraph
          , mapRelation
          , denote_empty
          , Relation.empty
          , Finset.mem_image
          , Finset.notMem_empty
          , false_and
          , exists_false
          ]
      · simp only
          [ mapGraph
          , mapRelation
          , denote_empty
          , Relation.empty
          , Finset.mem_image
          , Finset.notMem_empty
          , false_and
          , exists_false
          ]
  | vertex vertex =>
      ext x
      · simp only
          [ mapGraph
          , mapRelation
          , denote_vertex
          , Relation.vertex
          , Finset.mem_image
          , Finset.mem_singleton
          ]
        constructor
        · intro hMapped
          exact ⟨vertex, rfl, hMapped.symm⟩
        · rintro ⟨_local, rfl, hMapped⟩
          exact hMapped.symm
      · simp only
          [ mapGraph
          , mapRelation
          , denote_vertex
          , Relation.vertex
          , Finset.mem_image
          , Finset.notMem_empty
          , false_and
          , exists_false
          ]
  | overlay left right left_ih right_ih =>
      calc
        denote (mapGraph f (Graph.overlay left right)) =
            Relation.overlay (denote (mapGraph f left)) (denote (mapGraph f right)) := rfl
        _ =
            Relation.overlay (mapRelation f (denote left)) (mapRelation f (denote right)) := by
              rw [left_ih, right_ih]
        _ = mapRelation f (denote (Graph.overlay left right)) := by
              rw [denote_overlay, mapRelation_overlay]
  | connect left right left_ih right_ih =>
      calc
        denote (mapGraph f (Graph.connect left right)) =
            Relation.connect (denote (mapGraph f left)) (denote (mapGraph f right)) := rfl
        _ =
            Relation.connect (mapRelation f (denote left)) (mapRelation f (denote right)) := by
              rw [left_ih, right_ih]
        _ = mapRelation f (denote (Graph.connect left right)) := by
              rw [denote_connect, mapRelation_connect]

/-- `NamespaceDiscipline` records the proof-side safety of runtime node namespacing.

The `localAllowed` predicate is the generic Lean hook for executable syntax
rules such as the Haskell `NodeId` restriction that local inserted ids must not
contain the reserved namespace delimiter. Injectivity comes from the
`RuntimeNamespacePolicy`; this discipline records the topology-specific checks. -/
structure NamespaceDiscipline
    (isLocalAllowed : node → Prop)
    (ns : node → node)
    (context : PlanningContext node)
    (spec : SubgraphSpec node) :
    Prop where
  /-- Local inserted node ids are accepted by the runtime namespace syntax. -/
  localAllowed :
    ∀ localNode,
      localNode ∈ (denote spec.topology).vertices →
        isLocalAllowed localNode
  /-- Namespaced inserted nodes are fresh against the current topology. -/
  fresh :
    ∀ localNode,
      localNode ∈ (denote spec.topology).vertices →
        ns localNode ∉ (denote context.topology).vertices

/-- `namespaceSubgraphSpec ns spec` maps an inserted subgraph into final node IDs. -/
def namespaceSubgraphSpec
    (ns : node → node)
    (spec : SubgraphSpec node) :
    SubgraphSpec node :=
  { topology := mapGraph ns spec.topology
    definitions := spec.definitions.image ns
    entryNodes := spec.entryNodes.image ns
    exitNodes := spec.exitNodes.image ns }

/-- Namespaced inserted topology vertices remain fresh against the context topology. -/
theorem namespaceSubgraphSpec_fresh_against_context
    {isLocalAllowed : node → Prop}
    {ns : node → node}
    {context : PlanningContext node}
    {spec : SubgraphSpec node}
    (hDiscipline : NamespaceDiscipline isLocalAllowed ns context spec) :
    ∀ mappedNode,
      mappedNode ∈ (denote (namespaceSubgraphSpec ns spec).topology).vertices →
        mappedNode ∉ (denote context.topology).vertices := by
  intro mappedNode hNode
  simp only [namespaceSubgraphSpec, denote_mapGraph, mapRelation, Finset.mem_image] at hNode
  rcases hNode with ⟨localNode, hLocalNode, rfl⟩
  exact hDiscipline.fresh localNode hLocalNode

/-- Namespace discipline exposes the executable local-node syntax predicate. -/
theorem namespaceSubgraphSpec_local_allowed
    {isLocalAllowed : node → Prop}
    {ns : node → node}
    {context : PlanningContext node}
    {spec : SubgraphSpec node}
    (hDiscipline : NamespaceDiscipline isLocalAllowed ns context spec) :
    ∀ localNode,
      localNode ∈ (denote spec.topology).vertices →
        isLocalAllowed localNode :=
  hDiscipline.localAllowed

/-- Namespaced graph paths are images of source graph paths. -/
theorem graphPath_mapGraph_of_graphPath
    (f : node → node)
    {g : Graph node}
    {source target : node}
    (hPath : GraphPath g source target) :
    GraphPath (mapGraph f g) (f source) (f target) := by
  induction hPath with
  | direct hEdge =>
      apply GraphPath.direct
      simp only [denote_mapGraph, mapRelation, Finset.mem_image]
      exact ⟨_, hEdge, rfl⟩
  | trans leftPath rightPath left_ih right_ih =>
      exact GraphPath.trans left_ih right_ih

/-- Every mapped graph path has a source-level preimage when the mapping is injective. -/
theorem graphPath_mapGraph_preimage
    {f : node → node}
    {g : Graph node}
    (hInjective : Function.Injective f)
    {mappedSource mappedTarget : node}
    (hPath : GraphPath (mapGraph f g) mappedSource mappedTarget) :
    ∃ source target,
      mappedSource = f source ∧
        mappedTarget = f target ∧
          GraphPath g source target := by
  induction hPath with
  | direct hEdge =>
      simp only [denote_mapGraph, mapRelation, Finset.mem_image] at hEdge
      rcases hEdge with ⟨edge, hEdge, hMapped⟩
      rcases edge with ⟨source, target⟩
      cases hMapped
      exact ⟨source, target, rfl, rfl, GraphPath.direct hEdge⟩
  | trans leftPath rightPath left_ih right_ih =>
      rcases left_ih with ⟨source, middleLeft, hSource, hMiddleLeft, hLeftPath⟩
      rcases right_ih with ⟨middleRight, target, hMiddleRight, hTarget, hRightPath⟩
      have hMiddle : middleLeft = middleRight := by
        exact hInjective (hMiddleLeft.symm.trans hMiddleRight)
      refine ⟨source, target, hSource, hTarget, ?_⟩
      rw [← hMiddle] at hRightPath
      exact GraphPath.trans hLeftPath hRightPath

/-- Injective graph mapping preserves acyclicity. -/
theorem mapGraph_preserves_acyclic
    {f : node → node}
    {g : Graph node}
    (hInjective : Function.Injective f)
    (hAcyclic : Acyclic g) :
    Acyclic (mapGraph f g) := by
  intro mappedNode hCycle
  rcases graphPath_mapGraph_preimage hInjective hCycle with
    ⟨source, target, hSource, hTarget, hPath⟩
  have hSame : source = target := hInjective (hSource.symm.trans hTarget)
  rw [hSame] at hPath
  exact hAcyclic target hPath

/-- Reachability is preserved by graph mapping. -/
theorem reachableOrSame_mapGraph_of_reachableOrSame
    (f : node → node)
    {g : Graph node}
    {source target : node}
    (hReachable : ReachableOrSame g source target) :
    ReachableOrSame (mapGraph f g) (f source) (f target) := by
  rcases hReachable with hSame | hPath
  · left
    rw [hSame]
  · right
    exact graphPath_mapGraph_of_graphPath f hPath

/-- Namespacing preserves definition-domain coverage for inserted subgraphs. -/
theorem namespaceSubgraphSpec_preserves_definitionCoverage
    (ns : node → node)
    {spec : SubgraphSpec node}
    (hCoverage : DefinitionCoverage spec.topology spec.definitions) :
    DefinitionCoverage
      (namespaceSubgraphSpec ns spec).topology
      (namespaceSubgraphSpec ns spec).definitions := by
  unfold DefinitionCoverage at hCoverage ⊢
  simp only [namespaceSubgraphSpec, denote_mapGraph, mapRelation, hCoverage]

/-- Namespacing preserves node-inside-topology facts for inserted node sets. -/
theorem namespaceSubgraphSpec_preserves_nodesInside
    (ns : node → node)
    {spec : SubgraphSpec node}
    {nodes : Finset node}
    (hInside : NodesInside nodes spec.topology) :
    NodesInside (nodes.image ns) (namespaceSubgraphSpec ns spec).topology := by
  intro mappedNode hMappedNode
  simp only
    [namespaceSubgraphSpec, denote_mapGraph, mapRelation, Finset.mem_image] at hMappedNode ⊢
  rcases hMappedNode with ⟨localNode, hLocalNode, rfl⟩
  exact ⟨localNode, hInside localNode hLocalNode, rfl⟩

/-- Namespacing preserves orphan-freedom for inserted subgraphs. -/
theorem namespaceSubgraphSpec_preserves_orphanFree
    (ns : node → node)
    {spec : SubgraphSpec node}
    (hOrphanFree : OrphanFree spec) :
    OrphanFree (namespaceSubgraphSpec ns spec) := by
  intro mappedNode hMappedNode
  simp only
    [namespaceSubgraphSpec, denote_mapGraph, mapRelation, Finset.mem_image] at hMappedNode
  rcases hMappedNode with ⟨localNode, hLocalNode, rfl⟩
  rcases hOrphanFree localNode hLocalNode with
    ⟨⟨entry, hEntry, hEntryReachable⟩, ⟨exit, hExit, hExitReachable⟩⟩
  constructor
  · refine ⟨ns entry, ?_, ?_⟩
    · exact Finset.mem_image.mpr ⟨entry, hEntry, rfl⟩
    · exact reachableOrSame_mapGraph_of_reachableOrSame ns hEntryReachable
  · refine ⟨ns exit, ?_, ?_⟩
    · exact Finset.mem_image.mpr ⟨exit, hExit, rfl⟩
    · exact reachableOrSame_mapGraph_of_reachableOrSame ns hExitReachable

/-- Namespacing preserves the runtime inserted-subgraph validity bundle. -/
theorem namespaceSubgraphSpec_preserves_valid
    {ns : node → node}
    {spec : SubgraphSpec node}
    (hInjective : Function.Injective ns)
    (hValid : spec.Valid) :
    (namespaceSubgraphSpec ns spec).Valid :=
  { acyclic := mapGraph_preserves_acyclic hInjective hValid.acyclic
    definitionsCover :=
      namespaceSubgraphSpec_preserves_definitionCoverage ns hValid.definitionsCover
    entryNodesNonempty := Finset.Nonempty.image hValid.entryNodesNonempty ns
    exitNodesNonempty := Finset.Nonempty.image hValid.exitNodesNonempty ns
    entryNodesInside :=
      namespaceSubgraphSpec_preserves_nodesInside ns hValid.entryNodesInside
    exitNodesInside :=
      namespaceSubgraphSpec_preserves_nodesInside ns hValid.exitNodesInside
    orphanFree := namespaceSubgraphSpec_preserves_orphanFree ns hValid.orphanFree }

/-- `namespaceGraphRewrite ns rewrite` maps only the inserted subgraph.

The rewrite anchor already lives in the current topology namespace, matching
the executable Haskell planner. -/
def namespaceGraphRewrite
    (ns : node → node)
    (rewrite : GraphRewrite node) :
    GraphRewrite node :=
  match rewrite with
  | GraphRewrite.expandNode anchor mode spec =>
      GraphRewrite.expandNode anchor mode (namespaceSubgraphSpec ns spec)
  | GraphRewrite.appendAfter anchor spec =>
      GraphRewrite.appendAfter anchor (namespaceSubgraphSpec ns spec)

/-- Namespacing does not change the rewrite anchor. -/
theorem namespaceGraphRewrite_anchor
    (ns : node → node)
    (rewrite : GraphRewrite node) :
    (namespaceGraphRewrite ns rewrite).anchor = rewrite.anchor := by
  cases rewrite <;> rfl

/-- Namespacing does not change whether the anchor is removed or retained. -/
theorem namespaceGraphRewrite_anchorDisposition
    (ns : node → node)
    (rewrite : GraphRewrite node) :
    (namespaceGraphRewrite ns rewrite).anchorDisposition = rewrite.anchorDisposition := by
  cases rewrite with
  | expandNode _ mode _ =>
      cases mode <;> rfl
  | appendAfter _ _ =>
      rfl

/-- Namespacing maps the inserted rewrite spec and leaves the rewrite form unchanged. -/
theorem namespaceGraphRewrite_spec
    (ns : node → node)
    (rewrite : GraphRewrite node) :
    (namespaceGraphRewrite ns rewrite).spec =
      namespaceSubgraphSpec ns rewrite.spec := by
  cases rewrite <;> rfl

/-- `runtimePlannerRewrite policy rewrite` is the rewrite after runtime namespacing. -/
def runtimePlannerRewrite
    (policy : RuntimeNamespacePolicy node)
    (rewrite : GraphRewrite node) :
    GraphRewrite node :=
  namespaceGraphRewrite (policy.namespaceNode rewrite.anchor) rewrite

end Namespacing

/-! ## Runtime List Boundaries -/

section RuntimeLists

variable {node : Type}
variable [DecidableEq node]

/-- A runtime list and proof-side `Finset` describe the same node boundary.

The Haskell planner computes frontier-delta cost from duplicate-free entry
lists. Lean uses `Finset` boundaries, so this predicate records the
duplicate-free list bridge explicitly. -/
def RuntimeNodeListMatches (values : List node) (nodes : Finset node) : Prop :=
  values.Nodup ∧ values.toFinset = nodes

/-- Duplicate-free runtime lists have the same length as their proof-side node set cardinality. -/
theorem RuntimeNodeListMatches.card_eq_length
    {values : List node}
    {nodes : Finset node}
    (hMatches : RuntimeNodeListMatches values nodes) :
    nodes.card = values.length := by
  rcases hMatches with ⟨hNodup, hToFinset⟩
  rw [← hToFinset]
  exact List.toFinset_card_of_nodup hNodup

end RuntimeLists

/-! ## Planner Construction Bridge -/

section PlannerBridge

variable {node : Type}
variable [DecidableEq node]

/-- Runtime anchor fields agree with the namespaced rewrite and final topology.

The absence/presence fields are explicit construction obligations: this module
does not derive them from the topology equation. The executable planner is
responsible for producing a final topology whose anchor membership agrees with
the rewrite disposition. -/
structure RuntimeAnchorMatches
    (policy : RuntimeNamespacePolicy node)
    (rawRewrite : GraphRewrite node)
    (delta : PlannedRewriteDelta node) :
    Prop where
  /-- The delta records the raw rewrite anchor. -/
  anchorNode_eq : delta.anchorNode = rawRewrite.anchor
  /-- The delta records the rewrite-form anchor disposition. -/
  anchorDisposition_eq :
    delta.anchorDisposition = (runtimePlannerRewrite policy rawRewrite).anchorDisposition
  /-- Runtime construction obligation: removed anchors are absent from the final topology. -/
  removed_absent :
    delta.anchorDisposition = RewriteAnchorDisposition.removed →
      (runtimePlannerRewrite policy rawRewrite).anchor ∉ (denote delta.topology).vertices
  /-- Runtime construction obligation: retained anchors remain in the final topology. -/
  retained_present :
    delta.anchorDisposition = RewriteAnchorDisposition.retained →
      (runtimePlannerRewrite policy rawRewrite).anchor ∈ (denote delta.topology).vertices

/-- Runtime topology and definition fields agree with the relation-level planner model. -/
structure RuntimeDeltaMatches
    (policy : RuntimeNamespacePolicy node)
    (context : PlanningContext node)
    (rawRewrite : GraphRewrite node)
    (delta : PlannedRewriteDelta node) :
    Prop where
  /-- The planned final topology follows the relation-level planner construction. -/
  topology_eq :
    denote delta.topology =
      plannedFinalRelation context.topology (runtimePlannerRewrite policy rawRewrite)
  /-- Delta entry nodes are the namespaced inserted entry nodes. -/
  entryNodes_eq : delta.entryNodes = (runtimePlannerRewrite policy rawRewrite).spec.entryNodes
  /-- Delta exit nodes are the namespaced inserted exit nodes. -/
  exitNodes_eq : delta.exitNodes = (runtimePlannerRewrite policy rawRewrite).spec.exitNodes
  /-- Delta new nodes are computed from the relation diff. -/
  newNodes_eq :
    delta.newNodes =
      relationAddedNodes (denote context.topology) (denote delta.topology)
  /-- Delta removed nodes are computed from the relation diff. -/
  removedNodes_eq :
    delta.removedNodes =
      relationRemovedNodes (denote context.topology) (denote delta.topology)
  /-- Delta added edges are computed from the relation diff. -/
  addedEdges_eq :
    delta.addedEdges =
      relationAddedEdges (denote context.topology) (denote delta.topology)
  /-- Final definitions follow the runtime delete-or-retain formula. -/
  definitions_eq :
    delta.definitions = plannedFinalDefinitions context (runtimePlannerRewrite policy rawRewrite)

/-- Runtime structural cost fields agree with computed rewrite-delta data. -/
structure RuntimeCostMatches
    (policy : RuntimeNamespacePolicy node)
    (rawRewrite : GraphRewrite node)
    (delta : PlannedRewriteDelta node) :
    Prop where
  /-- Added-node cost equals the computed new-node count. -/
  addedNodes_eq : delta.cost.addedNodes = delta.newNodes.card
  /-- Added-edge cost equals the computed added-edge count. -/
  addedEdges_eq : delta.cost.addedEdges = delta.addedEdges.card
  /-- Added-depth cost follows the inserted longest-path computation. -/
  addedDepth_eq :
    ∃ insertedDepth,
      LongestInsertedPathNodeCount (runtimePlannerRewrite policy rawRewrite).spec insertedDepth ∧
        delta.cost.addedDepth =
          match delta.anchorDisposition with
          | RewriteAnchorDisposition.removed => insertedDepth - 1
          | RewriteAnchorDisposition.retained => insertedDepth
  /-- Entry nodes match the duplicate-free runtime list used for frontier-delta cost. -/
  entryNodes_runtimeList :
    ∃ entryList,
      RuntimeNodeListMatches entryList delta.entryNodes ∧
        delta.cost.frontierDelta = entryList.length - 1
  /-- Each accepted graph rewrite consumes one rewrite-operation unit. -/
  rewriteOps_eq : delta.cost.rewriteOps = 1

/-- `RuntimePlannerConstruction` is the proof-shaped output of executable planning.

It starts from the raw rewrite accepted by the runtime, records the
namespacing discipline that turns the raw inserted subgraph into the final
node namespace, and carries constructor equations for the planned delta. The
bridge below derives `PlanGraphRewriteChecks`; those checks are not restated
as fields here. -/
structure RuntimePlannerConstruction
    (policy : RuntimeNamespacePolicy node)
    (context : PlanningContext node)
    (rawRewrite : GraphRewrite node)
    (delta : PlannedRewriteDelta node) :
    Prop where
  /-- The runtime namespace validator accepted the raw inserted subgraph. -/
  namespaceDiscipline :
    NamespaceDiscipline
      policy.localAllowed
      (policy.namespaceNode rawRewrite.anchor)
      context
      rawRewrite.spec
  /-- The raw anchor exists in the current topology. -/
  anchorInTopology : rawRewrite.anchor ∈ (denote context.topology).vertices
  /-- The raw anchor has a current stage definition. -/
  anchorHasDefinition : rawRewrite.anchor ∈ context.definitions
  /-- The raw inserted subgraph passed runtime subgraph validation. -/
  rawSubgraphValid : rawRewrite.spec.Valid
  /-- Anchor identity and disposition agree with the namespaced rewrite. -/
  anchorMatches : RuntimeAnchorMatches policy rawRewrite delta
  /-- Delta topology and definitions agree with the relation-level planner model. -/
  deltaMatches : RuntimeDeltaMatches policy context rawRewrite delta
  /-- Structural cost agrees with computed delta data and runtime boundary lists. -/
  costMatches : RuntimeCostMatches policy rawRewrite delta
  /-- Final definitions exactly cover final topology vertices. -/
  finalDefinitionsCover : DefinitionCoverage delta.topology delta.definitions
  /-- Final topology passed runtime DAG validation. -/
  finalAcyclic : Acyclic delta.topology

/-- Existing vertices remain after adding edges to a relation. -/
theorem relationVertices_subset_addEdgesToRelation
    (relation : Relation node)
    (edges : Finset (node × node)) :
    relation.vertices ⊆ (addEdgesToRelation relation edges).vertices := by
  intro vertex hVertex
  simp only [addEdgesToRelation, Finset.mem_union]
  exact Or.inl (Or.inl hVertex)

/-- Existing edges remain after adding edges to a relation. -/
theorem relationEdges_subset_addEdgesToRelation
    (relation : Relation node)
    (edges : Finset (node × node)) :
    relation.edges ⊆ (addEdgesToRelation relation edges).edges := by
  intro edge hEdge
  simp only [addEdgesToRelation, Finset.mem_union]
  exact Or.inl hEdge

/-- Right-overlay vertices are present in the overlay. -/
theorem relationVertices_right_subset_overlay
    (left right : Relation node) :
    right.vertices ⊆ (Relation.overlay left right).vertices := by
  intro vertex hVertex
  simp only [Relation.overlay, Finset.mem_union]
  exact Or.inr hVertex

/-- Right-overlay edges are present in the overlay. -/
theorem relationEdges_right_subset_overlay
    (left right : Relation node) :
    right.edges ⊆ (Relation.overlay left right).edges := by
  intro edge hEdge
  simp only [Relation.overlay, Finset.mem_union]
  exact Or.inr hEdge

/-- Inserted-subgraph vertices are present in the relation-level planned final topology. -/
theorem insertedVertices_subset_plannedFinalRelation
    (context : Graph node)
    (rewrite : GraphRewrite node) :
    (denote rewrite.spec.topology).vertices ⊆
      (plannedFinalRelation context rewrite).vertices := by
  intro vertex hVertex
  simp only [plannedFinalRelation]
  exact
    relationVertices_subset_addEdgesToRelation _ _
      (relationVertices_subset_addEdgesToRelation _ _
        (relationVertices_right_subset_overlay _ _ hVertex))

/-- Inserted-subgraph edges are present in the relation-level planned final topology. -/
theorem insertedEdges_subset_plannedFinalRelation
    (context : Graph node)
    (rewrite : GraphRewrite node) :
    (denote rewrite.spec.topology).edges ⊆
      (plannedFinalRelation context rewrite).edges := by
  intro edge hEdge
  simp only [plannedFinalRelation]
  exact
    relationEdges_subset_addEdgesToRelation _ _
      (relationEdges_subset_addEdgesToRelation _ _
        (relationEdges_right_subset_overlay _ _ hEdge))

/-- A topology construction equation proves the inserted subgraph is present in the final graph. -/
theorem subgraphContainedInFinal_of_topology_eq
    {context : PlanningContext node}
    {rewrite : GraphRewrite node}
    {delta : PlannedRewriteDelta node}
    (hTopology : denote delta.topology = plannedFinalRelation context.topology rewrite) :
    SubgraphContainedInFinal rewrite delta := by
  constructor
  · intro vertex hVertex
    rw [hTopology]
    exact insertedVertices_subset_plannedFinalRelation context.topology rewrite hVertex
  · intro edge hEdge
    rw [hTopology]
    exact insertedEdges_subset_plannedFinalRelation context.topology rewrite hEdge

/-- Runtime construction exposes the local-node syntax acceptance checked before namespacing. -/
theorem runtimePlannerConstruction_local_allowed
    {policy : RuntimeNamespacePolicy node}
    {context : PlanningContext node}
    {rawRewrite : GraphRewrite node}
    {delta : PlannedRewriteDelta node}
    (hConstruction : RuntimePlannerConstruction policy context rawRewrite delta) :
    ∀ localNode,
      localNode ∈ (denote rawRewrite.spec.topology).vertices →
        policy.localAllowed localNode :=
  namespaceSubgraphSpec_local_allowed hConstruction.namespaceDiscipline

/-- Runtime construction exposes freshness of namespaced inserted nodes. -/
theorem runtimePlannerConstruction_namespaced_fresh
    {policy : RuntimeNamespacePolicy node}
    {context : PlanningContext node}
    {rawRewrite : GraphRewrite node}
    {delta : PlannedRewriteDelta node}
    (hConstruction : RuntimePlannerConstruction policy context rawRewrite delta) :
    ∀ mappedNode,
      mappedNode ∈
          (denote (runtimePlannerRewrite policy rawRewrite).spec.topology).vertices →
        mappedNode ∉ (denote context.topology).vertices := by
  rw [runtimePlannerRewrite, namespaceGraphRewrite_spec]
  exact namespaceSubgraphSpec_fresh_against_context hConstruction.namespaceDiscipline

/-- Executable planner construction fields establish the admission planning contract. -/
theorem runtimePlannerConstruction_planGraphRewriteChecks
    {policy : RuntimeNamespacePolicy node}
    {context : PlanningContext node}
    {rawRewrite : GraphRewrite node}
    {delta : PlannedRewriteDelta node}
    (hConstruction :
      RuntimePlannerConstruction policy context rawRewrite delta) :
    PlanGraphRewriteChecks context (runtimePlannerRewrite policy rawRewrite) delta := by
  have hAnchor :
      rawRewrite.anchor = (runtimePlannerRewrite policy rawRewrite).anchor := by
    simp only [runtimePlannerRewrite, namespaceGraphRewrite_anchor]
  have hSubgraphValid : (runtimePlannerRewrite policy rawRewrite).spec.Valid := by
    simp only [runtimePlannerRewrite, namespaceGraphRewrite_spec]
    exact
      namespaceSubgraphSpec_preserves_valid
        (policy.namespaceNode_injective rawRewrite.anchor)
        hConstruction.rawSubgraphValid
  rcases hConstruction.costMatches.entryNodes_runtimeList with
    ⟨entryList, hEntryMatches, hFrontierDelta⟩
  have hEntryCard :
      delta.entryNodes.card = entryList.length :=
    RuntimeNodeListMatches.card_eq_length hEntryMatches
  refine
    { anchorMatches := hConstruction.anchorMatches.anchorNode_eq.trans hAnchor
      anchorInTopology := ?_
      anchorHasDefinition := ?_
      subgraphValid := hSubgraphValid
      topologyMatches := hConstruction.deltaMatches.topology_eq
      subgraphContained :=
        subgraphContainedInFinal_of_topology_eq hConstruction.deltaMatches.topology_eq
      entryExitMatches :=
        { entryNodes_eq := hConstruction.deltaMatches.entryNodes_eq
          exitNodes_eq := hConstruction.deltaMatches.exitNodes_eq }
      anchorDispositionMatches :=
        { disposition_eq := hConstruction.anchorMatches.anchorDisposition_eq
          removed_absent := hConstruction.anchorMatches.removed_absent
          retained_present := hConstruction.anchorMatches.retained_present }
      topologyDiffMatches :=
        { newNodes_eq := hConstruction.deltaMatches.newNodes_eq
          removedNodes_eq := hConstruction.deltaMatches.removedNodes_eq
          addedEdges_eq := hConstruction.deltaMatches.addedEdges_eq }
      costMatches :=
        { addedNodes_eq := hConstruction.costMatches.addedNodes_eq
          addedEdges_eq := hConstruction.costMatches.addedEdges_eq
          addedDepth_eq := hConstruction.costMatches.addedDepth_eq
          frontierDelta_eq := by
            rw [hFrontierDelta, hEntryCard]
          rewriteOps_eq := hConstruction.costMatches.rewriteOps_eq }
      definitionUpdateMatches :=
        { definitions_eq := hConstruction.deltaMatches.definitions_eq }
      finalDefinitionsCover := hConstruction.finalDefinitionsCover
      finalAcyclic := hConstruction.finalAcyclic }
  · simpa only [hAnchor] using hConstruction.anchorInTopology
  · simpa only [hAnchor] using hConstruction.anchorHasDefinition

/-- Executable planner construction plus budget admission gives an abstract admissible rewrite. -/
theorem runtimePlannerConstruction_admissible
    {policy : RuntimeNamespacePolicy node}
    {context : PlanningContext node}
    {rawRewrite : GraphRewrite node}
    {budget remaining : RewriteBudget}
    {delta : PlannedRewriteDelta node}
    {contractOk : Graph node → Prop}
    (hConstruction : RuntimePlannerConstruction policy context rawRewrite delta)
    (hAdmitted : AdmittedRewriteDelta budget delta remaining)
    (hContracts :
      ∀ g, denote g = denote context.topology → contractOk g → contractOk delta.topology) :
    admissible
      (delta.toRewrite
        context.topology
        (plannedRewriteSafety_of_checks
          (runtimePlannerConstruction_planGraphRewriteChecks hConstruction)
          hContracts))
      context.topology
      budget :=
  planGraphRewriteChecks_admissible
    (runtimePlannerConstruction_planGraphRewriteChecks hConstruction)
    hAdmitted
    hContracts

end PlannerBridge

end Cortex.Wire
