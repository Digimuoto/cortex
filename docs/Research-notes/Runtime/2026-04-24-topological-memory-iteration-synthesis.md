---
title: "Topological Memory — Iteration Synthesis"
description: Research-grade retrospective on the DIG-538 / DIG-539 iteration round for Pulse topological memory — what was tried, what was discarded, what shipped, and what we now understand about the system
---

# Topological Memory — Iteration Synthesis

**Date:** 2026-04-24
**Scope:** `src/Cortex/Pulse/Memory/*`, `src/Cortex/Graph/Influence.hs`, and downstream reviewer-style retrieval.
**Context:** retained retrospective for the topological-memory iteration that introduced DAG random-walk influence and pull-based memory retrieval.

---

## 1. Executive summary

Over two sub-tickets (DIG-538, DIG-539) we replaced a hop-count graph signal with DAG random-walk influence, reshaped reviewer recall from push to pull, and discarded a PFS-based stop-at-k design after review caught three distinct correctness bugs. The final system is structurally simpler than the intermediate state: `WalkAlgorithm` went away, `composeScore` takes a `Double` influence value instead of `Int` hops, and the reviewer gets Markov-prefill + `cortex_memory_query` tool access under `MemoryTopological`.

Two durable lessons came out of the round:

- *Enumeration and scoring are orthogonal axes.* `WalkAlgorithm` (how candidates are collected) must not carry scoring model (how candidates are ranked). The DIG-538 v1 attempt conflated them and produced a misleading API with a real correctness bug.
- *Stop-at-k requires monotone priority.* Frontier best-first gives top-k only if the priority function is non-increasing along graph edges. Our `composeScore` isn't monotone — temporal and semantic axes can spike at any depth — so PFS + `take k` under `composeScore` is unsound by construction, independent of implementation bugs.

The current system is internally coherent and tested, but the *quality* of the new graph axis versus the old one is not yet empirically validated — ordering changes are demonstrable; improved reviews are an assumption.

## 2. What the system is today

Memory is a **deterministic query over the Pulse event substrate**, not a separate store. A stage's view is the result of a walk over `PersistedGraphState` at stage entry — captured once as a `MemorySnapshot` and bound to the stage's `MemoryHandle`.

Pipeline (`src/Cortex/Pulse/Memory/Query.hs:62`):

1. `walkCandidates` enumerates the reachable cone with BFS; hop-count is carried for display + the `swMaxGraphDistance` pre-filter.
2. `computeInfluenceMap` runs `dagRandomWalkInfluence` per direction relation (ancestors uses transposed topology; bidirectional runs both and merges per-node maps with `max`).
3. Hop-count cutoff applied.
4. Each surviving candidate scored via `composeScore(weights, influence[n], capturedAt, completedAt, scorer, queryText, bodyText)`.
5. Sort by `(score DESC, hops ASC, NodeId ASC)`.
6. `wsLimit` applied after sort.

Per-stage behaviour selected via `MemoryStrategy = MemoryClassic | MemoryTopological TopologicalStrategyConfig` declared on the wire. Agent-driven ad-hoc recall routes through the `cortex_memory_query` tool (`Memory/Tool.hs`), which resolves a preset + optional field overrides and runs the same pure pipeline in-process against the bound handle.

## 3. Design frame evolution (chronological)

### Frame 1 — DIG-529 / DIG-530: substrate + per-stage strategy *(inherited)*

- Memory = snapshot + pure walk + score.
- `MemoryHandle` binds once at stage entry → no frontier-sibling bleed.
- Wire authors declare `memory = topological { preset = …; routingKey = …; limit = …; };` per node.
- Evidence: `Memory.hs:5-16`, `Types.hs:523-566`, `docs/Architecture/cortex-pulse.md:683-906`.

### Frame 2 — DIG-538 v1: PFS as stop-at-k enumerator *(tried, discarded)*

**Hypothesis:** walk candidates in priority order (composite score as priority) and truncate at `k` to avoid scoring the full reachable set on large substrates.

**Implementation path:** `Cortex.Graph.Search` gained a `Frontier` class + `MinFrontier` / `MaxFrontier`, `walkCandidatesPfs` used `maxFrontier` over `composeScore`.

**Three independent bugs surfaced in review:**

