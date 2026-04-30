import Cortex.Wire.Rewrite
import Mathlib.Data.Finset.Basic
import Mathlib.Data.Finset.Prod

/-!
## Overview

Runtime-admission bridge for Wire rewrites.

## Context

`Cortex.Wire.Rewrite` proves safety for proof-carrying rewrites: if a
rewrite carries preservation certificates and consumes budget, then rewrite
chains preserve the stated invariants. The Haskell runtime, however, admits
rewrites through `planGraphRewrite`, `consumeRewriteBudget`, and
`admitRewriteDelta`.

This module names the proof-side shape of those runtime checks. It does not
execute Haskell. Instead, it records the obligations an accepted planned
rewrite must establish: the final topology must match the relation-level
planner construction, relation-diff sets must agree with the final topology,
anchor disposition must agree with the rewrite form, structural costs must
match the planned delta, definition-domain updates must follow the runtime
delete-or-retain formula, and budget admission must consume budget pointwise.
Under those obligations, an accepted plan instantiates the abstract `Rewrite`
certificate surface.

## Theorem Split

The page defines runtime-shaped rewrite inputs, subgraph validity, a
relation-level planner model, planned rewrite checks, budget admission, and
the bridge theorem from admitted planned deltas to abstract admissible
rewrites.
-/

namespace Cortex.Wire

open Cortex.Graph

/-! ## Runtime-Shaped Inputs -/

/-- `ExpansionMode` mirrors the runtime's node-expansion mode. -/
inductive ExpansionMode : Type where
  | replaceNode
  | retainNodeAsEnvelope
  deriving DecidableEq, Repr

/-- `RewriteAnchorDisposition` records whether the anchor remains materialized. -/
inductive RewriteAnchorDisposition : Type where
  | removed
  | retained
  deriving DecidableEq, Repr

/-- `SubgraphSpec node` is the proof-side shape of a proposed inserted subgraph. -/
structure SubgraphSpec (node : Type) where
  /-- Topology of the proposed inserted subgraph. -/
  topology : Graph node
  /-- Domain of the stage definitions supplied for the inserted subgraph. -/
  definitions : Finset node
  /-- Entry nodes exposed by the inserted subgraph. -/
  entryNodes : Finset node
  /-- Exit nodes exposed by the inserted subgraph. -/
  exitNodes : Finset node

/-- `GraphRewrite node` mirrors the runtime rewrite forms currently admitted. -/
inductive GraphRewrite (node : Type) : Type where
  | expandNode : node → ExpansionMode → SubgraphSpec node → GraphRewrite node
  | appendAfter : node → SubgraphSpec node → GraphRewrite node

namespace GraphRewrite

/-- `anchor rewrite` is the node around which the runtime plans the rewrite. -/
def anchor {node : Type} : GraphRewrite node → node
  | GraphRewrite.expandNode anchorNode _mode _spec => anchorNode
  | GraphRewrite.appendAfter anchorNode _spec => anchorNode

/-- `spec rewrite` is the inserted subgraph proposed by the rewrite. -/
def spec {node : Type} : GraphRewrite node → SubgraphSpec node
  | GraphRewrite.expandNode _anchor _mode subgraph => subgraph
  | GraphRewrite.appendAfter _anchor subgraph => subgraph

/-- `anchorDisposition rewrite` mirrors the runtime anchor-retention decision. -/
def anchorDisposition {node : Type} : GraphRewrite node → RewriteAnchorDisposition
  | GraphRewrite.expandNode _anchor ExpansionMode.replaceNode _spec =>
      RewriteAnchorDisposition.removed
  | GraphRewrite.expandNode _anchor ExpansionMode.retainNodeAsEnvelope _spec =>
      RewriteAnchorDisposition.retained
  | GraphRewrite.appendAfter _anchor _spec =>
      RewriteAnchorDisposition.retained

end GraphRewrite

/-! ## Relation-Level Planner Model

This section transcribes the Haskell `planGraphRewrite` topology construction
(`src/Cortex/Pulse/Rewrite.hs`) into a relation-level Lean model. The runtime
plan proceeds in five stages:

1. Resolve the anchor's predecessors and successors in the current topology.
2. Form the base topology by either deleting the anchor (`replaceNode`) or
   stripping its outgoing edges (`retainNodeAsEnvelope`, `appendAfter`).
