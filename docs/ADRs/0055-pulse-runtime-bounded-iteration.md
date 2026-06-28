---
title: "ADR 0055 - Pulse Runtime-Bounded Iteration"
description:
  "Classifies runtime-dynamic repetition as Pulse-admitted certified self-append of finite kernels,
  not Wire graph expansion, CorePure looping, or executor-hidden orchestration."
sidebar:
  label: "0055. Runtime-bounded iteration"
  order: 55
status: proposed
date: 2026-05-08
superseded_by: null
related:
  - docs/Architecture/04-graph-and-circuit.md
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/pure-execution.md
  - docs/Reference/Pulse/schema.md
  - docs/ADRs/0003-pulse-service-and-host-action-boundary.md
  - docs/ADRs/0005-budgeted-rewrite-admission-and-materialization.md
  - docs/ADRs/0037-wire-latent-structural-control.md
  - docs/ADRs/0043-pulse-in-memory-runner.md
  - docs/ADRs/0046-wire-compile-time-graph-forms.md
  - docs/ADRs/0047-wire-frontier-linearity-and-precedence.md
  - docs/ADRs/0048-wire-make-bounded-node-generation.md
  - docs/ADRs/0050-wire-corepure-output-residue.md
  - docs/ADRs/0056-admission-modes-witnessed-and-gas.md
  - docs/ADRs/0057-wire-latent-branch-witnessing-and-closure-charging.md
  - docs/ADRs/0058-pulse-atomic-suspend-settlement.md
  - docs/ADRs/0059-durable-external-call-frontiers-on-pulse.md
---

# ADR 0055 - Pulse Runtime-Bounded Iteration

## Status

Proposed - this ADR names the runtime boundary and required model for data-dependent iteration. It
does not add Wire syntax by itself.

This revision keeps the original ADR's policy shell - explicit loop policy, finite bounds, durable
lineage, cancellation, and non-silent exhaustion - but changes the target execution mechanism. The
runtime mechanism under design is **certified self-append**: Pulse realizes iteration by repeatedly
admitting fresh `AppendAfter` instances of a finite kernel under a frontier-shape invariant. The
older `LoopFrame` / `LoopState` side-trace sketch is no longer the preferred mechanism because it
would duplicate the rewrite log's history, determinism, and replay obligations.

## Context

Wire has two deliberately separate repetition pressures:

1. **Source repetition**, where a statically known count expands graph shape before lowering.
2. **Runtime repetition**, where a finite kernel should execute several times because runtime data
   says there is more work.

ADR 0046 and ADR 0048 keep source graph construction static: forms expand before Pulse execution,
and `make(N, K)` requires a compile-time-resolvable `N`. ADR 0050 keeps CorePure non-recursive and
authority-free; input-dependent CorePure may compute values at runtime, but it may not introduce
loops, inspect Pulse state, call executors, or create topology.

At the same time, ordinary programs need runtime-sized finite work:

- read chunks until EOF, subject to a maximum item count;
- drain a queue until it is empty, subject to a maximum batch size;
- retry or refine a bounded analysis while a runtime score remains below a threshold;
- let an upstream node propose a count, then clamp or validate that count before executing a kernel.

The tempting spelling is to let an executor output drive a source-level form:

```text
# not admitted by this ADR
decide_bound -> repeat(kernel, bound)
```

That cannot work as Wire graph expansion. By the time `decide_bound` produces a value, the source
graph has already elaborated, port matching has already been checked, and topology witnesses have
already been built. Feeding runtime values back into source graph shape would make source
elaboration depend on execution.

The other tempting spelling is a sealed executor that internally loops until it decides to stop and
then emits one downstream value. That is acceptable only as executor-local implementation detail,
not as the substrate's graph-level iteration model. The discriminator is exposure: if downstream
consumers or operators need per-iteration lineage, frontier transitions, checkpointable progress, or
typed exhaustion, the work must lower to Pulse-owned runtime iteration. A truly unbounded sealed
loop does not fit the downstream dataflow model: downstream nodes can advance only after a completed
output exists.

## Decision

Pulse should classify **runtime-bounded iteration** as a runtime-admitted execution feature: a
finite Wire/Circuit kernel may be repeated under a runtime-dynamic bound only when Pulse can
enforce, checkpoint, and record a finite per-run budget.

