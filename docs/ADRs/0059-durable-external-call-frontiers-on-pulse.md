---
title: "ADR 0059 - Durable External-Call Frontiers on Pulse"
description:
  "How a Wire subgraph bound to an external backend (quantum, OpenAPI, WASM, MCP) runs durably on
  Pulse: the host binds an external-call capability, a connected same-backend frontier contracts to
  a single Pulse stage, and long-running backends use idempotent submit/park/resume over a trusted
  external-call wake signal settled by ADR 0058's atomic suspend settlement."
sidebar:
  label: "0059. Durable external-call frontiers"
  order: 59
status: proposed
date: 2026-06-16
superseded_by: null
related:
  - docs/ADRs/0003-pulse-service-and-host-action-boundary.md
  - docs/ADRs/0014-executor-taxonomy-model-vs-external-call.md
  - docs/ADRs/0019-executor-registration-and-binding.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0026-wire-failure-taxonomy.md
  - docs/ADRs/0032-wire-boundary-contract-resources.md
  - docs/ADRs/0035-wire-rewrite-algebra-forms.md
  - docs/ADRs/0053-executor-catalog-manifests-and-pulse-bindings.md
  - docs/ADRs/0054-downstream-wire-packages-and-host-bindings.md
  - docs/ADRs/0056-admission-modes-witnessed-and-gas.md
  - docs/ADRs/0058-pulse-atomic-suspend-settlement.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/Reference/Pulse/signals.md
  - docs/Reference/Pulse/schema.md
  - docs/Consumers/Quantum.md
---

# ADR 0059 - Durable External-Call Frontiers on Pulse

## Status

Proposed. Motivated by long-running external-backend work, with the QEC repetition-code workbench as
the first downstream pressure case. This ADR records how a Wire-authored external-backend frontier
runs as a durable Pulse stage, and pins the frontier projection plus durable execution contract the
existing executor ADRs leave open. It does not change the registration model (ADR 0019), the
executor taxonomy (ADR 0014), or the host-owned authority boundary (ADR 0003); it composes them and
adds frontier projection.

## Context

A Wire program can name an external backend by executor authority — `@quantum.cnot`,
`@quantum.measure_z`, and (anticipated by ADR 0014) OpenAPI, WASM, and MCP surfaces. The substrate
already decides how that authority is registered and bound:

- **ADR 0019** splits executor meaning into three substrate layers: Wire projection (inert
  ports/effect), a Capability spec (inert authority: config decoder, providers, codec, host-bound
  flag), and Pulse execution of _already-bound_ stage actions; inert profiles published downstream
  (e.g. by Logos) are admitted through Capability as a fourth, non-substrate input. Capability specs
  **do not embed a Pulse `StageAction`**, and **Pulse does not own executor registration** — the
  host turns a spec into runnable code.
- **ADR 0014** classifies a registered external backend as an `ExternalCallExecutor` (typed I/O
  under a registered name), distinct from `ModelExecutor`.
- **ADR 0053** is the catalog bridge: an executor id resolves to an inert admission projection
  consumed by Wire and Capability for static checking, an executor manifest (build + host binding),
  and a runtime binding record (Circuit emission + Pulse dispatch). Pulse dispatches the bound
  `StageAction`; it does not interpret backend categories.
- **ADR 0003** keeps domain authority outside the Pulse runtime: Pulse reaches host-owned behavior
  only across authenticated, idempotent boundaries, never by writing host tables or owning domain
  backends. A `host-action-v1` endpoint is one such boundary, not the only executor ABI.
- **ADR 0058** gives Pulse a durable await: a run can suspend on a signal and be woken without
  polling. The `run-terminal:` family is **reserved for child Pulse runs** — external/host delivery
  of it is refused (anti-forgery, see `Cortex.Pulse.Query`). External job completion must not reuse
  that namespace, and it must not use an author-deliverable ordinary signal either: it uses a
  separate reserved `external-call:` namespace delivered only by the trusted external-call runtime
  path. The signal row is a wake token for the parked stage, not the provider result payload.