3. Overlay the inserted subgraph.
4. Wire the entry sources to the inserted entry nodes. The entry source set is
   the anchor's predecessors when the anchor is removed and the anchor itself
   when the anchor is retained.
5. Wire the inserted exit nodes to the anchor's successors.

`plannedFinalRelation` carries out exactly those five stages on the relation
denotation. The bridge theorem `topologyMatches` requires `delta.topology` to
match this construction; `relationAddedNodes`, `relationRemovedNodes`, and
`relationAddedEdges` recover the runtime `relationDiff` outputs from the same
relation.

The planner takes the inserted subgraph as already living in the final node
namespace. The runtime obtains that shape through `namespaceSubgraph`; a later
executable correspondence theorem must connect that function to this
proof-side input.
-/

section PlannerRelation

variable {node : Type}
variable [DecidableEq node]

/-- `predecessorsOf relation target` extracts direct predecessors of `target`. -/
def predecessorsOf (relation : Relation node) (target : node) : Finset node :=
  (relation.edges.filter (fun edge => edge.2 = target)).image Prod.fst

/-- `successorsOf relation source` extracts direct successors of `source`. -/
def successorsOf (relation : Relation node) (source : node) : Finset node :=
  (relation.edges.filter (fun edge => edge.1 = source)).image Prod.snd

/-- `removeVertexFromRelation relation vertex` removes a vertex and incident edges. -/
def removeVertexFromRelation (relation : Relation node) (vertex : node) : Relation node :=
  { vertices := relation.vertices.erase vertex
    edges := relation.edges.filter (fun edge => edge.1 ≠ vertex ∧ edge.2 ≠ vertex) }

/-- `removeOutgoingFromRelation relation vertex` removes all outgoing edges from a vertex. -/
def removeOutgoingFromRelation (relation : Relation node) (vertex : node) : Relation node :=
  { vertices := relation.vertices
    edges := relation.edges.filter (fun edge => edge.1 ≠ vertex) }

/-- `addEdgesToRelation relation edges` adds edges and their endpoint vertices. -/
def addEdgesToRelation (relation : Relation node) (edges : Finset (node × node)) :
    Relation node :=
  { vertices := relation.vertices ∪ edges.image Prod.fst ∪ edges.image Prod.snd
    edges := relation.edges ∪ edges }

/-- `plannedFinalRelation context rewrite` mirrors the runtime topology construction.

The subgraph is assumed to already live in the final node namespace. The Haskell
planner obtains that shape through `namespaceSubgraph`; a later executable
correspondence theorem must connect that function to this proof-side input. -/
def plannedFinalRelation (context : Graph node) (rewrite : GraphRewrite node) :
    Relation node :=
  let oldRelation := denote context
  let anchorNode := rewrite.anchor
  let insertedRelation := denote rewrite.spec.topology
  let predecessors := predecessorsOf oldRelation anchorNode
  let successors := successorsOf oldRelation anchorNode
  let baseRelation :=
    match rewrite with
    | GraphRewrite.expandNode _anchor ExpansionMode.replaceNode _spec =>
        removeVertexFromRelation oldRelation anchorNode
    | GraphRewrite.expandNode _anchor ExpansionMode.retainNodeAsEnvelope _spec =>
        removeOutgoingFromRelation oldRelation anchorNode
    | GraphRewrite.appendAfter _anchor _spec =>
        removeOutgoingFromRelation oldRelation anchorNode
  let withSubgraph := Relation.overlay baseRelation insertedRelation
  let entrySources :=
    match rewrite.anchorDisposition with
    | RewriteAnchorDisposition.removed => predecessors
    | RewriteAnchorDisposition.retained => {anchorNode}
  let withEntries :=
    addEdgesToRelation withSubgraph (entrySources ×ˢ rewrite.spec.entryNodes)
  addEdgesToRelation withEntries (rewrite.spec.exitNodes ×ˢ successors)

/-- Nodes added by moving from `oldRelation` to `newRelation`. -/
def relationAddedNodes (oldRelation newRelation : Relation node) : Finset node :=
  newRelation.vertices \ oldRelation.vertices

