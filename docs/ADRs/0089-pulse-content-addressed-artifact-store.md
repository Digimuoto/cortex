---
title: "ADR 0089 — Pulse-Owned Content-Addressed Run Artifact Store"
description:
  "Pulse stores run-output artifacts as immutable content rows keyed by a canonical typed-envelope
  SHA-256 address, with per-emission provenance rows linking content to the run and node that
  produced it, and ships a strictly opt-in stock binder for the ADR 0071 artifact-emission boundary.
  Blob stores, retention, and access control stay host-owned."
sidebar:
  label: "0089. Run artifact store"
  order: 89
status: proposed
date: 2026-07-05
superseded_by: null
related:
  - docs/Architecture/08-artifacts-and-provenance.md
  - docs/Reference/Pulse/schema.md
  - docs/ADRs/0003-pulse-service-and-host-action-boundary.md
  - docs/ADRs/0006-compiled-workflow-artifact-boundary.md
  - docs/ADRs/0071-wire-artifact-emission.md
  - docs/ADRs/0083-pulse-schema-lifecycle.md
  - docs/ADRs/0085-wire-contract-schema-as-type-enforcement.md
  - docs/ADRs/0002-cortex-downstream-ownership-boundary.md
---

# ADR 0089 — Pulse-Owned Content-Addressed Run Artifact Store

## Status

