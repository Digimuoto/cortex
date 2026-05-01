import Cortex.Graph.Safety
import Mathlib.Data.Finset.Basic
import Mathlib.Order.WellFoundedSet

/-!
## Overview

This module gives the Paper 1 Pulse kernel its static topology model.

## Context

The live runtime stores materialized node identifiers and relation-style
edges. The proof kernel deliberately uses an extensional finite-node
model instead: a node type `ν`, a finite topology domain, a boolean edge
predicate, and strict reachability derived as the transitive closure of
that edge predicate.

## Theorem Split

The page first defines edge-derived paths and the fixed topology record,
then exposes reachability facts used by the frontier antichain,
failure-closure, and recovered-state domain proofs in later modules.
-/

namespace Cortex.Pulse

/-! ## Edge Paths -/

/-- `EdgePath edge a b` is non-empty reachability from `a` to `b` through
the direct edge predicate. -/
inductive EdgePath {ν : Type u} (edge : ν → ν → Bool) : ν → ν → Prop where
  | direct {a b : ν} : edge a b = true → EdgePath edge a b
  | trans {a b c : ν} : EdgePath edge a b → EdgePath edge b c → EdgePath edge a c

namespace EdgePath

variable {ν : Type u} {edge : ν → ν → Bool} {nodes : Finset ν}

/-- `source_mem` lifts direct-edge source membership through an `EdgePath`. -/
theorem source_mem
    (hSource : ∀ {a b : ν}, edge a b = true → a ∈ nodes)
    {a b : ν}
    (hPath : EdgePath edge a b) :
    a ∈ nodes := by
  induction hPath with
  | direct hEdge => exact hSource hEdge
  | trans _ _ ihLeft _ => exact ihLeft

/-- `target_mem` lifts direct-edge target membership through an `EdgePath`. -/
theorem target_mem
    (hTarget : ∀ {a b : ν}, edge a b = true → b ∈ nodes)
    {a b : ν}
    (hPath : EdgePath edge a b) :
    b ∈ nodes := by
  induction hPath with
  | direct hEdge => exact hTarget hEdge
  | trans _ _ _ ihRight => exact ihRight

/-- `last_step` decomposes a non-empty path into its final direct edge. -/
theorem last_step {a b : ν}
    (hPath : EdgePath edge a b) :
    edge a b = true ∨ ∃ c : ν, EdgePath edge a c ∧ edge c b = true := by
  induction hPath with
  | direct hEdge => exact Or.inl hEdge
  | trans hLeft hRight _ ihRight =>
      rcases ihRight with hDirect | ⟨c, hPrefix, hEdge⟩
      · exact Or.inr ⟨_, hLeft, hDirect⟩
      · exact Or.inr ⟨c, EdgePath.trans hLeft hPrefix, hEdge⟩

end EdgePath

/-! ## Relation Bridges -/

namespace EdgePath

variable {ν : Type} [DecidableEq ν]

/-- `of_relationPath_edgeBool` lowers relation reachability to boolean-edge reachability. -/
theorem of_relationPath_edgeBool
    {relation : Cortex.Graph.Relation ν}
    {source target : ν}
    (hPath : Cortex.Graph.Relation.Path relation source target) :
    EdgePath (Cortex.Graph.Relation.edgeBool relation) source target := by
  induction hPath with
  | direct hEdge =>
      exact EdgePath.direct (Cortex.Graph.Relation.edgeBool_true_of_mem hEdge)
  | trans _ _ ihLeft ihRight =>
      exact EdgePath.trans ihLeft ihRight

/-- `to_relationPath_edgeBool` lifts boolean-edge reachability to relation reachability. -/
theorem to_relationPath_edgeBool
    {relation : Cortex.Graph.Relation ν}
    {source target : ν}
    (hPath : EdgePath (Cortex.Graph.Relation.edgeBool relation) source target) :
    Cortex.Graph.Relation.Path relation source target := by
  induction hPath with
  | direct hEdge =>
      exact Cortex.Graph.Relation.Path.of_edgeBool_true hEdge
  | trans _ _ ihLeft ihRight =>
      exact Cortex.Graph.Relation.Path.trans ihLeft ihRight

/-- `edgeBool_iff_relationPath` equates Pulse paths with relation paths. -/
theorem edgeBool_iff_relationPath
    (relation : Cortex.Graph.Relation ν)
    (source target : ν) :
    EdgePath (Cortex.Graph.Relation.edgeBool relation) source target ↔
      Cortex.Graph.Relation.Path relation source target :=
  ⟨to_relationPath_edgeBool, of_relationPath_edgeBool⟩

end EdgePath

/-! ## Fixed Topology -/

/-- `DAG ν` is the fixed Pulse topology for the Paper 1 kernel.

`edge a b = true` means that `a` is a direct dependency of `b`.
`DAG.reaches G a b` is the non-empty transitive closure of that direct
edge relation. The structure packages only the concrete edge topology and
the laws needed to rule out off-topology edges and cycles, without
committing the model to UUIDs, database rows, or a concrete graph
container. -/
structure DAG (ν : Type u) where
  /-- `nodes` is the finite set of materialized nodes in the topology. -/
  nodes : Finset ν
  /-- `edge a b` means source `a` must complete before target `b` can run. -/
  edge : ν → ν → Bool
  /-- `edge_source_mem` keeps every direct-edge source inside the topology. -/
  edge_source_mem : ∀ {a b : ν}, edge a b = true → a ∈ nodes
  /-- `edge_target_mem` keeps every direct-edge target inside the topology. -/
  edge_target_mem : ∀ {a b : ν}, edge a b = true → b ∈ nodes
  /-- `acyclic` rules out non-empty paths from a node back to itself. -/
  acyclic : ∀ a : ν, ¬ EdgePath edge a a

