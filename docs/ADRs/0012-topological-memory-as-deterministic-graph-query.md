---
title: "ADR 0012 — Topological Memory as Deterministic Graph Query"
description:
  "Memory is a deterministic stage-entry query over settled graph state, with the read surface
  selected per node."
sidebar:
  label: "0012. Topological memory"
  order: 12
status: accepted
date: 2026-04-23
superseded_by: null
related:
  - docs/Architecture/06-pulse-runtime.md
  - docs/Reference/Wire/configured-executors-and-execution-boundary.md
---

# ADR 0012 — Topological Memory as Deterministic Graph Query

## Status

Accepted — topological memory and per-node memory strategy are now part of the shipped runtime and
Wire surface.

## Context

Classic chain-scoped inputs work for simple linear flows, but they are too narrow for graph-native
workflows where a node may need principled access to settled upstream observations beyond its direct
input bundle. At the same time, turning memory into a separate mutable store would weaken replay,
inspection, and causal clarity.

The runtime needed a memory surface that respects graph topology, remains deterministic, and does
not blur past observations with live orchestration state.

## Decision

Define memory as a deterministic graph query over settled graph state at stage entry.

- memory is read from the Pulse substrate, not from a separate mutable memory database
- the snapshot is bound at stage entry so same-frontier execution does not bleed into the current
  node's view
- the memory read surface is selected per node through declared strategy rather than by one global
  runtime switch

Classic direct-input reads remain valid, but topological memory is the graph-native read model when
a node needs broader settled context.

## Alternatives considered

- **Keep memory as direct chain inputs only** — rejected because graph-native review and rewrite
  nodes need a principled way to read settled upstream context beyond one chain-shaped bundle.
- **Introduce a separate mutable memory store** — rejected because it would weaken determinism and
  make memory diverge from the actual graph substrate.
- **Use only a run-level environment override** — rejected because memory policy belongs to node
  semantics and workflow authoring, not to one global toggle.

## Consequences

### Positive

- Memory reads stay tied to durable graph state and causal topology.
- Per-node strategy keeps the read surface explicit in the authoring layer.
- Review and rewrite nodes can ground themselves in settled upstream evidence without violating
  replay discipline.

### Negative

- Memory policy becomes part of workflow authoring and runtime metadata.
- The runtime has to maintain walk, scoring, and snapshot rules as semantic infrastructure rather
  than as incidental helpers.

### Obligations

- Keep topological memory restricted to settled observations rather than live orchestration state.
- Preserve stage-entry snapshot semantics.
- Add new memory strategies only as explicit runtime surfaces with clear semantics.

## Traceability

- Feature keys: `pulse.topological_memory`
- Public surface: `Cortex.Pulse` (the per-node memory query surface and read-strategy selection),
  `docs/Reference/Wire/configured-executors-and-execution-boundary.md`
- Implementation: `src/Cortex/Pulse/Memory.hs` (stage-entry snapshot binding, `queryMemory`),
  `src/Cortex/Pulse/Memory/Query.hs` (`pureQueryMemory` — the deterministic graph query),
  `src/Cortex/Pulse/Memory/Types.hs`, `src/Cortex/Pulse/Memory/Walk.hs`
- Tests: `test/Cortex/Pulse/MemorySpec.hs`, `test/Cortex/Pulse/MemoryIntegrationSpec.hs`
- Theory/proof: none

## Related

- [../Architecture/06-pulse-runtime.md](../Architecture/06-pulse-runtime.md)
- [../Reference/Wire/configured-executors-and-execution-boundary.md](../Reference/Wire/configured-executors-and-execution-boundary.md)

## Amendment — Composite Memory Scoring and the DAG Random-Walk Influence Primitive (2026-06-27)

_Proposed amendment. Append-only extension of the accepted decision above; the original decision
text is unchanged. The base decision (memory is a deterministic graph query at stage entry) remains
accepted._

### Context

ADR 0012 fixes that memory **is** a deterministic graph query over settled state at stage entry, but
it deliberately left the _ranking model_ unspecified — it named "walk, scoring, and snapshot rules"
as semantic infrastructure without choosing one. The shipped runtime now carries a concrete scoring
model, so the canon needs a governing decision that does not silently encode product-shaped ranking
policy as substrate law.