/-- Nodes removed by moving from `oldRelation` to `newRelation`. -/
def relationRemovedNodes (oldRelation newRelation : Relation node) : Finset node :=
  oldRelation.vertices \ newRelation.vertices

/-- Edges added by moving from `oldRelation` to `newRelation`. -/
def relationAddedEdges
    (oldRelation newRelation : Relation node) :
    Finset (node × node) :=
  newRelation.edges \ oldRelation.edges

end PlannerRelation

/-! ## Planning Predicates -/

section PlanningPredicates

variable {node : Type}
variable [DecidableEq node]

/-- `DefinitionCoverage topology definitions` says definitions exactly cover topology vertices. -/
def DefinitionCoverage (topology : Graph node) (definitions : Finset node) : Prop :=
  definitions = (denote topology).vertices

/-- `NodesInside nodes topology` says every listed node appears in the topology. -/
def NodesInside (nodes : Finset node) (topology : Graph node) : Prop :=
  ∀ node, node ∈ nodes → node ∈ (denote topology).vertices

/-- `ReachableOrSame g source target` matches runtime reachability, including the root itself. -/
def ReachableOrSame (g : Graph node) (source target : node) : Prop :=
  source = target ∨ GraphPath g source target

/-- `OrphanFree spec` says each inserted node lies on an entry-to-exit path. -/
def OrphanFree (spec : SubgraphSpec node) : Prop :=
  ∀ node,
    node ∈ (denote spec.topology).vertices →
      (∃ entry, entry ∈ spec.entryNodes ∧ ReachableOrSame spec.topology entry node) ∧
        ∃ exit, exit ∈ spec.exitNodes ∧ ReachableOrSame spec.topology node exit

/-- `GraphPathNodeCount g source target count` counts vertices along a non-branching path. -/
inductive GraphPathNodeCount (g : Graph node) : node → node → Nat → Prop where
  | same {node : node} :
      node ∈ (denote g).vertices →
        GraphPathNodeCount g node node 1
  | direct {source target : node} :
      (source, target) ∈ (denote g).edges →
        GraphPathNodeCount g source target 2
  | cons {source next target : node} {count : Nat} :
      (source, next) ∈ (denote g).edges →
        GraphPathNodeCount g next target count →
          GraphPathNodeCount g source target (count + 1)

/-- `EntryExitPathNodeCount spec count` witnesses an entry-to-exit path with `count` nodes. -/
def EntryExitPathNodeCount (spec : SubgraphSpec node) (count : Nat) : Prop :=
  ∃ entry exit,
    entry ∈ spec.entryNodes ∧
      exit ∈ spec.exitNodes ∧
        GraphPathNodeCount spec.topology entry exit count

/-- `LongestInsertedPathNodeCount spec depth` mirrors the runtime inserted-depth computation. -/
def LongestInsertedPathNodeCount (spec : SubgraphSpec node) (depth : Nat) : Prop :=
  (∀ count, EntryExitPathNodeCount spec count → count ≤ depth) ∧
    (depth = 0 ∨ EntryExitPathNodeCount spec depth)

/-- `SubgraphSpec.Valid spec` collects the runtime's inserted-subgraph checks. -/
structure SubgraphSpec.Valid (spec : SubgraphSpec node) : Prop where
  /-- The inserted subgraph itself is acyclic. -/
  acyclic : Acyclic spec.topology
  /-- Inserted definitions exactly cover inserted topology nodes. -/
  definitionsCover : DefinitionCoverage spec.topology spec.definitions
  /-- Inserted subgraphs must expose at least one entry node. -/
  entryNodesNonempty : spec.entryNodes.Nonempty
  /-- Inserted subgraphs must expose at least one exit node. -/
  exitNodesNonempty : spec.exitNodes.Nonempty
  /-- Every entry node belongs to the inserted topology. -/
  entryNodesInside : NodesInside spec.entryNodes spec.topology
  /-- Every exit node belongs to the inserted topology. -/
  exitNodesInside : NodesInside spec.exitNodes spec.topology
  /-- Every inserted node is reachable from an entry and can reach an exit. -/
  orphanFree : OrphanFree spec

/-- `PlanningContext` is the current runtime topology plus definition domain. -/
structure PlanningContext (node : Type) where
  /-- Current materialized topology before the rewrite is applied. -/
  topology : Graph node
  /-- Domain of current stage definitions. -/
  definitions : Finset node