Despite all of this, no decision says how a Wire **subgraph** bound to an external backend becomes a
**durable Pulse stage**. Two facts collide:

1. **Granularity.** Some external backends execute a whole collected frontier as one coherent
   request. A quantum circuit is the pressure case: many Wire gate nodes lower to one provider
   submission, and per-gate Pulse checkpointing would be physically meaningless. The generic problem
   is that the durable unit is a collected same-backend frontier, not every source node inside it.
2. **Lifetime.** A local simulator call is synchronous and cheap; a hardware submission is
   long-running, externally stateful, and non-idempotent unless guarded by a provider or host
   idempotency key. The first needs no durability; the second is a textbook durable-task shape.

Because neither is pinned, external backends sit outside Pulse entirely on the standalone bridge,
forfeiting durable scheduling, recovery, observability, and the await primitive — exactly the
capabilities the hardware path most needs.

## Decision

A Wire subgraph bound to an external backend runs on Pulse as a **durable external-call frontier**,
composed from the existing layers without weakening any boundary.

The mechanism is **backend-neutral**. Quantum/Braket is the worked example throughout, but the same
frontier shape serves any `ExternalCallExecutor` (OpenAPI, WASM, MCP) and a slow `ModelExecutor`;
only the concrete Wire package and host binding pack are backend-specific, and those are downstream
artifacts (ADR 0054 / `docs/Consumers/Quantum.md`), not substrate obligations of this ADR.

### 1. Binding stays in Capability, not Pulse

The host registers the backend as an `ExternalCallExecutor` Capability spec (ADR 0019/0014) and the
host runtime binding pack supplies the runnable `StageAction`. Pulse does not gain a backend
registry, an in-process Qiskit handler, or knowledge of `quantum.*`. "Run it on Pulse" means _the
bound stage runs under Pulse's scheduler_, not _Pulse owns the backend_ — consistent with ADR 0019's
"Pulse does not own executor registration" and ADR 0003's host-owned authority boundary.

**The packaging mechanism is ADR 0054, not a new one.** The backend ships as two artifacts whose
dependency direction is one-way:

- A **Wire package** — inert compile-time vocabulary, imported with `use`. It exports contracts
  (`QuantumResult`, `MeasurementCounts`, `ShotCount`, `BackendConfig`), executor admission
  projections (`quantum.prepare_zero`, `quantum.x`, `quantum.cnot`, `quantum.measure_z`,
  `quantum.realize`), and can later host reusable `.wire` modules such as repetition-code helpers.
  It carries **no** credentials, SDK authority, or `StageAction`.
- A **host runtime binding pack** — the only artifact with runtime authority. It resolves
  `quantum.realize` (or `quantum.braket.realize`) to a Pulse `StageAction`, injects the AWS
  profile/region/device ARN/S3 bucket, performs OpenQASM lowering, Braket submit, park/resume, and
  result fetch, and mints the ADR 0053 runtime binding records.

`use quantum.braket.{@realize}` brings the **name** into source scope only; it does not grant AWS
access. Compile and `wire build`/check succeed without the binding pack — runnable Pulse lowering is
what fails, with a typed `missing runtime binding`. This is the ADR 0054 invariant (importing a Wire
package never grants runtime authority; only a host binding pack does), specialized to quantum:

```wire
use quantum.core.{@prepare_zero, @x, @cnot, @measure_z};
use quantum.braket.{@realize};
use quantum.qec.{RepetitionResult, Syndrome};

# circuit authored as native Wire topology; final frontier collected by @realize
```

```sh
wire pulse run examples/wire/qec-repetition-realize.wire \
  --wire-package quantum --binding-pack braket --config braket-local.json
```

