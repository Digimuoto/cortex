---
title: Ideas
description: Research ideas surfacing from paper iterations on the frontier algebra
---

# Ideas surfacing from paper iterations

## Idea 1: Closed states as a Boolean algebra

The set of closed states (where `propagateFailure gs = gs`) is closed under
the accumulate operation: if gs is closed and we accumulate a new fact and
re-close, the result is still closed. This means closed states form a
sub-monoid of GraphState under accumulation+closure. Is there additional
algebraic structure (meet, complement) that would make this a Boolean algebra
or a Heyting algebra? If so, it would give us a logic over graph states.

## Idea 2: The observation schedule as a refinement relation

Sequential and concurrent execution produce the same final state but different
intermediate observations. This is a refinement relation: the sequential path
is a refinement of the concurrent path (it exposes more intermediate states).
Could this be formalized as a simulation relation between two transition
systems? That would give us a clean proof that sequential and concurrent
execution are observationally equivalent at frontier boundaries.

## Idea 3: The persistence safety theorem generalizes beyond failure

The theorem says: "closure idempotency makes incremental persistence safe."
But this isn't specific to failure propagation. Any closure operator on the
graph state — not just failure propagation — would give the same safety
property. What if we had multiple closure operators (failure propagation,
signal resolution, resource accounting) composed? The composition of closure
operators is a closure operator iff they commute. This gives a precise
criterion for adding new "consequence derivation" phases.

## Idea 4: The forward/reset partition suggests a session type

Forward outcomes advance a node through a typed session:
  Pending → Running → {Completed(v), Failed(e), Skipped, Waiting(s)}

Reset outcomes break the session. If we modeled node execution as a session
type, the forward/reset distinction would be enforced by the type system.
Workers would be *unable* to produce reset outcomes — only the coordinator
(via cancellation/shutdown) could. This would make the constitutional
restriction on workers into a type-level guarantee.

## Idea 5: classifyGraphState as a Brzozowski derivative

The classification of a graph state is essentially: "given the current state,
what language of future executions is possible?" Progressing = non-empty
language. Settled = empty language (done). Suspended = blocked until input.
Stuck = empty language (error). This is analogous to the Brzozowski derivative
of a regular language: the derivative of a language L with respect to a
symbol a is {w | aw ∈ L}. The frontier is the set of "next symbols."

This is probably too speculative for any of the three papers, but it suggests
a connection to language theory that might be interesting for a deeper
theoretical treatment.

## Idea 6: The three-phase pattern as a design pattern for other systems

The accumulate-close-classify pattern is not specific to workflow execution.
It applies to any system where:
1. Multiple independent agents produce local facts
2. Those facts have global consequences that are computed centrally
3. The system needs to make a lifecycle decision based on the closed state

Examples:
- Distributed consensus (votes are facts, quorum is closure, decision is classification)
- Build systems (compilation results are facts, dependency propagation is closure, build status is classification)
- Game state (player actions are facts, physics resolution is closure, game state classification is classification)

This could be a separate short paper or blog post — "the accumulate-close-classify pattern."

## Idea 7: simulateRun as a test oracle and specification

simulateRun is a pure function that runs the entire runtime lifecycle
with no IO. It takes a WorkerOracle (NodeId → Inputs → NodeOutcome) and
produces the complete wave history + final StepResult.

This has several implications:

a) It's a **test oracle**: any behavior observed in the real IO executor
   should match what simulateRun produces given the same oracle. We could
   property-test this: run simulateRun with a deterministic oracle, then
   run the real executor with the same stage actions, and compare final
   graph states.

b) It's a **specification**: the Lean 4 mechanization can target
   simulateRun directly as the executable specification. The Haskell
   code is the implementation; simulateRun is the spec; Lean proves
   properties of the spec.

c) It enables **what-if analysis**: before executing a real graph, run
   simulateRun with various failure scenarios to predict behavior.
   "If node B fails, what happens?" becomes a pure function call.

d) It's a **fuzzer target**: generate random oracles (with random
   success/failure/suspension per node) and verify that simulateRun
   always terminates and produces a consistent final state.

## Idea 8: The algebra surface area is now measurable

The pure algebra kernel is exactly 5 named functions:
  readyNodes → reduceFacts → propagateFailure → classifyGraphState
  (composed as applyFrontierResults)

Plus the simulation: simulateRun.

Everything else is IO glue. This ratio is measurable:
- Graph.hs: ~1100 lines, 0 IO types, 60 pure functions
- Executor.hs: ~1700 lines, the IO coordinator

The "purity ratio" of the runtime is ~40% pure algebra by line count.
The semantic ratio is higher: all lifecycle decisions live in the pure
layer. The IO layer is persistence, logging, and concurrency machinery.

This metric could be tracked over time. As extensions are added (graph
rewriting, quorum dependencies), the purity ratio should stay high or
increase — if it drops, the extension is leaking IO into the algebra.

## Idea 9: Rewrite materialization watermark as a projection checkpoint

This idea is now large enough to justify a dedicated plan:
`../../Roadmap/Plans/rewrite-materialization-and-recovery.md`.

The rewrite-capable runtime now persists append-only rewrite lineage plus a
monotone materialization watermark (`applied_rewrite_id`) on graph state.
This is a useful abstraction boundary:

- lineage = immutable structural history
- watermark = "all rewrites up to here are reflected in the current materialized graph"

That is more precise than saying the system "just replays the log", and it is
lighter than full graph snapshots after every accepted rewrite. The concept
looks a lot like a projection checkpoint in event-sourced systems, where the
read model is rebuilt from an append-only stream up to a known durable offset.

Possible write-up directions:
- Rewrite materialization and recovery plan (`DIG-433`): recovery semantics and determinism burden
- a shorter design note comparing rewrite-watermark recovery with event-sourced
  projection rebuilds

## Idea 10: Local graph substitution and process migration are different extension classes

This boundary is also now part of the rewrite-materialization track, not just a parked note.

The current rewrite model is still local graph substitution:
- rewrite a node boundary
- materialize the new local topology
- resume deterministically from the new boundary

Future planner/operator rewrites may want broader structural changes that move
or reinterpret already-executed regions. That is no longer "just another
rewrite constructor"; it starts to look like dynamic process migration with an
explicit state-mapping or history-equivalence problem.

This suggests a useful research boundary:
- local rewrites can be handled by substitution + lineage + watermark
- non-local rewrites may require migration semantics, not just replay

Possible write-up directions:
- Paper 2 (`DIG-432`): extension boundary of the algebra
- Rewrite materialization and recovery plan (`DIG-433`): recovery and migration semantics for broader graph changes