/-- `plannedFinalDefinitions context rewrite` mirrors the runtime definition-domain update.

Replacing an anchor deletes its current definition before overlaying the inserted definitions.
Retaining an anchor and appending after an anchor keep the old definition domain and overlay the
inserted definitions. The inserted subgraph is assumed to already live in the final namespace. -/
def plannedFinalDefinitions
    (context : PlanningContext node)
    (rewrite : GraphRewrite node) :
    Finset node :=
  match rewrite.anchorDisposition with
  | RewriteAnchorDisposition.removed =>
      context.definitions.erase rewrite.anchor ∪ rewrite.spec.definitions
  | RewriteAnchorDisposition.retained =>
      context.definitions ∪ rewrite.spec.definitions

/-- `PlannedRewriteDelta` mirrors the runtime's planned rewrite output. -/
structure PlannedRewriteDelta (node : Type) where
  /-- Final topology after applying the planned rewrite. -/
  topology : Graph node
  /-- Final definition domain after applying the planned rewrite. -/
  definitions : Finset node
  /-- Nodes newly introduced by the planned rewrite. -/
  newNodes : Finset node
  /-- Nodes removed by the planned rewrite. -/
  removedNodes : Finset node
  /-- Edges newly introduced by the planned rewrite. -/
  addedEdges : Finset (node × node)
  /-- Entry nodes of the inserted subgraph after namespacing. -/
  entryNodes : Finset node
  /-- Exit nodes of the inserted subgraph after namespacing. -/
  exitNodes : Finset node
  /-- Anchor node that produced the rewrite. -/
  anchorNode : node
  /-- Whether the anchor remains in the final topology. -/
  anchorDisposition : RewriteAnchorDisposition
  /-- Structural cost computed for this rewrite. -/
  cost : RewriteCost

/-- `SubgraphContainedInFinal rewrite delta` records that the inserted subgraph was inserted. -/
structure SubgraphContainedInFinal
    (rewrite : GraphRewrite node)
    (delta : PlannedRewriteDelta node) :
    Prop where
  /-- Every inserted vertex appears in the final topology. -/
  verticesInside :
    ∀ node,
      node ∈ (denote rewrite.spec.topology).vertices →
        node ∈ (denote delta.topology).vertices
  /-- Every inserted edge appears in the final topology. -/
  edgesInside :
    ∀ edge,
      edge ∈ (denote rewrite.spec.topology).edges →
        edge ∈ (denote delta.topology).edges

/-- `EntryExitMatches rewrite delta` ties delta entry/exit sets to the inserted subgraph. -/
structure EntryExitMatches
    (rewrite : GraphRewrite node)
    (delta : PlannedRewriteDelta node) :
    Prop where
  /-- Delta entry nodes are exactly the inserted subgraph entry nodes. -/
  entryNodes_eq : delta.entryNodes = rewrite.spec.entryNodes
  /-- Delta exit nodes are exactly the inserted subgraph exit nodes. -/
  exitNodes_eq : delta.exitNodes = rewrite.spec.exitNodes

/-- `AnchorDispositionMatches rewrite delta` couples the runtime disposition to topology. -/
structure AnchorDispositionMatches
    (rewrite : GraphRewrite node)
    (delta : PlannedRewriteDelta node) :
    Prop where
  /-- Delta disposition agrees with the rewrite form. -/
  disposition_eq : delta.anchorDisposition = rewrite.anchorDisposition
  /-- Removed anchors are absent from the final topology. -/
  removed_absent :
    delta.anchorDisposition = RewriteAnchorDisposition.removed →
      rewrite.anchor ∉ (denote delta.topology).vertices
  /-- Retained anchors remain in the final topology. -/
  retained_present :
    delta.anchorDisposition = RewriteAnchorDisposition.retained →
      rewrite.anchor ∈ (denote delta.topology).vertices

