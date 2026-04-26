---
title: "Deterministic Multi-Rewrite Admission"
description: Current Cortex runtime semantics for same-wave rewrite proposals, plus validation questions for a future paper direction.
status: draft
related:
  - docs/Architecture/07-rewrites-and-materialization.md
  - docs/Reference/rewrites.md
  - docs/Publications/Paper-3-graph-substitution-semantics/
---

# Deterministic Multi-Rewrite Admission

This note records the current runtime semantics for multiple rewrite proposals arising from one frontier wave and sketches why that seam may justify a future paper.

## Current Runtime Semantics

The current runtime is not "one rewrite ever" and not "fully concurrent rewrite commutation" either.

It is closer to:

1. frontier nodes execute concurrently from the same settled snapshot
2. any frontier node may emit `StageRewrite`
3. rewrite admission is serialized through a shared admission gate and shared remaining-budget state
4. each admitted proposal is persisted immediately as an admitted rewrite row with a monotone `rewrite_id`
5. after the frontier completes, admitted rows from that wave are materialized in `rewrite_id` order
6. the loop then recurses on the new topology

That gives Cortex a real same-wave multi-proposal story, but the semantics are still **ordered admission and ordered materialization**, not an order-insensitive concurrent substitution law.

## Important Boundary Cases

Two cases matter especially.

### Admitted but Not Yet Materialized

Admission and materialization are separate. A rewrite row may already exist in lineage while the graph watermark still points to an earlier materialized topology.

That means:

- lineage says the proposal was admitted
- the materialized graph does not yet include its structural effect
- resume/admin logic must interpret that state as "admitted but not yet applied"

This is not a corner case. It is part of the intended durability boundary.

### Terminal Frontier Outcomes

A frontier can still terminate the run before admitted rewrite rows from that wave are materialized. That gives a second important state:

- a rewrite was admitted
- a sibling failure or other terminal outcome won the frontier
- the run ended before the admitted rewrite affected the materialized topology

This is one reason the seam is interesting. The rewrite log and the materialized graph are not redundant views of the same thing.

## Why This Might Be a Paper

The interesting question is not "can multiple rewrites happen?" They already can.

The interesting question is:

> What semantic law justifies deterministic ordered admission of multiple structural proposals from one frontier wave, and what stronger law would be needed to treat those proposals as truly concurrent?

That splits the design space cleanly:

- **current Cortex machine:** concurrent proposal, serialized admission, ordered materialization
- **stronger future machine:** explicit independence relation and commutation law for same-wave rewrites

The first is already real. The second is still theory debt.

## Validation Program

If this becomes a paper direction, "complex end shapes looked good" is not enough. A serious validation program would need at least:

1. **Order sensitivity tests.** Force different admission orders for same-wave proposals and compare resulting topology, budget, provenance, and run outcome.
2. **Independence candidates.** Define a local criterion over anchors, interfaces, and budget effects that predicts when two proposals should commute.
3. **Counterexample suite.** Construct non-commuting siblings on purpose: overlapping anchors, interface collisions, budget races, and terminal sibling outcomes.
4. **Watermark invariants.** Show that admitted-but-unmaterialized lineage is always distinguishable from applied topology through watermark discipline.
5. **Replay and resume checks.** Validate that resume reconstructs the same materialized topology and frontier from the same admitted lineage prefix and watermark.
6. **Admin-surface clarity.** Confirm that operator surfaces can explain the difference between admitted lineage and applied topology without ambiguity.

## Likely Paper Shape

If pursued, the strongest framing is probably not "concurrent graph rewriting" in the broadest categorical sense.

A more Cortex-shaped framing would be:

- deterministic same-wave multi-proposal admission
- ordered materialization over durable lineage
- minimal independence law for stronger concurrency

That would stay close to the real machine instead of overclaiming a stronger concurrency model than Cortex currently has.

## Related

- [../Paper-3-graph-substitution-semantics/](../Paper-3-graph-substitution-semantics/) — current substitution paper.
- [../../Architecture/07-rewrites-and-materialization.md](../../Architecture/07-rewrites-and-materialization.md) — updated architecture contract.
- [../../Reference/rewrites.md](../../Reference/rewrites.md) — updated normative rewrite reference.