The quantum/Braket surface is the **first downstream consumer** of this mechanism; its concrete Wire
package decomposition (`quantum.core` / `quantum.qec` / `quantum.braket`) and host binding pack are
specified downstream (`docs/Consumers/Quantum.md`), not in this substrate ADR.

### 2. Frontier projection: a pure fusion rewrite feeding a collect stage

The author marks the frontier boundary explicitly with a `collect`-style external-call executor (for
example `@quantum.realize`) rather than the materializer inferring a maximal subgraph. The source
remains ordinary Wire topology and is **collected** at that boundary, which separates cleanly into a
pure half and an effectful half:

```
build_frontier  =>  fuse           =>  collect            =>  continue
(source graph)      (pure rewrite)     (host-owned effect)    downstream Pulse stages
                   emits payload       consumes payload
```

- **Fusion is a pure in-Wire rewrite.** A contraction collapses the collected same-backend subgraph
  into a single typed external-call payload derived deterministically from the frozen topology. It
  runs in the substrate under the ADR 0035 rewrite algebra, carries **no** effect, authority, or
  backend semantics, and emits the frozen payload as a value on one linear edge. Domain-specific
  translation into that payload is owned by the downstream package or host binding, not by Pulse.
- **The collecting stage is a thin effectful consumer.** The collecting stage takes the frozen
  payload value and produces named outputs through the bound `StageAction` (§3). Backend-specific
  lowering (for example OpenQASM serialization in the quantum extension) and the external
  submit/park/resume effect live in the host binding pack, not in the pure rewrite.

This split is the decision for **where fusion lives** (previously an open question): Cortex owns the
structural collection check, the canonical frozen-payload envelope, and the durable attempt record;
domain-specific payload construction and backend-specific lowering stay downstream or host-side. The
substrate never gains backend semantics, and the host never re-derives graph structure on resume:
the frozen payload is read back from the durable attempt record (§3), not recomputed from the live
graph.

The collecting node's **output ports are declared ordinary Wire output ports**. Cortex requires
their labels to be distinct and wraps completed outputs through the canonical Wire output-envelope
path; it does not prescribe a measurement schema, result record, or backend-specific output family.
The quantum extension may choose one output per named measurement. Another external backend may
choose a different output shape, as long as port linearity and contract validation hold.

**Collection is a contraction with a decidable admission check.** Sinking the frontier into the
fusion rewrite collapses the collected subgraph into one payload-producing node — structurally a
contraction. Two obligations follow, and both are decisions, not open questions:

- **Admission.** A frontier is admissible iff, for the nodes **inside the collected set**: every
  node shares one external-call authority and one await strategy, and no non-backend node
  intervenes. The constraint is on the collected set, **not** on the collect stage's **frozen
  boundary inputs**: parameters fed in from the surrounding graph are legitimate inbound edges, not
  cross-authority violations — requiring every parameter to be static config would block
  parameterized external calls. A collected set that mixes authorities or pulls in a non-backend
  node is **rejected** (the author/materializer must place separate collect nodes); the validator
  does not silently split it. This is a decidable check in the `validatorReady_sound` lineage — the
  same machinery that admits other rewrites — not host-side guesswork.
- **Port linearity.** The contraction must preserve port linearity. It does **not** reduce to
  `bulkContract`: `bulkContract` only erases endpoints monotonically, whereas collection erases the
  collected internal outputs and re-emerges the collect node's declared output ports, so the
  existing `bulkContract_preserves_portLinear` does not discharge it (`theory/README.md` records
  this). The obligation is therefore a dedicated `external_call_collect_preserves_portLinear` (see
  _Obligations_): collected outputs become internal under the single-pair `contract` lemma, the
  fresh collect outputs are disjoint and each consumed once, and the two combine by a
  domain-disjointness argument. The frozen payload flows on a single linear edge consumed exactly
  once by the collect node, which keeps the consumed side trivial. Governed by ADR 0035's rewrite
  boundary laws; the collected external-call resource is accounted under ADR 0032's boundary
  resource algebra.