/-- `TopologyDiffMatches context delta` ties delta sets to the relation diff. -/
structure TopologyDiffMatches
    (context : PlanningContext node)
    (delta : PlannedRewriteDelta node) :
    Prop where
  /-- New nodes are exactly final vertices absent from the old topology. -/
  newNodes_eq :
    delta.newNodes =
      relationAddedNodes (denote context.topology) (denote delta.topology)
  /-- Removed nodes are exactly old vertices absent from the final topology. -/
  removedNodes_eq :
    delta.removedNodes =
      relationRemovedNodes (denote context.topology) (denote delta.topology)
  /-- Added edges are exactly final edges absent from the old topology. -/
  addedEdges_eq :
    delta.addedEdges =
      relationAddedEdges (denote context.topology) (denote delta.topology)

/-- `DefinitionUpdateMatches context rewrite delta` ties definitions to the planner update. -/
structure DefinitionUpdateMatches
    (context : PlanningContext node)
    (rewrite : GraphRewrite node)
    (delta : PlannedRewriteDelta node) :
    Prop where
  /-- Final definition-domain keys match the runtime delete-or-retain update formula. -/
  definitions_eq : delta.definitions = plannedFinalDefinitions context rewrite

/-- `PlannedRewriteCostMatches rewrite delta` ties every budget dimension to the delta. -/
structure PlannedRewriteCostMatches
    (rewrite : GraphRewrite node)
    (delta : PlannedRewriteDelta node) :
    Prop where
  /-- Added-node cost equals the relation-diff node count. -/
  addedNodes_eq : delta.cost.addedNodes = delta.newNodes.card
  /-- Added-edge cost equals the relation-diff edge count. -/
  addedEdges_eq : delta.cost.addedEdges = delta.addedEdges.card
  /-- Added-depth cost is computed from the inserted entry-to-exit longest path. -/
  addedDepth_eq :
    ∃ insertedDepth,
      LongestInsertedPathNodeCount rewrite.spec insertedDepth ∧
        delta.cost.addedDepth =
          match delta.anchorDisposition with
          | RewriteAnchorDisposition.removed => insertedDepth - 1
          | RewriteAnchorDisposition.retained => insertedDepth
  /-- Frontier delta is the number of inserted entries beyond the first. -/
  frontierDelta_eq : delta.cost.frontierDelta = delta.entryNodes.card - 1
  /-- Each planned graph rewrite consumes one rewrite-operation unit. -/
  rewriteOps_eq : delta.cost.rewriteOps = 1

/-- `PlanGraphRewriteChecks context rewrite delta` is the Lean-side runtime planning contract. -/
structure PlanGraphRewriteChecks
    (context : PlanningContext node)
    (rewrite : GraphRewrite node)
    (delta : PlannedRewriteDelta node) :
    Prop where
  /-- The delta records the rewrite anchor. -/
  anchorMatches : delta.anchorNode = rewrite.anchor
  /-- The anchor exists in the current topology. -/
  anchorInTopology : rewrite.anchor ∈ (denote context.topology).vertices
  /-- The anchor has a current stage definition. -/
  anchorHasDefinition : rewrite.anchor ∈ context.definitions
  /-- The inserted subgraph satisfies the runtime subgraph checks. -/
  subgraphValid : rewrite.spec.Valid
  /-- The final topology matches the proof-side relation-level planner construction. -/
  topologyMatches :
    denote delta.topology = plannedFinalRelation context.topology rewrite
  /-- The inserted subgraph is present in the final topology. -/
  subgraphContained : SubgraphContainedInFinal rewrite delta
  /-- Delta entry/exit nodes are the inserted subgraph entry/exit nodes. -/
  entryExitMatches : EntryExitMatches rewrite delta
  /-- Delta anchor disposition agrees with the rewrite and final anchor membership. -/
  anchorDispositionMatches : AnchorDispositionMatches rewrite delta
  /-- Delta new/removed/added sets agree with relation-level topology diffs. -/
  topologyDiffMatches : TopologyDiffMatches context delta
  /-- Delta cost agrees with every structural budget dimension. -/
  costMatches : PlannedRewriteCostMatches rewrite delta
  /-- Delta definitions agree with the runtime delete-or-retain update formula. -/
  definitionUpdateMatches : DefinitionUpdateMatches context rewrite delta
  /-- The final topology has a definition for each materialized node and no extras. -/
  finalDefinitionsCover : DefinitionCoverage delta.topology delta.definitions
  /-- The runtime validates the final topology as acyclic. -/
  finalAcyclic : Acyclic delta.topology

end PlanningPredicates

