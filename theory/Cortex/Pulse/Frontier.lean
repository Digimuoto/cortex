/-
# Pulse Runtime — Frontier Safety

Mechanization of the Pulse executor's frontier-safety invariant:

> For any reachable execution state `S`, the computed frontier `F(S)`
> contains only nodes whose dependencies are all terminal in `S`.

Together with the determinism axiom (`step_independent`), this gives
**verified concurrency**: any subset of the frontier may be executed
in parallel and the result is well-typed and deterministic up to
external sparks (LLM outputs, IO).

This file is currently a *scaffold*. Every theorem that carries real
content is admitted as an `axiom`; the structural definitions are
real and compile.

## Roadmap

1. Replace `NodeId`, `State`, `terminal`, `frontier` placeholders with
   the concrete shapes from `src/Cortex/Pulse/Plan.hs` and
   `src/Cortex/Pulse/Executor/Frontier.hs`.
2. Discharge `frontier_only_ready` (the headline invariant).
3. Discharge `step_independent` (parallel commutativity of frontier
   subsets).
4. Discharge `progress` (every non-terminal state has a non-empty
   frontier or is stuck-with-reason).

## References

- ADR 0014 — executor taxonomy.
- `docs/architecture/06-pulse-runtime.md` — substrate chapter.
- `docs/publications/paper-1-staged-reduction/manuscript.md` —
  staged reduction proof sketches.
-/

import Cortex.Graph.Core

namespace Cortex.Pulse

/-- Identifier for a node in a Pulse plan. Concretely a UUID on the
    Haskell side; here we keep it abstract to focus on the structure
    of the proof obligations. -/
abbrev NodeId := Nat

/-- The state of a node during execution. The full Haskell
    `RunOutcome` has more variants; we capture the lattice that
    matters for frontier safety. -/
inductive NodeState : Type where
  | pending     : NodeState     -- not yet scheduled
  | running     : NodeState     -- claimed, in flight
  | completed   : NodeState     -- terminal; produced a result
  | failed      : NodeState     -- terminal; produced an error
  | cancelled   : NodeState     -- terminal; pre-empted
  deriving Repr, DecidableEq

namespace NodeState

/-- A node is *terminal* iff no further transition is possible from it. -/
def terminal : NodeState → Bool
  | completed => true
  | failed    => true
  | cancelled => true
  | _         => false

/-- A node is *ready* iff it has not started and (separately) all of its
    dependencies are terminal. The "dependencies are terminal" half is
    a global predicate, modeled by `State.deps_terminal`. -/
def isPending : NodeState → Bool
  | pending => true
  | _       => false

end NodeState

/-- A run state: assignment from node IDs to their current node-state,
    plus the static dependency graph (the compiled circuit). -/
structure State where
  /-- Per-node state. -/
  status : NodeId → NodeState
  /-- Static dependency edges: `deps i = [j₁, …, jₙ]` means node `i`
      depends on each `jₖ`. Lifted from the compiled circuit. -/
  deps   : NodeId → List NodeId

namespace State

/-- All of `i`'s dependencies are terminal in `s`. -/
def depsTerminal (s : State) (i : NodeId) : Bool :=
  s.deps i |>.all (fun j => (s.status j).terminal)

/-- The frontier: every pending node whose dependencies are all
    terminal. Listed eagerly here; the Haskell side computes it lazily
    via the compiled-circuit reverse index. -/
def frontier (s : State) (nodes : List NodeId) : List NodeId :=
  nodes.filter (fun i => (s.status i).isPending && s.depsTerminal i)

end State

/-! ## Invariants and theorems (axiomatized) -/

/-- **Headline invariant.** Every node in the frontier has all its
    dependencies terminal. Trivial by the filter definition; recorded
    as a theorem for the proof tree to depend on. -/
theorem frontier_only_ready (s : State) (nodes : List NodeId) :
    ∀ i ∈ State.frontier s nodes,
      s.depsTerminal i = true := by
  intro i hi
  simp [State.frontier, List.mem_filter] at hi
  exact hi.2.2

/-- **Step independence.** Stepping any two distinct frontier nodes
    commutes. This is the property that licenses parallel execution
    of any subset of the frontier.

    Currently axiomatized: needs a concrete `step` definition and an
    accompanying determinism property over external sparks. -/
axiom step_independent
    (s : State) (nodes : List NodeId)
    (i j : NodeId)
    (hi : i ∈ State.frontier s nodes)
    (hj : j ∈ State.frontier s nodes)
    (hij : i ≠ j) :
  -- Placeholder shape: stepping i then j produces the same state as
  -- stepping j then i. Concrete definition pending `step : State →
  -- NodeId → State`.
  True

/-- **Progress.** Every non-terminal reachable state either has a
    non-empty frontier (so execution can advance) or is stuck with a
    structural explanation (cycle, missing executor, budget exceeded).

    Axiomatized; discharge requires the rewrite-admission story
    (`Cortex.Wire.Rewrite`). -/
axiom progress
    (s : State) (nodes : List NodeId) :
  -- Placeholder shape.
  True

/-- **Determinism modulo external sparks.** Given a fixed sequence of
    LLM outputs and IO results, two executions of the same plan from
    the same initial state produce the same final state.

    This is the audit-trail property that makes Pulse runs replayable.
    Axiomatized; discharge requires modelling the spark-stream and
    the executor taxonomy from ADR 0014. -/
axiom determinism_modulo_sparks
    (s₀ : State) (nodes : List NodeId) :
  -- Placeholder shape.
  True

end Cortex.Pulse