**Payload emission is canonical.** The collected payload is a deterministic value derived from the
frozen frontier, with ordered steps and sorted output labels so the payload — and its content hash —
is identical across replays of the same topology. That content hash is the stable frontier identity
used by the durable attempt record (§3). Domain packages own any additional ordering rules needed by
their backend (for example quantum gate-order constraints).

### 3. Execution is a host-owned external effect via the bound StageAction

The collecting stage is a **host-owned external effect executed through the bound `StageAction`**
that **consumes the frozen payload** produced by the pure fusion rewrite (§2), under ADR 0003's
trust boundary (domain authority lives in the host, not Pulse). Backend-specific lowering happens
inside the host binding pack, never in the pure rewrite. The host-action-v1 protocol is **one
possible ABI/driver** for that effect — not the required mechanism: per
`docs/Reference/Pulse/host-actions.md`, capability/executor calls do not use the host-action
protocol unless a host explicitly registers an executor that calls back into its own service. The
host may equally implement the `StageAction` as a direct provider SDK call, a subprocess, or a
brokered process. Pulse dispatches the **opaque bound `StageAction`** and observes only its result —
_complete_ or _suspend_. The **await strategy** that decides which shape applies is binding metadata
declared in the ADR 0053 admission projection / runtime binding record (alongside replay, effect,
and isolation), **not** a category Pulse interprets. Two strategies:

- **Synchronous** (local simulator, fast pure-ish backends): the action runs the frozen payload and
  returns results inline; the stage completes in one transaction.
- **Submit/park/resume** (hardware, any long-running async backend — and equally a slow
  `ModelExecutor`): the action _submits_ and returns a job handle, then suspends. The run **parks**
  via ADR 0058's atomic suspend settlement on a reserved `external-call:` wake signal derived from
  the attempt key. Ordinary user-facing signal delivery rejects this namespace, just as it rejects
  `run-terminal:`; only the trusted external-call delivery helper can mark it delivered. On delivery
  the run **resumes by re-arming the waiting node**, not by completing it from the signal payload.
  The resumed `StageAction` reads the attempt record and provider completion state, then maps the
  fetched result to the collect node's output ports or to a typed failure. No poll loop; a crash
  recovers to the parked-and-awaiting state.

**Idempotency is anchored to a durable attempt record, not the live graph and not the signal rows.**
ADR 0058's settlement transaction commits only graph state, `pulse.signals` wait rows, and
`runs.status` — it does not carry executor metadata. The host binding therefore uses a separate
Pulse-owned external-call attempt record, keyed by run id, node id, runtime binding id, and frontier
id — the canonical payload digest, which is the stable frontier identity (a single derivation rule,
not a choice). Pulse stores provider-specific fields as opaque data; it does not interpret the
backend. The `external-call:` signal name is derived from this attempt key, so a wake resolves
exactly one parked stage attempt.

The submit protocol is crash-safe:

1. reserve the attempt record before provider submission, storing the frozen payload and a
   deterministic Pulse-side idempotency key derived from the frozen materialized frontier;
2. derive the provider submit/dedup token deterministically in the driver and submit to the provider
   outside the database transaction using that provider token. The provider token may incorporate
   request parameters beyond the payload digest (region, device, shots, bucket, prefix, action); it
   need not equal the Pulse attempt key, but it must be reproduced byte-for-byte on crash re-entry;
3. persist the external job handle on the attempt record before returning `StageSuspend`;
4. during ADR 0058 suspend settlement, atomically link the waiting node and reserved
   `external-call:` wake signal to the attempt record.