The target realization is **certified self-append**. Iteration `i + 1` is a fresh kernel instance
appended after iteration `i`'s loop-carried continuation frontier with the existing rewrite
alphabet. In the v1 slice, that step is `AppendAfter` after one composite continuation-state node. A
kernel whose loop-carried continuation is produced by more than one exit node is not admitted by
this ADR's first slice; supporting it would require a separate boundary-law ADR and runtime-version
bump. The graph grows monotonically. It never gains a back-edge, revisits an existing node, or
mutates prior history. The loop-carried state is visible as settled graph output from earlier
iterations and as the frontier consumed by the next admitted append.

A per-iteration append of a previously admitted, compile-bounded kernel is witnessed under ADR 0056:
asserted, metered, and gas-neutral for `rbRewriteOpsMax`, `rbAddedNodesMax`, `rbAddedEdgesMax`,
`rbAddedDepthMax`, and `rbFrontierDeltaMax`. The loop's iteration cap is the gate for the loop step
itself. Only open topology proposed inside the kernel body re-enters rewrite gas at that body's own
rewrite boundary.

Runtime-bounded iteration is not source graph expansion, not CorePure recursion, and not an
unbounded background process hidden inside an ordinary executor. The source graph remains finite;
the runtime count never changes source elaboration or source node identity. Materialized iteration
instances receive deterministic iteration-indexed identities through rewrite admission. The repeated
body is a finite admitted kernel. Pulse owns the iteration policy, budget enforcement,
checkpoint/resume behavior, cancellation boundary, lineage, and failure semantics.

This ADR does not choose final surface syntax. Any future syntax or executor-like spelling must
lower to the same runtime concept:

```text
upstream value -> CorePure clamp/validate -> Pulse runtime-bounded kernel execution
```

The upstream value may be executor output. CorePure may derive or clamp the bound as ordinary
authority-free value adaptation. Pulse then admits or rejects the requested iteration against
policy. The value never feeds Wire source elaboration.

The required runtime concept is:

```text
RuntimeIteration =
  finite admitted kernel
  + loop policy
  + requested runtime bound or guard
  + frontier-shape witness
  + deterministic iteration namespace
  + admitted self-append lineage
  + optional additive snapshots
```

If any of those fields is missing, the mechanism is not this ADR's feature. It is either static
source elaboration, CorePure value computation, an ordinary executor-local algorithm, a child-run
design, an open rewrite proposal without iteration policy, or an unbounded service loop at the
Pulse/host process boundary.

## Mental Model

The safe model is **bounded kernel repetition inside the runtime process loop, realized as
frontier-preserving admitted graph growth**.

| Layer                      | Repetition shape                                      | Owner              | Rule                                                                  |
| -------------------------- | ----------------------------------------------------- | ------------------ | --------------------------------------------------------------------- |
| Pulse/host process         | scheduler, poller, service, or daemon loop            | Pulse or host      | May be long-lived; not an ordinary downstream-producing graph node    |
| Wire source elaboration    | `make(N, K)`, forms, future static repeat             | Wire compiler      | Count and graph shape are static before Pulse execution               |
| CorePure                   | value derivation, filtering, clamping, record shaping | CorePure evaluator | Total, authority-free, non-recursive, no host effects or topology     |
| Runtime-bounded iteration  | self-append fresh kernel instances under policy       | Pulse              | Runtime count is data; finite budget, checkpoints, and lineage govern |
| Executor-local computation | internal algorithm inside one stage action            | registered action  | Allowed as local authority; not graph-level iteration unless exposed  |

The important separation is not "loops bad, no loops." The separation is: **only Pulse may turn
runtime data into repeated graph-level work, and only by admitting bounded, auditable graph
growth**.

## Boundary Rules

### Runtime bound

A runtime-dynamic count or guard is admissible only when paired with an enforceable finite budget.
The budget must be stored and consumed by Pulse-owned runtime state, not merely promised by an
executor prompt or returned in an unchecked payload.

Examples:

| Shape                                      | Status under this ADR                                      |
| ------------------------------------------ | ---------------------------------------------------------- |
| `repeat kernel 10`                         | Source-level static repetition candidate, outside this ADR |
| `repeat kernel bound` where `bound <= cap` | Runtime-bounded Pulse iteration                            |
| `repeat kernel until eof, max = cap`       | Runtime-bounded Pulse iteration                            |
| `repeat kernel until model says stop`      | Runtime-bounded only with an explicit cap and policy       |
| `repeat kernel forever`                    | Not a downstream-producing graph node                      |

A guard such as EOF, score threshold, or queue emptiness is a stopping condition, not by itself a
resource bound. The runtime policy must still include a finite cap or another finite resource
witness that Pulse can enforce.

