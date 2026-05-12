---
title: "Epic — Substrate Soundness Closure"
description:
  "Prove the novel Wire/Pulse substrate is mechanically sound end-to-end, before investing in
  parser, compiler, IO, or persistence correspondence."
sidebar:
  label: "Substrate soundness"
  order: 1
status: active
date: 2026-05-13
related:
  - docs/ADRs/0038-wire-proof-track-theorem-ledger.md
  - docs/Reference/proof-status.md
  - docs/Roadmap/Plans/lean-mechanization.md
  - docs/Roadmap/Plans/rewrite-materialization-and-recovery.md
---

# Epic — Substrate Soundness Closure

## Summary

Prove that the **novel middle** of Cortex — Wire's port-keyed `=>`, boundary resources,
`select(...)`, `make`/`makeEach`/`*`, the node boundary normal form, and Pulse's safe-run envelope —
is mechanically sound end-to-end. Engineering surfaces (parser correctness, compiler completeness,
executor IO, durable persistence schema) are non-goals for this epic: they are amplification work,
not where the algebraic novelty is at risk.

The epic delivers when a single named **closure-witness bundle** — `AdmissionArtifact.Sound` paired
with the extra premises `runStart_establishes_safeRunState` requires (source planning context
validity, registry boundary, `WireTopologyDAGBridge`, budget bound,
`persistedRecoveryPreconditions`) — composes through the four cross-layer bridges into the existing
`AdmittedWirePulseTrace.preserves_safeRunState_from_runStart` and `final_not_stuck_from_runStart`
theorems. `Sound` alone is not the closure precondition; it is the artifact-side half of it.

## Motivation

The 28 dashboard rows in [Reference/proof-status.md](../../Reference/proof-status.md) enumerate the
sub-claims that constitute substrate soundness. They are individually mechanized at the Lean level;
their **composition** is not yet a theorem. The recently landed admission-artifact reconstruction
stack (`AdmissionArtifact.Sound.to{Primitive,Generated,Phantom,Select}Reconstruction`) is the
artifact-boundary half of that composition. The other half — lifting reconstructions to concrete
witnesses (`CertifiedGraph`, `MakeWitness`+`KindInstantiatedFrontiers`, `PhantomAdapterWitness`,
durable selected-branch recovery) and stitching them into the run-trace theorem — is the remaining
substrate work.

This epic exists because that work is **the actual research deliverable**. Once it closes, the
substrate is known to be sound. Everything else (parser, IO, persistence, compiler completeness) is
known to be solvable engineering, and the case for investing in it becomes a product decision rather
than a research uncertainty.

## Goals

1. **Four cross-layer bridges, each shipping a premise-discharge companion.** For each artifact-
   boundary reconstruction predicate, lift it to the corresponding concrete certified witness
   **and** name a companion theorem that takes runtime-side step data and produces a _specific
   bridge-derived sub-obligation_ for a _specific_ `RuntimeStep closure` certificate field. The
   companions are intentionally partial: no single bridge discharges any `RuntimeStep` constructor
   on its own (e.g., `selectedBranchRecovery` needs persisted + record + provenance +
   `RegistryBoundaryDeltaAdmitted record.step.delta` +
   `MaterializedPulseState record.step.nextContext nextG nextState` simultaneously, per
   `theory/Cortex/Wire/RunTrace.lean:276`). Composition into a full constructor instance happens in
   Slice 6's runtime-to-admitted lift.
   - `PrimitiveGraphReconstruction → ElaborationIR.CertifiedGraph` (accepted-node decls + module
     binding expansion) — companion discharges _source-side_ admissibility: contributes to
     `SourcePlanningContextValid snapshot.context` and to the source-topology side of
     `registryBoundary registry snapshot.context.topology`. It does **not** discharge
     `MaterializedPulseState` at any step. The closure's `WireTopologyDAGBridge` premise feeds
     run-start safety only (`theory/Cortex/Wire/RunTrace.lean:387`); per-step
     `MaterializedPulseState step.nextContext nextG nextState`
     (`theory/Cortex/Wire/RunTrace.lean:208, :278`) is per-step runtime materialization evidence the
     executor supplies alongside the step, not from any bridge.
   - `GeneratedReconstruction → MakeWitness` + `KindInstantiatedFrontiers` (accepted-kind
     substitution evidence) — companion discharges `RuntimeConstructionInputs.rawSubgraphValid` and
     the kind-shape validity portion of `ConstructedPlanningStep.inputs` (per
     `theory/Cortex/Wire/Planner/Chain.lean:47`) for rewrites that lower a generated form. It does
     **not** discharge per-node registry admission for the added nodes — that lives in
     `RegistryBoundaryDeltaAdmitted.newNodes` (per `theory/Cortex/Wire/Admission.lean:447`) and
     comes from the runtime's registry-membership facts.
   - `PhantomReconstruction → PhantomAdapterWitness` (operand objects + certified `BulkContract`
     traces) — companion discharges the bulk-contraction-related admission portion of
     `RegistryBoundaryDeltaAdmitted registry step.delta` for rewrites that involve `*` adapters.
   - `(SelectReconstruction × PersistedSelectedBranchAdmission) → SelectedBranchRecoveryRecord` (the
     persisted-provenance witness names the chosen arm; `SelectReconstruction` alone supplies latent
     admission evidence but never selects) — companion supplies the `persisted` and `record`
     arguments of `selectedBranchRecovery` plus the `SelectedBranchRecoveryRecord.Provenance`
     premise. It does **not** supply `RegistryBoundaryDeltaAdmitted record.step.delta` or
     `MaterializedPulseState record.step.nextContext nextG nextState`. Delta admission comes from
     Slice 4 (when `*` is involved) plus runtime registry-membership facts; per-step
     `MaterializedPulseState` is per-step runtime materialization evidence the executor supplies
     alongside the step description, not from any bridge.
