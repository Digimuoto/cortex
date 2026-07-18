---
title: "ADR 0092 — Circuit Engine and Runtime-Host Boundary"
description:
  "Makes the generated circuit engine the canonical owner of fixed-topology scheduling and
  transition validation while runtime hosts own effects, durability, authority, and control."
sidebar:
  label: "0092. Engine and runtime host"
  order: 92
status: accepted
date: 2026-07-18
superseded_by: null
related:
  - docs/Architecture/04-graph-and-circuit.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/ADRs/0003-pulse-service-and-host-action-boundary.md
  - docs/ADRs/0004-graph-native-pulse-execution.md
  - docs/ADRs/0090-computable-pulse-kernel-and-extraction-boundary.md
  - docs/ADRs/0091-lean-hosted-freestanding-wire-c-backend.md
  - docs/ADRs/0093-versioned-circuit-state-event-control-protocol.md
  - docs/ADRs/0094-hosted-x86-64-linux-executable-profile.md
---

# ADR 0092 — Circuit Engine and Runtime-Host Boundary

## Status

Accepted. The target-independent decision model, generated C engine ABI, generic process host, Pulse
whole-run host, and non-Pulse reference host implement this boundary for the fixed-topology,
effect-only DAG profile.

## Context

Circuit is the admitted executable topology, but the original implementation coupled its driving
loop to Pulse's Haskell graph executor. That made durable execution work, yet it obscured two
independent responsibilities:

- deciding which node may run and whether a completion is a valid state transition; and
- exercising runtime authority, executing effects, and making state durable.

The freestanding C backend in ADR 0091 supplied a topology-specialized decision implementation. The
hosted Linux work needed the same engine to run under Pulse without making Pulse protocol,
PostgreSQL, credentials, or effect values part of the generated artifact.

## Decision

The canonical fixed-topology execution chain is:

```text
admitted Circuit
  → cortex.wire.static-program/v1
  → generated C circuit engine
  → target executable
  → runtime host
```

The **circuit engine** owns:

- dense-node scheduling and frontier order;
- readiness, completion, skip, failure closure, cancellation, and terminal validation;
- monotonic checkpoint sequencing; and
- import/export validation for its typed structural state.

The **runtime host** owns:

- effect implementations and all credentials, bindings, and capabilities;
- retries, timeouts, replay policy, leases, and external idempotency;
- durable checkpoint commit and recovery storage;
- process lifecycle, cancellation requests, observability, and operator control; and
- actual effect values. The engine sees only opaque nonzero output handles.

Pulse is one production runtime host. Its graph-native executor from ADR 0004 remains the default
backend and remains the host for dynamic topology, conditions, signals, artifacts, rewrites, and
other profiles outside the static engine. For an eligible compiled Circuit, Pulse may instead host
the generated executable as a second whole-run backend. This clarifies ADRs 0003 and 0004; it does
not supersede or edit them.

The generic boundary is proved operationally by `runHostedReferenceHost`, which completes effects
without Pulse or PostgreSQL. Pulse integration is therefore not a `StageAction` and the generated
engine is not a Pulse subprocess with embedded Pulse authority. It is a decision process hosted by
an authority-bearing runtime.

### Process and authority boundary

Each Circuit run gets one child process. The host spawns the caller-supplied, validated artifact and
communicates through inherited stdin/stdout pipes. The executable has no listener, socket, attach
token, embedded public key, credential, or independently attaching supervisor protocol. Stdout is
the versioned engine protocol; bounded stderr is diagnostics only.

A host failure, lease loss, stale graph-state CAS, persistence failure, malformed protocol, identity
mismatch, or unexpected child exit terminates the process and cancels workers while preserving the
last committed snapshot. Selecting the hosted backend is explicit and frozen for the run; it never
falls back to the Haskell executor after execution begins.

### Eligibility

The first hosted engine profile admits exactly the existing static-program subset: a closed,
fixed-topology DAG of effectful task nodes. Delayed CorePure, conditions/select, signals, artifacts,
rewrites, runtime topology mutation, and streaming dataflow are typed rejections.

## Alternatives considered

- **Keep Pulse as the only Circuit driver.** Rejected because it makes scheduling semantics and
  runtime authority inseparable and prevents a portable target executable.
- **Embed Pulse, PostgreSQL, or credentials in the executable.** Rejected because target code would
  acquire host authority and a consumer-specific persistence dependency.
- **Make the hosted engine another `StageAction`.** Rejected because the engine owns the whole
  Circuit drive, not one effect node inside Pulse's scheduler.
- **Allow attaching supervisors.** Rejected for v1. Inherited pipes and parent ownership give one
  unambiguous authority path without cryptographic attachment policy.

## Consequences

### Positive

- One admitted static Circuit has a portable decision engine and multiple possible hosts.
- Pulse retains its durable machinery without remaining the exclusive expression of Circuit
  scheduling semantics.
- Generated artifacts stay inert and authority-free.
- A reference host can test portability independently from Pulse.

### Negative

- The static hosted profile is narrower than general Pulse execution.
- Process and protocol supervision add overhead relative to in-process Haskell execution.
- Hosts must serialize accepted completions around durable checkpoint acknowledgements.

### Obligations

- Keep scheduling and transition decisions in the generated engine, not in a hosted runner.
- Keep host authority, effect values, credentials, and bindings out of engine state and manifests.
- Preserve the explicit no-fallback backend selection and exact artifact/profile resume check.
- Raise a new decision before adding shared daemons, socket attachment, alternate transports, or
  streaming dataflow.

## Traceability

- Feature keys: `wire.circuit_engine_host_boundary`
- Public surface: `Cortex.Wire`, `Cortex.Pulse`, `CircuitExecutionBackend`, `CircuitRunOptions`,
  `runHostedProgram`
- Implementation: `src/Cortex/Wire/Circuit/{Engine,Hosted}.hs`,
  `src/Cortex/Pulse/Circuit/Hosted.hs`, `src/Cortex/Pulse/Circuit.hs`
- Tests: `test/Cortex/Wire/Circuit/EngineSpec.hs`, `test/Cortex/Pulse/ExecutorSpec.hs`,
  `checks.cortex-wire-hosted-pulse`
- Theory/proof: `Cortex.Wire.StaticC.driveEngine_*`

## Related

- [ADR 0003 — Pulse Service and Host-Action Boundary](0003-pulse-service-and-host-action-boundary.md)
- [ADR 0004 — Graph-Native Pulse Execution](0004-graph-native-pulse-execution.md)
- [ADR 0090 — Computable Circuit-Engine Decision Kernel](0090-computable-pulse-kernel-and-extraction-boundary.md)
- [ADR 0091 — Lean-Hosted Freestanding Wire C Backend](0091-lean-hosted-freestanding-wire-c-backend.md)
- [ADR 0093 — Versioned Circuit State, Event, and Control Protocol](0093-versioned-circuit-state-event-control-protocol.md)
- [ADR 0094 — Hosted x86_64 Linux Executable Profile](0094-hosted-x86-64-linux-executable-profile.md)