The runtime-proposed bound is data. It may be absent, malformed, too large, stale, or adversarial.
Admission must normalize or reject it before the first body execution. The admitted effective bound
is the minimum of the validated request and the configured policy cap, unless the policy chooses a
stricter rule. A request that validates or clamps to a zero effective bound is rejected before the
first body execution: a runtime-bounded loop must execute its body at least once. An empty stopping
condition — a queue that is already drained, for example — is the kernel guard's concern, signalled
at the first iteration, and is not expressed as a zero bound.

### Kernel boundary

The repeated body must be a finite admitted kernel. Its continuation boundary is linear and
frontier-shape-preserving:

```text
state_in + item? -> state_out + emitted* + guard + terminal?
```

Each iteration consumes the current continuation state at most once and produces the next
continuation state at most once. This is the runtime analogue of ADR 0047's linear frontier rule,
not a license for graph cycles or implicit copying.

The stronger self-append invariant is:

```text
exit_frontier(i) == input_frontier(i + 1)
```

where equality is by declared frontier shape, not by node identity. The appended kernel consumes the
previous instance's loop-carried exit frontier and exposes an identically shaped loop-carried exit
frontier for the next step. The materialized graph grows; the boundary presented to the loop driver
does not.

The kernel declaration is the source of truth for that frontier-shape witness. The natural equality
model is multiset equality on ADR 0047's typed frontier roles, labels, and contracts, restricted to
the loop-state role and with input/output direction transposed across the step boundary. Current
`SubgraphSpec` values carry entry and exit node ids, not a port-shape object, and rewrite
`frontierDelta` is a breadth meter rather than a shape check. Durable lineage should therefore store
a reference or hash of the admitted kernel declaration's witness, not invent an independent
frontier-shape convention.

The kernel may expose ordinary input/output contracts, but its external interface must say which
ports are:

- loop state consumed and produced across iterations;
- per-iteration item input;
- per-iteration emitted output;
- terminal summary output;
- runtime guard or continuation signal.

The loop-carried continuation crossing the iteration boundary is the single `state_out` producer of
iteration `i`; iteration `i + 1` is anchored after that one continuation-state node. The kernel's
full exit frontier may still have breadth greater than one, such as `state_out`, emitted outputs,
guard output, and terminal output. Emitted, guard, and terminal outputs are settled downstream
outputs, not the continuation consumed by the next append. A kernel whose loop-carried state is
produced by multiple exit nodes is inadmissible as a self-append loop body in the first slice.

The transition shape is:

```text
(i, state_i, item_i?)
  -- admitted kernel execution -->
(i + 1, state_(i+1), emitted_i*, guard_i, terminal_i?)
```

Pulse must preserve these invariants:

- `i` is monotone and cannot exceed the admitted effective bound.
- `state_i` has exactly one predecessor except at `i = 0`.
- `state_(i+1)` has exactly one producer: the completed `i`th kernel execution.
- the appended kernel's exposed continuation boundary has the same shape at every step.
- emitted outputs are either accumulated, streamed, or reduced according to explicit policy.
- checkpoint and provenance identify which iterations completed before resume.
- source graph topology and source node identities do not depend on the runtime count.
- materialized iteration node identities are deterministic, iteration-indexed, and namespace-safe.

The deterministic namespace seed is decoupled from the topological anchor. Fresh iteration-local ids
use a flat iteration-indexed namespace such as `loop_root:iter_<i>:<local>`, not recursive prefixes
based on the prior instance's materialized node id. Admission must also bound namespace segment size
so adversarial local ids cannot exceed storage or identifier limits independent of the iteration
count.

An implementation may realize a kernel as one stage, a sealed local action, or child runs, but the
observable runtime contract is the same: the admitted lineage must explain which iterations
happened, which frontier each step consumed and produced, and why the loop stopped.

### Loop policy

A `LoopPolicy` or equivalent carrier must be explicit before runtime-bounded iteration is admitted.
At minimum it must include:

- maximum body executions;
- how runtime-requested bounds are decoded, clamped, rejected, or defaulted;
- budget-exhaustion behavior;
- checkpoint cadence;
- cancellation points;
- deterministic namespace policy for fresh iteration instances;
- certified loop-kernel witness/digest binding the gas-neutral step to the admitted finite kernel
  template;
- whether the kernel is rewrite-closed or may propose open topology, and if so the shared or
  per-iteration rewrite gas law for those body-local proposals;
- emitted-output aggregation policy;
- partial-result contract, if partial completion is allowed;
- fallback contract, if fallback completion is allowed;
- whether the kernel may propose rewrites.

