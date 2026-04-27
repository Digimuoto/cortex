import Mathlib.Data.Finset.Basic

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

end DAG

end Cortex.Pulse