2. **The closure-witness bundle and final theorem.** Define a single proof-side record (working name
   `SubstrateSoundnessClosure`) that packages `Sound` with the five extra premises
   `runStart_establishes_safeRunState` requires, plus the four bridge witnesses above. The final
   epic deliverable is one public theorem of **runtime-to-admitted lift shape**: given a runtime-
   side trace description that is consistent with the closure's bridges, the theorem **constructs**
   an `AdmittedWirePulseTrace` whose every step-constructor premise is discharged by the matching
   bridge companion plus runtime data, **and** the resulting trace is safe (citing
   `preserves_safeRunState_from_runStart`) and cannot finish stuck (citing
   `final_not_stuck_from_runStart`). The bridges are load-bearing at **certificate-construction
   time**: the `RuntimeTrace closure` certificate cannot be manufactured without each constructor's
   bridge-derived fields, so a runtime cannot just hand the lift a pre-built admitted step and skip
   the bridges. The lift body itself may pass through runtime-supplied Lean-shaped premises
   (`ConstructedPlanningStep`, `RegistryBoundaryDeltaAdmitted`, `MaterializedPulseState`) directly;
   what the bridges constrain is which runtime traces can be _handed to_ the lift in the first
   place.
3. **Dragon retirement (precondition to the bundle).** Verify or refute the architectural questions
   that could still force model rethinking: operand identity in primitive bulk-row recovery,
   executable vs. proof-side kind substitution agreement, recursive bindings, and the
   running-mark/result-order/rewrite-admission ↔ finite-trace correspondence that
   concurrent-frontier Pulse execution requires. Each item that survives verification becomes a
   named premise of the closure bundle or a separate slice.
4. **Updated proof-status framing.** Once closed, the dashboard summary should distinguish
   "substrate proven" from "executable correspondence engineered."

## Non-goals

- **Parser correctness / compiler completeness.** ADR 0038 already excludes admission gates. The
  question "every Wire program the parser accepts compiles to a `ValidatorReady` artifact" is
  amplification engineering. Park it.
- **Executor IO modeling.** Pulse's safe-run envelope already treats external effects as out of
  kernel. Modeling executor IO termination, timeouts, retries, or domain-specific authority is a
  downstream consumer concern, not a substrate-novelty concern.
- **Durable persistence schema verification.** The Haskell durable lineage decoder must produce
  `PersistedSelectedBranchAdmission`-shaped data, but proving every schema version round-trips is
  engineering, not novelty.
- **Performance / liveness / fairness.** The substrate proves partial correctness (safety
  preservation along any finite trace). Termination, progress, and scheduling fairness are
  separately motivated research questions, not subsumed by this epic.