Prompt text, model instructions, executor config, or downstream product policy are not sufficient
unless they lower to this Pulse-owned carrier.

With the v1 flat namespace convention, `iter_0` is the seed body execution and counts against the
maximum body-execution cap. A loop admitted with maximum body executions `N` may materialize at most
`iter_0` through `iter_<N-1>`; appending `iter_<N>` is rejected.

The self-append step is proposed through the existing stage result path: the kernel's settled
loop-exit completion emits a dedicated witnessed loop-step result,
`StageLoopStep(output, LoopStepWitness, AppendAfter stateOutNode nextKernelSpec)`. This is a
distinct `StageResult` constructor rather than an overloaded `StageRewrite`: it lets the executor
route the step to gas-neutral (witnessed) admission under ADR 0056 after checking the live
frontier-shape witness, certified kernel witness, deterministic namespace, and run-local loop
control against the registered loop declaration. That declaration is a registration of static
`LoopPolicy` plus admitted effective bound, not the static policy alone; the mutable control
decrements the remaining self-append budget before the row is admitted. The result remains a
stage-proposed result admitted in the ordinary frontier wave — not a new Pulse-internal proposer.
(An ordinary planner `StageRewrite` from a rewrite-closed loop kernel is rejected rather than
treated as the loop step.) A suspending iteration follows the existing exclusive sequence:
`StageSuspend`, resume, `StageComplete` or `StageLoopStep`; a stage cannot suspend and rewrite in
the same outcome.

### Completion and budget exhaustion

A runtime-bounded iteration node completes only when it reaches a terminal condition under its
finite budget. Budget exhaustion is not silent success. The loop policy must choose one of the
explicit outcomes:

- fail the run with a typed budget-exhaustion error;
- complete with an explicitly marked partial result;
- degrade to a configured fallback result.

The default should be failure unless the node's contract declares a partial-result shape. The
ordinary success shape must not be reused for budget exhaustion, cancellation, or fallback; that
would make downstream consumers unable to distinguish "finished" from "stopped safely."

### Runtime lineage and recovery

Durable Pulse must be able to resume from persisted state without replaying completed iterations
incorrectly. The minimal durable lineage is:

- admitted effective bound and policy version;
- current iteration index, equal to the count of loop-kernel append rewrites materialized through
  the rewrite materialization watermark and reconciled on resume;
- frontier-shape witness reference or hash;
- last completed iteration frontier reference;
- admitted append rewrite ids for completed iterations and admitted-beyond-watermark appends;
- witnessed append replay metadata per rewrite row: policy version, admitted effective bound,
  `remaining_before`, `remaining_after`, and the step frontier witness checked at admission;
- deterministic namespace seed;
- emitted-output aggregation state;
- terminal reason, when present;
- budget-exhaustion, cancellation, fallback, or partial-result marker, when present.

Replay cost may require realized-circuit snapshots. A snapshot is valid only when it is additive and
validator-checked: it records a deterministic, order-stable fold of iterations whose appends are
materialized at or below the rewrite materialization watermark and lets recovery resume from that
watermark without mutating or erasing earlier lineage. If admitted append lineage exists beyond the
watermark, recovery first deterministically finishes materialization in `rewrite_id` order before
continuing the fold. A snapshot is an artifact over history, not a replacement for history, and the
fold need not be commutative or associative when it is re-derived from the same ordered prefix.

For irreversible host actions, the checkpoint boundary must compose with ADR 0003 idempotency keys
derived from the iteration namespace or append `rewrite_id`, and with ADR 0058 atomic settlement.
Materialization replays the admitted structural diff, not the stage action. The duplication risk is
post-resume scheduling of host work whose completion was not durably recorded. If that cannot be
guaranteed for a kernel, the kernel is not admissible as a durable runtime-bounded iteration body
under this ADR.

If an iteration parks on an external call, ADR 0059's external-call attempt record owns the
in-flight effect status while the rewrite materialization watermark owns which iteration structures
exist in the graph. Resume joins those two records: materialize any admitted-beyond-watermark append
lineage, then reconcile the parked attempt record before scheduling more loop work.

### Runtime ownership

Pulse owns:

- admitting the requested dynamic bound against configured policy;
- tracking remaining iteration budget;
- admitting each self-append step as the loop-exit `StageLoopStep` under the existing rewrite
  alphabet and frontier-shape witness;
- checking cancellation between iterations, before irreversible host actions, and at parked
  external-call awaits, including teardown of the `NodeWaiting` row and ADR 0059 attempt record when
  cancellation wins;
