---
title: "Hosted Circuit Execution"
description:
  "Normative build, artifact, engine-state, JSONL protocol, and Pulse-host integration contract for
  the x86_64-linux-v1 Circuit target."
sidebar:
  label: "Hosted execution"
  order: 9
status: accepted
date: 2026-07-18
related:
  - docs/ADRs/0091-lean-hosted-freestanding-wire-c-backend.md
  - docs/ADRs/0092-circuit-engine-runtime-host-boundary.md
  - docs/ADRs/0093-versioned-circuit-state-event-control-protocol.md
  - docs/ADRs/0094-hosted-x86-64-linux-executable-profile.md
  - docs/Architecture/06-pulse-runtime.md
---

# Hosted Circuit Execution

This page is the normative interface for building and hosting Cortex's first complete target
executable. It does not replace the freestanding `cortex_wire_program_v1_*` ABI: the hosted engine
ABI and process protocol are separately versioned additions.

## Build command

```text
wire build --target x86_64-linux-v1 --output DIR [--return NAME] FILE
```

The command is supported on x86_64 Linux through the Nix-wrapped toolchain. It compiles and admits
the selected Wire return, lowers `cortex.wire.static-program/v1`, invokes the Lean-hosted C emitter,
and links the generated engine with the POSIX JSONL runner.

The output directory contains:

| File                     | Contract                                                                |
| ------------------------ | ----------------------------------------------------------------------- |
| `circuit-engine`         | Topology-specialized x86_64 Linux ELF.                                  |
| `hosted.manifest.json`   | Inert target, schema, identity, provenance, and digest manifest.        |
| `static-program.json`    | Canonical `cortex.wire.static-program/v1` input.                        |
| `executor-map.json`      | Dense node ID to logical node/executor map.                             |
| `program.c`, `program.h` | Generated implementation and both freestanding/engine ABI declarations. |
| `program.manifest.json`  | Lean emitter counts and program identity.                               |

The manifest schema is `cortex.wire.hosted-program-manifest/v1`; the target is
`cortex.wire.target/x86_64-linux-v1`, the target triple is `x86_64-unknown-linux-gnu`, the engine
ABI is `cortex.wire.engine/v1`, and the process protocol is `cortex.wire.host-process/v1`.

`loadHostedProgramArtifact` is the only constructor for `HostedProgramArtifact`. It validates the
manifest and target, requires a safe relative executable name, checks a regular executable file, and
recomputes the SHA-256 digest. A caller must load the artifact again when resuming; Pulse does not
store executable bytes.

## Eligibility

`x86_64-linux-v1` accepts a fixed acyclic topology containing only effectful task nodes. It rejects
CorePure residue, conditions/select, signals, artifacts, rewrites, runtime topology changes,
streaming dataflow, sparse dense IDs, malformed edges, or artifact/program mismatch. Rejection is
typed and never falls back to another backend.

## Engine state

`cortex.wire.engine-state/v1` contains:

- program identity;
- positive checkpoint sequence;
- dense node statuses;
- opaque `uint64` output handles; and
- active/completed/failed/cancelled terminal state.

Handle zero means no output. A completed node must have a nonzero handle; all other statuses must
have zero. The engine validates identity, node count, dependency closure, normalization, status,
terminal state, and handle presence on import. Effect values, credentials, and runtime bindings are
forbidden from the state.

## Process protocol

The executable reads host commands from stdin and writes engine events to stdout as canonical JSONL.
Each line is bounded to 2 MiB. Stdout carries protocol only; stderr is diagnostic and host capture
is bounded to 64 KiB.

| Direction     | Messages                                                                             |
| ------------- | ------------------------------------------------------------------------------------ |
| Engine → host | `hello`, `checkpoint`, `effect_requested`, `terminal`, `protocol_error`              |
| Host → engine | `start`, `restore`, `effect_completed`, `checkpoint_committed`, `cancel`, `shutdown` |

Every message carries `protocol`; run-scoped messages carry `run_id`; effect and checkpoint messages
carry their monotonic sequence where applicable. Wrong versions, identities, run IDs, sequences,
message kinds, malformed JSON, oversized lines, and duplicate/stale completions fail closed.
Cancellation is the deliberate race-tolerant exception: `cancel` is an idempotent no-op after the
engine has made a terminal decision, both before acknowledgement of its final checkpoint and after
the terminal event, because host intent can cross terminal output already in flight.

Cancellation is race-tolerant in both directions. Once the host has sent `cancel` it drops rather
than forwards everything the engine produced before reading it: late effect requests, late worker
completions, and completions buffered behind a pending checkpoint. The engine's cancelled checkpoint
is the single durable authority for what was undone. If a cancel arrives at the engine while a
checkpoint is unacknowledged, the engine defers it and applies it immediately after the
acknowledgement — a cancel never invalidates an in-flight checkpoint sequence.

An effect worker torn down because the run itself is being stopped (host shutdown, operator
cancellation) reports an _interruption_, not a completion. The host never forwards interruptions:
the engine keeps the node running until the imminent `cancel` resets it to pending, so durable state
never records a stopping host as a node failure. Interruptions are only legal when a cancellation
watcher is installed. That watcher must either issue the run-level cancel or report its own failure
within the same bounded response window; an interrupted node cannot leave a run waiting forever.

