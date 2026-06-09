---
title: "ADR 0055 - Pulse Runtime-Bounded Iteration"
description:
  "Classifies runtime-dynamic repetition as Pulse-admitted bounded execution of finite kernels, not
  Wire graph expansion or CorePure looping."
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
  - "GitHub #181"
  - "GitHub #182"
---

# ADR 0055 - Pulse Runtime-Bounded Iteration

## Status

Proposed - this ADR names the runtime boundary and required model for data-dependent iteration. It
does not add Wire syntax by itself.

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
not as the substrate's graph-level iteration model, unless Pulse can still observe and enforce a
finite runtime budget. A truly unbounded sealed loop does not fit the downstream dataflow model:
downstream nodes can advance only after a completed output exists.

## Decision

Pulse should classify **runtime-bounded iteration** as a runtime-admitted execution feature: a
finite Wire/Circuit kernel may be repeated under a runtime-dynamic bound only when Pulse can
enforce, checkpoint, and record a finite per-run budget.

Runtime-bounded iteration is not source graph expansion, not CorePure recursion, and not an
unbounded background process hidden inside an ordinary executor. The source graph remains finite and
its node identities remain source-elaborated. The repeated body is a finite admitted kernel. Pulse
owns the iteration policy, budget enforcement, checkpoint/resume behavior, cancellation boundary,
lineage, and failure semantics.

This ADR does not choose final surface syntax. Any future syntax or executor-like spelling must
lower to the same runtime concept:

```text
upstream value -> CorePure clamp/validate -> Pulse runtime-bounded kernel execution
```

The upstream value may be executor output. CorePure may derive or clamp the bound as ordinary
authority-free value adaptation. Pulse then admits or rejects the requested iteration against
policy. The value never feeds Wire source elaboration.

The required runtime object is:

```text
RuntimeIteration =
  finite admitted kernel
  + loop policy
  + requested runtime bound or guard
  + continuation state
  + durable iteration trace
```

If any of those fields is missing, the mechanism is not this ADR's feature. It is either static
source elaboration, CorePure value computation, an ordinary executor-local algorithm, a child-run
design, or an unbounded service loop at the Pulse/host process boundary.

## Mental Model

The safe model is **bounded kernel repetition inside the runtime process loop, not dynamic graph
construction**.

| Layer                      | Repetition shape                                      | Owner              | Rule                                                                 |
| -------------------------- | ----------------------------------------------------- | ------------------ | -------------------------------------------------------------------- |
| Pulse/host process         | scheduler, poller, service, or daemon loop            | Pulse or host      | May be long-lived; not an ordinary downstream-producing graph node   |
| Wire source elaboration    | `make(N, K)`, forms, future static repeat             | Wire compiler      | Count and graph shape are static before Pulse execution              |
| CorePure                   | value derivation, filtering, clamping, record shaping | CorePure evaluator | Total, authority-free, non-recursive, no host effects or topology    |
| Runtime-bounded iteration  | repeat a finite kernel under admitted policy          | Pulse              | Runtime count is data; finite budget, checkpoints, and trace govern  |
| Executor-local computation | internal algorithm inside one stage action            | registered action  | Allowed as local authority; not graph-level iteration unless exposed |

The important separation is not "loops bad, no loops." The separation is: **only Pulse may turn
runtime data into repeated graph-level work, and only under a finite auditable policy**.

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
stricter rule.

### Kernel boundary

The repeated body must be a finite admitted kernel. Its continuation boundary is linear:

```text
state_in + item? -> state_out + emitted* + guard + terminal?
```

Each iteration consumes the current continuation state at most once and produces the next
continuation state at most once. This is the runtime analogue of ADR 0047's linear frontier rule,
not a license for graph cycles or implicit copying.

The kernel may expose ordinary input/output contracts, but its external interface must say which
ports are:

- loop state consumed and produced across iterations;
- per-iteration item input;
- per-iteration emitted output;
- terminal summary output;
- runtime guard or continuation signal.

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
- emitted outputs are either accumulated, streamed, or reduced according to explicit policy.
- checkpoint and provenance identify which iterations completed before resume.
- graph topology and source node identities do not change because of the runtime count.

An implementation may realize a kernel as one stage, a sealed local action, or child runs, but the
observable runtime contract is the same: the trace must explain which iterations happened and why
the loop stopped.

### Loop policy

A `LoopPolicy` or equivalent carrier must be explicit before runtime-bounded iteration is admitted.
At minimum it must include:

- maximum body executions;
- how runtime-requested bounds are decoded, clamped, rejected, or defaulted;
- budget-exhaustion behavior;
- checkpoint cadence;
- cancellation points;
- emitted-output aggregation policy;
- partial-result contract, if partial completion is allowed;
- fallback contract, if fallback completion is allowed;
- whether the kernel may propose rewrites.

Prompt text, model instructions, executor config, or downstream product policy are not sufficient
unless they lower to this Pulse-owned carrier.

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
- current iteration index;
- continuation state or resumable state reference;
- completed iteration ids;
- emitted-output aggregation state;
- terminal reason, when present;
- budget-exhaustion, cancellation, fallback, or partial-result marker, when present.

For irreversible host actions, the checkpoint boundary must be strong enough to avoid duplicating a
completed irreversible effect after crash recovery. If that cannot be guaranteed for a kernel, the
kernel is not admissible as a durable runtime-bounded iteration body under this ADR.

### Runtime ownership

Pulse owns:

- admitting the requested dynamic bound against configured policy;
- tracking remaining iteration budget;
- checking cancellation between iterations and before irreversible host actions;
- checkpointing enough state to resume without re-running completed iterations incorrectly;
- recording iteration lineage, emitted outputs, terminal outcome, and budget exhaustion;
- deciding how iteration interacts with rewrite budgets if the body can propose rewrites.

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
or duration. Cancellation is checked between polls. A timeout-shaped outcome is not ordinary success
unless the node contract explicitly declares a timeout/fallback result.

### Runtime-sized fan-in without runtime topology

A kernel may process N runtime items and aggregate them into one output value. It does not create N
Wire nodes and it does not make N new graph edges. If the program needs N graph vertices, N must be
known during source elaboration or introduced through admitted rewrites under the rewrite contract,
not through this iteration feature.

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
| Runtime count changes node ids or graph hash        | Graph identity is source-elaborated and already witnessed                | Keep count as runtime data only                       |
| Local runner succeeds without durable checkpoints   | Ephemeral success does not prove durable recovery or cancellation safety | Report missing durable guarantees                     |

## Relationship To Existing Runtime Features

Runtime-bounded iteration is similar to rewrite admission in one important respect: runtime
authority is finite and explicit. ADR 0005 made rewrite budget a runtime law rather than a prompt
convention. This ADR applies the same discipline to repetition.

Runtime-bounded iteration is also distinct from child workflows. A durable implementation may
realize large or long-running iterations through child runs or sub-runs, but parent-child lifecycle
semantics are an implementation and API decision layered under this ADR. If child runs are used, the
same budget, cancellation, checkpoint, and provenance obligations still apply.

The in-memory Pulse runner from ADR 0043 may support runtime-bounded iteration for local execution,
but it must report which durable guarantees are absent. Local success does not prove durable lease
recovery, service API visibility, signal resume, or cancellation propagation.

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
- **Treat runtime iteration as a special rewrite loop** - rejected because the repeated work does
  not necessarily change topology. Rewrites remain the bounded topology-evolution surface; this ADR
  is bounded execution of a fixed admitted kernel. If a loop body can propose rewrites, the
  interaction must be specified explicitly.
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
- The tail-linearity intuition from bounded source repetition carries over as a runtime continuation
  boundary rather than as graph recursion.

### Negative

- Pulse needs a new typed carrier for iteration policy, remaining budget, and iteration outcome.
- Durable execution needs additional history/provenance rows or events to explain iteration
  progress.
- Local runner parity becomes more nuanced because local iteration can execute without durable
  checkpoints or cross-process recovery.
- The proof track must extend beyond the fixed-topology kernel to cover per-iteration preservation
  or a bounded run trace over repeated kernels.
- Syntax must be designed carefully so users do not read runtime-bounded iteration as ordinary Wire
  graph expansion.
- Runtime iteration adds another budget surface next to rewrite gas, retry policy, timeouts, and
  task-level concurrency. Operator surfaces must make the distinctions legible.

### Obligations

- Define a `LoopPolicy` or equivalent runtime carrier with at least: maximum iteration count, budget
  exhaustion behavior, checkpoint cadence, cancellation points, and emitted-output aggregation
  policy.
- Define `LoopState`, `LoopFrame`, and `LoopOutcome` or equivalent carriers so state lineage,
  emitted-output aggregation, terminal reason, and budget exhaustion are represented in runtime data
  rather than prose.
- Define the admitted kernel boundary: continuation state in/out, optional item input, optional
  emitted output, terminal summary, and guard/continuation signal.
- Define how a runtime-proposed bound is validated against policy and how rejection is reported.
- Define durable history/provenance for completed iterations, partial progress, cancellation, and
  budget exhaustion.
- Define output-size and aggregation policy; iteration count alone does not bound accumulated
  payload size.
- Define local-runner behavior separately from durable behavior, following ADR 0043's warning
  against semantic overclaim.
- State the rewrite interaction before admitting rewrite-capable loop bodies: shared parent budget,
  per-iteration child budget, or rejection of rewrites inside loop kernels.
- State the retry interaction: retry may recover a failed body execution, but it must not advance
  the continuation state twice or duplicate emitted outputs.
- Add reference documentation explaining that CorePure may compute loop-bound values but may not
  feed source graph construction.
- Add theorem targets:
  - a finite admitted iteration budget bounds the number of body executions;
  - each body execution preserves the admitted kernel boundary;
  - continuation state is consumed and produced linearly across iterations;
  - emitted outputs are owned by exactly one completed iteration and aggregated according to policy;
  - cancellation and budget exhaustion preserve safe run state;
  - resume from an iteration checkpoint does not duplicate completed iterations;
  - runtime-bound values do not affect source elaboration or graph identity.

## Related

- [ADR 0003 - Pulse Service and Host-Action Boundary](0003-pulse-service-and-host-action-boundary.md)
- [ADR 0005 - Budgeted Rewrite Admission and Materialization](0005-budgeted-rewrite-admission-and-materialization.md)
- [ADR 0037 - Wire Latent Structural Control Operators](0037-wire-latent-structural-control.md)
- [ADR 0043 - Pulse In-Memory Runner](0043-pulse-in-memory-runner.md)
- [ADR 0046 - Wire Compile-Time Graph Forms](0046-wire-compile-time-graph-forms.md)
- [ADR 0047 - Wire Frontier Linearity and Topology Operator Precedence](0047-wire-frontier-linearity-and-precedence.md)
- [ADR 0048 - Wire Compile-Time Make for Bounded Node Generation](0048-wire-make-bounded-node-generation.md)
- [ADR 0050 - Wire CorePure Output Residue](0050-wire-corepure-output-residue.md)
- [Architecture 05 - Wire Language](../Architecture/05-wire-language.md)
- [Architecture 06 - Pulse Runtime](../Architecture/06-pulse-runtime.md)
