# Pulse schema migrations

Forward, idempotent DDL for the `pulse` schema, applied to **deployed** databases provisioned before
the corresponding code change.

This repository has **no in-repo migration runner**. The `pulse` schema is owned by Pulse and
applied out of band; `test/sql/pulse-schema.sql` is a generated dump used only by the ephemeral test
database (`just test-db`), which already reflects every column. These files exist so an operator (or
the deployment / schema pipeline that provisions the `pulse` schema) can bring an existing database
up to the current shape.

- Each file is named `NNNN_short_description.sql`, applied in lexical order.
- Each is **idempotent** (safe to re-run) and backfills existing rows.
- Apply the relevant migrations **before** rolling out the code that depends on the new shape.

Apply one with, e.g.:

```sh
psql -v ON_ERROR_STOP=1 -f migrations/0001_graph_rewrites_admission_mode.sql
```

| File                                     | Adds                                                                      | For code                                                    |
| ---------------------------------------- | ------------------------------------------------------------------------- | ----------------------------------------------------------- |
| `0001_graph_rewrites_admission_mode.sql` | `pulse.graph_rewrites.admission_mode`                                     | ADR 0055 / 0056 witnessed self-append admission             |
| `0002_external_call_attempts.sql`        | `pulse.external_call_attempts` table, key index, run FK, `failure_reason` | ADR 0059 §3 durable submit/park/resume external-call stages |