- **Filling the eight `open` Haskell-correspondence rows.** These are runtime witness-production
  tasks. Most are pure engineering. Two (registry edge compatibility, terminal-discharge in closed
  actualized port linearity) carry mild novelty wrinkles; resolve those _if_ they turn up while
  doing the bridge work, otherwise defer.

## Design principles

1. **Novelty before engineering.** Every research hour goes to closing the substrate composition.
   Engineering work that doesn't surface a novelty question waits.
2. **Strengthen at the upstream boundary.** When a downstream proof needs more from a reconstruction
   record, prefer adding a field to the record (and proving it from existing `Sound` data) over
   re-deriving the fact in the downstream proof. The Copilot-driven `sourceUnique` field on
   `GeneratedReconstruction` is the exemplar.
3. **Adversarial review at each bridge.** Every bridge ships with a `lean-theorem-attack` pass.
   Style is downstream of soundness.
4. **Stable bridge APIs, one delivery signal.** Each cross-layer bridge ships as a named theorem
   with a stable API; downstream proofs cite the bridge, not the artifact predicate. Reusable
   composition lemmas are encouraged for proof robustness — what is single is the **final** public
   theorem citing the closure-witness bundle. Don't conflate "fewer named lemmas" with "better
   structure."
5. **Out-of-scope claims stay out of scope.** Don't quietly extend the epic to cover parser/IO
   correctness because they "feel related." They are not part of this research question.

## Delivery slices

Each slice is mergeable independently and ships under the same gating discipline as the recent
admission-artifact stack (signed/signed-off, full `fmt-check && docs-check && lean-check` gate,
mandatory `lean-theorem-attack` review on substrate slices).

### Slice 1 — Dragon retirement (precondition to bundle shape)

Resolve the architectural questions that could otherwise force the closure-witness bundle to be
redesigned mid-epic. Each item lands as either "no novelty risk, defer to engineering" or as a named
field on the bundle (or a separate preliminary slice).

- **Recursive bindings.** Does Wire grammar admit recursive bindings? If yes, does the proof model
  need a termination predicate for `topLevelBindings_establish_staticContext`? Inspect grammar +
  current closure laws.
- **Concurrent-frontier ↔ finite-trace correspondence.** Runtime frontier execution is already
  concurrent — workers run in parallel and the executor applies completed results incrementally (see
  `docs/Architecture/06-pulse-runtime.md` and `src/Cortex/Pulse/Executor/Frontier.hs`). Lean already
  has a normalized frontier fact fold (`Cortex.Pulse.RunSafety`,
  `pulseExecutionStep_preserves_safeRunState`, `normalizedFrontierFactsState`). The open question is
  **correspondence** from running-mark, result-order, and rewrite-admission runtime behavior to the
  existing batch / finite-trace surface — not "sequential or interleaving" in the abstract.
- **Operand identity for primitive bulk-row recovery.** The biggest dragon. Decide between
  artifact-schema extension (operand markers), traversal determinism, or persisting the witness
  directly. Choice determines Slice 4 shape and possibly the artifact schema version.
- **Kind substitution correspondence.** Decide whether executable kind substitution can be
  identified with proof-side substitution or needs a separate agreement theorem. Sets Slice 3's
  proof shape.
- **Registry edge compatibility witness completeness.** Are there any registry edges whose
  compatibility relation cannot be witnessed by a closed term? If yes, the Lean predicate is too
  liberal; if no, the open Haskell row is pure engineering.
- **Terminal-discharge classification.** Does the runtime concept of "terminal egress vs. fan-out
  adapter" cleanly match the proof model's `OutputPortUse` classification?

Output: a memo or short ADR per surviving item, plus a confirmed closure-witness-bundle shape that
feeds Slice 6.

Each bridge slice ships **two named theorems**: the reconstruction lift, and a premise-discharge
companion that takes runtime-side step data and produces a specific bridge-derived sub-obligation
for a specific `RuntimeStep closure` certificate field. The companions are intentionally partial —
no single bridge discharges a `RuntimeStep` constructor on its own. The companions feed into Slice
6's `RuntimeTrace closure` certificate format: each `RuntimeStep closure` constructor takes the
companion-derived witnesses as required fields, so the certificate cannot be manufactured without
invoking the bridges. The lift body itself may pass through runtime-supplied Lean-shaped premises
directly; the bridges' load-bearing role is at certificate construction, not inside the lift body.

