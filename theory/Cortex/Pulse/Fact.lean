/-
# Pulse Kernel — Node Facts

Frontier workers produce node-local facts. The fixed-topology kernel only
needs the node key, the resulting status, and an optional output; payload
and failure detail contents remain abstract.
-/

import Cortex.Pulse.State

namespace Cortex.Pulse

/-- Abstract worker outcome for a single node. -/
inductive NodeOutcome (payload : Type v) : Type v where
  | succeeded : payload → NodeOutcome payload
  | skipped : NodeOutcome payload
  | suspended : NodeOutcome payload
  | failed : NodeOutcome payload
  | timedOut : NodeOutcome payload
  | cancelled : NodeOutcome payload
  | shutdown : NodeOutcome payload
  | runCancelled : NodeOutcome payload
  | rewritten : payload → NodeOutcome payload
  deriving Repr

namespace NodeOutcome

variable {payload : Type v}

/-- Status contributed by an outcome. -/
def status : NodeOutcome payload → NodeStatus
  | succeeded _ => NodeStatus.completed
  | skipped => NodeStatus.skipped
  | suspended => NodeStatus.waiting
  | failed => NodeStatus.failed
  | timedOut => NodeStatus.failed
  | cancelled => NodeStatus.interrupted
  | shutdown => NodeStatus.interrupted
  | runCancelled => NodeStatus.interrupted
  | rewritten _ => NodeStatus.rewritten

/-- Optional output contributed by an outcome. -/
def output : NodeOutcome payload → Option payload
  | succeeded value => some value
  | rewritten value => some value
  | skipped => none
  | suspended => none
  | failed => none
  | timedOut => none
  | cancelled => none
  | shutdown => none
  | runCancelled => none

end NodeOutcome

/-- Durable fact emitted for one node. -/
structure NodeResult (ν : Type u) (payload : Type v) where
  /-- Node whose state is updated by this fact. -/
  node : ν
  /-- Abstract outcome for the node. -/
  outcome : NodeOutcome payload

namespace NodeResult

variable {ν : Type u} {payload : Type v}

/-- Apply a node-local fact to the extensional graph state. -/
def applyNodeFact [DecidableEq ν]
    (result : NodeResult ν payload)
    (state : GraphState ν payload) : GraphState ν payload where
  status := fun n =>
    if n = result.node then result.outcome.status else state.status n
  output := fun n =>
    if n = result.node then result.outcome.output else state.output n

/-- Facts for distinct nodes commute because they update disjoint keys. -/
theorem applyNodeFact_comm [DecidableEq ν]
    (r1 r2 : NodeResult ν payload)
    (state : GraphState ν payload)
    (hDistinct : r1.node ≠ r2.node) :
    applyNodeFact r1 (applyNodeFact r2 state) =
      applyNodeFact r2 (applyNodeFact r1 state) := by
  have hDistinctSymm : r2.node ≠ r1.node := by
    intro hEq
    exact hDistinct hEq.symm
  ext n
  · by_cases h1 : n = r1.node
    · by_cases h2 : n = r2.node
      · exact False.elim (hDistinct (by rw [← h1, ← h2]))
      · simp [applyNodeFact, h1, hDistinct]
    · by_cases h2 : n = r2.node
      · simp [applyNodeFact, h2, hDistinctSymm]
      · simp [applyNodeFact, h1, h2]
  · by_cases h1 : n = r1.node
    · by_cases h2 : n = r2.node
      · exact False.elim (hDistinct (by rw [← h1, ← h2]))
      · simp [applyNodeFact, h1, hDistinct]
    · by_cases h2 : n = r2.node
      · simp [applyNodeFact, h2, hDistinctSymm]
      · simp [applyNodeFact, h1, h2]

end NodeResult

end Cortex.Pulse