/-! ## Reachability Facts -/

namespace DAG

variable {ν : Type u} (G : DAG ν)

/-- `G.reaches a b` is edge-derived strict reachability. -/
def reaches (a b : ν) : Prop :=
  EdgePath G.edge a b

/-- `G.predecessor a b` says `a` is a direct predecessor of `b`. -/
def predecessor (a b : ν) : Prop :=
  G.edge a b = true

/-- `reaches_of_edge` turns a direct edge into a strict reachability witness. -/
theorem reaches_of_edge {a b : ν} (hEdge : G.predecessor a b) :
    G.reaches a b :=
  EdgePath.direct hEdge

/-- `reaches_trans` composes two edge-derived reachability witnesses. -/
theorem reaches_trans {a b c : ν}
    (hLeft : G.reaches a b)
    (hRight : G.reaches b c) :
    G.reaches a c :=
  EdgePath.trans hLeft hRight

/-- `reaches_source_mem` keeps reachable sources inside the finite topology. -/
theorem reaches_source_mem {a b : ν} (hReach : G.reaches a b) :
    a ∈ G.nodes :=
  EdgePath.source_mem G.edge_source_mem hReach

/-- `reaches_target_mem` keeps reachable targets inside the finite topology. -/
theorem reaches_target_mem {a b : ν} (hReach : G.reaches a b) :
    b ∈ G.nodes :=
  EdgePath.target_mem G.edge_target_mem hReach

/-- `not_reaches_self` states strict reachability is irreflexive in a DAG. -/
theorem not_reaches_self (a : ν) :
    ¬ G.reaches a a :=
  G.acyclic a

/-- `not_reaches_reverse` rules out strict reachability in both directions. -/
theorem not_reaches_reverse {a b : ν} (hReach : G.reaches a b) :
    ¬ G.reaches b a := by
  intro hBack
  exact G.acyclic a (G.reaches_trans hReach hBack)

/-- `exists_reaches_minimal` finds a reachability-minimal member of a finite set. -/
theorem exists_reaches_minimal
    (nodes : Finset ν)
    (hNonempty : nodes.Nonempty) :
    ∃ node ∈ nodes, ∀ predecessor ∈ nodes, ¬ G.reaches predecessor node := by
  classical
  let nodeSet : Set ν := {node | node ∈ nodes}
  have hFinite : nodeSet.Finite := by
    simp [nodeSet]
  letI : IsStrictOrder ν G.reaches :=
    { irrefl := fun node => G.not_reaches_self node
      trans := fun _ _ _ hLeft hRight => G.reaches_trans hLeft hRight }
  have hWFOn : nodeSet.WellFoundedOn G.reaches := hFinite.wellFoundedOn
  rw [Set.wellFoundedOn_iff] at hWFOn
  have hSetNonempty : nodeSet.Nonempty := by
    rcases hNonempty with ⟨node, hNode⟩
    exact ⟨node, by simpa [nodeSet] using hNode⟩
  rcases hWFOn.has_min nodeSet hSetNonempty with ⟨node, hNode, hMinimal⟩
  refine ⟨node, by simpa [nodeSet] using hNode, ?_⟩
  intro predecessor hPredecessor hReach
  have hPredecessorSet : predecessor ∈ nodeSet := by
    simpa [nodeSet] using hPredecessor
  exact hMinimal predecessor hPredecessorSet ⟨hReach, hPredecessorSet, hNode⟩

/-! ## Relation Construction -/

section RelationConstruction

variable {ν : Type} [DecidableEq ν]

/-- `ofRelation` constructs a Pulse DAG from an endpoint-closed acyclic relation. -/
def ofRelation
    (relation : Cortex.Graph.Relation ν)
    (hEndpoints : Cortex.Graph.Relation.EdgeEndpointsInVertices relation)
    (hAcyclic : Cortex.Graph.Relation.Acyclic relation) :
    DAG ν :=
  { nodes := relation.vertices
    edge := Cortex.Graph.Relation.edgeBool relation
    edge_source_mem := fun hEdge =>
      Cortex.Graph.Relation.edgeBool_source_mem hEndpoints hEdge
    edge_target_mem := fun hEdge =>
      Cortex.Graph.Relation.edgeBool_target_mem hEndpoints hEdge
    acyclic := fun node hPath =>
      hAcyclic node (EdgePath.to_relationPath_edgeBool hPath) }

/-- `ofRelation_edge_true_iff` identifies the constructed DAG edge predicate. -/
theorem ofRelation_edge_true_iff
    (relation : Cortex.Graph.Relation ν)
    (hEndpoints : Cortex.Graph.Relation.EdgeEndpointsInVertices relation)
    (hAcyclic : Cortex.Graph.Relation.Acyclic relation)
    (source target : ν) :
    (ofRelation relation hEndpoints hAcyclic).edge source target = true ↔
      (source, target) ∈ relation.edges :=
  Cortex.Graph.Relation.edgeBool_true_iff relation source target

/-- `ofRelation_reaches_iff_path` identifies constructed DAG reachability. -/
theorem ofRelation_reaches_iff_path
    (relation : Cortex.Graph.Relation ν)
    (hEndpoints : Cortex.Graph.Relation.EdgeEndpointsInVertices relation)
    (hAcyclic : Cortex.Graph.Relation.Acyclic relation)
    (source target : ν) :
    (ofRelation relation hEndpoints hAcyclic).reaches source target ↔
      Cortex.Graph.Relation.Path relation source target :=
  EdgePath.edgeBool_iff_relationPath relation source target

end RelationConstruction

end DAG

end Cortex.Pulse
