---
title: Cortex Feature Status
description:
  Capability/status canon for Cortex substrate. Each row joins a stable feature key to its governing
  ADR, implementation status, tests, proof status, and reference docs. The single extraction source
  for release notes.
sidebar:
  label: Feature status
  order: 4
status: active
date: 2026-06-27
related:
  - docs/ADRs/0063-adr-traceability-and-feature-status-canon.md
  - docs/Reference/proof-status.md
  - docs/Architecture/02-ownership-and-boundaries.md
---

# Cortex Feature Status

This page is the **capability/status canon**: what substrate capabilities exist, where they live,
and how far they are verified. It is not a marketing feature list — rows cover substrate
capabilities that may not be user-visible in any product sense.

Governance, the feature-key grammar, and the column contract are defined in
[ADR 0063 — ADR Traceability and Feature Status Canon](../ADRs/0063-adr-traceability-and-feature-status-canon.md).
The three status dimensions are kept separate: **ADR status** (the decision), **implementation
status** (the code), and **proof status** (owned by [`proof-status.md`](proof-status.md); the
`Theory` cell links there rather than restating it).

Rows are seeded conservatively. A row is created with its stable feature key and an honest status
_before_ its evidence links exist; cells are filled in as the capability is governed and verified.
The matrix may under-claim (an empty cell is honest); it must never dangle — `just docs-check`
validates that every evidence link resolves.

## Status keys

| Dimension      | Values                                                                         |
| -------------- | ------------------------------------------------------------------------------ |
| ADR status     | `proposed` · `accepted` · `superseded` · `deprecated`                          |
| Implementation | `planned` · `partial` · `implemented` · `verified` · `retired`                 |
| Proof          | see [`proof-status.md`](proof-status.md) (`proven`/`hooked`/`tested`/`open`/…) |

`partial` here means: substrate code exists but the capability is not yet governed by an accepted
ADR and verified through linked evidence in this matrix. It is the conservative seed status; it is
not a claim that the feature is incomplete.

## Capabilities

| Feature key                       | Capability                                                      | Governing ADR       | ADR status | Impl status | Tests | Theory                          | Reference                                                        | Tracking |
| --------------------------------- | --------------------------------------------------------------- | ------------------- | ---------- | ----------- | ----- | ------------------------------- | ---------------------------------------------------------------- | -------- |
| `pulse.graph_state_cas`           | Optimistic-concurrency single-writer graph-state CAS            | 0064                | proposed   | partial     | —     | —                               | —                                                                | #304     |
| `pulse.frontier_concurrency`      | Concurrent frontier execution & cooperative cancellation        | 0065                | proposed   | partial     | —     | —                               | —                                                                | #304     |
| `pulse.resume_recovery`           | Graph-state-driven resume & recovery preconditions              | 0066                | proposed   | partial     | —     | [proof-status](proof-status.md) | —                                                                | #304     |
| `pulse.stage_retry_policy`        | Per-stage retry, backoff & replay-safety policy                 | 0067                | proposed   | partial     | —     | —                               | [Pulse/types](Pulse/types.md)                                    | #304     |
| `pulse.scheduler_leasing`         | Scheduler lease recovery, fair claiming & backpressure          | 0068                | proposed   | partial     | —     | —                               | [Pulse/service-api](Pulse/service-api.md)                        | #259     |
| `pulse.memory_scoring`            | Composite memory scoring & DAG random-walk influence            | 0012 (amend)        | proposed   | partial     | —     | —                               | —                                                                | #304     |
| `rewrite.planner_drift_witness`   | Haskell↔Lean rewrite planner correspondence & drift witness    | 0069                | proposed   | partial     | —     | [proof-status](proof-status.md) | [rewrites](rewrites.md)                                          | #304     |
| `wire.file_imports`               | File imports, file-return selection & module closure semantics  | 0070                | proposed   | partial     | —     | —                               | [Wire/modules-imports](Wire/modules-imports-and-file-returns.md) | #304     |
| `wire.artifact_emission`          | Artifact-emission boundary node & durable artifact-ref contract | 0071                | proposed   | partial     | —     | —                               | —                                                                | #304     |
| `corepure.stdlib_catalogue`       | CorePure ergonomic stdlib catalogue                             | 0072                | proposed   | partial     | —     | [proof-status](proof-status.md) | [Wire/pure-execution](Wire/pure-execution.md)                    | #295     |
| `corepure.division_model`         | Finite Float64 division & non-finite rejection                  | 0073                | proposed   | partial     | —     | —                               | [Wire/pure-execution](Wire/pure-execution.md)                    | #304     |
| `capability.effect_class_lattice` | Executor side-effect class lattice & digest identity            | 0014 / 0053 (amend) | proposed   | partial     | —     | —                               | —                                                                | #304     |
| `cli.wire_fmt`                    | Canonical Wire source formatter & `wire fmt` command            | 0074                | proposed   | partial     | —     | —                               | [Wire/style](Wire/style.md)                                      | #304     |
| `cli.service_config`              | cortex-pulse service config, runner-token minting & credentials | 0075                | proposed   | partial     | —     | —                               | [Pulse/service-api](Pulse/service-api.md)                        | #304     |
| `cli.proof_fixtures`              | Wire CLI proof-fixture & grammar-acceptance subcommands         | 0076                | proposed   | partial     | —     | [proof-status](proof-status.md) | —                                                                | #304     |
| `packaging.manifest_versioning`   | Wire package manifest versioning & forward-compatibility        | 0077                | proposed   | partial     | —     | —                               | —                                                                | #304     |
| `proof.elaboration_kernel`        | Lean-owned Wire elaboration IR & certifying admission kernel    | 0078                | proposed   | partial     | —     | [proof-status](proof-status.md) | —                                                                | #103     |
| `proof.admission_artifact_schema` | Wire admission artifact Haskell→Lean witness-exchange schema    | 0079                | proposed   | partial     | —     | [proof-status](proof-status.md) | —                                                                | #304     |

Every row now points to its governing decision: 16 new Stage-2 ADRs (`0063`–`0078`) plus two
amendments — `pulse.memory_scoring` amends ADR 0012, and `capability.effect_class_lattice` amends
ADRs 0014/0053. All carry ADR status `proposed`. `Impl status` stays `partial` until the governing
ADR is accepted and the row's evidence is verified, at which point it advances to
`implemented`/`verified` and the `Tests` cell is filled. Detailed per-capability evidence
(implementation, tests, theory) lives in each ADR's `## Traceability` block.

## Related

- [ADR 0063 — ADR Traceability and Feature Status Canon](../ADRs/0063-adr-traceability-and-feature-status-canon.md)
- [Cortex Proof Status](proof-status.md) — the proof-specific status matrix.
- [Chapter 02 — Ownership and Boundaries](../Architecture/02-ownership-and-boundaries.md)