### Slice 2 — Primitive → `ElaborationIR.CertifiedGraph` lift

Map `PrimitiveGraphReconstruction` to `Cortex.Wire.ElaborationIR.CertifiedGraph`. The reconstructed
final replay frame has nodes, bindings, entries, exits, and connections; the lift adds _acceptance_
— each node is a validated executor type, each binding is a resolved module reference. Module-
binding provenance for primitive rows is the proof-engineering substance.

**Premise-discharge companion:** discharge **source-side** admissibility — specifically the portions
of `SourcePlanningContextValid snapshot.context` and
`registryBoundary registry snapshot.context.topology` that follow from knowing the source-side
accepted topology. The `CertifiedGraph`'s `usedNodes` and `usedRefs` ledgers are what the companion
projects into these premises. The companion does **not** discharge `MaterializedPulseState` at any
step — that's a _runtime_ materialization predicate (`WireTopologyDAGBridge` +
`wellFormedGraphState`, per `theory/Cortex/Wire/PulseSafety.lean:152`). The closure's
`WireTopologyDAGBridge` premise feeds run-start safety only
(`theory/Cortex/Wire/RunTrace.lean:387`); per-step
`MaterializedPulseState step.nextContext nextG nextState` is per-step runtime materialization
evidence the executor supplies alongside the step, not from any bridge or from the closure's
run-start `WireTopologyDAGBridge`. The `CertifiedGraph` is the source-side baseline that bounds what
the runtime is permitted to materialize, not the materialization witness itself.

Risk: low. The accepted-node declarations are stable data; module-binding expansion is mechanical
once the artifact schema is committed to recording binding markers (it already does so for
`bindingRef` rows).

### Slice 3 — Generated → `MakeWitness` + `KindInstantiatedFrontiers` lift

Map `GeneratedReconstruction` to `LinearPortGraph.MakeWitness` plus `KindInstantiatedFrontiers`. The
reconstruction gives accepted source `MakeItem`s, unique source-child rows, and primitive-backed
child frontiers. The witness adds accepted-kind substitution evidence: that the template kind's
formal port set substitutes to exactly the per-child generated labels under the kind elaborator's
substitution function.

**Premise-discharge companion:** given the `MakeWitness`+`KindInstantiatedFrontiers` and runtime-
supplied rewrite data, discharge `RuntimeConstructionInputs.rawSubgraphValid` and the kind-shape
validity portion of `ConstructedPlanningStep.inputs` (per
`theory/Cortex/Wire/Planner/Chain.lean:47`) for rewrites that lower a generated form. The companion
does **not** discharge per-node registry admission for the added generated nodes — that's
`RegistryBoundaryDeltaAdmitted.newNodes` (per `theory/Cortex/Wire/Admission.lean:447`) and comes
from the runtime's registry-membership facts. Pairs with Slices 2 and 4 (and the runtime's planner
data + registry facts) in Slice 6 to fully discharge the `constructedRewrite` constructor.

Risk: **medium**. Hidden inside is a Lean-vs-Haskell correspondence theorem: executable kind
substitution must agree with proof-side substitution. Slice 1 resolves whether this is one agreement
theorem or a clean identification.

### Slice 4 — Phantom → `PhantomAdapterWitness` lift

Map `PhantomReconstruction` to `LinearPortGraph.PhantomAdapterWitness`. The reconstruction gives
primitive-backed adapter node, source-linear open object, replayed bulk rows, and product-shape
evidence. The witness adds the **left/right operand `LinearPortObject`s and certified `BulkContract`
traces**, neither of which is in the artifact today.

**Premise-discharge companion:** given the `PhantomAdapterWitness` and runtime-supplied rewrite
delta data, discharge the bulk-contraction-related admission portion of
`RegistryBoundaryDeltaAdmitted registry step.delta` for rewrites whose delta includes a `*` adapter.
The companion is partial: it covers the added-edge admission obligations contributed by the bulk
contraction; non-phantom added edges and added nodes still come from Slices 2/3 plus runtime data.
Independent of Slice 3 for non-generated phantoms; pairs with Slice 3 when a generated `*` is
involved.

