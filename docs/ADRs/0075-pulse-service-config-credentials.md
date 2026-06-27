---
title: "ADR 0075 — cortex-pulse Service Config, Runner-Token Minting and Credential Surface"
description:
  "cortex-pulse fixes its process-level service-config and credential surface at the CLI boundary:
  secrets enter only as file paths, the JWT signing secret is mandatory and non-empty, credentials
  are held redacted in a typed config, and concurrency caps are clamped to safe ranges."
sidebar:
  label: "0075. Pulse service config & credentials"
  order: 75
status: proposed
date: 2026-06-27
superseded_by: null
related:
  - docs/Architecture/06-pulse-runtime.md
  - docs/Reference/Pulse/service-api.md
  - docs/Reference/Pulse/host-actions.md
  - docs/Reference/feature-status.md
  - docs/ADRs/0003-pulse-service-and-host-action-boundary.md
  - docs/ADRs/0008-pulse-operator-visibility-surfaces.md
  - "GitHub #304"
---

# ADR 0075 — cortex-pulse Service Config, Runner-Token Minting and Credential Surface

## Status

Proposed — this records the configuration and credential contract already shipped on the
`cortex-pulse` shell. The decision is not yet accepted, and the implementation is partial: the
config/credential _surface_ exists, but token minting and credential _selection_ are not present in
this repository (see Consequences and the feature-status row).

## Context

ADR 0003 made `Pulse` a standalone durable execution service that reaches host domain behavior only
through authenticated, idempotent host actions, and asserts that communication uses "a dedicated
service credential". ADR 0008 fixed the operator-visibility surfaces. Neither ADR says how a running
`cortex-pulse` process is _configured_: where its database and pool settings come from, how the
signing material for runner tokens enters the process, how the service credential is provisioned, or
how the two credential flags relate. The Pulse Service API reference states the inbound auth and
idempotency contract but not the process-startup configuration that backs it.

That gap matters because the configuration surface is security-relevant. The process needs:

- database connection and pool sizing,
- JWT signing material plus issuer / audience / expiry for the runner tokens that authenticate Pulse
  to the host,
- a service credential for internal host actions (with a legacy admin-API-key predecessor still in
  the field),
- concurrency caps that bound how much work a single instance claims.

A secret that arrives as a command-line flag value leaks into process listings, shell history, and
crash dumps. A signing secret that silently defaults lets an unconfigured deployment mint tokens
that a host cannot distinguish from a configured one. A configuration surface that prints itself
verbatim leaks credentials into logs and traces. The substrate needs an explicit decision about how
this surface is shaped, independent of the host-boundary decision in ADR 0003.

## Decision

`cortex-pulse` fixes its process-level service-config and credential surface at the executable's CLI
boundary, carried by a single typed `PulseConfig` value, with the following invariants.

- **Configuration is a typed record.** All process configuration is collected into `PulseConfig`
  (`src/Cortex/Pulse/Types.hs`), constructed once in `app/cortex-pulse/Main.hs` and passed to
  `runPulse`. `PulseConfig` is re-exported on the public `Cortex.Pulse` root.
- **Secrets enter as file paths, never as flag values.** Every credential-bearing input is a path:
  `--db-password-file`, `--jwt-secret-file`, `--admin-api-key-file`, `--service-credential-file`.
  The process reads the file at startup and trims trailing whitespace; no secret material appears on
  `argv`.
- **The JWT signing secret is mandatory and non-empty.** `readRequiredSecretFile` aborts startup
  with a `userError` when `--jwt-secret-file` is absent ("Pulse must be able to mint runner tokens")
  or resolves to an empty file. The DB password, admin API key, and service credential are optional:
  an absent password is the empty text, and an absent admin key or service credential is `Nothing`.
- **The admin API key is a deprecated alias for the service credential.**
  `--service-credential-file` is the dedicated Pulse service credential for internal host actions;
  `--admin-api-key-file` is retained and labeled legacy ("prefer `--service-credential-file`"). Both
  are loaded independently into `pulseAdminApiKey` and `pulseServiceCredential`. The precedence is
  expressed as a CLI deprecation label, not as runtime selection code in this repository.
- **The config redacts itself.** The hand-written `Show PulseConfig` renders the DB password and JWT
  secret as `<redacted>`, the admin API key as `Just <redacted>` / `Nothing`, and elides the
  remaining fields (including the service credential) behind `...`. No credential is rendered in
  cleartext.
- **Concurrency caps are clamped at `runPulse`.** `--max-concurrent-tasks` (default 4),
  `--max-frontier-concurrency` (default 1, sequential), and repeatable
  `--task-type-max-concurrent TYPE=N` are clamped to safe ranges before use: max-concurrent to at
  least 1, frontier concurrency to `[1, 16]`, and every per-type limit to at least 1; the per-type
  parser rejects `N < 1`.

This is one decision: the shape of the process-startup configuration and credential surface. It does
not decide how runner tokens are signed or which credential a host action selects — those are
downstream of this surface (see Consequences).

## Boundary rules