/-! ## Registry Boundary Preservation -/

section RegistryBoundaryPreservation

variable {executor config contract authority : Type}
variable [DecidableEq contract]
variable [DecidableEq (StagedExecutorNode executor config authority)]

/-- `RegistryBoundaryDeltaAdmitted registry delta` bundles the per-delta registry obligations that
are not inherited from the source graph boundary.

This witness is load-bearing only when paired with a `TopologyDiffMatches` proof for the same
delta, which ties `delta.newNodes` and `delta.addedEdges` to the final topology. -/
structure RegistryBoundaryDeltaAdmitted
    (registry : ExecutorRegistry executor config contract authority)
    (delta : PlannedRewriteDelta (StagedExecutorNode executor config authority)) :
    Prop where
  /-- Every genuinely added vertex is admitted by the registry. -/
  newNodes :
    ∀ node,
      node ∈ delta.newNodes →
        nodeAdmittedBy registry node
  /-- Every genuinely added edge has registry-compatible endpoints. -/
  addedEdges :
    ∀ source target,
      (source, target) ∈ delta.addedEdges →
        edgeAdmittedBy registry source target

/-- A planned delta preserves the registry boundary when every genuinely added vertex and edge is
explicitly admitted.

Existing vertices and edges reuse the source boundary witness. Vertices in `delta.newNodes` and
edges in `delta.addedEdges` are the only new obligations, with edge compatibility kept separate
from vertex admission. -/
theorem registryBoundary_preserved_of_addedNodes_addedEdges_admitted
    (registry : ExecutorRegistry executor config contract authority)
    {context : PlanningContext (StagedExecutorNode executor config authority)}
    {delta : PlannedRewriteDelta (StagedExecutorNode executor config authority)}
    (hDiff : TopologyDiffMatches context delta)
    (hBoundary : registryBoundary registry context.topology)
    (hNewNodes :
      ∀ node,
        node ∈ delta.newNodes →
          nodeAdmittedBy registry node)
    (hAddedEdges :
      ∀ source target,
        (source, target) ∈ delta.addedEdges →
          edgeAdmittedBy registry source target) :
    registryBoundary registry delta.topology := by
  constructor
  · intro node hFinalNode
    by_cases hOldNode : node ∈ (denote context.topology).vertices
    · exact hBoundary.1 node hOldNode
    · have hAddedNode : node ∈ delta.newNodes := by
        rw [hDiff.newNodes_eq]
        simp only [relationAddedNodes, Finset.mem_sdiff]
        exact ⟨hFinalNode, hOldNode⟩
      exact hNewNodes node hAddedNode
  · intro source target hFinalEdge
    by_cases hOldEdge : (source, target) ∈ (denote context.topology).edges
    · exact hBoundary.2 source target hOldEdge
    · have hAddedEdge : (source, target) ∈ delta.addedEdges := by
        rw [hDiff.addedEdges_eq]
        simp only [relationAddedEdges, Finset.mem_sdiff]
        exact ⟨hFinalEdge, hOldEdge⟩
      exact hAddedEdges source target hAddedEdge

/-- A planned delta preserves the registry boundary from its bundled delta-admission evidence. -/
theorem registryBoundary_preserved_of_delta_admitted
    (registry : ExecutorRegistry executor config contract authority)
    {context : PlanningContext (StagedExecutorNode executor config authority)}
    {delta : PlannedRewriteDelta (StagedExecutorNode executor config authority)}
    (hDiff : TopologyDiffMatches context delta)
    (hBoundary : registryBoundary registry context.topology)
    (hDelta : RegistryBoundaryDeltaAdmitted registry delta) :
    registryBoundary registry delta.topology :=
  registryBoundary_preserved_of_addedNodes_addedEdges_admitted
    registry
    hDiff
    hBoundary
    hDelta.newNodes
    hDelta.addedEdges

end RegistryBoundaryPreservation

/-! ## Budget Admission -/

section BudgetAdmission

variable {node : Type}

/-- `AdmittedRewriteDelta budget delta remaining` mirrors `admitRewriteDelta`. -/
structure AdmittedRewriteDelta
    (budget : RewriteBudget)
    (delta : PlannedRewriteDelta node)
    (remaining : RewriteBudget) :
    Prop where
  /-- The planned cost fits every remaining budget dimension. -/
  fits : delta.cost.fitsIn budget
  /-- The runtime returns the pointwise-decremented remaining budget. -/
  remaining_eq : remaining = budget.consume delta.cost

