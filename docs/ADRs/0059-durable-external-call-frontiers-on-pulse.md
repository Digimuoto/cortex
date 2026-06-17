---
title: "ADR 0059 - Durable External-Call Frontiers on Pulse"
description:
  "How a Wire subgraph bound to an external backend (quantum, OpenAPI, WASM, MCP) runs durably on
  Pulse: the host binds an external-call capability, a connected same-backend frontier projects to a
  single Pulse stage, and long-running backends use idempotent submit/park/resume over the
  run-terminal await."
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
Pulse run, and pins the two pieces the existing executor ADRs leave open. It does not change the
registration model (ADR 0019), the executor taxonomy (ADR 0014), or the host-action boundary (ADR
0003); it composes them and adds frontier projection.

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
- **ADR 0003** restricts how Pulse reaches domain behavior: only through authenticated, idempotent
  host-action APIs, never by writing host tables or running domain backends in the runtime process.
- **ADR 0058** gives Pulse a durable await: a run can suspend on a `run-terminal:` (or general)
  signal and be woken without polling.

Despite all of this, no decision says how a Wire **subgraph** bound to an external backend becomes a
**durable Pulse stage**. Two facts collide:

1. **Granularity.** Wire models a quantum circuit as many gate-nodes, but the backend executes the
   whole circuit as one coherent submission — gates are sub-millisecond and cannot be checkpointed
   between. `docs/Consumers/Quantum.md` already states the host _"walks the materialized nodes and
   appends operations to the selected quantum circuit"_: fusion is a host responsibility today,
   performed outside Pulse. Materializing each gate as a durable stage would be absurd.
2. **Lifetime.** A local simulator call is synchronous and cheap; a hardware submission is
   long-running, externally stateful, and non-idempotent (submit returns a job id; you poll). The
   first needs no durability; the second is a textbook durable-task shape.

