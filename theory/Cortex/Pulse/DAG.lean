/-
# Pulse Kernel — Fixed DAG

This module gives the Paper 1 Pulse kernel its static topology model.

The live runtime stores materialized node identifiers and relation-style
edges. The proof kernel deliberately uses an extensional finite-node
model instead: a node type `ν`, a boolean edge predicate, and a strict
reachability relation with the DAG laws needed by the frontier and
failure-closure proofs.
-/

import Mathlib.Data.Finset.Basic

namespace Cortex.Pulse

/-- Fixed Pulse topology for the Paper 1 kernel.

`edge a b = true` means that `a` is a direct dependency of `b`.
`reaches` is strict reachability over one or more edges. The structure
packages the laws the rest of the kernel needs without committing the
model to UUIDs, database rows, or a concrete graph container. -/
structure DAG (ν : Type u) where
  /-- Finite set of materialized nodes in the topology. -/
  nodes : Finset ν
  /-- Direct dependency edge: source must complete before target can run. -/
  edge : ν → ν → Bool
  /-- Strict reachability through one or more dependency edges. -/
  reaches : ν → ν → Prop
  /-- Every direct edge is a reachability witness. -/
  edge_reaches : ∀ {a b : ν}, edge a b = true → reaches a b
  /-- Strict reachability is transitive. -/
  reaches_trans : ∀ {a b c : ν}, reaches a b → reaches b c → reaches a c
  /-- A DAG has no non-empty path from a node back to itself. -/
  acyclic : ∀ a : ν, ¬ reaches a a

namespace DAG

variable {ν : Type u} (G : DAG ν)

/-- `a` is a direct predecessor of `b`. -/
def predecessor (a b : ν) : Prop :=
  G.edge a b = true

/-- Direct edges are strict reachability witnesses. -/
theorem reaches_of_edge {a b : ν} (hEdge : G.predecessor a b) :
    G.reaches a b :=
  G.edge_reaches hEdge

/-- Strict reachability is irreflexive in a DAG. -/
theorem not_reaches_self (a : ν) :
    ¬ G.reaches a a :=
  G.acyclic a

/-- Strict reachability cannot hold in both directions. -/
theorem not_reaches_reverse {a b : ν} (hReach : G.reaches a b) :
    ¬ G.reaches b a := by
  intro hBack
  exact G.acyclic a (G.reaches_trans hReach hBack)

end DAG

end Cortex.Pulse