Risk: **high**. This is the largest dragon. Slice 1 picks between artifact-schema extension,
operand-traversal determinism, or persist-the-witness; the chosen path determines the proof shape
here.

### Slice 5 — `(SelectReconstruction × PersistedSelectedBranchAdmission) → SelectedBranchRecoveryRecord`

Construct a `SelectedBranchRecoveryRecord` (`actualize : SelectActualize family`, `insertedDepth`,
`remaining`, `step : ConstructedPlanningStep`) from `SelectReconstruction` _and_ a persisted
selected-branch admission witness. `SelectReconstruction` alone supplies latent admission evidence
but never **selects** an arm — the runtime's persisted provenance row names the chosen arm, the
inserted depth, and the constructed step. The bridge proves: given consistent latent admission and
persisted provenance, the resulting record satisfies `selectedBranch_recovery_deterministic`.

**Premise-discharge companion:** supply the `persisted` argument, the `record` argument, and the
`SelectedBranchRecoveryRecord.Provenance persisted.toRecoveryRecord record` premise of
`AdmittedWirePulseStep.selectedBranchRecovery` (`theory/Cortex/Wire/RunTrace.lean:270-280`). The
companion does **not** supply `RegistryBoundaryDeltaAdmitted registry record.step.delta` or
`MaterializedPulseState record.step.nextContext nextG nextState`. `RegistryBoundaryDeltaAdmitted`
comes from Slice 4 (when the chosen branch contains `*`) plus runtime registry-membership facts;
`MaterializedPulseState` is **per-step runtime materialization evidence** the executor supplies
alongside the step description, not from any bridge or from the closure's run-start
`WireTopologyDAGBridge`. Full constructor discharge happens in Slice 6's lift, where the
`RuntimeStep.selectedBranchRecovery` constructor takes `hMaterialized` as an explicit field.

Risk: medium. `selectedBranch_recovery_deterministic` is already proven on the proof side; what's
missing is the decoder from the runtime's durable format plus the consistency theorem with latent
admission. Coupling concern: selected branches that contain a `*` adapter depend on Slice 4 via
`SelectedBranchRecoveryRecord.PhantomAdapterEmbedding`. Order Slice 5 after Slice 4.

### Slice 6 — Closure-witness bundle + final theorem

Define `SubstrateSoundnessClosure` as a structure bundling `Sound`, the five extra premises
`runStart_establishes_safeRunState` requires (`SourcePlanningContextValid` for the source planning
context, `_root_.Cortex.Wire.registryBoundary registry topology`,
`WireTopologyDAGBridge topology G`, `remainingBudget.le initialBudget`,
`persistedRecoveryPreconditions G state`), and the four bridge witnesses from Slices 2–5.

The final theorem is **runtime-to-admitted lift shape**. It takes a closure-indexed, proof-carrying
runtime-trace certificate (rewrites the executor wants to apply, frontier-fact batches the workers
want to commit, selected-branch recoveries the durable lineage wants to replay — each annotated with
bridge-derived witnesses) and lifts it to an `AdmittedWirePulseTrace`. The bridges are load-bearing
in a _certificate-construction_ sense: producing a valid `RuntimeTrace closure` value requires each
constructor to be supplied with its bridge-derived fields, so a runtime trace cannot be
_manufactured_ without invoking the bridges. The lift body itself does not necessarily re-derive
constructor premises from bridge fields — for constructors whose runtime data already includes
Lean-shaped premises (`ConstructedPlanningStep`, `RegistryBoundaryDeltaAdmitted`,
`MaterializedPulseState`), the lift may pass those through directly. The bridge fields function as a
_certified-input format_, not as a force-the-body-to- consume guarantee. Safety and non-stuckness
follow from the existing trace theorems applied to `closure.lift rt`. Statement shape (working
draft):