- checkpointing enough state to resume without re-running completed iterations incorrectly;
- recording iteration lineage, emitted outputs, terminal outcome, and budget exhaustion;
- deciding how iteration interacts with rewrite budgets if the body can propose open topology.

Wire owns only the finite source kernel and value-level preparation of the requested bound.

## Examples

### Queue drain

A node reads up to `maxItems = 100` queue messages. The guard is "queue empty." The budget is `100`.
Completion is success only if the queue becomes empty before or at the cap. If the cap is exhausted
while work remains, policy chooses typed budget exhaustion or an explicitly marked partial batch.

### Paginated ingest

A kernel fetches one page and returns `{ nextCursor, items, state }`. The loop stops when
`nextCursor = null` or `maxPages` is reached. Emitted items are aggregated according to policy. On
resume, completed page indexes and cursor state must prevent duplicate page effects.

### Bounded refinement

An upstream node proposes `requestedRounds = 12`. CorePure clamps or validates the request against
local value rules. Pulse admits `effectiveRounds <= policy.maxRounds`. Each iteration consumes the
previous draft and score, emits an optional candidate, and stops when `score >= threshold` or the
budget is exhausted.

### Poll external job

A kernel checks external job status. The guard is "job complete." The budget is a maximum poll count
or duration. For synchronous polling, cancellation is checked between polls. For durable
submit/park/resume polling, cancellation is checked at the parked-await boundary and must settle the
waiting graph state plus the ADR 0059 attempt record. A timeout-shaped outcome is not ordinary
success unless the node contract explicitly declares a timeout/fallback result.

### Runtime-sized fan-in without source topology

A kernel may process N runtime items and aggregate them into one output value. It does not create N
Wire source nodes and it does not make source elaboration depend on N. If the program needs visible
per-item graph work, Pulse introduces fresh materialized vertices through admitted self-append
rewrites under this ADR's policy, namespace, and frontier-shape rules.

## Counterexamples And Rejections

These are not edge cases to tolerate; they are the adversarial tests the model must reject or mark
explicitly.

| Candidate                                           | Why it fails this ADR                                                    | Repair direction                                      |
| --------------------------------------------------- | ------------------------------------------------------------------------ | ----------------------------------------------------- |
| Runtime value drives `make(bound, K)`               | Source topology would depend on executor output                          | Use static `make`, admitted rewrite, or runtime loop  |
| CorePure `while` computes until queue empty         | CorePure would gain recursion and host/runtime observation               | Move observation behind a registered executor kernel  |
| Executor prompt says "loop at most 10 times"        | Prompt text is not an enforceable Pulse budget                           | Lower to `LoopPolicy` with stored remaining budget    |
| Guard `until eof` with no cap                       | EOF is a stopping condition, not a resource bound                        | Add finite cap or finite resource witness             |
| Model decides whether to continue with no hard cap  | The model may never stop or may ignore policy                            | Add explicit cap and typed exhaustion outcome         |
| Budget exhaustion returns normal success payload    | Downstream cannot distinguish complete from partial/fallback             | Declare partial/fallback contract or fail             |
| Crash repeats iteration 7 after irreversible action | Durable lineage/checkpoint was too weak for the action                   | Move checkpoint boundary or reject durable admission  |
| Loop body emits unbounded list in memory            | Iteration budget does not bound output accumulation                      | Add aggregation/window/output-size policy             |
| Nested loops multiply work silently                 | Local caps do not state global resource consumption                      | Require nested admission or product/global budget law |
| Loop body proposes rewrites under unspecified gas   | Rewrite and iteration authorities interact without a shared law          | Reject v1 or define shared/per-iteration budgets      |
| Self-append step consumes open rewrite gas          | Run-global rewrite gas may fail before the loop cap with the wrong error | Witness the admitted kernel append under ADR 0056     |
| Runtime count changes source ids or source hash     | Source identity is already elaborated and witnessed                      | Use deterministic materialized append ids             |
| Loop self-append changes frontier shape each step   | Per-step port leakage breaks bounded liveness and proof composition      | Reject or require a different boundary law            |
| Crash re-emits iteration 7's append                 | Retry advanced the materialized index twice                              | Freshness rejects duplicate namespace/rewrite lineage |
| Snapshot rewrites away old iterations               | History mutation breaks replay, provenance, and monotone graph growth    | Add validator-checked snapshots as additive artifacts |
| Local runner succeeds without durable checkpoints   | Ephemeral success does not prove durable recovery or cancellation safety | Report missing durable guarantees                     |

## Relationship To Existing Runtime Features

