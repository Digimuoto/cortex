---
title: "ADR 0059 - Durable External-Call Frontiers on Pulse"
description:
  "How a Wire subgraph bound to an external backend (quantum, OpenAPI, WASM, MCP) runs durably on
  Pulse: the host binds an external-call capability, a connected same-backend frontier contracts to
  a single Pulse stage, and long-running backends use idempotent submit/park/resume over an ordinary
  durable Pulse signal settled by ADR 0058's atomic suspend settlement."
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
  - docs/Consumers/Quantum.md
  - "GitHub #269"
---

# ADR 0059 - Durable External-Call Frontiers on Pulse

## Status

Proposed. Motivated by the QEC repetition-code workbench (#269), whose quantum circuits today run
through a standalone Python bridge under the local `wire run` interpreter, with Pulse uninvolved.
This ADR records how such a Wire-authored external-backend graph should instead run as a durable
Pulse run, and pins the frontier projection plus durable execution contract the existing executor
ADRs leave open. It does not change the registration model (ADR 0019), the executor taxonomy (ADR
0014), or the host-owned authority boundary (ADR 0003); it composes them and adds frontier
projection.

## Context

A Wire program can name an external backend by executor authority — `@quantum.cnot`,
`@quantum.measure_z`, and (anticipated by ADR 0014) OpenAPI, WASM, and MCP surfaces. The substrate
already decides how that authority is registered and bound:

- **ADR 0019** splits executor meaning into four layers: Wire projection (inert ports/effect), a
  Capability spec (inert authority: config decoder, providers, codec, host-bound flag), Pulse
  execution of _already-bound_ stage actions, and Logos profiles. Capability specs **do not embed a
  Pulse `StageAction`**, and **Pulse does not own executor registration** — the host turns a spec
  into runnable code.
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
  of it is refused (anti-forgery, see `Cortex.Pulse.Query`). External job completion must therefore
  ride an **ordinary durable signal**, not `run-terminal:`, unless the job is itself modeled as a
  child Pulse run.

Despite all of this, no decision says how a Wire **subgraph** bound to an external backend becomes a
**durable Pulse stage**. Two facts collide:

1. **Granularity.** Wire models a quantum circuit as many gate-nodes, but the backend executes the
   whole circuit as one coherent submission — gates are sub-millisecond and cannot be checkpointed
   between. `docs/Consumers/Quantum.md` already states the host _"walks the materialized nodes and
   appends operations to the selected quantum circuit"_: fusion is a host responsibility today,
   performed outside Pulse. Materializing each gate as a durable stage would be absurd.
2. **Lifetime.** A local simulator call is synchronous and cheap; a hardware submission is
   long-running, externally stateful, and non-idempotent unless guarded by a provider or host
   idempotency key. The first needs no durability; the second is a textbook durable-task shape.

Because neither is pinned, external backends sit outside Pulse entirely (the #269 bridge),
forfeiting durable scheduling, recovery, observability, and the await primitive — exactly the
capabilities the hardware path most needs.

## Decision

A Wire subgraph bound to an external backend runs on Pulse as a **durable external-call frontier**,
composed from the existing layers without weakening any boundary.

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
  `quantum.realize`), and reusable `.wire` modules (repetition-code helpers). It carries **no**
  credentials, SDK authority, or `StageAction`.
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
wire pulse run examples/wire/qec-repetition-code.wire \
  --wire-package quantum --binding-pack braket --config braket-local.json
```

This makes the quantum surface the **first real downstream Wire package**: `quantum.core` (generic
circuit vocabulary), `quantum.qec` (reusable QEC modules/contracts), `quantum.braket` (the Braket
realization projection, until realization can be kept fully generic), and a Braket host binding pack
(the AWS/Pulse implementation).

### 2. Frontier projection via an explicit realize node

The author marks the frontier boundary explicitly with a **realize node** — a `collect`-style
external-call executor (e.g. `@quantum.realize`) — rather than the materializer inferring a maximal
subgraph. The circuit is authored as ordinary Wire topology (gate-nodes, for composition and typing)
and **collected into the realize node**, which is the durable external-call stage:

```
build_circuit  =>  realize        =>  decode      =>  report
(gate frontier)    (submit+wait)      downstream Pulse stages
```

The realize node's **payload is the fused sub-plan** (the backend-neutral operation list the bridge
builds today, gathered from the upstream same-backend nodes feeding it); the gate-nodes are payload,
never stages. Its **output ports are one per named measurement** — `s01`, `s12`, `final_d0`, … are
distinct typed result ports, not a single results record. Per-measurement ports keep the
substructural discipline native: a results record would need a `*` (copy) to fan it to multiple
downstream consumers, reintroducing the linearity question the typed ports avoid. The realize node
cannot consume post-measurement values as _inputs_, because those exist only after it executes; it
consumes the frontier and produces the results. This is the author-explicit form of the
host-walks-nodes behavior `Quantum.md` documents, and it mirrors the existing `std.io.command`
send-spec / await-result / continue pattern the eraser already uses.

**Collection is a contraction with a decidable admission check.** Sinking the frontier into the
realize node is a rewrite that collapses the collected subgraph into one node — structurally a
contraction. Two obligations follow, and both are decisions, not open questions:

- **Admission.** A frontier is admissible iff, for the nodes **inside the collected set**: every
  node shares one external-call authority and one await strategy, and no non-backend node
  intervenes. The constraint is on the collected set, **not** on the realize node's **frozen
  boundary inputs**: classical parameters fed to the realize node (shot count, rotation angles,
  `BackendConfig`) are legitimate inbound edges, not cross-authority violations — requiring every
  parameter to be static config would block parameterized external calls. A collected set that mixes
  authorities or pulls in a non-backend node is **rejected** (the author/materializer must place
  separate realize nodes); the validator does not silently split it. This is a decidable check in
  the `validatorReady_sound` lineage — the same machinery that admits other rewrites — not host-side
  guesswork.
- **Port linearity.** The contraction must preserve port linearity. The ADR's position is that
  realize **reduces to `bulkContract`**, discharged by the existing
  `bulkContract_preserves_portLinear` (no new proof — the strong outcome). If realize turns out not
  to reduce (e.g. because measurement ports re-emerge as realize outputs in a way `bulkContract`
  does not model), it is a new rewrite carrying its own `realize_preserves_portLinear`. This is a
  **formal obligation** (see _Obligations_), and it is governed by ADR 0035's rewrite boundary laws;
  the collected external-call resource is accounted under ADR 0032's boundary resource algebra.

**Fused-plan emission is canonical.** The payload is built from a partial order (gates on disjoint
qubits are unordered), so the builder must emit a **deterministic, canonical linearization** of the
frozen subgraph. Non-commuting gates are already forced by qubit dataflow; the canonical rule fixes
the order of the commuting/independent set so the plan — and its hash — is identical across replays
of the same topology.

### 3. Execution is a host-owned external effect via the bound StageAction

The realize stage is a **host-owned external effect executed through the bound `StageAction`**,
under ADR 0003's trust boundary (domain authority lives in the host, not Pulse). The host-action-v1
protocol is **one possible ABI/driver** for that effect — not the required mechanism: per
`docs/Reference/Pulse/host-actions.md`, capability/executor calls do not use the host-action
protocol unless a host explicitly registers an executor that calls back into its own service. The
host may equally implement the `StageAction` as a direct provider SDK call (Braket submit), a
subprocess, or a brokered process. Pulse dispatches the **opaque bound `StageAction`** and observes
only its result — _complete_ or _suspend_. The **await strategy** that decides which shape applies
is binding metadata declared in the ADR 0053 admission projection / runtime binding record
(alongside replay, effect, and isolation), **not** a category Pulse interprets. Two strategies:

- **Synchronous** (local simulator, fast pure-ish backends): the action runs the fused circuit and
  returns results inline; the stage completes in one transaction.
- **Submit/park/resume** (hardware, any long-running async backend — and equally a slow
  `ModelExecutor`): the action _submits_ and returns a job handle, then suspends. The run **parks**
  via ADR 0058's atomic suspend settlement on an **ordinary durable signal** (delivered by the host
  through the service API on job completion — _not_ the reserved `run-terminal:` family). On
  delivery the run **resumes**; the resumed `StageAction` reads the attempt record and provider
  completion state, then maps the result to the realize node's output ports or to a typed failure.
  No poll loop; a crash recovers to the parked-and-awaiting state.

**Idempotency is anchored to a durable attempt record, not the live graph and not the signal rows.**
ADR 0058's settlement transaction commits only graph state, `pulse.signals` wait rows, and
`runs.status` — it does not carry executor metadata. The host binding therefore uses a separate
Pulse-owned external-call attempt record, keyed by run, stage, runtime binding id, and frontier id.
Pulse stores provider-specific fields as opaque data; it does not interpret the backend.

The submit protocol is crash-safe:

1. reserve the attempt record before provider submission, storing the frozen fused plan and a
   deterministic idempotency key derived from the frozen materialized frontier;
2. submit to the provider outside the database transaction using that key;
3. persist the external job handle on the attempt record before returning `StageSuspend`;
4. during ADR 0058 suspend settlement, atomically link the waiting node and ordinary durable signal
   to the attempt record.

If the process dies after reservation but before submit, recovery re-enters the stage and submits
with the same key. If it dies after provider submit but before the handle is recorded, recovery must
either replay the idempotent submit and recover the same handle or consult a host idempotency store;
a backend that cannot provide one of those guarantees is not admissible for `submit_park_resume`.
Once the handle is recorded, recovery reconnects to that attempt instead of creating a fresh
provider task. The completion signal is a wake token carrying completion status and optional
provider result locator; the resumed `StageAction` reads the attempt record, fetches or validates
the provider result, and maps it to output envelopes or a typed failure.

**The failure path is typed.** Job reject, calibration error, queue timeout, and async-submit
failure propagate through the **failure closure** (ADR 0026): the realize stage fails with a typed
reason, delivered as a failure outcome on the same durable signal, and downstream stages observe the
closed failure rather than a missing result. A realize node _may_ additionally expose a typed error
output for recoverable backend errors an author wants to branch on, but the default negative path is
closure, not silence.

### 4. Analysis is ordinary downstream Pulse stages

Syndrome extraction, decoding, and reporting are not external-backend work. They are pure or
host-effecting stages downstream of the measurement frontier, scheduled like any other Pulse stage.
The QEC decoder is data-pipeline post-processing on labeled measurement outputs, not a quantum
executor.

## Mental Model

> A backend is bound once as a Capability and runs as a Pulse stage. The author builds the circuit
> as Wire and _collects_ it into a realize node: its payload is the fused gates, its outputs are the
> measurement results. Cheap backends return inline; long-running backends submit, park on a
> completion signal, and resume. Decoding is just the next stage.

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
  separate realize nodes; the validator never silently splits. Frozen classical parameters fed to a
  realize node are not authority violations.
- **Idempotency is anchored to a durable attempt record.** A separate external-call attempt record
  holds the idempotency key, external job handle, frozen fused plan, and completion signal name.
  Attempt reservation precedes provider submit; the provider call happens outside the DB
  transaction; ADR 0058 settlement atomically links the waiting node and signal to the attempt
  record. The key is read back from the attempt record on resume, never recomputed from the
  rewritable graph, so replay after a crash never double-submits. Signal/wait rows are not
  overloaded with this metadata.
- **Fused-plan emission is canonical.** The payload is a deterministic canonical linearization of
  the frozen subgraph, so the same topology yields the same plan and hash across replays.
- **Await strategy is binding metadata, not Pulse interpretation.** The synchronous vs
  submit/park/resume choice lives in the ADR 0053 admission projection / binding record; Pulse
  dispatches an opaque `StageAction` and reacts only to complete-or-suspend.
- **The negative path is closed, not silent.** Backend failures propagate through the ADR 0026
  failure closure with a typed reason; the realize node never resumes with a missing result.

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

- Add a realize-node (`collect`-style) external-call executor with one typed output port per named
  measurement, and the materialization rule that sinks its upstream same-authority,
  same-await-strategy frontier into one stage carrying the canonically-serialized fused plan.
- Implement the decidable admission validator in the `validatorReady` lineage: nodes inside the
  collected set share one backend authority and await strategy, no non-backend node intervenes, and
  mixed collected authorities are rejected. Frozen classical boundary inputs to the realize node are
  allowed and are not cross-authority violations.
- Add an **await strategy** field (`synchronous` | `submit_park_resume`) to the ADR 0053 admission
  projection / runtime binding record — at the executor level, covering `ModelExecutor` too. Pulse
  dispatches the opaque `StageAction` and reacts only to complete-or-suspend; it does not read the
  field.
- Define a Pulse-owned durable **external-call attempt record** holding
  `{idempotency key, external job handle, frozen fused plan, completion signal name}` as opaque
  provider-aware runtime state. Reserve it before provider submit, persist the handle before
  returning `StageSuspend`, and have ADR 0058 settlement atomically link the waiting node/signal to
  that attempt. Deliver completion through an **ordinary durable signal** via the service API (never
  the reserved `run-terminal:` family). The signal wakes the run and may carry completion status or
  a result locator, but the resumed `StageAction` remains responsible for fetching/validating
  provider results and producing output envelopes or a typed failure.
- Route backend failures (reject, timeout, calibration, submit failure) through the ADR 0026 failure
  closure with a typed reason.
- Ship the quantum surface as ADR 0054 artifacts: a `quantum.*` Wire package (contracts + admission
  projections + reusable `.wire` modules) and a Braket host runtime binding pack that mints the ADR
  0053 runtime binding records; runnable lowering without the pack fails with
  `missing runtime binding`.
- Keep the standalone bridge and `wire run` path working; both consume the same Capability binding.

#### Formal (theory/)

- Discharge port-linearity for the realize contraction: establish that it reduces to `bulkContract`
  (cite `bulkContract_preserves_portLinear`) or, failing that, prove `realize_preserves_portLinear`.
- Account the collected external-call resource under ADR 0032's boundary resource algebra, and show
  the contraction obeys ADR 0035's rewrite boundary laws.
- Confirm the gas treatment against ADR 0056: a **source-authored** realize contraction is
  compile-witnessed materialization — **gas-neutral as an admission gate, recorded as cost/metric**,
  never rejected for gas. When an **open producer** introduces the frontier it pays once at its own
  admission boundary (ADR 0056/0057); the later witnessed realization does not refill or recharge.

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

(The admission rule, per-measurement typing, idempotency anchoring, the linearity discharge, and the
gas treatment were open questions in earlier drafts; review promoted them to the decisions and
obligations above — the gas treatment resolves to ADR 0056's witnessed-neutral rule.)

1. **Does realize reduce to `bulkContract`?** The ADR's position is yes (reuse the existing proof);
   the formal obligation will confirm or refute it. If it does not reduce,
   `realize_preserves_portLinear` is a genuinely new proof, and that changes the cost of this ADR.
2. **Where fusion lives.** Does the canonical fused-plan builder run in Pulse materialization or
   stay host-side and get handed the collected frontier? The host-owned-effect boundary (ADR 0003)
   argues host-side; materialization must at least identify and freeze the frontier the realize node
   sinks.
3. **Local-sim durability.** Should synchronous local simulation run as a Pulse stage at all, or
   stay on the `wire run` path? Uniformity vs overhead.
4. **Await-strategy taxonomy.** Is `synchronous | submit_park_resume` sufficient, or do streaming
   and partial-result backends need a third shape?

## First Consumer

The QEC repetition-code workbench (#269) is the prototype, and it validates the boundary on the
`wire run` + bridge path. Hardware execution itself already exists through the standalone OpenQASM
bridge(s) — it is **not** the future work. The remaining work this ADR scopes is the **Pulse-durable
frontier integration**: the realize-node contraction, the await strategy, and submit/park/resume
over an ordinary durable signal. The first such durable frontier becomes the revisit point for this
ADR, per the "ADR after the prototype clarifies the boundary" sequencing.