If the process dies after reservation but before submit, recovery re-enters the stage and submits by
re-deriving the same provider submit/dedup token. If it dies after provider submit but before the
handle is recorded, recovery must either replay the idempotent submit and recover the same handle or
consult a host idempotency store; a backend that cannot provide one of those guarantees is not
admissible for `submit_park_resume`. Once the handle is recorded, recovery reconnects to that
attempt instead of creating a fresh provider task. The completion signal is a wake token carrying
completion status and optional provider result locator; it is never committed as the node output.
The resumed `StageAction` reads the attempt record, fetches or validates the provider result, and
maps it to output envelopes or a typed failure.

The resume fetch/validate step is at-least-once safe. A crash after the provider result is fetched
or the attempt record is settled but before the node-completion graph write may re-enter the same
fetch path; the driver must make that re-entry idempotent. A premature or duplicate `external-call:`
wake that observes a non-terminal provider job must re-suspend or surface a typed retry/no-progress
outcome, not close the stage as a provider failure. A provider-result identity/integrity mismatch
(for example device identity, request identity, or result hash) is a typed failure closure, never a
silent settle.

**The failure path is typed.** Job reject, calibration error, queue timeout, and async-submit
failure propagate as typed failures under ADR 0026's closed failure taxonomy, closed via the
**failure-closure** operator (Architecture 06): the resumed collect stage fails with a typed reason
after reading the attempt record/provider status, and downstream stages observe the closed failure
rather than a missing result. A collect node _may_ additionally expose a typed error output for
recoverable backend errors an author wants to branch on, but the default negative path is closure,
not silence.

### 4. Analysis is ordinary downstream Pulse stages

Syndrome extraction, decoding, and reporting are not external-backend work. They are pure or
host-effecting stages downstream of the measurement frontier, scheduled like any other Pulse stage.
The QEC decoder is data-pipeline post-processing on labeled measurement outputs, not a quantum
executor.

## Mental Model

> A backend is bound once as a Capability and runs as a Pulse stage. The author builds a Wire
> frontier and _collects_ it: a pure fusion rewrite contracts the frontier into a deterministic
> frozen payload, and the collect stage consumes that payload and emits declared outputs. Cheap
> backends return inline; long-running backends submit, park on a trusted external-call wake signal,
> re-run the collect stage on wake, then produce outputs. Downstream analysis is ordinary Pulse
> work.

## Boundary Rules

- **No backend code in Pulse.** Pulse schedules a bound `StageAction`; the backend lives in the host
  per ADR 0003/0019. The local `wire run` interpreter and the standalone bridge remain valid for
  non-durable dev use — the Capability binding is the shared seam, so a backend is registered once
  and reachable from both runtimes.
- **Frontier, not node, is the unit of durable work.** Durability attaches at the
  submission/frontier boundary. There is no per-gate checkpoint; recovery re-enters the frontier and
  uses the attempt record plus idempotency key to reconnect to, fetch, or idempotently re-submit the
  whole provider task.
- **One authority per frontier, by decidable check.** A collected set mixing two backend authorities
  (or pulling in a non-backend node) is **rejected** by the admission validator — the author places
  separate collect nodes; the validator never silently splits. Frozen parameters fed to a collect
  node are not authority violations.
- **Idempotency is anchored to a durable attempt record.** A separate external-call attempt record
  holds the idempotency key, external job handle, frozen payload, and completion signal name.
  Attempt reservation precedes provider submit; the provider call happens outside the DB
  transaction; ADR 0058 settlement atomically links the waiting node and reserved wake signal to the
  attempt record. The Pulse-side key is read back from the attempt record on resume, never
  recomputed from the rewritable graph. Provider submit/dedup tokens are deterministic driver-owned
  derivations from that attempt plus provider request parameters, so replay after a crash never
  double-submits. Signal/wait rows are not overloaded with this metadata.
- **External-call signals are reserved wake tokens.** Ordinary signal delivery rejects
  `external-call:*`. The trusted external-call delivery path may mark the signal delivered, but
  settlement and resume treat the payload only as wake metadata. A delivered external-call signal
  re-arms the waiting node so the bound `StageAction` can fetch, validate, and commit canonical
  output envelopes.