Runtime-bounded iteration is similar to rewrite admission in one important respect: runtime
authority is finite and explicit. ADR 0005 made rewrite budget a runtime law rather than a prompt
convention. This ADR applies the same discipline to repetition and, in its target mechanism, reuses
the existing admitted rewrite alphabet instead of inventing a loop-specific graph mutation API.

The self-append mechanism is narrower than arbitrary rewrite planning. A planner-authored rewrite
may propose new topology whose shape is unknown before the proposal returns. Runtime iteration
chooses a previously admitted kernel, appends fresh instances of that kernel, and checks the
frontier-shape invariant at every step. Open rewrite authority inside the kernel remains a separate
policy decision governed by ADR 0056 and ADR 0057's admission-mode split. The loop step itself is
not open rewrite authority when it appends the previously admitted compile-bounded kernel; it is a
witnessed materialization of that certified shape.

Runtime-bounded iteration is also distinct from child workflows. A durable implementation may
realize large or long-running iterations through child runs or sub-runs, but parent-child lifecycle
semantics are an implementation and API decision layered under this ADR. If child runs are used, the
same budget, cancellation, checkpoint, and provenance obligations still apply.

The in-memory Pulse runner from ADR 0043 may support runtime-bounded iteration for local execution,
but it must report which durable guarantees are absent. Local success does not prove durable lease
recovery, service API visibility, signal resume, or cancellation propagation. In particular, it can
exercise only in-process self-append behavior unless backed by durable admit, materialize,
watermark, and resume recovery.

Runtime-bounded iteration is also distinct from stage retry. A retry policy re-executes the same
stage after a retryable failure from the same checkpointed input. Runtime-bounded iteration advances
a successful continuation state across body executions. A "refinement loop" is iteration only when
each successful body execution produces the next state; retry remains the failure-recovery surface.

## Alternatives considered

- **Let runtime values drive Wire graph expansion** - rejected because source elaboration, port
  matching, and proof witnesses happen before executor output exists. This would make topology
  depend on execution.
- **Add loops to CorePure** - rejected because CorePure is the deterministic authority-free value
  layer. ADR 0050 explicitly keeps loops, recursion, host callbacks, and executor authority out of
  CorePure.
- **Hide iteration inside ordinary executors** - rejected as the general rule because Pulse would
  not own per-iteration budget, checkpoints, cancellation, provenance, or partial progress. A
  bounded executor-local algorithm is still allowed as an implementation detail, but it is not a
  graph-level runtime iteration feature.
- **Use a separate `LoopFrame` / `LoopState` execution trace** - rejected for the target design. A
  side trace would duplicate the rewrite log's history, replay, determinism, and provenance
  obligations. The policy shell survives, but the preferred mechanism is monotone admitted graph
  growth.
- **Add a new loop rewrite primitive** - rejected for the first slice. The loop step should be an
  ordinary `AppendAfter` for single-anchor continuation loops. If a loop-carried continuation spans
  multiple exit nodes, that resistance is design feedback and needs a separate boundary law plus a
  runtime-version bump.
- **Treat runtime iteration as stage retry** - rejected because retry is failure recovery for the
  same stage input, while iteration is successful state transition under a continuation boundary.
- **Require all iteration counts to be static** - rejected because finite runtime-sized work is
  common and useful. A queue drain or chunk sweep can be finite without the exact count being known
  during source elaboration.
- **Accept unbounded downstream-producing loops** - rejected because a downstream graph node
  requires a completed output. A truly unbounded service loop belongs to the Pulse or host process
  boundary, not to an ordinary dataflow node.

## Consequences

### Positive

- Runtime-sized finite work has a canonical home without making Wire or CorePure Turing-complete.
- Executor outputs can influence iteration as data, while graph shape remains source-elaborated and
  finite.
- Pulse can enforce iteration budgets, checkpoint progress, expose operator visibility, and preserve
  cancellation semantics.
- The design extends the same bounded-authority discipline already used for rewrite materialization.
- The tail-linearity intuition from bounded source repetition carries over as a runtime
  frontier-shape invariant rather than as graph recursion.
- Loop-carried values and per-iteration provenance stay in materialized graph lineage and the
  rewrite log, avoiding the older `LoopFrame` / `LoopState` side trace's duplication of history,
  replay, determinism, and provenance.
- The runtime keeps only a minimal typed control carrier for policy version, admitted effective
  bound, iteration index, remaining iteration budget, aggregation state, and terminal outcome; these
  fields are authoritative control state, not graph-derived loop-carried values.

### Negative

- Pulse needs a new typed carrier for iteration policy, remaining budget, frontier shape, and
  iteration outcome.