1. **Double-`Down` priority wrapping.** `MaxFrontier` wraps its stored priority in `Down` internally; passing `Down p` produced `Down (Down Double)`, which preserves natural `Double` order, so `Set.minView` extracted the *smallest* score first. The `-∞` sentinel for the origin and out-of-scope nodes ended up first.

2. **Best-first ≠ global top-k for non-monotone priority.** Example: `origin → a → b, origin → c` with `score(b) > score(c) > score(a)`. Best-first expands `origin`, pushes `{a, c}`, extracts `c` first, and with `limit = 1` returns `c` — but globally `b` wins. `composeScore` blends `1/(1 + hops)` (monotone) with temporal + semantic (per-node, non-monotone), so the monotonicity precondition fails by construction.

3. **Bidirectional via overlay collapse.** `walkCandidatesPfs` used `topology <> transposeRelation topology` as a single relation, letting a walk alternate directions — from `A`, the shape `A → B ← C` reached `C` via `A → B → C`. BFS preserved direction cones by walking per-relation and merging with `min`; PFS didn't.

All three have pinned regression tests in `test/Cortex/Pulse/MemorySpec.hs` and `test/Cortex/GraphSpec.hs`.

**Why discarded rather than repaired:** the correctness fix at commit `ebd166dc` (enumerate fully, priority-sort, post-hoc apply limit) produced observable output identical to BFS. The `WalkAlgorithm = WalkBfs | WalkPfs` knob became dead plumbing. Keeping it would have conflated enumeration strategy with scoring model — a category error that compounds.

### Frame 3 — Alternatives considered, not shipped

- **A\* with admissible heuristic.** The only sound upper bound on unknown per-node temporal + semantic contributions is `w_temporal · 1 + w_semantic · 1` — near 2 at default weights, larger than any plausible real score. Under that bound A\* prunes nothing; it degenerates to BFS with bookkeeping overhead.
- **Iterative Personalized PageRank with damping + ε fixed point.** On a DAG, iteration is unnecessary — one topological pass computes the exact stationary distribution.
- **`GraphPrior = HopDecay | RandomWalkInfluence` as user-selectable axis.** Deferred. Shipping RandomWalkInfluence unconditionally; if A/B capability is needed later, add the selector with a real reason.

### Frame 4 — DIG-538 v2 shipped: DAG random-walk influence

Implementation at `src/Cortex/Graph/Influence.hs:56`:

```haskell
dagRandomWalkInfluence alpha origin rel =
  let outDeg v = Set.size (Map.findWithDefault Set.empty v (relSucc rel))
      step v predVals
        | v == origin = 1
        | otherwise =
            sum [ if deg == 0 then 0 else alpha * uMass / fromIntegral deg
                | (u, uMass) <- Map.toList predVals, let deg = outDeg u ]
   in case foldTopSort step rel of
        Nothing -> Map.empty
        Just (_, results) ->
          if Set.member origin (relVertices rel) then results else Map.empty
```

One `foldTopSort` pass; α = 0.85 hardcoded; returns empty on cyclic input. `composeScore`'s signature swapped from `Int` hops to `Double` influence (`Score.hs`), and `pureQueryMemory` threads the per-node influence map through. `Bidirectional` runs influence per-direction and merges with `max`, mirroring BFS's per-direction + `min` shape for hop distance.

**Why this is sound where PFS wasn't:** no traversal-time decision to get wrong. Every reachable node is scored; ranking is a full sort. The remaining correctness question is whether the *signal* is meaningful — a separate question, tested in isolation.

### Frame 5 — DIG-539 v1: Markov prefill + tool retrieval *(partially shipped, partially reversed)*

**Original framing:** "reviewer recall shouldn't stuff the whole ancestor cone into the prompt; use `scInputs` for the Markov boundary + `cortex_memory_query` tool for deeper access under `MemoryTopological`."

**Shipped:**

- `runReviewerTopological` (DeepReport reviewer) uses `runToolLoop` with `cortex_memory_query` in `cortexChoiceTools`; `runReviewerClassic` is single-shot, no tools. Gating is at the tool catalog, not via system-prompt language.
- `reviewerMemoryToolNudge` tells the model about the Markov-boundary semantics and names the tool.
- Legacy env override `PORTMAN_DIG529_MEMORY` retired.

**Reversed in review:**

