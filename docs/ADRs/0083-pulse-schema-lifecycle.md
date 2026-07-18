---
title: "ADR 0083 - Pulse Schema Lifecycle and Migration Policy"
description:
  "Govern Pulse's schema source of truth, fresh provisioning path, forward migration files,
  validation behavior, and downstream rollout expectations."
sidebar:
  label: "0083. Pulse schema lifecycle"
  order: 83
status: accepted
date: 2026-06-30
superseded_by: null
related:
  - docs/Architecture/06-pulse-runtime.md
  - docs/Reference/Pulse/schema.md
  - data/pulse-schema.sql
  - docs/ADRs/0003-pulse-service-and-host-action-boundary.md
  - docs/ADRs/0011-compatibility-barriers-and-fresh-run-recovery.md
---

# ADR 0083 - Pulse Schema Lifecycle and Migration Policy

## Status

Accepted. The policy is implemented by `provisionPulseSchema`, the checked-in full schema dump,
idempotent forward migration files, provisioning checks, and the required `pulse-schema-drift` Nix
gate. The guard loads the full dump, replays every migration in lexical order, normalizes `pg_dump`
session tokens, compares the resulting `pulse` schemas, and verifies the recorded migration head.

## Context

Pulse owns its `pulse` PostgreSQL schema. Fresh downstream setup uses the checked-in
`data/pulse-schema.sql` dump through `Cortex.Pulse.Database.provisionPulseSchema`, while deployed
databases need forward DDL when new tables, columns, or enum labels land. The reference docs already
describe this shape, but no ADR governed the lifecycle.

## Decision

Pulse uses a split schema lifecycle:

- `data/pulse-schema.sql` is the source used for fresh provisioning and ephemeral test databases.
- `provisionPulseSchema` creates the schema when absent and validates required current objects when
  it already exists.
- `provisionPulseSchema` is not a general migration runner and does not mutate stale deployed
  schemas into the current shape.
- Deployed databases are upgraded by explicit forward, idempotent DDL files in `migrations/`,
  applied in lexical order by the operator or deployment pipeline.
- A schema-changing PR must update the full dump, add or amend the relevant migration file for
  deployed databases, and update the schema reference when the public shape changes.
- `checks.pulse-schema-drift` must prove that applying the complete migration set to the full dump
  is a no-op and that the dump's recorded migration head names the latest migration.
- Downstreams must apply required migrations before rolling out code that depends on the new shape.

## Consequences

### Positive

- Fresh provisioning remains one library call.
- Deployed-database upgrades stay explicit and auditable.
- Downstreams can decide their own migration runner without Cortex owning deployment policy.

### Negative

- A stale deployed database is rejected or fails validation until the operator applies migrations.
- Schema changes pay the cost of maintaining both the curated dump and the forward migration, plus
  the database-backed drift check.

### Obligations

- Keep `docs/Reference/Pulse/schema.md` and `migrations/README.md` aligned with this policy.
- Keep migration files idempotent and safe to re-run.
- Maintain `checks.pulse-schema-drift` and `just schema-drift-check` as required gates.
- Do not introduce implicit destructive migrations into `provisionPulseSchema`.

## Traceability

- Feature keys: `pulse.schema_lifecycle`
- Public surface: `Cortex.Pulse.Database.provisionPulseSchema`, `docs/Reference/Pulse/schema.md`,
  `migrations/README.md`
- Implementation: `src/Cortex/Pulse/Database.hs`, `data/pulse-schema.sql`, `migrations/`
- Tests: `test/Cortex/Pulse/ExecutorSpec.hs`, `test/Cortex/Pulse/SchedulerSpec.hs`,
  `checks.pulse-schema-drift`
- Theory/proof: none

## Related

- [ADR 0003 - Pulse Service and Host-Action Boundary](./0003-pulse-service-and-host-action-boundary.md)
- [ADR 0011 - Compatibility Barriers and Fresh-Run Recovery](./0011-compatibility-barriers-and-fresh-run-recovery.md)
- [Pulse Schema Reference](../Reference/Pulse/schema.md)
- [Pulse schema migrations](../../migrations/README.md)
