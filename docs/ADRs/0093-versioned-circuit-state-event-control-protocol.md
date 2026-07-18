---
title: "ADR 0093 — Versioned Circuit State, Event, and Control Protocol"
description:
  "Defines the typed engine snapshot and bounded canonical JSONL process protocol, including the
  durable checkpoint-acknowledgement barrier that gates successor effects."
sidebar:
  label: "0093. Engine state and protocol"
  order: 93
status: accepted
date: 2026-07-18
superseded_by: null
related:
  - docs/Architecture/06-pulse-runtime.md
  - docs/Reference/Pulse/schema.md
  - docs/Reference/Pulse/events.md
  - docs/ADRs/0064-pulse-graph-state-cas.md
  - docs/ADRs/0066-pulse-resume-recovery.md
  - docs/ADRs/0092-circuit-engine-runtime-host-boundary.md
---

# ADR 0093 — Versioned Circuit State, Event, and Control Protocol

## Status

Accepted. The generated engine ABI, POSIX runner, Haskell codecs and validators, generic host, Lean
snapshot model, C harnesses, restore-boundary smoke checks, and Pulse recovery mapping implement the
v1 contracts.

## Context

A hosted circuit engine must survive host and child crashes without giving the child database
authority or persisting a second opaque state blob. It also needs a fail-closed process boundary:
unbounded or out-of-order JSON, identity drift, and premature successor dispatch are correctness
failures, not recoverable framing noise.

## Decision

### Engine ABI and state

Keep `cortex.wire.static-program/v1` and the existing `cortex_wire_program_v1_*` freestanding ABI
unchanged. Add the separately versioned `cortex_wire_engine_v1_*` ABI for hosted operation.

The exported state schema is `cortex.wire.engine-state/v1`:

- exact program identity;
- positive, monotonically increasing checkpoint sequence;
- dense node statuses;
- opaque `uint64` output handles, where zero means no output; and
- terminal state: active, completed, failed, or cancelled.

Import validates identity, node count, status domain, terminal consistency, dependency closure,
normalization, and output-handle presence. Completed nodes require nonzero handles; every other
status requires zero. The state contains no effect value, credential, runtime binding, or host
authority.

### Hosted process protocol

The process protocol is `cortex.wire.host-process/v1`, encoded as one bounded canonical JSON object
per line over stdin/stdout.

Engine events are `hello`, `checkpoint`, `effect_requested`, `terminal`, and `protocol_error`. Host
commands are `start`, `restore`, `effect_completed`, `checkpoint_committed`, `cancel`, and
`shutdown`. Messages carry the protocol version and run correlation; effect and checkpoint messages
carry their applicable monotonic sequence.

Protocol lines are limited to 2 MiB. Stdout is protocol-only. Stderr is drained as diagnostics and
captured only up to 64 KiB. Oversized, malformed, unterminated, version-mismatched, out-of-sequence,
wrong-run, duplicate, stale, post-terminal, or otherwise unexpected messages fail closed and
terminate the hosted run.

### Durability barrier

Checkpoint acknowledgement is the host/engine commit barrier:

1. The engine exports its initial state before requesting the first effect.
2. Every accepted completion increments the checkpoint sequence and exports a checkpoint.
3. The engine does not unlock or drive successor work until the host sends `checkpoint_committed`
   for that exact sequence.
4. The engine exports and waits for acknowledgement of the final checkpoint before emitting the
   terminal event.

Ready effects may run concurrently. The generic host buffers finished workers and serializes
completion delivery, checkpoint commit, and acknowledgement. A host crash may therefore repeat an
effect whose completion was not durably committed, but it cannot start a successor from an
uncommitted predecessor state.

Pulse keeps `pulse.graph_state.node_statuses` and `node_outputs` as its sole authoritative recovery
snapshot. It persists only the hosted checkpoint sequence in addition. Stable output handles are
reconstructed as dense node ID plus one; actual JSON values remain keyed by logical `NodeId`. Resume
performs existing replay normalization, deterministically constructs engine state, and restores a
fresh child process.

## Alternatives considered

- **Persist an opaque engine-state blob in Pulse.** Rejected because it creates a competing recovery
  authority and hides graph state from existing validation and inspection.
- **Acknowledge completion before persistence.** Rejected because a successor could perform an
  effect whose predecessor state disappears after a crash.
- **Socket or binary transport in v1.** Rejected. Bounded JSONL over inherited pipes is easiest to
  inspect and integrate with current Pulse; CBOR/shared memory require measured pressure or a
  streaming-dataflow profile.

## Consequences

### Positive

- Crash recovery has an explicit, testable commit boundary.
- Engine state is small, typed, authority-free, and independently validated.
- Pulse retains one canonical durable snapshot.
- Protocol transcripts are inspectable and easy to reproduce.

### Negative

- Every accepted completion adds one durability round trip.
- JSONL framing is not intended for high-volume streaming values.
- Hosts must buffer concurrent completions while one checkpoint is outstanding.

### Obligations

- Preserve acknowledgement-before-successor ordering and final-checkpoint-before-terminal.
- Reject non-normalized or inconsistent restore state rather than repairing it in the engine.
- Keep protocol and state schema versions independent from the freestanding program ABI.
- Benchmark protocol overhead without imposing a threshold; revisit transport only with evidence.

## Traceability

- Feature keys: `wire.host_process_protocol`
- Public surface: `EngineState`, `EngineEvent`, `HostCommand`, `HostedRuntimeHost`
- Implementation: `src/Cortex/Wire/Circuit/{Engine,Hosted}.hs`,
  `data/cortex-wire-hosted-runner-v1.c`, `theory/CortexWireC.lean`
- Tests: `test/Cortex/Wire/Circuit/EngineSpec.hs`,
  `test/fixtures/wire/static-program-v1/two-node-engine-harness.c`,
  `checks.cortex-wire-hosted-linux-smoke`, `checks.cortex-wire-hosted-pulse`
- Theory/proof: `Cortex.Wire.StaticC.Snapshot.Valid`, `export_import_snapshot`,
  `import_export_snapshot`, `acceptCompletion_blocks_drive`

## Related

- [ADR 0064 — Pulse Graph-State CAS](0064-pulse-graph-state-cas.md)
- [ADR 0066 — Pulse Resume and Recovery Preconditions](0066-pulse-resume-recovery.md)
- [ADR 0092 — Circuit Engine and Runtime-Host Boundary](0092-circuit-engine-runtime-host-boundary.md)
- [ADR 0094 — Hosted x86_64 Linux Executable Profile](0094-hosted-x86-64-linux-executable-profile.md)