- *Review + rewriter stages aren't reviewer-shaped.* In parallel-claim-branches-v1 the Markov boundary of `runReviewStage` / `runRewriterStage` is the **merge** node — `scInputs` is the merged document, not analyst branches. Collapsing "analyst retrieval" to `analystOutputsFromInputs ctx.scInputs` lost sibling-branch access. Fix at `4a9b8495` restored `retrieveAncestorAnalystBranches` (returns `[]` under classic; walks under topological).
- *The tool-nudge said "use `queryText` to narrow recall," but the scorer was hardcoded to `nullSemanticScorer`.* Fixed at `2e0f73b4` by defaulting to `defaultSemanticScorer` (token-jaccard).
- *`peelWireValueEnvelope` looked for `wireValues` field; actual `WireValueSet` serialises as `values`.* Dormant bug that became load-bearing once reviewer recall routed through the generic extractor. Fixed at `2e0f73b4`.

## 4. Findings

### F1 — Enumeration/scoring split is the right abstraction boundary *(Observed; high confidence)*

`WalkSpec` no longer carries `wsAlgorithm`; `Walk.hs` exports only `walkCandidates` / `directionRelations` / `bfsDistance`; the per-node graph-axis signal lives in `Cortex.Graph.Influence` and is composed in at `Query.hs:82`.

Future graph priors (Katz-style, SimRank, precomputed embeddings) slot in by replacing `dagRandomWalkInfluence`'s output, not by touching the walk. Future enumerators (heap-based exact top-k, approximate retrieval) slot into `walkCandidates` without touching scoring.

### F2 — Stop-at-k isn't real without monotone priority or a sound heuristic *(Observed; high confidence)*

Saved as durable session memory (`feedback_stop_at_k_requires_monotone_priority.md`). Any future PR proposing "PFS for stop-at-k" over composite scoring must first show the priority is monotone along edges. For our `composeScore`, no.