Because neither is pinned, external backends sit outside Pulse entirely (the #269 bridge),
forfeiting durable scheduling, recovery, observability, and the await primitive — exactly the
capabilities the hardware path most needs.

## Decision

A Wire subgraph bound to an external backend runs on Pulse as a **durable external-call frontier**,
composed from the existing layers without weakening any boundary.

### 1. Binding stays in Capability, not Pulse

The host registers the backend as an `ExternalCallExecutor` Capability spec (ADR 0019/0014) and
binds it to a runnable `StageAction` in the host process that embeds Pulse. Pulse does not gain a
backend registry, an in-process Qiskit handler, or knowledge of `quantum.*`. "Run it on Pulse" means
_the bound stage runs under Pulse's scheduler_, not _Pulse owns the backend_ — consistent with ADR
0019's "Pulse does not own executor registration" and ADR 0003's host-action boundary.

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
never stages. Its **output ports are the labeled measurement results** — `s01`, `s12`, `final_d0`, …
become the realize node's result fields, consumed by downstream stages. The realize node cannot
consume post-measurement values as _inputs_, because those exist only after it executes; it consumes
the frontier and produces the results. This is the author-explicit form of the host-walks-nodes
behavior `Quantum.md` documents, and it mirrors the existing `std.io.command` send-spec /
await-result / continue pattern the eraser already uses.

At materialization, the realize node is the **projection sink**: upstream nodes sharing its
external-call authority and effect class fuse into its payload; everything downstream is ordinary
Pulse stages.

### 3. Execution goes through the host-action boundary (ADR 0003)

The stage's external call is an idempotent host action. Two execution shapes, selected by the
backend's declared effect class:

- **Synchronous** (local simulator, fast pure-ish backends): the host action runs the fused circuit
  and returns results inline; the stage completes in one transaction.
- **Submit/park/resume** (hardware, any long-running async backend): the host action _submits_ under
  an idempotency key and returns a job handle; the run **parks** (ADR 0058) on that job's completion
  signal; the host delivers a `run-terminal`-style signal when the job finishes; the run **resumes**
  with results. No poll loop; a crash recovers to the parked-and-awaiting state, and the idempotency
  key prevents double submission on replay.

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
  submission/frontier boundary. There is no per-gate checkpoint; a circuit is re-submitted whole on
  recovery, guarded by the idempotency key.
- **One executor authority per frontier.** A frontier mixing two backends does not project to one
  call; it splits at the authority boundary into separate stages with typed ports between them.
- **Idempotency is mandatory for async submits.** Every mutating host-action submit carries an
  idempotency key derived from the run, the frontier, and the fused-plan hash, so replay after a
  crash never double-submits.
- **Effect class decides the shape.** A backend declares synchronous vs submit/park/resume in its
  Capability spec; Pulse does not infer it.

## Consequences

### Positive

- The hardware quantum path gains durable submission, recovery, and await-without-polling for free
  by reusing ADR 0058 — the single most valuable Pulse capability for long-running jobs.
- Generalizes beyond quantum: OpenAPI, WASM, and MCP backends (ADR 0014) all land as durable
  external-call frontiers through the same mechanism.
- No boundary erosion: registration stays in Capability, domain effects stay behind host actions.

### Negative

- Frontier projection is new machinery: a realize-node executor plus materialization that sinks the
  upstream same-backend frontier into its payload is more than 1:1 node-to-stage materialization.
- Two execution shapes (sync vs submit/park/resume) widen the host-action contract a backend must
  satisfy.
- Re-submitting a whole circuit on recovery wastes the prior (uncommitted) backend run; acceptable
  because partial-circuit resumption is not physically meaningful.

### Obligations

- Add a realize-node (`collect`-style) external-call executor and the materialization rule that
  sinks its upstream same-authority, same-effect-class frontier into one stage carrying the fused
  plan, with the realize node's result fields as the stage's output ports.
- Define the `ExternalCallExecutor` effect-class field (`synchronous` | `submit_park_resume`) in the
  Capability spec and have Pulse dispatch on it.
- Specify the idempotency-key derivation (run id + frontier id + fused-plan hash).
- Wire the submit/park/resume host action to ADR 0058's run-terminal await for completion delivery.
- Keep the standalone bridge and `wire run` path working; both consume the same Capability binding.

## Alternatives Considered

- **Register a quantum `TaskHandler` directly in Pulse's `TaskRegistry`.** Rejected: it would put
  backend code in the runtime process and bypass the Capability layer, contradicting ADR 0019
  ("Pulse does not own executor registration") and ADR 0003 (domain effects via host actions only).
- **Materialize each gate as a durable stage.** Rejected: gates are coherent and sub-millisecond;
  per-gate durability is meaningless and would multiply scheduling cost by ~50x for a trivial
  circuit.
- **Keep external backends outside Pulse permanently (the current bridge).** Rejected for the
  hardware path: long-running async jobs are precisely what durable runs + the await primitive exist
  for. Retained for local dev simulation, where durability adds nothing.

## Open Questions

1. **Realize-node ergonomics.** With an explicit realize node the author draws the boundary, so the
   materializer no longer infers a maximal subgraph — but it must still validate that everything
   collected into a realize node shares one backend authority/effect class, and reject a frontier
   that mixes backends or smuggles a non-fusible node. What is the exact admission rule?
2. **Where fusion lives.** Does the fused-plan builder move from the Python bridge into Pulse
   materialization, or stay host-side and get handed the realize node's collected frontier? The
   host-action boundary argues host-side; materialization needs at least to identify the frontier
   the realize node sinks.
3. **Realize node typing.** Are the realize node's result fields declared per-measurement (one
   output port per named measurement) or as a single results record the decoder destructures? The
   former keeps Wire's typed-port discipline; the latter is terser for many measurements.
4. **Idempotency-key stability under rewrite.** If a rewrite changes the frontier between attempts,
   the fused-plan hash changes; is that a fresh submission (correct) or a recovery hazard?
5. **Local-sim durability.** Should synchronous local simulation run as a Pulse stage at all, or
   stay on the `wire run` path? Uniformity vs overhead.
6. **Effect-class taxonomy.** Is `synchronous | submit_park_resume` sufficient, or do streaming and
   partial-result backends need a third shape?

## First Consumer

The QEC repetition-code workbench (#269) is the prototype. Its offline-simulator milestone validates
the boundary on the `wire run` + bridge path; its hardware extension is the first
`submit_park_resume` external-call frontier. This ADR should be revisited once that hardware path is
built, per the "ADR after the prototype clarifies the boundary" sequencing.
