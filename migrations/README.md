# Pulse schema migrations

Forward, idempotent DDL for the `pulse` schema, applied to **deployed** databases provisioned before
the corresponding code change.

This repository has **no in-repo migration runner**. The `pulse` schema is owned by Pulse:
`data/pulse-schema.sql` is the curated full-schema dump a fresh database is provisioned from — by
`Cortex.Pulse.Database.provisionPulseSchema` (the library surface) and by the ephemeral test
database (`just test-db`) — and already reflects every column. These migration files exist so an
operator (or the deployment / schema pipeline that provisions the `pulse` schema) can bring an
**already-deployed** database up to the current shape without re-provisioning.

- Each file is named `NNNN_short_description.sql`, applied in lexical order.
- Each is **idempotent** (safe to re-run) and backfills existing rows.
- Apply the relevant migrations **before** rolling out the code that depends on the new shape.

Apply one with, e.g.:

```sh
psql -v ON_ERROR_STOP=1 -f migrations/0001_graph_rewrites_admission_mode.sql
```

| File                                              | Adds                                                                      | For code                                                    |
| ------------------------------------------------- | ------------------------------------------------------------------------- | ----------------------------------------------------------- |
| `0001_graph_rewrites_admission_mode.sql`          | `pulse.graph_rewrites.admission_mode`                                     | ADR 0055 / 0056 witnessed self-append admission             |
| `0002_external_call_attempts.sql`                 | `pulse.external_call_attempts` table, key index, run FK, `failure_reason` | ADR 0059 §3 durable submit/park/resume external-call stages |
| `0003_graph_rewrites_admission_mode_external.sql` | `'external'` in the `admission_mode` CHECK                                | ADR 0088 externally-driven step admission                   |
| `0004_pulse_artifacts.sql`                        | `pulse.artifacts` + `pulse.artifact_provenance` tables, index, FKs        | ADR 0089 content-addressed run artifact store               |
| `0005_circuit_execution_profile.sql`              | Frozen Circuit backend identity + hosted checkpoint sequence              | ADR 0092–0094 hosted Circuit execution                      |