The security-relevant invariants that are actually implemented at this surface:

1. Credential material is supplied only by file path; flag values never carry secrets.
2. Startup fails closed when the runner-token signing secret is missing or empty, before any DB pool
   or scheduler work begins.
3. The runner-token claim parameters are fixed config, not derived: `--jwt-issuer` (default
   `cortex-pulse`), `--jwt-audience` (default `cortex-host`), `--jwt-expiration` (default 86400 s).
4. `PulseConfig`'s `Show` instance never prints a secret in cleartext.
5. Within the runtime, the credential fields are held on `PulseConfig` and reachable through the
   executor's `TaskContext` (`tcConfig`), but they are _not_ threaded to stage or node runners:
   `mkStageEnv` forwards only `pulseMaxFrontierConcurrency` onto `StageEnv`. The inbound
   `X-Pulse-Credential` validation (constant-time, fail-closed) is the Service API contract; the
   HTTP server that enforces it is not part of this repository's grounded surface.

## Alternatives considered

- **Pass secrets as CLI flag values or environment variables directly.** Rejected — flag values and
  environment leak into process listings, shell history, supervisor configs, and crash dumps. Taking
  only a file path keeps the secret bytes off `argv` and lets the operator own file permissions.
- **Make the JWT signing secret optional with a generated default.** Rejected — a silently defaulted
  signing key lets an unconfigured deployment mint runner tokens that look configured. Failing
  closed at startup is the safer default for security-relevant material.
- **Collapse `--admin-api-key-file` and `--service-credential-file` into one flag now.** Rejected —
  deployments already provision the admin key. Keeping both with a deprecation label lets the
  service credential become canonical without a breaking flag removal; the surface can drop the
  legacy flag once consumers migrate.

## Consequences

### Positive

- The process never accepts secret material on `argv`; the typed `PulseConfig` is the single carrier
  and redacts itself on display.
- An unconfigured runner-token signing secret fails fast and loudly rather than minting under an
  implicit key.
- Concurrency is bounded even under hostile or typo'd input, because the caps are clamped rather
  than trusted.

### Negative

- The credential surface is fixed but the runtime in this repository does not yet consume it: no JWT
  signing library is imported in `src/` or `app/`, and the substrate shell runs with an empty task
  registry. The config carries signing material and credentials that this shell never uses, so the
  gap between the surface and any minting behavior must be tracked, not assumed closed.
- The admin-key / service-credential precedence is a labeling convention at the CLI, not enforced
  selection logic, so "prefer the service credential" is documentation, not a runtime guarantee.

### Obligations

- Keep the JWT signing secret mandatory and non-empty; do not introduce a default.
- Keep `Show PulseConfig` in lockstep with new secret fields so no credential is ever printed.
- When runner-token minting and credential selection land — in a consumer runner or the substrate —
  they must read from this typed config, honor the service-credential-over-admin-key precedence, and
  gain dedicated tests; the feature-status `Tests` cell and impl status move forward only then.
- Resolve the placement question recorded below before the ADR is accepted.

## Open questions

- **Stage-3 placement.** This is a process-startup configuration and credential surface exposed at
  the `cortex-pulse` CLI boundary, so its primary category here is **Packaging, CLI & tooling**. But
  what it configures — the service credential, the runner-token claim parameters, and the scheduler
  concurrency caps — is owned by the **Pulse runtime** (ADR 0003). Whether this decision classifies
  as CLI tooling or as Pulse runtime is deferred to the Stage-3 classification of this sweep (GitHub
  #304).
- **Runner-token minting.** The title and config surface anticipate runner-token minting, but no
  signing path exists in this repository (see Consequences): the config carries the JWT claim
  parameters and signing-secret path, yet nothing in `src/` or `app/` mints a token. How tokens are
  signed and rotated, and which credential a host action selects, is a separate future decision
  downstream of this surface — not settled here.

## Traceability

- Feature keys: `cli.service_config`
- Public surface: `Cortex.Pulse` (re-exports `PulseConfig`), the `app/cortex-pulse` executable,
  `docs/Reference/Pulse/service-api.md`
- Implementation: `app/cortex-pulse/Main.hs`, `src/Cortex/Pulse/Types.hs`, `src/Cortex/Pulse.hs`
- Tests: none
- Theory/proof: none
- Tracking: GitHub #304

## Related

- [ADR 0003 — Pulse Service and Host-Action Boundary](./0003-pulse-service-and-host-action-boundary.md)
  — asserts the dedicated service credential this ADR provisions.
- [ADR 0008 — Pulse Operator Visibility Surfaces](./0008-pulse-operator-visibility-surfaces.md) —
  the operator-facing surfaces that the same process exposes.
- [Chapter 06 — Pulse Runtime](../Architecture/06-pulse-runtime.md)
- [Pulse Service API Reference](../Reference/Pulse/service-api.md) — inbound auth and idempotency
  contract.
- [Pulse Host Actions Reference](../Reference/Pulse/host-actions.md) — the outbound Pulse → host
  direction the service credential authenticates.
- GitHub #304