- **Resume fetch is idempotent and not-ready-tolerant.** Fetch/validate may be re-entered after a
  crash or duplicate wake. Re-entry must be safe, a non-terminal provider job must re-suspend or
  return a typed retry/no-progress outcome, and provider-result identity/integrity mismatch closes
  the stage through the typed failure path.
- **Fused-plan emission is canonical.** The payload is a deterministic canonical linearization of
  the frozen subgraph, so the same topology yields the same plan and hash across replays.
- **Await strategy is binding metadata, not Pulse interpretation.** The synchronous vs
  submit/park/resume choice lives in the ADR 0053 admission projection / binding record; Pulse
  dispatches an opaque `StageAction` and does not infer backend category from the field.
- **The negative path is closed, not silent.** Backend failures propagate as typed reasons under ADR
  0026's failure taxonomy, closed via the failure-closure operator; the collect node never resumes
  with a missing result.

## Consequences

### Positive

- The hardware quantum path gains durable submission, recovery, and await-without-polling for free
  by reusing ADR 0058 — the single most valuable Pulse capability for long-running jobs.
- Generalizes beyond quantum: OpenAPI, WASM, and MCP backends (ADR 0014), and equally a slow
  `ModelExecutor` (long generation), all land as durable submit/park/resume stages through the same
  await strategy — the field belongs at the executor level, not just `ExternalCallExecutor`.
- No boundary erosion: registration stays in Capability, domain authority stays host-owned.

### Negative

- Frontier collection is new machinery: a realize-node executor, a decidable admission check, and a
  contraction rewrite with a discharged linearity proof — more than 1:1 node-to-stage
  materialization.
- Two await strategies (sync vs submit/park/resume) widen the external-effect contract a backend's
  bound `StageAction` must satisfy, and add a binding-metadata field threaded through the ADR 0053
  catalog.
- Re-entering a frontier on recovery can require a reconnect, fetch, or idempotent whole-task
  re-submit. Partial-circuit resumption is not physically meaningful, so the attempt-record
  idempotency key is the safety boundary.

### Obligations

#### Implementation

- Add the **fusion contraction** rewrite that sinks a same-authority, same-await-strategy frontier
  into a single generic, canonically-linearized `ExternalCallPayload` value, and a collect-style
  external-call executor with declared typed output ports that consumes that value.
- Implement the decidable admission validator in the `validatorReady` lineage: nodes inside the
  collected set share one backend authority and await strategy, no non-backend node intervenes, and
  mixed collected authorities are rejected. Frozen boundary inputs to the collect node are allowed
  and are not cross-authority violations.
- Add an **await strategy** field (`synchronous` | `submit_park_resume`) to the ADR 0053 admission
  projection / runtime binding record — at the executor level, covering `ModelExecutor` too. Pulse
  dispatches the opaque `StageAction` and reacts only to complete-or-suspend; it does not infer
  backend behavior from the field.
- Define a Pulse-owned durable **external-call attempt record** holding
  `{idempotency key, external job handle, frozen payload, completion signal name}` as opaque
  provider-aware runtime state. Reserve it before provider submit, persist the handle before
  returning `StageSuspend`, and have ADR 0058 settlement atomically link the waiting node/signal to
  that attempt. Deliver completion through the reserved `external-call:` namespace with a trusted
  runtime helper; ordinary `deliverSignal` rejects both `run-terminal:*` and `external-call:*`. The
  signal wakes the run and may carry completion status or a result locator, but it never supplies
  the node output; the resumed `StageAction` remains responsible for fetching/validating provider
  results and producing output envelopes or a typed failure.
- Require the `ExternalCallDriver` to derive provider submit/dedup tokens deterministically from the
  attempt record plus provider request parameters, without assuming equality with the Pulse-side
  idempotency key.
