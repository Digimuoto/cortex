---
title: "ADR 0094 — Hosted x86_64 Linux Executable Profile"
description:
  "Defines the opt-in x86_64-linux-v1 bundle, build command, inert manifest, validated artifact
  loader, and Pulse execution-profile persistence contract."
sidebar:
  label: "0094. Hosted x86_64 Linux"
  order: 94
status: accepted
date: 2026-07-18
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/Reference/Pulse/schema.md
  - docs/ADRs/0083-pulse-schema-lifecycle.md
  - docs/ADRs/0091-lean-hosted-freestanding-wire-c-backend.md
  - docs/ADRs/0092-circuit-engine-runtime-host-boundary.md
  - docs/ADRs/0093-versioned-circuit-state-event-control-protocol.md
---

# ADR 0094 — Hosted x86_64 Linux Executable Profile

## Status

Accepted. The CLI target, Nix-wrapped Lean/Clang build, deterministic bundle and manifest, artifact
loader, reference host, Pulse backend, migration 0005, database integration check, ELF audits, and
sanitizer/restore smoke gates implement the first hosted target.

## Context

ADR 0091 emits portable freestanding C but leaves the final adapter and link to a consumer. Cortex
also needs a complete hosted target that can be built and executed today, while keeping the
freestanding v1 ABI stable and retaining Pulse's Haskell executor as the compatibility default.

## Decision

### Build command and bundle

The canonical command is:

```text
wire build --target x86_64-linux-v1 --output DIR [--return NAME] FILE
```

It performs Wire compilation and admission, static-program lowering, Lean-hosted C generation,
pinned compilation/linking, and manifest generation. The initial build profile is supported on
x86_64 Linux through the Nix-wrapped Lean 4 and Clang 18 toolchain. Other build hosts receive a
typed unsupported-target error.

The deterministic bundle contains:

- `circuit-engine`, a topology-specialized x86_64 Linux ELF;
- `program.c`, `program.h`, and the C-emitter manifest;
- `static-program.json`;
- `executor-map.json`; and
- `hosted.manifest.json`.

The hosted manifest is inert metadata. It records the target and target triple, schema and ABI
versions, program identity, executable name, dense executor map, toolchain provenance, and SHA-256
digests for the executable and static program. It contains no effect binding, credential, attach
authority, or executable bytes.

`HostedProgramArtifact` has no public constructor. `loadHostedProgramArtifact` validates the
manifest schema, target, ABI/protocol versions, dense executor map, relative executable path,
regular executable file, and recomputed executable digest. Distribution systems may externally sign
the manifest, but a signature attests distribution only and grants no runtime capability.

### Public execution selection

The existing public roots export:

```text
CircuitExecutionBackend
  = PulseGraphRuntimeV1
  | HostedX86_64LinuxV1 HostedProgramArtifact
```

`CircuitRunOptions` and `defaultCircuitRunOptions` select the backend per compiled-Circuit run.
Existing run and resume functions remain compatibility wrappers selecting `PulseGraphRuntimeV1`.
Managed options carry the same per-run selection, and option-bearing caller-owned and managed
fresh/resume functions expose hosted execution without adding a `Cortex.Circuit` root.

Before hosted execution, Cortex lowers the Circuit independently to the Pulse plan and static
program and requires exact node, topology, executor-map, and program-identity agreement with the
artifact. Ineligible Circuit forms or mismatches are typed failures with no fallback.

### Durable identity and recovery

Migration 0005 adds nullable, consistency-checked execution backend, program identity, artifact
digest, and protocol version columns to `pulse.runs`, plus the hosted checkpoint sequence to
`pulse.graph_state`.

- Managed fresh runs write their complete profile atomically with run creation.
- Caller-owned compiled runs atomically freeze a previously-null profile before the first effect.
- Repeating the identical freeze is idempotent; any different profile is rejected.
- Resume requires the caller-supplied artifact's recomputed executable digest and identity to equal
  the persisted profile before ownership is claimed.
- Pulse stores no executable bytes; every fresh run or resume receives a caller-supplied artifact.

Pulse maps engine effect requests into its existing binding, retry, timeout, replay-safety,
stage-attempt, lease, cancellation, output-validation, and graph-state CAS machinery. Actual output
values remain in Pulse. The generic scheduler and task registry are unchanged because hosted
selection applies only to compiled-Circuit entrypoints.

## Alternatives considered

- **Make hosted Linux the default.** Rejected. The Haskell Pulse graph runtime is the compatibility
  default and supports a broader Circuit profile.
- **Store ELF bytes in PostgreSQL.** Rejected. Durable run identity needs the digest and profile,
  not an executable distribution service.
- **Encrypt or embed a public key in each executable.** Rejected. The spawning host supplies all
  runtime authority; artifact attestation is orthogonal.
- **Add a shared daemon or second production supervisor.** Deferred. One process per run and the
  reference host are sufficient to prove the generic boundary.

## Consequences

### Positive

- Cortex has a complete, reproducible hosted artifact rather than only a C module.
- Pulse can execute the same generated decision engine while retaining its durable semantics.
- Run identity prevents artifact or backend drift across resume.
- Existing callers keep their Haskell default unchanged.

### Negative

- Hosted runs pay process, JSONL, and checkpoint-acknowledgement overhead.
- Callers must retain and resupply the exact artifact for resume.
- The first target is Linux/x86_64 and only the fixed effect-only DAG subset.

### Obligations

- Keep the bundle deterministic under the pinned toolchain and audit its ELF sections/symbols.
- Verify every artifact digest on load and resume; never trust a persisted path or manifest digest
  without recomputation.
- Keep full schema dump, migration 0005, provisioning checks, schema reference, and the
  dump-versus-migrations drift gate aligned.
- Keep hosted execution opt-in and never silently fall back after selection.

## Traceability

- Feature keys: `wire.hosted_x86_64_linux`
- Public surface: `wire build --target x86_64-linux-v1`, `HostedProgramArtifact`,
  `CircuitExecutionBackend`, compiled-Circuit option-bearing run/resume functions
- Implementation: `app/wire/Main.hs`, `src/Cortex/Wire/Circuit/{Engine,Hosted}.hs`,
  `src/Cortex/Pulse/Circuit{,/Hosted}.hs`, `migrations/0005_circuit_execution_profile.sql`
- Tests: `checks.cortex-wire-hosted-linux-smoke`, `checks.cortex-wire-hosted-pulse`,
  `checks.pulse-schema-drift`, `test/Cortex/Pulse/ExecutorSpec.hs`
- Theory/proof: [Cortex Proof Status](../Reference/proof-status.md)

## Related

- [ADR 0083 — Pulse Schema Lifecycle](0083-pulse-schema-lifecycle.md)
- [ADR 0091 — Lean-Hosted Freestanding Wire C Backend](0091-lean-hosted-freestanding-wire-c-backend.md)
- [ADR 0092 — Circuit Engine and Runtime-Host Boundary](0092-circuit-engine-runtime-host-boundary.md)
- [ADR 0093 — Versioned Circuit State, Event, and Control Protocol](0093-versioned-circuit-state-event-control-protocol.md)