- Durable execution needs additional history/provenance rows or events to explain iteration
  progress.
- Each step persists the loop-carried anchor output in rewrite lineage, so durable retention can
  grow as `O(N * stateSize)`, not just as `O(N)` row count.
- Long loops need additive realized-circuit snapshots or recovery may become too expensive;
  snapshots compress replay time but do not truncate or mutate the append-only rewrite log.
- Local runner parity becomes more nuanced because local iteration can execute without durable
  checkpoints or cross-process recovery.
- The proof track must compose append-continuation boundary preservation over an unbounded prefix of
  finite admitted steps, rather than proving a theorem about completed final runs.
- Syntax must be designed carefully so users do not read runtime-bounded iteration as ordinary Wire
  graph expansion.
- Runtime iteration adds another budget surface next to rewrite gas, retry policy, timeouts, and
  task-level concurrency. Operator surfaces must make the distinctions legible.

### Obligations

Acceptance of this proposed ADR requires the in-text design gates to remain explicit: v1 self-append
uses one composite continuation-state anchor, the loop step is a witnessed ADR 0056 append of a
previously admitted kernel, the proposer is the existing loop-exit `StageLoopStep`, and durable
suspend/external-call interactions are delegated to ADR 0058 and ADR 0059. The obligations below are
the implementation, reference-doc, and proof work for the runtime-bounded-iteration track unless
they explicitly ask for a follow-up boundary-law ADR.

- Define a `LoopPolicy` or equivalent runtime carrier with at least: maximum iteration count, budget
  exhaustion behavior, checkpoint cadence, cancellation points, and emitted-output aggregation
  policy.
- Define the self-append carrier: kernel reference, frontier-shape witness, deterministic namespace
  seed, materialized-append index, remaining iteration budget, aggregation state, and loop outcome.
- Define the admitted kernel boundary: continuation state in/out, optional item input, optional
  emitted output, terminal summary, and guard/continuation signal.
- Define the step admission rule: iteration `i + 1` is an `AppendAfter` of a fresh kernel instance
  after iteration `i`'s single composite continuation-state node, and the resulting continuation
  frontier must match the loop frontier shape. Kernels with multi-node loop-carried continuation
  state require a separate boundary-law ADR.
- Define the ADR 0056 witnessed admission path for per-iteration appends so the loop step itself is
  gas-neutral and typed iteration exhaustion is not hidden behind `rewrite_budget_exceeded`.
- Define how a runtime-proposed bound is validated against policy and how rejection is reported.
- Define durable history/provenance for completed iterations, partial progress, cancellation, and
  budget exhaustion.
- Define additive realized-circuit snapshots as validator-checked artifacts, not history mutation.
- Define deterministic output-size and aggregation policy; iteration count alone does not bound
  accumulated payload size, and snapshot validation must re-derive the same ordered prefix fold.
- Define local-runner behavior separately from durable behavior, following ADR 0043's warning
  against semantic overclaim.
- State the rewrite interaction before admitting rewrite-capable loop bodies: shared parent budget,
  per-iteration child budget, or rejection of open rewrites inside loop kernels.
- State the retry interaction: retry may recover a failed body execution, but it must not advance
  the continuation state twice, duplicate emitted outputs, or re-admit the same iteration append.
- State parked-await cancellation for durable external calls: cancellation must repair waiting graph
  state and the ADR 0059 attempt record without admitting an extra iteration.
- Add reference documentation explaining that CorePure may compute loop-bound values but may not
  feed source graph construction.
- Add theorem targets:
  - a finite admitted iteration budget bounds the number of body executions;
  - each self-append step preserves the admitted kernel boundary;
  - frontier-shape preservation composes across any finite prefix of admitted steps;
  - continuation state is consumed and produced linearly across iterations;
  - emitted outputs are owned by exactly one completed iteration and aggregated according to policy;
  - the durable iteration index equals the count of self-append instances materialized through the
    rewrite watermark;
  - replay from the namespace seed and materialized index re-derives identical iteration-indexed
    node identities;
  - additive snapshots are faithful deterministic folds of the materialized ordered prefix;
  - cancellation and budget exhaustion preserve safe run state;
  - resume from an iteration checkpoint or snapshot does not duplicate completed iterations or host
    effects;
  - runtime-bound values do not affect source elaboration or source graph identity.

## Design Stress Points

The first design pass should attack these questions before any Pulse implementation starts:

1. **Can plain `AppendAfter` express the v1 loop step?** Hand-build one step for the paginated
   ingest kernel with `state_out` as one composite node, run it through rewrite planning and
   admission, and verify that entry/exit wiring preserves the continuation frontier. Then split
   `state_out` across two exit nodes and confirm that a single `AppendAfter` cannot anchor both
   without a new boundary law. This is also the place to prove that the loop-exit `StageLoopStep`
   proposer is sufficient.
2. **Where does the loop frontier live?** The kernel declaration should carry the authoritative
   frontier-shape witness, with lineage storing only a reference or hash. The checker must decide
   the ADR 0047 typed-shape equality relation and reject prose-only conventions.
3. **How do budgets compose?** Run a many-iteration queue drain on the ordinary gassed path and
   record which rewrite dimension fails first. Re-run the same kernel as an ADR 0056 witnessed
   append and confirm the visible terminal outcome is the typed iteration-cap outcome, not
   `rewrite_budget_exceeded`. Reject open rewrite authority inside loop kernels until the
   shared/per-step budget law is explicit.
4. **Can crash-resume join rewrite lineage with parked external effects?** Exercise a run with
   materialized iterations, an admitted-beyond-watermark append, and a parked ADR 0059 external-call
   attempt. Resume must materialize admitted rewrites in `rewrite_id` order, reconcile the attempt
   record, derive the index from the watermark, and cancel without leaking `NodeWaiting` or attempt
   rows.
5. **What is a valid snapshot?** Build an additive snapshot at a materialization watermark and
   independently re-fold the ordered prefix. Deterministic order-sensitive reducers are admissible
   when they re-derive the same value; nondeterministic reducers and history-truncating compaction
   are not.
6. **Does the proof model expose hidden assumptions?** State the one-step to finite-prefix
   frontier-preservation lemma and the namespace replay invariant early, reusing ADR 0038 recovery
   determinism where possible. Any proof need for multi-node continuation state, a second index
   source, or recursive namespace prefixes should feed back into the implementation slice before
   code lands.
7. **What is local-runner parity allowed to claim?** The in-memory runner can exercise in-process
   self-append decisions, but it cannot claim durable admit, materialize, watermark, resume, signal,
   lease, or snapshot safety without the durable substrate.

## Traceability

- Feature keys: `pulse.runtime_bounded_iteration`
- Public surface: `Cortex.Pulse`, `docs/Architecture/06-pulse-runtime.md`
- Implementation: `src/Cortex/Pulse/Iteration.hs` (`LoopPolicy`, `admitRuntimeBound`, `LoopControl`,
  the v1 self-append admission law and frontier-shape witness checks)
- Tests: `test/Cortex/Pulse/IterationSpec.hs`
- Theory/proof: none (the finite-budget and frontier-shape-preservation theorem targets in this
  ADR's Obligations are not yet mechanized)

## Related

- [ADR 0003 - Pulse Service and Host-Action Boundary](0003-pulse-service-and-host-action-boundary.md)
- [ADR 0005 - Budgeted Rewrite Admission and Materialization](0005-budgeted-rewrite-admission-and-materialization.md)
- [ADR 0037 - Wire Latent Structural Control Operators](0037-wire-latent-structural-control.md)
- [ADR 0043 - Pulse In-Memory Runner](0043-pulse-in-memory-runner.md)
- [ADR 0046 - Wire Compile-Time Graph Forms](0046-wire-compile-time-graph-forms.md)
- [ADR 0047 - Wire Frontier Linearity and Topology Operator Precedence](0047-wire-frontier-linearity-and-precedence.md)
- [ADR 0048 - Wire Compile-Time Make for Bounded Node Generation](0048-wire-make-bounded-node-generation.md)
- [ADR 0050 - Wire CorePure Output Residue](0050-wire-corepure-output-residue.md)
- [ADR 0056 - Admission Modes: Witnessed Materialization and Open Rewrite Gas](0056-admission-modes-witnessed-and-gas.md)
- [ADR 0057 - Latent Branch Witnessing and Proposal Closure Charging](0057-wire-latent-branch-witnessing-and-closure-charging.md)
- [ADR 0058 - Pulse Atomic Suspend Settlement](0058-pulse-atomic-suspend-settlement.md)
- [ADR 0059 - Durable External-Call Frontiers on Pulse](0059-durable-external-call-frontiers-on-pulse.md)
- [Architecture 05 - Wire Language](../Architecture/05-wire-language.md)
- [Architecture 06 - Pulse Runtime](../Architecture/06-pulse-runtime.md)

## Tracking

- #251 — runtime-bounded-iteration implementation, reference, and proof work.