Proposed — this is the separate persistence decision ADR 0071 reserved ("if target-namespace
validation or a substrate-level `artifact_ref` schema is later wanted, raise it as a separate
decision"). ADR 0071 stays authoritative for the emission node and the `artifact_ref` payload kind;
this ADR decides only where an emitted value can durably live.

## Context

ADR 0071 made artifact emission a typed circuit boundary and `artifact_ref` a contract-typed payload
kind, deliberately shipping no persistence interpreter: the default binder rejects artifact
boundaries, so an authored emission node is "honest about intent but not end-to-end durable on its
own." ADR 0085 names validation of the _resolved_ durable content behind an `artifact_ref` as an
open follow-up "at the artifact-store boundary" — a boundary that did not exist.

Meanwhile the only durable home for a run's outputs is `graph_state.node_outputs`: a single mutable,
CAS-versioned `jsonb` row per run. Rewrites overwrite and prune outputs in place, there is no
attempt granularity, no immutability, and no way to reference one output from another run. A
downstream consumer wanting a durable, hash-referenced value (a carried context summary at segment
rollover, a per-step transcript) must ship its own store and its own provenance linkage for values
Pulse already persisted once.

The apparent conflict: ADR 0003 assigns "artifact stores" to the host, and Chapter 08 leaves blob
storage to the consumer boundary. The resolution is the tier split — Pulse already durably persists
every node output in Postgres; an immutable, content-addressed, provenance-linked view of those same
values is the same substrate persistence tier. What ADR 0003 keeps host-owned is the _product_
store: blobs and object storage, retention and GC policy, access control, and any schema for the
referenced content.

## Decision

Pulse owns a content-addressed store for run-output artifacts, in two tables (forward migration
0004, ADR 0083 lifecycle):

- **`pulse.artifacts`** — immutable content rows keyed by the canonical address: `sha256:<64 hex>`
  over the canonical UTF-8 encoding (`Cortex.Wire.Pure.canonicalJson`: recursively key-sorted
  objects, canonical numbers) of the typed envelope

  ```json
  { "contract": <string|null>, "mediaType": <string>, "payloadKind": <string>, "value": <payload> }
  ```

  Including the typing fields makes every column a pure function of the address, so writers upsert
  with `ON CONFLICT DO NOTHING` and a conflicting insert is by construction identical to the stored
  row — first-writer metadata can never silently win an argument. Content dedups across runs;
  content rows carry no run FK and are **never deleted by Cortex**.

- **`pulse.artifact_provenance`** — per-emission rows linking a content row to the `(run, node)`
  that emitted it, with the ADR 0071 `kind` and rendered `to` target recorded verbatim and
  interpreted by nothing, unique on `(run_id, node_id, artifact_hash)`, cascading with their run.

The typed surface is `Cortex.Pulse.Artifact` (`artifactAddress`, `putArtifact` / `getArtifact` /
`listArtifactsForRun` over hand-written Hasql statements, every call on the `Either` error path) —
named deliberately apart from `Cortex.Wire.Circuit.Artifact`, ADR 0006's workflow-as-artifact
boundary: this ADR stores values a workflow emits, not the workflow itself.

**Stock opt-in binder.** `bindPulseArtifactBoundary` interprets a `CircuitArtifactBoundary` by
persisting the stage input (lifting `WireValue` typing when the input carries it) and completing
with an `artifact_ref` envelope holding the suggested reference object
`{artifactHash, store, kind, runId, nodeId, mediaType, contract}`. It is `SafeToReplay` by content
addressing: the same input yields the same address, both writes are conflict-free upserts, and the
reference carries no timestamps or nonces. The default binder continues to reject artifact
boundaries; a host injects this binder — or its own — explicitly, so ADR 0071's "the host owns what
happens at the `to` target" survives with Cortex merely offering one injectable target.

## Boundary Rules

- **Kind and target stay opaque** (ADR 0071): recorded on provenance rows as free text, never
  enumerated, validated, or interpreted.
- **The reference object is a convention, not a schema.** Substrate validation of `artifact_ref`
  payloads remains structural ("a JSON object"); a downstream contract may pin the suggested shape
  with an ADR 0085 schema.
- **The address definition is pinned.** The hashed envelope shape above is normative; changing it is
  a new address scheme decided by a new ADR, not an edit.
- **No retention authority.** Cortex never deletes content rows. Unreferenced content is
  garbage-collectable by an operator anti-join against `pulse.artifact_provenance`; whether and when
  to run it is host policy (ADR 0003), documented, not implemented.
- **Host stores stay host stores.** Blob/object storage, access control, and product persistence
  policy remain downstream; a host that wants them binds its own interpreter and ignores this store
  entirely.

## Alternatives considered

- **Host-only stores (status quo).** Keeps the substrate smaller but leaves the ADR 0071 boundary
  inert for every consumer and makes each downstream re-implement persistence and provenance for
  values Pulse already durably holds in `node_outputs`.
- **Single table with a run FK.** Simpler, but either loses cross-run dedup or deletes shared
  content when one run is deleted; splitting content from provenance makes the deletion semantics
  exact.
- **Hash over the payload value only.** Maximizes dedup but lets two emissions disagree about
  contract/media-type/kind while sharing a row — first-writer-wins metadata drift under
  `ON CONFLICT DO NOTHING`.
- **Ship the store without the stock binder.** Smaller slice, but every consumer would write the
  same thin binder against `putArtifact`, and the emission boundary would stay not-end-to-end
  durable by default tooling.

## Consequences

### Positive

- The artifact-emission boundary is end-to-end durable for any host with a Pulse pool, strictly
  opt-in, with run/node provenance attached at the substrate layer and dedup by content.
- Run outputs gain an immutable, cross-run-addressable home that `graph_state`'s mutable CAS row
  deliberately is not; a rollover summary or transcript is referenced by hash, not copied.
- ADR 0085's resolved-content validation follow-up now has its boundary: `getArtifact` is the place
  a contract schema for referenced content would attach.

### Negative

- Payloads live twice while a run is live (in `node_outputs` and in the store); acceptable for the
  emitted-artifact subset, revisit only if volume demands it.
- `jsonb` payloads only — binary content needs the host blob store this ADR deliberately does not
  replace.
- Two artifact-flavoured Pulse surfaces (this store and the workflow-as-artifact boundary of
  ADR 0006) plus the capability catalog's manifest addressing now coexist; naming keeps them apart,
  readers must too.

### Obligations

- Resolved-content contract validation at `getArtifact` is the named ADR 0085 follow-up — a separate
  decision, not implemented here.
- Document the operator GC anti-join in the schema reference; never implement deletion in substrate
  code paths.
- Keep dump, forward migration, `pulseSchemaRequiredTables`, and the schema reference aligned (ADR
  0083).
- If blob/off-row payloads or size quotas are later wanted, raise them as separate decisions.

## Traceability

- Feature keys: `pulse.artifact_store`
- Public surface: `Cortex.Pulse`,
  [Chapter 08 — Artifacts and Provenance](../Architecture/08-artifacts-and-provenance.md),
  [`docs/Reference/Pulse/schema.md`](../Reference/Pulse/schema.md)
- Implementation: `src/Cortex/Pulse/Artifact.hs` (`artifactAddress`, `pulseArtifactRefValue`,
  `bindPulseArtifactBoundary`), `src/Cortex/Pulse/Query/Artifact.hs` (`putArtifact`, `getArtifact`,
  `listArtifactsForRun`), `src/Cortex/Wire/Pure.hs` (`canonicalJson`, exported),
  `migrations/0004_pulse_artifacts.sql`, `data/pulse-schema.sql`
- Tests: `test/Cortex/Pulse/ArtifactSpec.hs` (address laws; store CRUD, dedup, cascade),
  `test/Cortex/Pulse/ExecutorSpec.hs` ("persists an artifact boundary through the stock Pulse
  binder")
- Theory/proof: none

## Related

- [ADR 0071 — Artifact-Emission Boundary Node and Durable Artifact-Reference Contract](0071-wire-artifact-emission.md)
  — the emission boundary this store makes end-to-end durable; its opacity rules bind here.
- [ADR 0006 — Compiled Workflow Artifact Boundary](0006-compiled-workflow-artifact-boundary.md) —
  the workflow-as-artifact boundary this store sits beside, not inside.
- [ADR 0003 — Pulse Service and Host-Action Boundary](0003-pulse-service-and-host-action-boundary.md)
  — the substrate/host persistence split this ADR's tier argument preserves.
- [ADR 0085 — Wire Contract Schema as Type Enforcement](0085-wire-contract-schema-as-type-enforcement.md)
  — names the resolved-content validation follow-up this store gives a home.
- [ADR 0083 — Pulse Schema Lifecycle](0083-pulse-schema-lifecycle.md) — the dump/migration
  discipline the new tables follow.
- [Chapter 08 — Artifacts and Provenance](../Architecture/08-artifacts-and-provenance.md)

## Tracking

- #368 — content-addressed run-output artifacts (downstream Logos ADR 0019 / logos#115, Logos ADR
  0016 semantic-context artifacts).