```lean
/-- Runtime-side step description, closure-indexed and proof-carrying.

`RuntimeStep closure start next` is a **certified-input format**: each
constructor mirrors one `AdmittedWirePulseStep` constructor and bundles both
(a) the runtime-supplied data and Lean-shaped premises the executor commits to,
and (b) bridge-derived witnesses that audit the runtime data against the
artifact-side bridges. The bridge fields make the trace a certificate — a
`RuntimeStep closure` value cannot be **constructed** without supplying the
bridge-derived fields. They do not necessarily force the lift body to re-derive
the Lean-shaped premises from bridge data; for constructors whose runtime data
already carries the premise in the right shape (`ConstructedPlanningStep`,
`RegistryBoundaryDeltaAdmitted`, `MaterializedPulseState`), the lift may pass
those through directly. The bridges are load-bearing for **certificate
construction**, not for forcing the lift's body to type-check.
-/
inductive RuntimeStep
    (closure : SubstrateSoundnessClosure …) :
    (start next : WirePulseSnapshot …) → Type where
  | constructedRewrite
      (start : WirePulseSnapshot …)
      (rawRewrite : GraphRewrite …)
      (nextG : DAG …) (nextState : GraphState …)
      (step : ConstructedPlanningStep …)
      -- Bridge-derived premises (each is a required field, not a hypothesis):
      (sourceSideAdmitted : closure.bridgePrimitive.SourceSideAdmitsRewrite step)
      (rawSubgraphValid :
        RewriteInvolvesGeneratedForm step →
          closure.bridgeGenerated.RawSubgraphValidFor step)
      (bulkDeltaAdmitted :
        RewriteInvolvesPhantomStar step →
          closure.bridgePhantom.BulkDeltaAdmitsFor step)
      -- Per-step runtime materialization (NOT from any bridge):
      (hMaterialized :
        MaterializedPulseState step.nextContext nextG nextState)
      (hDelta : RegistryBoundaryDeltaAdmitted registry step.delta) :
      RuntimeStep closure start { context := step.nextContext, G := nextG,
                                   state := nextState, remainingBudget := … }
  | selectedBranchRecovery
      (start : WirePulseSnapshot …)
      (nextG : DAG …) (nextState : GraphState …)
      -- Slice 5 contribution:
      (selectRecovery :
        closure.bridgeSelect.RecoveryFor (chosenArm := …))
      -- Per-step runtime materialization + delta admission (NOT from Slice 5):
      (hDelta :
        RegistryBoundaryDeltaAdmitted registry
          selectRecovery.record.step.delta)
      (hMaterialized :
        MaterializedPulseState selectRecovery.record.step.nextContext
          nextG nextState) :
      RuntimeStep closure start …
  -- Other constructors (recovery, frontierFacts, corePureSuccess,
  -- selectActualize) carry their own runtime data and the bridge-derived
  -- premises they need from the closure.

/-- A runtime trace is a list of `RuntimeStep`s linked snapshot-to-snapshot. -/
inductive RuntimeTrace (closure : SubstrateSoundnessClosure …) :
    (start last : WirePulseSnapshot …) → Type where
  | nil (s) : RuntimeTrace closure s s
  | cons {start mid last} (step : RuntimeStep closure start mid)
      (rest : RuntimeTrace closure mid last) : RuntimeTrace closure start last

/-- The lift function. Total over `rt : RuntimeTrace closure start last` —
no separate consistency premise is needed because `RuntimeTrace`'s
constructors already carry the bridge-discharge witnesses required to
construct each `AdmittedWirePulseStep`. -/
def SubstrateSoundnessClosure.lift
    {start last : WirePulseSnapshot …}
    (closure : SubstrateSoundnessClosure …)
    (rt : RuntimeTrace closure start last) :
    AdmittedWirePulseTrace registry initialBudget payload start last := …

theorem SubstrateSoundnessClosure.lift_safe_and_not_stuck
    {executor config contract authority payload : Type}
    {registry : ExecutorRegistry executor config contract authority}
    {initialBudget : RewriteBudget}
    {start last : WirePulseSnapshot executor config authority payload}
    (closure : SubstrateSoundnessClosure registry initialBudget …)
    (rt : RuntimeTrace closure start last)
    (hStart : start = closure.start.recovered) :
    -- (1) The constructed trace preserves safety.
    SafeWirePulseSnapshot registry initialBudget last ∧
    -- (2) The constructed trace cannot finish stuck.
    (∀ stuck : GraphState (WireNode executor config authority) payload,
      classifyGraphState last.G last.state ≠ StepResult.stuck stuck)
```

The bridges are load-bearing in **two** type-level places, both at certificate-construction time
rather than inside the lift body:

1. **`RuntimeTrace closure`** is closure-indexed. Without a closure value, the type cannot be
   instantiated.