The implementation ranks each in-scope candidate by a three-axis composite (`composeScore` in
`src/Cortex/Pulse/Memory/Score.hs`): a graph-influence axis, a wall-clock temporal-decay axis, and a
pluggable semantic-similarity axis. The graph axis is **not** hop count — hop count is carried only
for display and the `swMaxGraphDistance` pre-filter. The graph axis is a _consumer-neutral
random-walk influence primitive_,
`dagRandomWalkInfluence :: Ord a => Double -> a -> Relation a -> Map a Double`
(`src/Cortex/Algebra/Graph/Influence.hs`, re-exported from the `Cortex.Algebra.Graph` root),
imported by the query engine at `src/Cortex/Pulse/Memory/Query.hs` alongside the `influenceDamping`
binding. It is a single-pass DAG analogue of personalized PageRank: the origin gets mass 1, every
other reachable vertex receives `α · mass(u) / outDeg(u)` summed over predecessors `u`, computed in
one topological pass (O(|V| + |E|), no convergence loop, no `ε`), and it returns `Map.empty` on
cyclic input. Because it lives in `Cortex.Algebra` over any `Ord a`, it carries no memory or Pulse
semantics of its own.

This raises a scope question: is the _exact_ scoring model a ratified substrate contract, or a
substrate-incidental default a downstream layer may re-tune? This amendment answers only what the
code lets it answer honestly: Cortex owns deterministic graph-state query mechanics and generic
ranking hooks; downstream libraries own cognitive memory policy, role names, and product ranking
defaults.

### Decision

Extend ADR 0012 along two separable layers — ratify the durable Cortex parts, and explicitly refuse
to canonize downstream ranking policy.

1. **Ratify the influence primitive and the deterministic-query discipline.** The graph axis of
   memory scoring is `Cortex.Algebra.Graph.Influence.dagRandomWalkInfluence`, a consumer-neutral
   random-walk primitive over any `Ord a` that rewards aggregate causal support — a merge node fed
   by several predecessors outranks a single linear chain of equal hop distance — rather than raw
   hop count. The memory query stays a _pure, total, deterministic_ fold: results are ordered by a
   fixed total order — score descending, then graph distance ascending, then `NodeId` ascending
   (`sortMatches` in `src/Cortex/Pulse/Memory/Query.hs`) — so equal-score candidates have exactly
   one defined ordering. `clamp01` maps `NaN` to 0 so every comparison is total. The per-direction
   `max`-merge for transpose/`Bidirectional` walks and the stage-entry snapshot binding from ADR
   0012 are likewise substrate guarantees. These are the durable contract.

2. **Record the current composite as a compatibility default, not a frozen ranking contract.** The
   shipped mechanics expose generic knobs — `ScoreWeights`, pluggable `SemanticScorer`, `WalkSpec`,
   and named generic presets (`causal`, `influence_biased`, `recent_bidirectional`, `default`). The
   current fallback values are damping `α = 0.85` (`influenceDamping`), temporal decay
   `1 / (1 + age_hours)`, token-jaccard text overlap (`defaultSemanticScorer`), and equal default
   axis weights `1.0 / 1.0 / 1.0` (`defaultScoreWeights`). Those values are substrate-provided
   fallbacks so the query is usable without a downstream scorer; they are **not** ratified as
   canonical product ranking policy. A downstream reasoning layer may override scoring through the
   exposed hooks without changing substrate semantics.

### Obligations

- Keep `dagRandomWalkInfluence` consumer-neutral: no Pulse, memory, or downstream naming leaks into
  `Cortex.Algebra.Graph`.
- Preserve the deterministic total order and the `clamp01` totality guarantee. Any new axis must
  normalise into `[0, 1]` and contribute zero when absent, so adding an axis can never make the
  ordering non-total.
- Treat damping, decay shape, semantic fallback, and default weights as compatibility defaults. Do
  not promote a specific weighting to a ratified ranking contract without a follow-up decision that
  settles binding question B11.
- If damping or weights become per-stage tunable, expose them as explicit `ScoreWeights` /
  `WalkSpec` surfaces rather than a global toggle — consistent with ADR 0012's per-node-strategy
  obligation.
- **Preset-name ownership is settled.** The `WalkSpec` preset _mechanism_ and the generic presets
  are substrate; role-shaped names are not. Cortex accepts the legacy serialized aliases `analyst`,
  `reviewer`, and `planner` only for compatibility with already-authored Wire, mapping them to
  `causal`, `influence_biased`, and `recent_bidirectional` respectively. New Cortex documentation
  and schemas must use the generic names. Downstream packages such as Logos may expose their own
  role vocabulary above those generic presets.

### Traceability

- Feature keys: `pulse.memory_scoring`
- Public surface: `Cortex.Pulse` (memory query, walk specs, generic presets, and compatibility
  aliases), `Cortex.Algebra.Graph` (the `dagRandomWalkInfluence` primitive)
- Implementation: `src/Cortex/Algebra/Graph/Influence.hs`, `src/Cortex/Pulse/Memory/Score.hs`,
  `src/Cortex/Pulse/Memory/Query.hs`, `src/Cortex/Pulse/Memory/Types.hs`
- Tests: `test/Cortex/Algebra/GraphSpec.hs`, `test/Cortex/Pulse/MemorySpec.hs`
- Theory/proof: none