- Require resumed fetch/validate to be idempotent across re-entry and tolerant of not-yet-terminal
  provider jobs; provider-result identity or integrity mismatch must surface as a typed failure
  closure.
- Add the generic binding helper that turns an `ExternalCallDriver` plus runtime binding metadata
  into a `StageDefinition`: derive the attempt key from run id, node id, runtime binding id, and the
  frontier id (the canonical payload digest); reserve or load the attempt record; submit or fetch
  through the driver; wrap completed outputs through the canonical Wire output-envelope path.
- Exercise both wake timing paths in DB-backed tests: a trusted `external-call:` signal already
  delivered before suspend settlement, and a trusted `external-call:` signal delivered while the run
  is parked and observed on resume. Both paths re-arm the node and re-enter the `StageAction`.
- Expose a Pulse-owned pool-construction helper from `Cortex.Pulse.Database` so a downstream durable
  runner/provider-completion watcher need not import `Platform.Database` directly, and add a
  `listSubmittedExternalCallAttempts` query (alongside the existing load-by-key) for a DB-wide
  watcher that has no single run to scope by.
- Provision `pulse.external_call_attempts` for deployed databases: add the forward migration
  (`CREATE TABLE` + the four-part `(run_id, node_id, runtime_binding_id, frontier_id)` unique index)
  under `migrations/` with a ledger entry, matching the test-schema shape, so a migration-built
  production database has the table the test dump already carries.
- Realign the affected reference docs with the reserved-namespace model:
  `docs/Reference/Pulse/ schema.md §10` and `docs/Reference/Pulse/signals.md` must describe the
  `external-call:` reserved family and its re-arm-on-wake resolution rather than any "ordinary
  durable signal" wording, and the executor haddock (`driverSignalName`, the `AwaitStrategy`
  doc-comments) must be reconciled the same way when the code lands.
- Route backend failures (reject, timeout, calibration, submit failure) through the ADR 0026 failure
  taxonomy, closed via the failure-closure operator, with a typed reason.
- (Downstream, not substrate.) A consumer ships its backend surface as ADR 0054 artifacts — a Wire
  package (contracts + admission projections + reusable `.wire` modules) and a host runtime binding
  pack that mints the ADR 0053 runtime binding records; runnable lowering without the pack fails
  with `missing runtime binding`. The quantum/Braket instance is specified in
  `docs/Consumers/Quantum.md`.
- Keep the standalone bridge and `wire run` path working; both consume the same Capability binding.

#### Formal (theory/)

- Discharge port-linearity for the fusion contraction — it is **never admitted unproven**. It does
  not reduce to `bulkContract` (the collect contraction re-emerges fresh declared output ports,
  which `bulkContract` does not model), so prove the dedicated
  **`external_call_collect_preserves_portLinear`**: collected outputs become internal under the
  single-pair `contract` lemma, the fresh collect ports are disjoint and each consumed once,
  combined by a domain-disjointness argument; the `ExternalCallPayload` single linear edge keeps the
  consumed side trivial. (`theory/README.md` tracks this as the open obligation.)
- Account the collected external-call resource under ADR 0032's boundary resource algebra, and show
  the contraction obeys ADR 0035's rewrite boundary laws.
- Confirm the gas treatment against ADR 0056: a **source-authored** collect contraction is
  compile-witnessed materialization — **gas-neutral as an admission gate, recorded as cost/metric**,
  never rejected for gas. When an **open producer** introduces the frontier it pays once at its own
  admission boundary (ADR 0056/0057); the later witnessed realization does not refill or recharge.
- Extend the suspend-settlement safety/liveness model to the `external-call:` family.
  `formal/RunTerminalSignal.tla` covers only the `run-terminal:` family, whose delivery resolves the
  waiter to a terminal value; it does **not** model the `external-call:` re-arm-on-wake resolution
  or the not-ready re-suspend cycle. Model the re-arm transition (delivery returns the waiter to
  `NodePending`, not `done`) and show the wake → re-suspend → wake loop terminates under a provider
  eventual-terminality fairness assumption. Until that lands, the `run-terminal:` model is not a
  proof of family-specific settlement.