Legitimate paths to real stop-at-k: (a) restrict priority to a monotone axis (graph-only), (b) precompute per-node scores offline so retrieval is heap-top-k over a set, (c) derive an admissible upper bound tight enough to prune (we don't have one).

### F3 — Influence signal is measurably different from hop decay; whether better is untested *(Observed mechanism; unvalidated fitness; medium confidence)*

**Revised from high to medium** after review feedback.

Mechanism is observed: the fanout-fixture test on the same snapshot returns `[analyst-a, analyst-b, analyst-c, planner]` under hop decay and `[planner, analyst-a, analyst-b, analyst-c]` under influence. Planner (3-way merge target from the reviewer) outranks direct-predecessor analysts because α² · 3 / 3 = α² > α/3.

**The open question is fitness for purpose.** If the reviewer's job is to scrutinize what the analysts wrote, the analysts are the nodes whose content matters. Ranking planner above them under `limit = k` pushes content-bearing nodes off the list — the opposite of what we want.

Mitigation in the current code: `retrieveAncestorAnalystBranches` (used by `runReviewStage` / `runRewriterStage`) filters via `analystBranchExtractor`, so non-analyst nodes drop out before scoring. Within the filtered slot, influence and hop-decay both rank equal-distance sibling analysts identically. The risk is concentrated on the *tool-driven* reviewer recall path where the model chooses the routing filter; if it omits one, planner-type nodes can outrank content nodes.

**What would downgrade this from "risk" to "demonstrated improvement":** a held-out set of reviewer queries comparing top-k under influence vs hop-decay under a rubric of "did the retrieved fragments let the reviewer detect a real concern?"

### F4 — "Memory strategy" isn't stage-role-keyed; it's `(role, wire-topology)`-keyed *(Observed; high confidence)*

**Sharpened from original framing.** The original DIG-539 framing was "every review-shaped stage uses Markov prefill." Reality: every review-shaped stage has to ask what its Markov boundary actually is, and the answer depends on wire topology, not stage name.

`runReviewStage` and `runRewriterStage` share the "reviewer" stage role but sit in a wire where their Markov boundary is a merge node, not analyst branches. `retrieveAncestorAnalystBranches` is a hand-rolled instance of what the general abstraction wants to be: "walk past my Markov boundary to nodes of type X."

**Implication:** there's no such thing as a generic stage-role-keyed memory strategy. If a third stage needs a custom ancestor-walker, that's the signal to promote memory-strategy resolution into wire-structural arguments — e.g. `memory = topological { past-boundary = merge; upstream-of-type = "analyst"; … }` rather than preset names. Watch-item; not yet urgent.

### F5 — Agent-facing retrieval surface is now behaviour-honest *(Observed; high confidence)*

Before this round: the nudge said "use `queryText`" but the scorer returned zero; the generic extractor failed on `WireValueSet`-shaped outputs. Both silently degraded retrieval under a limit. After `2e0f73b4`: token-jaccard is the default scorer (pluggable), both envelope shapes peel correctly, and tests pin both behaviours.

### F6 — Tuning priorities (revised order) *(Inferred; medium confidence)*

**Reordered from original memo** after review feedback.

1. **Semantic scorer.** `tokenJaccard` is a baseline, not a serious retrieval mechanism. Swapping for embedding-based scoring is probably where the retrieval-quality ceiling actually sits. Pluggable via `qSemanticScorer`; no API change needed to swap.
2. **Preset catalog openness.** `resolveWalkSpecPreset` is a closed case-of over four named presets. Wire authors can't define new presets without a Haskell change. If custom per-wire memory shapes proliferate, this is where authoring friction shows up.
3. **Influence cache.** Tool-loop reviewer calls `cortex_memory_query` repeatedly within one stage; each call recomputes the influence map. Memoise on `MemoryHandle`. This is a latency concern, not a ranking-quality concern.
4. **Damping factor α.** Hardcoded at 0.85. On a DAG with max hop distance 2–6, α^5 = 0.44 at default — α mostly shifts decay sharpness rather than flipping orderings. Probably a distraction compared to (1).

### F7 — Architecture alignment with DIG-488/490 is concrete at the `qExtractor` seam *(Observed; medium confidence)*

The typed-artifact / topology-bounded-retrieval direction asks downstream nodes
to bind slices of upstream artifacts rather than receiving whole payloads. The
memory system is the retrieval half of that direction. The `qExtractor` hook is
the integration point.

**Concrete sketch.** The `Query` type already carries a pluggable extractor:

```haskell
data Query = Query
  { qRoutingKey      :: Maybe Text
  , qSemanticText    :: Maybe Text
  , qExtractor       :: Aeson.Value -> Maybe ExtractedFields
  , qSemanticScorer  :: SemanticScorer
  }

data ExtractedFields = ExtractedFields
  { efRoutingKey :: Maybe Text
  , efBodyText   :: Text
  , efEvidence   :: [Text]
  }
```

A typed-projection extractor slots in like this (pseudocode against the DIG-488 plan's vocabulary):

```haskell
-- Given a declared artifact type A and a projection π : A → Slice,
-- produce an extractor that decodes the raw output as A, runs the
-- projection, and populates ExtractedFields from the slice.
projectionExtractor
  :: (Aeson.FromJSON a)
  => ArtifactProjection a slice
  -> (slice -> SliceFields)
  -> Aeson.Value
  -> Maybe ExtractedFields
projectionExtractor projection sliceFields raw = do
  artifact <- decodeJson (unwrapWireStageValue raw)
  let slice = applyProjection projection artifact
      fields = sliceFields slice
  pure ExtractedFields
    { efRoutingKey = sfRoutingKey fields
    , efBodyText   = sfBodyText fields
    , efEvidence   = sfEvidenceRefs fields
    }
```

Where `ArtifactProjection a slice` is the typed lens the DIG-488 plan wants to introduce (one full artifact, many narrow projections), and `SliceFields` carries the same three axes the scorer + router already consume. The full artifact stays in `msNodeOutputs`; only the projected slice enters the match record.

**What needs to exist for this to land:**

- `Cortex.Wire.Value` (or a new `Cortex.Artifact`) exposes `ArtifactProjection` as a type.
- `.cr` grammar lets a `memory = topological { … }` declaration name a projection on the retrieved nodes — e.g. `projection = "analyst_headline"`.
- `Cortex.Pulse.Memory.Tool` resolves the projection name at query time and builds the extractor.

None of this touches the query pipeline, the scorer, the walk, or the influence computation. The abstraction boundary F1 gives us is exactly the place DIG-488 integration slots in.

## 5. What we'd undo if we could

Honest retrospective: given what we know now, we'd skip the DIG-538 v1 PFS implementation entirely and jump straight to the enumerate-then-sort + random-walk influence shape. The PFS detour cost one full review cycle and left behind three regression tests that exist only because of the mistake.

What the detour *did* produce that was worth keeping: the three regression tests themselves (now pinning correctness invariants future refactors will need), and the `Frontier` / `MinFrontier` / `MaxFrontier` abstractions in `Cortex.Graph.Search` (unused by memory but useful for other search problems). Net-positive on the extraction, net-negative on the round-trip cost.

The retained lesson: *don't add a user-facing knob (`WalkAlgorithm`) when the design intent is really a scoring change.* Enumeration and scoring are orthogonal axes; conflating them produces APIs that look flexible but aren't.

## 6. Honest statements of uncertainty

- **Influence-vs-hop ranking quality is untested on real reviewer transcripts.** Merge-vs-chain is mathematically correct; whether it produces *better reviews* is unvalidated.
- **Bidirectional `max`-merge is a judgment call.** Other reasonable choices: sum (total attention), min (conservative), per-direction maps exposed separately. `max` mirrors BFS's `min`-merge shape for hop distance — aesthetic, not derived from a use case.
- **α = 0.85 is the standard PageRank default and not validated for this domain.** See F6 for why this is probably a distraction.
- **The biggest quality lever is almost certainly semantic scorer sophistication, not graph axis tuning.** Swapping `tokenJaccard` for an embedding model would dominate any improvement from α tuning or influence-vs-hop.
- **F4's "watch-item" may already be triggered.** If DIG-488/490's typed-artifact future means more stages with merge-gated Markov boundaries, the "memory strategy parameterised by wire-structural arguments" evolution could be forced sooner than expected.

## 7. Prioritised next steps

### Act now

- **None blocking.** Current state is correct, tested, internally coherent. The negative lessons and the `qExtractor` integration sketch are captured above.

### Design next

- **Retrieval-quality A/B harness.** Held-out reviewer query set; top-k under influence vs hop-decay under a judgment rubric. Block the "influence is better" claim on this.
- **Semantic scorer upgrade.** `tokenJaccard` → embedding-based. Biggest likely quality lever.
- **Influence cache on `MemoryHandle`.** Tool-loop reviewer makes repeated calls within one stage; memoise.

### Write up

- Two ADRs split out of this memo:
  - *Enumeration and scoring are orthogonal axes* (positive lesson from F1).
  - *Stop-at-k requires monotone priority* (negative lesson from F2).
- Update any paper-drafts that still describe hop-count as the graph axis.

### Parked

- A\* / monotone-priority stop-at-k. Requires domain structure we don't have. Revisit only if substrate sizes grow by ≥10× and full-cone scoring becomes a hotspot.
- User-selectable `GraphPrior`. Add if/when we have a second prior that's observably useful for distinct stage kinds.

---

## Appendix A — Reviewer notes / revisions accepted

The memo above reflects the revised stance. The deltas from the original draft, with attribution:

- **F3 downgraded high → medium.** "Different is not better." The original memo treated ordering change as evidence of improvement; it's only evidence that the new axis is doing something. Fitness for purpose requires an eval harness, flagged as "Design next."
- **F4 sharpened.** Original framing was "stage-specific calibration required" (tuning concern). Revised framing: there is no stage-role-keyed memory strategy that is correct across wires — the strategy is a `(role, topology)` function. `retrieveAncestorAnalystBranches` is evidence that the right long-term abstraction may be memory strategies parameterised by wire-structural relationships, not preset names.
- **F6 reordered.** Original priority put α tuning near the top; revised ranks semantic scorer > preset catalog > cache > α. On DAGs with bounded hop distance, α mostly shifts decay sharpness rather than flipping orderings; `tokenJaccard` → embeddings is where the ranking-quality ceiling actually sits.
- **F7 earned.** Original memo asserted DIG-488/490 alignment without showing mechanism. This revision includes the `qExtractor` typed-projection sketch (§4 F7) so the alignment claim is a demonstration, not an assertion.
- **New §5: What we'd undo if we could.** Template improvement for future research memos — explicit cost-accounting of iteration dead ends, because "the detour happened" is how future-me remembers it was considered and rejected with receipts.

The reviewer's core thesis — *"different" is not "better"* — is the most load-bearing correction and shaped the F3 downgrade.