The host arms a 60-second response deadline whenever the protocol mandates engine output (the
checkpoint after `start`/`restore`/`effect_completed`/`cancel`, and child exit after `shutdown`). A
fresh deadline begins only when a new obligation is created and is cleared by the matching response
before host-side persistence begins. Unrelated queued traffic cannot extend it, and effect execution
is not timed as protocol work. A wedged engine or cancellation watcher fails the run instead of
pinning it while its lease renews; a child that ignores `shutdown` after a committed terminal is
killed without affecting the recorded outcome. Async lease cancellation propagates to the lease
supervisor and is never converted into a hosted run fault.

`defaultHostedResponseTimeout` is 60 seconds. Hosts that need a tighter bound construct a positive
`HostedResponseTimeout` with `mkHostedResponseTimeout` and use
`runHostedProgramWithResponseTimeout`; the deadline remains per protocol obligation rather than an
effect-execution timeout.

The host re-hashes the executable immediately before every spawn (fresh and resume) and fails closed
on a digest mismatch. A hash-then-exec of a path still leaves a millisecond replacement window that
the portable process API cannot close (that would need `O_PATH` + `fexecve`); the recheck bounds the
exposure to that window instead of the artifact's lifetime.

Checkpoint order is load-bearing:

1. Commit the initial checkpoint before the first effect.
2. Commit and acknowledge every accepted completion checkpoint before driving a successor.
3. Commit and acknowledge the final checkpoint before accepting the terminal event.

Ready effects may execute concurrently. A host serializes completion delivery and checkpoint
acknowledgements and may buffer workers that finish while another checkpoint is pending.

### Host-protocol assurance boundary

The Lean engine model proves snapshot validity, whole-drive classification, and the checkpoint gate;
it intentionally carries no process handles, workers, queues, or clocks. The concurrent host
lifecycle is a separate state machine:

- `Cortex.Wire.Circuit.HostProtocol` is the pure executable policy used by the IO event loop;
- `formal/HostedProtocol.tla` is its bounded concurrency model; and
- `Cortex.Wire.Circuit.HostedSpec` refines the policy against real pipes, workers, cancellation, and
  child processes through scripted engines.

TLC checks acknowledgement before successor work, buffered-completion gating, successful-terminal
quiescence, operator and interruption-driven cancellation liveness, crossing-checkpoint deadline
preservation, unrelated-traffic deadline stability, terminal precedence after child exit, and the
prohibition on forwarding direct or buffered completions after cancellation or terminal authority.
Four expected-failure configurations remove one protection at a time, including post-terminal
completion dropping, so those completion and deadline properties exercise a reachable violation.

The proof boundary is deliberate: Lean proves that an accepted engine completion cannot unlock
successor drive before the checkpoint gate, while TLA+ proves the host lifecycle ordering around
workers, acknowledgements, cancellation, clocks, and child exit. Neither model is described as
proving the other's state space. Run both the Wire host model and the existing Pulse run-terminal
signal model with:

```sh
just tla-check
```

The repository records transport overhead with an opt-in Criterion suite:

```sh
just bench-hosted-protocol
```

It measures representative command encoding, event round trips, and checkpoint batches. Timings are
observations rather than acceptance thresholds; CBOR or shared memory requires measured end-to-end
pressure or a future streaming-dataflow requirement.

## Runtime hosts

`runHostedProgram` is the generic inherited-pipe host. `runHostedReferenceHost` supplies inert
success effects and proves that Pulse is not required by the engine boundary.

Pulse selects the backend through:

```haskell
data CircuitExecutionBackend
  = PulseGraphRuntimeV1
  | HostedX86_64LinuxV1 HostedProgramArtifact

data CircuitRunOptions = CircuitRunOptions
  { croExecutionBackend :: CircuitExecutionBackend
  }
```

`defaultCircuitRunOptions` selects `PulseGraphRuntimeV1`. Option-bearing fresh and resume functions
exist for caller-owned and managed runs; compatibility entrypoints retain the default.

For hosted runs, Pulse freezes backend, program identity, artifact digest, and protocol version
before the first effect. It persists actual JSON outputs in `pulse.graph_state.node_outputs` and
reconstructs engine handles as dense ID plus one. `node_statuses` and `node_outputs` remain the sole
authoritative recovery snapshot; `hosted_checkpoint_sequence` and `hosted_terminal_state` record
only the acknowledged engine sequence and terminal decision. Resume verifies the exact artifact
profile before lease claim and restores a fresh child.

## Authority and non-goals

The executable has no socket, listener, attachment token, embedded key, credential, or host-action
binding. The spawning runtime host supplies all authority through inherited pipes. External manifest
signatures may attest distribution but do not grant runtime capability.

CBOR, shared memory, streaming values, a shared daemon, socket attachment, executable encryption,
and a second non-Pulse production supervisor are outside v1.

## Related

- [Chapter 06 — Pulse Runtime](../../Architecture/06-pulse-runtime.md)
- [Pulse Schema Reference](../Pulse/schema.md)
- [ADR 0092 — Circuit Engine and Runtime-Host Boundary](../../ADRs/0092-circuit-engine-runtime-host-boundary.md)
- [ADR 0093 — Versioned Circuit State, Event, and Control Protocol](../../ADRs/0093-versioned-circuit-state-event-control-protocol.md)
- [ADR 0094 — Hosted x86_64 Linux Executable Profile](../../ADRs/0094-hosted-x86-64-linux-executable-profile.md)