## Alternatives Considered

- **Register a quantum `TaskHandler` directly in Pulse's `TaskRegistry`.** Rejected: it would put
  backend semantics in the runtime process and bypass the Capability layer, contradicting ADR 0019
  ("Pulse does not own executor registration") and ADR 0003 (domain authority stays host-owned).
- **Materialize each gate as a durable stage.** Rejected: gates are coherent and sub-millisecond;
  per-gate durability is meaningless and would multiply scheduling cost by ~50x for a trivial
  circuit.
- **Keep external backends outside Pulse permanently (the current bridge).** Rejected for the
  hardware path: long-running async jobs are precisely what durable runs + the await primitive exist
  for. Retained for local dev simulation, where durability adds nothing.

## Open Questions

(The admission rule, per-measurement typing, idempotency anchoring, the linearity discharge, the gas
treatment, and **where fusion lives** were open questions in earlier drafts; review promoted them to
the decisions and obligations above — fusion is a pure in-substrate rewrite emitting the generic
`ExternalCallPayload` (§2); the linearity discharge resolves to the dedicated
`external_call_collect_preserves_portLinear` lemma — it does **not** reduce to `bulkContract`,
because the collect contraction re-emerges fresh declared output ports (`theory/README.md`); and the
gas treatment resolves to ADR 0056's witnessed-neutral rule.)

1. **Local-sim durability.** Should synchronous local simulation run as a Pulse stage at all, or
   stay on the `wire run` path? Uniformity vs overhead.
2. **Await-strategy taxonomy.** Is `synchronous | submit_park_resume` sufficient, or do streaming
   and partial-result backends need a third shape?

## First Consumer

The QEC repetition-code workbench is the prototype, and it validates the boundary on the
`wire run` + bridge path. Hardware execution itself already exists through the standalone OpenQASM
bridge(s) — it is **not** the future work. The remaining work this ADR scopes is the **Pulse-durable
frontier integration**: the realize-node contraction, the await strategy, and submit/park/resume
over a reserved external-call wake signal. The first such durable frontier becomes the revisit point
for this ADR, per the "ADR after the prototype clarifies the boundary" sequencing.

## Traceability

- Feature keys: `pulse.external_call_frontier`
- Public surface: `Cortex.Pulse`, `docs/Reference/Pulse/signals.md`,
  `docs/Reference/Pulse/schema.md`
- Implementation: `src/Cortex/Pulse/Rewrite/Contract.hs` (`admitFrontierContraction` — the §2
  decidable admission check), `src/Cortex/Pulse/Lowering/ExternalCallPayload.hs` (canonical
  `ExternalCallPayload`), `src/Cortex/Pulse/Lowering/ExternalCallStage.hs`,
  `src/Cortex/Pulse/Executor/ExternalCall.hs` (the §3 submit/park/resume protocol),
  `src/Cortex/Pulse/Executor/ExternalCallStore.hs`, `src/Cortex/Pulse/Query/ExternalCall.hs`
  (durable attempt record)
- Tests: `test/Cortex/Pulse/FrontierContractionSpec.hs`,
  `test/Cortex/Pulse/Lowering/ExternalCallPayloadSpec.hs`,
  `test/Cortex/Pulse/Executor/ExternalCallSpec.hs`,
  `test/Cortex/Pulse/Executor/ExternalCallAttemptSpec.hs`
- Theory/proof: none (the `realize_preserves_portLinear` discharge is an open obligation tracked in
  `theory/README.md`; the `external-call:` settlement family is not yet modelled in
  `formal/RunTerminalSignal.tla`)

## Tracking

- #269 — QEC repetition-code workbench and durable frontier integration.
