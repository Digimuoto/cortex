---
title: "ADR 0009 — Rewrite Provenance and Topology Integrity"
description:
  "Materialized graph state carries per-node provenance and a topology integrity witness so rewrite
  history can be trusted on resume and inspection."
sidebar:
  label: "0009. Graph integrity"
  order: 9
status: accepted
date: 2026-04-23
superseded_by: null
related:
  - docs/Architecture/07-rewrites-and-materialization.md
  - docs/Reference/rewrites.md
---

# ADR 0009 — Rewrite Provenance and Topology Integrity

## Status

Accepted — provenance-bearing graph state and topology integrity checks are part of the landed
rewrite substrate.

## Context

Once Pulse began admitting and materializing rewrites, the system needed more than a coarse rewrite
log. Operators and the resume path both needed to know:

- which rewrite introduced which nodes
- whether the persisted materialized topology still agrees with the stored graph state
- whether graph evolution can be trusted after crashes, restarts, and replay

Without explicit provenance and integrity witnesses, the runtime would still execute, but
explanation and trust would stay weaker than the durability story implied.

## Decision

Persist rewrite provenance and topology integrity as part of graph state.

- graph state carries per-node provenance describing whether a node came from the initial plan or
  from an admitted rewrite
- graph state carries a topology integrity witness that can be checked on resume
- admin inspection surfaces expose these facts directly instead of reconstructing them loosely from
  surrounding events

This makes provenance and integrity runtime facts, not offline audit conveniences.

## Alternatives considered

- **Persist only a coarse rewrite history** — rejected because it does not answer which current
  nodes came from which rewrite.
- **Trust reconstructed topology without an integrity witness** — rejected because resume and
  inspection need to detect drift or corruption explicitly.
- **Compute provenance only in admin tools after the fact** — rejected because trust and resume
  correctness belong in the runtime substrate itself.

## Consequences

### Positive

- Resume can detect mismatches between persisted graph state and expected topology.
- Operators can inspect graph evolution with node-level provenance instead of only reading rewrite
  IDs in isolation.
- The runtime's durability claims become easier to justify because current state carries its own
  witness.

### Negative

- Graph-state persistence becomes richer and more exacting.
- Topology representation changes now have to preserve or intentionally revise the integrity law.

### Obligations

- Update provenance and integrity witnesses whenever materialized topology changes.
- Surface provenance in admin tooling as a first-class fact rather than collapsing it into prose.
- Keep integrity failure behavior explicit and non-silent.

## Traceability

- Feature keys: `rewrite.provenance_integrity`
- Public surface: `Cortex.Pulse`, [`docs/Reference/rewrites.md`](../Reference/rewrites.md)
- Implementation: `src/Cortex/Pulse/Materialization.hs` (`NodeProvenance`, `NodeProvenanceEntry`,
  `initialProvenance`, `computeTopologyHash`, `pgsNodeProvenance`, `pgsTopologyHash`),
  `src/Cortex/Pulse/Executor/Resume.hs`
- Tests: `test/Cortex/Pulse/ExecutorSpec.hs`
  (`persists per-node provenance and topology hash after a successful rewrite`),
  `test/Cortex/Pulse/GraphRewriteSpec.hs`
- Theory/proof: none
- Tracking: GitHub #304

## Related

- [../Architecture/07-rewrites-and-materialization.md](../Architecture/07-rewrites-and-materialization.md)
- [../Reference/rewrites.md](../Reference/rewrites.md)
