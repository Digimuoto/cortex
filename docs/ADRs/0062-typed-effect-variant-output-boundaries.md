---
title: "ADR 0062 - Typed Effect Variant Output Boundaries"
description:
  "A bound executor stage may complete by emitting exactly one declared output variant label with a
  contract-valid payload, validated before commit and branchable by select, refining the exclusive
  output grouping ADR 0017 specified and discharging the failure-routing hook in ADR 0026."
sidebar:
  label: "0062. Typed variant output boundaries"
  order: 62
status: proposed
date: 2026-06-27
superseded_by: null
related:
  - docs/ADRs/0017-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0026-wire-failure-taxonomy.md
  - docs/ADRs/0033-wire-select-guarded-affine-collapse.md
  - docs/ADRs/0053-executor-catalog-manifests-and-pulse-bindings.md
  - docs/ADRs/0059-durable-external-call-frontiers-on-pulse.md
  - "GitHub #313"
  - "GitHub #314"
  - "GitHub #321"
  - "GitHub #315"
  - "GitHub #138"
---

# ADR 0062 - Typed Effect Variant Output Boundaries

## Status

Proposed - extends ADR 0024, ADR 0033, and ADR 0053, fulfils the failure-routing hook left open by
ADR 0026, generalises the typed-error-output option in ADR 0059, and discharges the exclusive-output
grouping ADR 0017 specified but the runtime never implemented. It does not edit those ADRs; ADR 0033
now distinguishes the committed-label guard source (#314) from the reusable production Pulse
entrypoint still tracked in #321.

## Context

An executor stage today completes by producing a single output value per node - every
output-carrying result (`StageComplete` and the rewrite/loop results `StageRewrite`,
`StageRejectRewrite`, `StageLoopStep`) flows through one wrap boundary - or it fails. What is
missing is completing by choosing **one of several declared, typed output variants** that a
downstream `select(...)` branches on. So a domain- or effect-recoverable outcome - a backend reject,
a model-gateway failure, a `ready | repair` gate - collapses into a terminal run failure instead of
routing to a recovery arm.

The substrate already gestures at this gap from three directions:

- ADR 0026 (failure taxonomy) states deterministic failures "may be surfaced as typed executor
  failures" and that "whether a graph routes those failures through an explicit error contract is a
  topology decision, not a change to the failure taxonomy" - but names no mechanism.
- ADR 0059 says a realize node "may additionally expose a typed error output for recoverable backend
  errors", defaulting to closure - again with no generic mechanism.
- The Wire language already has variant outputs: `PortOutputSumDecl`/`SumVariant` compile to
  `(group id, label, contract)` exclusive groups, and `select(...)` arms resolve by label. ADR 0033
  defines `select` as guarded affine collapse where "runtime selects exactly one arm", and ADR 0017
  specifies the port profile carries "exclusive-output grouping".

Two facts make this a real, narrow piece of substrate work rather than a syntax change:

1. **The exclusive grouping is dropped before runtime.** `loweredPortsToWirePorts` and the port
   metadata keep only `port name -> contract`; at the egress boundary a sum `ok:T | err:U` is
   indistinguishable from two independent product outputs. ADR 0017's grouping obligation was never
   implemented.
2. **The reusable production `select(...)` entrypoint is still pending.** The committed-label guard
   source exists (`committedVariantConditionBinding`) and the lowering path can carry condition
   binders, but `lowerCompiledCircuitToSomeStagePlan` still lacks a reusable production caller on
   `main`; the production Pulse lowering path lowers only realize nodes. So "branch on an
   executor-emitted variant label" is not just a local boundary-validation feature — it still
   depends on the production entrypoint tracked in #321.

The open question is: what is the smallest substrate boundary that lets an executor commit one typed
variant, validate it before commit, persist it durably, and let `select` branch on it on resume
without re-running the effect - without inventing an "error channel" or a new persistence shape.

## Decision

### Model: an exclusive output group is a sum type

A node's exclusive output group is a sum type, and selection is by **label**:

- exclusive output group = sum type;
- variant label = constructor / tag;
- variant contract = the payload type (interface) for that constructor;
- payload = a value inhabiting that contract.

So the Wire boundary

```text
-> succeeded: Result
 | rejected: RejectReason
 | failed: BackendFailure;
```

is morally `data Outcome = Succeeded Result | Rejected RejectReason | Failed BackendFailure`. But
`Result` is **not** a host type: it is a stable, serializable **contract id** in the Wire catalog.
Contracts are Wire's portable type-identity surface for payload compatibility - not Haskell, Rust,
or WASM types.

**Label and contract are distinct, and selection is by label.** The label answers _which branch_;
the contract answers _what payload shape_. Two variants may share a contract when their branch
meaning differs:

```text
-> accepted: ReviewDecision
 | rejected: ReviewDecision;
```

That is well-formed only because selection is by label; contract-only dispatch would be ambiguous.

### Three layers

- **Wire compile time** owns the known contract ids, port labels, exclusive-group membership, and
  label/contract compatibility. (The exclusive group is dropped before runtime today; this ADR
  carries it through.)
- **The Pulse boundary** (this ADR's substrate, #313) validates and commits: exactly one emitted
  label, payload-kind/shape validation against _that label's_ contract, and a durable `WireValue`
  commit. It is host-language-agnostic - it sees `(label, payload)`, never a host type.
- **The host binding** maps host values onto that surface: a host-type <-> contract-id codec and a
  host-constructor <-> variant-label map. This is host-specific ergonomics, the deferred
  codec-registry work (#315), and is not part of this ADR's substrate.

### Substrate (Pulse boundary)

The boundary is **N labelled variants**, not a baked-in `ok | err`. A completing variant reuses the
existing output envelope: the chosen label is `WireValue.wireValuePort` (already set to the output
port name at egress - for a sum node the port name _is_ the variant label), the payload is
`wireValueValue`, the label's contract is `wireValueContract`. No new `StageResult` constructor,
`NodeOutcome` shape, or persistence column is introduced.

For this ADR, a **variant-emitting executor boundary must expose exactly one exclusive output group
and no ordinary output ports**, so completion commits **exactly one** `WireValue` (the chosen
variant); a `WireValueSet`, multiple values, or zero is rejected (new enforcement, since the
boundary currently validates set members independently). Ordinary multi-output **product** nodes are
unchanged, including a port whose contract is a bounded indexed product such as `[T; 4]` - that is
one product contract on one ordinary port, not a sum/product mix. Supporting "one selected variant
plus ordinary side outputs" would need a different envelope and downstream linearity story and is
**out of scope**.

The node grammar itself permits multiple output clauses (a sum group beside ordinary ports), so this
variant-boundary restriction is an ADR-0062 rule, not a grammar rule; `select(...)`'s
`resolveExclusiveBoundary` already rejects a sum-plus-extra-exit boundary. (The comment at the
`resolveExclusiveBoundary` site claiming the grammar forbids the mix is stale; #313 should correct
it.)

The boundary validates a candidate variant **before commit** (ADR 0053):

- the emitted label is a member of the node's declared exclusive output group;
- the payload satisfies _that label's_ contract (payload kind and shape);
- an invalid label or payload is a **typed** failure, `executor_output_validation_failure`
  (consistent with ADR 0026), not a silent branch and not an untyped `stage_failure`.

To make membership checkable at runtime, the exclusive group id is carried into the runtime port
profile (`WireOutputPort` gains an exclusive-group field, round-tripped through port metadata),
discharging the ADR 0017 grouping obligation.

These checks live at the shared wrap boundary (`wrapWireStageResult` -> `wrapNodeBoundaryOutput`),
which already runs for every output-carrying result, so variant validation applies uniformly to the
output slot of every output-carrying successful result (`StageComplete`, `StageRewrite`,
`StageRejectRewrite`, `StageLoopStep`); `StageSuspend` and the failure results are unaffected.

### Failure boundary

Three distinct cases, kept separate:

- a **declared, recoverable** outcome the author chose to branch on is emitted as a variant;
- an **invariant / decode / unexpected-exception / timeout** failure stays on the hard Pulse failure
  path - `StageFail`-surfaced typed failures (`StageFailureTyped`), exceptions
  (`StageFailureException`), and timeouts (`StageFailureTimeout`) (ADR 0026 unchanged);
- an **invalid emitted variant** (undeclared label, or a payload failing the label's contract) is
  `executor_output_validation_failure`.

A bind-time check, where the binder's declared emitter-label set is available, verifies it is a
subset of the node's declared variants; runtime membership validation (above) stays authoritative
for every emitted candidate. (The host constructor -> label mapping that would make the
emitter-label set precise is deferred to #315.) The recover-versus-fail-hard decision for a given
run is the binder's, within the three cases above.

### select consumes the label

`select(...)` branches on the committed **label**, never on the contract or a host constructor. The
condition binder reads the producer's single committed envelope from its inputs, takes
`wireValuePort` as the chosen label, and maps it to the compiled arm. Native N-way runtime is not
required: the existing nested binary condition tree is kept, and each generated condition node tests
the persisted label against its `thenKeys` / `elseKeys`; a label in neither is a typed failure,
never a silent default arm. Public `select(...)` syntax is unchanged (arms already resolve by
label).

Durability reuses what exists: the selected branch persists as the `graph_rewrites` delta plus
`NodeRewritten` and replays on resume; the committed label persists on the producer's node output.
The binder reads only persisted inputs and never re-invokes the backend, so the rare crash-window
predicate re-run is deterministic and the effect runs once.

### Scope

Tracked in three implementation steps under this ADR: the emission + validation + persistence
substrate (#313), the committed-label select guard/lowering path exercised by durable-resume tests
(#314, relating to #138), and the reusable production Pulse entrypoint for downstream callers
(#321). The host-type codec registry, the host typeclasses, and per-contract schema strength are
explicitly **out of scope** and deferred (#315); this ADR ships on Layer-1 payload-kind/shape
validation over the current `WireValue`.

This ADR bundles two decisions against the one-decision-per-ADR rule: the emission boundary (#313)
and the production select runtime (#314/#321). Whether to split it into an emission-boundary ADR and
a select-runtime ADR is tracked in #320.

## Alternatives considered

- **A new `StageResult` constructor (`StageCompleteVariant label payload`).** Rejected: it forces
  edits across `Plan`, `wrapWireStageResult`, the durable node-outcome path, and the executor for
  zero added expressiveness - the label already fits the existing `WireValue` port slot, and the
  exactly-one rule plus exclusive-group metadata supply the "which variant" semantics. The compiler
  allocates one port per sum variant, so a variant's port name is its label by construction.
- **Bake in an `ok | err` error channel.** Rejected: downstream graphs already need N-way
  (`ready | repair`, `rejected | failed | succeeded`); an `ok | err` primitive would invite three
  slightly different mechanisms. The exclusive group already carries N labels.
- **An order-based `Either err ok` adapter (`Right` -> first label, `Left` -> second).** Rejected:
  it is order-sensitive and misroutes `err | ok` or any non-`ok | err` pair. A host adapter must
  name both labels explicitly through a constructor -> label map; that mapping is host-binding
  ergonomics and lives in the codec layer (#315), not in this substrate.
- **Drive `select` by re-running a predicate over the producer's value (the existing test-only
  binder shape).** Rejected as the primary path: for an effectful producer, re-deriving the branch
  means re-running the effect on resume. Reading the committed label instead keeps resume
  effect-free; the predicate form remains available for pure conditions.
- **Require the host-type codec registry (#315) first.** Rejected as a blocker: the variant boundary
  is a Layer-1 concern (label membership + payload kind/shape) and ships on the current `WireValue`.
  The codec registry and `ContractId` versioning are a separate, deferred refinement of ADR 0017
  (#315).

## Consequences

### Positive

- Recoverable backend and domain failures can be routed to a `select` recovery arm as first-class
  typed variants, instead of collapsing the run - the topology mechanism ADR 0026 named but left
  unbuilt, and the generic form of ADR 0059's typed error output.
- N-way variants are uniform across consumers; no per-consumer error convention.
- Selection is by label, not contract, so two variants may share a contract (e.g.
  `accepted | rejected: ReviewDecision`); contract-only dispatch could not express this.
- Reuses the existing envelope, persistence, and rewrite-replay machinery: no new result
  constructor, no schema/column change, no `select(...)` syntax change.
- Output-validation failures become typed (`executor_output_validation_failure`), closing a place
  where the boundary currently raises an untyped `stage_failure`.
- Discharges ADR 0017's exclusive-output-grouping obligation and supplies the runtime guard source
  ADR 0033 deferred.

### Negative

- It builds the committed-label `select(...)` runtime path for the first time (#314) and still needs
  a reusable production entrypoint (#321). The substrate (#313) is independently shippable, but the
  headline branch capability depends on downstream callers having that entrypoint.
- Layer-1 validation does not catch a payload that is valid JSON of the right kind but semantically
  wrong against the contract; strong per-contract schemas wait on the deferred codec work (#315).
- Overloading `WireValue.wireValuePort` for the variant label makes the runtime exclusive-group
  metadata load-bearing for correctness (without it the boundary cannot distinguish a grouped
  variant port from an ungrouped product port).

### Obligations

- A bind-time check should verify the binder's declared emitter-label set (where available) is a
  subset of the node's declared variants; runtime membership validation stays authoritative for
  every emitted candidate (the precise emitter-label set depends on the host constructor -> label
  mapping deferred to #315).
- A variant-emitting boundary must be exactly one exclusive group with no ordinary output ports;
  completion commits exactly one `WireValue` (reject a `WireValueSet`, multiple values, or zero).
  This is new enforcement, since `validateExplicitWireOutput` currently validates set members
  independently. Ordinary product multi-output nodes are unchanged. #313 should also correct the
  stale `resolveExclusiveBoundary` comment that claims the node grammar forbids the
  sum-plus-ordinary mix.
- The `select` binder must read only persisted inputs and never re-invoke the backend, preserving
  the effect-once / deterministic-resume property.
- On landing #321, update this ADR's Traceability block to include the production entrypoint module.
- If strong per-contract payload validation, cross-version replay safety, or a host-type codec
  registry are later wanted, pursue them through #315 (refining ADR 0017) rather than widening this
  boundary silently.
- The Lean proof-side select admission / materialization correspondence (#138) covers the durable
  selected-branch story; keep it in scope when #314 lands.

## Traceability

- Feature keys: `wire.typed_effect_variant_outputs`
- Public surface: `Cortex.Wire`, `docs/Reference/Wire/conditionality.md`
- Implementation: `src/Cortex/Wire/NodeBoundary.hs` (exclusive output-group validation),
  `src/Cortex/Wire/Runtime.hs` (`wrapNodeBoundaryOutput`, `executor_output_validation_failure`),
  `src/Cortex/Wire/Circuit/Lowering.hs` (`committedVariantConditionBinding`,
  `bindCircuitConditionNode`), `src/Cortex/Wire/Compile.hs` (`resolveExclusiveBoundary`)
- Tests: `test/Cortex/Pulse/ExecutorSpec.hs`, `test/Cortex/Wire/Circuit/CompilerSpec.hs`,
  `test/Cortex/Wire/RuntimeSpec.hs`
- Theory/proof:
  [the "Select source admission" and "Select actualization" rows](../Reference/proof-status.md)
- Tracking: GitHub #313, #314, #321

## Related

- [0017 - Wire Executor and Port Catalog Boundary](0017-wire-executor-and-port-catalog-boundary.md) -
  specifies exclusive-output grouping in the port profile and the application-codec layer this ADR
  implements (grouping) and defers (codecs).
- [0024 - Typed Executor Node Interface](0024-typed-executor-node-interface.md) - variants remain
  typed output ports, each with a contract.
- [0026 - Wire Failure Taxonomy](0026-wire-failure-taxonomy.md) - the failure-as-explicit-error-
  contract topology hook this ADR realises; invariant failures stay hard failures.
- [0033 - Wire Select as Guarded Affine Collapse](0033-wire-select-guarded-affine-collapse.md) - the
  exclusive-arm selection model this ADR supplies a runtime guard source and durability for.
- [0053 - Executor Catalog Manifests and Pulse Runtime Bindings](0053-executor-catalog-manifests-and-pulse-bindings.md)
  - the Pulse-visible ABI and validate-before-commit boundary this ADR refines with an exclusive
    output envelope.
- [0059 - Durable External-Call Frontiers on Pulse](0059-durable-external-call-frontiers-on-pulse.md)
  - the typed-error-output option this ADR generalises to N variants.
- [0079 - Wire Admission Artifact as Haskell-to-Lean Proof-Witness Exchange Schema](0079-wire-admission-witness-schema.md)
  - the proof-side counterpart: the admission witness retains the select-variant exclusive-group
    provenance (`selectVariantsShareExclusiveGroup`) this ADR drops before runtime.