/-- Budget admission never replenishes any structural budget dimension. -/
theorem admittedRewriteDelta_remaining_le_initial
    {budget remaining : RewriteBudget}
    {delta : PlannedRewriteDelta node}
    (hAdmitted : AdmittedRewriteDelta budget delta remaining) :
    remaining.le budget := by
  rw [hAdmitted.remaining_eq]
  exact RewriteBudget.consume_le budget delta.cost

/-- Budget admission exposes the rewrite-operation bound needed by chain termination. -/
theorem admittedRewriteDelta_rewriteOps_bound
    {budget remaining : RewriteBudget}
    {delta : PlannedRewriteDelta node}
    (hAdmitted : AdmittedRewriteDelta budget delta remaining) :
    delta.cost.rewriteOps ≤ budget.rewriteOps :=
  hAdmitted.fits.2.2.2.2

end BudgetAdmission

/-! ## Bridge To Proof-Carrying Rewrites -/

section Bridge

variable {node : Type}
variable [DecidableEq node]
variable {contractOk : Graph node → Prop}

/-- `PlannedRewriteSafety` supplies the non-structural certificate for a planned delta. -/
structure PlannedRewriteSafety
    (source : Graph node)
    (delta : PlannedRewriteDelta node)
    (contractOk : Graph node → Prop) :
    Prop where
  /-- The final topology is acyclic. Usually projected from `PlanGraphRewriteChecks`. -/
  finalAcyclic : Acyclic delta.topology
  /-- Caller-specific contract validity is preserved by this planned rewrite. -/
  preservesContracts :
    ∀ g, denote g = denote source → contractOk g → contractOk delta.topology
  /-- The planned delta consumes at least one rewrite operation. -/
  rewriteOpsPositive : 0 < delta.cost.rewriteOps

/-- Planning checks provide the acyclicity and operation-budget parts of rewrite safety. -/
theorem plannedRewriteSafety_of_checks
    {context : PlanningContext node}
    {rewrite : GraphRewrite node}
    {delta : PlannedRewriteDelta node}
    (hChecks : PlanGraphRewriteChecks context rewrite delta)
    (hContracts :
      ∀ g, denote g = denote context.topology → contractOk g → contractOk delta.topology) :
    PlannedRewriteSafety context.topology delta contractOk := by
  refine
    { finalAcyclic := hChecks.finalAcyclic
      preservesContracts := hContracts
      rewriteOpsPositive := ?_ }
  rw [hChecks.costMatches.rewriteOps_eq]
  exact Nat.zero_lt_one

namespace PlannedRewriteDelta

/-- `toRewrite source delta safety` turns an accepted plan into a proof-carrying rewrite. -/
def toRewrite
    (source : Graph node)
    (delta : PlannedRewriteDelta node)
    (hSafety : PlannedRewriteSafety source delta contractOk) :
    Rewrite node contractOk :=
  { apply := fun g =>
      if denote g = denote source then
        some delta.topology
      else
        none
    cost := delta.cost
    rewriteOps_positive := hSafety.rewriteOpsPositive
    preserves_acyclic := by
      intro g g' hApply _hAcyclic
      by_cases hSource : denote g = denote source
      · simp [hSource] at hApply
        cases hApply
        exact hSafety.finalAcyclic
      · simp [hSource] at hApply
    preserves_contracts := by
      intro g g' hApply hContracts
      by_cases hSource : denote g = denote source
      · simp [hSource] at hApply
        cases hApply
        exact hSafety.preservesContracts g hSource hContracts
      · simp [hSource] at hApply }

end PlannedRewriteDelta

/-- The planned rewrite applies to the source topology it was planned against. -/
theorem plannedRewrite_applicable
    {source : Graph node}
    {delta : PlannedRewriteDelta node}
    {hSafety : PlannedRewriteSafety source delta contractOk} :
    applicable (delta.toRewrite source hSafety) source := by
  exact ⟨delta.topology, by simp [PlannedRewriteDelta.toRewrite]⟩