2. **`RuntimeStep closure`'s constructors carry the bridge-derived fields as required arguments.** A
   `RuntimeStep closure` value cannot be **manufactured** without supplying each constructor's
   bridge-derived premise as a field. Closure-indexing on its own is necessary but not sufficient: a
   parameter `closure : SubstrateSoundnessClosure …` does **not** force the relation's body to
   consume the closure; only the constructors' fields do.

Conjuncts (1) and (2) follow from the existing
`AdmittedWirePulseTrace.preserves_safeRunState_from_runStart` and
`AdmittedWirePulseTrace.final_not_stuck_from_runStart` (`theory/Cortex/Wire/RunTrace.lean:381`,
`:402`) applied to `closure.lift rt` plus the closure's five run-start premises.

Per-step runtime materialization (`MaterializedPulseState step.nextContext nextG nextState` and
`MaterializedPulseState record.step.nextContext nextG nextState`) is supplied by the runtime as a
**field on each `RuntimeStep` constructor**, not by any bridge in the closure. The closure's
`WireTopologyDAGBridge` premise only feeds run-start safety for `start.context.topology`/`start.G`
(`theory/Cortex/Wire/RunTrace.lean:387`); post-rewrite materialization is per-step runtime evidence
the executor commits to alongside its step description.

Risk: low-to-medium once Slices 1–5 exist. Defining `RuntimeStep`'s field signatures early in Slice
6 may reveal that one of the bridge companions needs a stronger statement than Slices 2–5 produced;
revisit those slices before declaring closure. In particular, the per-constructor "BridgeXYZ.FooFor
step" predicates that appear as `RuntimeStep` fields are the canonical place to audit whether a
bridge actually discharges what each constructor needs.

### Slice 7 — Proof-status reframing

Once the final theorem lands, update `docs/Reference/proof-status.md` to distinguish "substrate
proven" from "executable correspondence engineered." The 28-row matrix doesn't need to grow; the
**summary table** should add a row for the composed substrate theorem and re-classify the eight
`open` rows under "engineering correspondence."

## Risks and open questions

All of these are inputs to Slice 1 (dragon retirement). Resolutions land before the corresponding
bridge slice writes Lean.

- **Phantom operand identity.** The largest single risk; decide schema-extend vs. traversal-
  determinism vs. persist-the-witness before Slice 4.
- **Kind substitution correspondence.** May factor cleanly or may need a separate Lean-vs-Haskell
  agreement theorem; resolution sets Slice 3's proof shape.
- **Recursive bindings.** Verification question about existing Wire grammar. If grammar admits
  recursion, the closure-witness bundle gains a termination premise; otherwise no novelty risk.
- **Concurrent-frontier correspondence.** Runtime is already concurrent; the existing Lean batch
  surface (`pulseExecutionStep_preserves_safeRunState`, `normalizedFrontierFactsState`) handles
  result-order invariance. The correspondence theorem is from the runtime's running-mark / result-
  order / rewrite-admission behavior into that finite-trace surface. Could require a separate
  scheduler-correspondence lemma if the runtime applies rewrites mid-frontier rather than at
  frontier boundaries.
- **Bridges may interact.** Slice 5 depends on Slice 4 when selected branches contain `*` adapters.
  Consider whether the four bridges are truly independent or whether a shared lifting infrastructure
  (e.g., a `ReconstructionToWitness` typeclass) would shorten the path.

## Related

- [../../ADRs/0038-wire-proof-track-theorem-ledger.md](../../ADRs/0038-wire-proof-track-theorem-ledger.md)
  — the theorem ledger this epic delivers against. The "Ordering" section of ADR 0038 should be
  superseded by the slice ordering above once this epic ships its first bridge.
- [../../Reference/proof-status.md](../../Reference/proof-status.md) — current 28-row dashboard;
  destination for Slice 7's summary reframing.
- [../Plans/lean-mechanization.md](../Plans/lean-mechanization.md) — the older fixed-topology
  staged-reduction mechanization plan. Scoped to one component; not superseded by this epic.
- [../Plans/rewrite-materialization-and-recovery.md](../Plans/rewrite-materialization-and-recovery.md)
  — the rewrite/recovery dynamic-topology plan. Slice 4 of this epic consumes the recovery-side
  results.
- [../../../theory/README.md](../../../theory/README.md) — proof inventory; expanded with each
  slice.