/-- Admitted planned deltas instantiate the abstract `admissible` rewrite predicate. -/
theorem admittedPlannedRewrite_admissible
    {source : Graph node}
    {budget remaining : RewriteBudget}
    {delta : PlannedRewriteDelta node}
    {hSafety : PlannedRewriteSafety source delta contractOk}
    (hAdmitted : AdmittedRewriteDelta budget delta remaining) :
    admissible (delta.toRewrite source hSafety) source budget :=
  ⟨hAdmitted.fits, plannedRewrite_applicable⟩

/-- Runtime planning checks plus budget admission give an abstract admissible rewrite. -/
theorem planGraphRewriteChecks_admissible
    {context : PlanningContext node}
    {rewrite : GraphRewrite node}
    {budget remaining : RewriteBudget}
    {delta : PlannedRewriteDelta node}
    (hChecks : PlanGraphRewriteChecks context rewrite delta)
    (hAdmitted : AdmittedRewriteDelta budget delta remaining)
    (hContracts :
      ∀ g, denote g = denote context.topology → contractOk g → contractOk delta.topology) :
    admissible
      (delta.toRewrite context.topology (plannedRewriteSafety_of_checks hChecks hContracts))
      context.topology
      budget :=
  admittedPlannedRewrite_admissible hAdmitted

/-- Runtime planning checks expose the final DAG certificate used by rewrite safety. -/
theorem planGraphRewriteChecks_final_acyclic
    {context : PlanningContext node}
    {rewrite : GraphRewrite node}
    {delta : PlannedRewriteDelta node}
    (hChecks : PlanGraphRewriteChecks context rewrite delta) :
    Acyclic delta.topology :=
  hChecks.finalAcyclic

/-- Runtime planning checks expose the final topology construction equation. -/
theorem planGraphRewriteChecks_topology_matches
    {context : PlanningContext node}
    {rewrite : GraphRewrite node}
    {delta : PlannedRewriteDelta node}
    (hChecks : PlanGraphRewriteChecks context rewrite delta) :
    denote delta.topology = plannedFinalRelation context.topology rewrite :=
  hChecks.topologyMatches

/-- Runtime planning checks expose the relation-diff equations for delta sets. -/
theorem planGraphRewriteChecks_topologyDiffMatches
    {context : PlanningContext node}
    {rewrite : GraphRewrite node}
    {delta : PlannedRewriteDelta node}
    (hChecks : PlanGraphRewriteChecks context rewrite delta) :
    TopologyDiffMatches context delta :=
  hChecks.topologyDiffMatches

/-- Runtime planning checks expose the structural cost equations. -/
theorem planGraphRewriteChecks_costMatches
    {context : PlanningContext node}
    {rewrite : GraphRewrite node}
    {delta : PlannedRewriteDelta node}
    (hChecks : PlanGraphRewriteChecks context rewrite delta) :
    PlannedRewriteCostMatches rewrite delta :=
  hChecks.costMatches

/-- Runtime planning checks expose anchor-disposition agreement. -/
theorem planGraphRewriteChecks_anchorDispositionMatches
    {context : PlanningContext node}
    {rewrite : GraphRewrite node}
    {delta : PlannedRewriteDelta node}
    (hChecks : PlanGraphRewriteChecks context rewrite delta) :
    AnchorDispositionMatches rewrite delta :=
  hChecks.anchorDispositionMatches

/-- Runtime planning checks expose the exact definition-domain update equation. -/
theorem planGraphRewriteChecks_definitionUpdateMatches
    {context : PlanningContext node}
    {rewrite : GraphRewrite node}
    {delta : PlannedRewriteDelta node}
    (hChecks : PlanGraphRewriteChecks context rewrite delta) :
    DefinitionUpdateMatches context rewrite delta :=
  hChecks.definitionUpdateMatches

/-- Runtime planning checks expose final definitions as the planned update formula. -/
theorem planGraphRewriteChecks_definitions_eq
    {context : PlanningContext node}
    {rewrite : GraphRewrite node}
    {delta : PlannedRewriteDelta node}
    (hChecks : PlanGraphRewriteChecks context rewrite delta) :
    delta.definitions = plannedFinalDefinitions context rewrite :=
  hChecks.definitionUpdateMatches.definitions_eq

end Bridge

end Cortex.Wire
