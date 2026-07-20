---
title: "ADR 0098 - Wire Node Policy and Executor Field Ownership"
description:
  "Classifies every node metadata and executor argument field by semantic owner, binding time,
  scope, and authority status; diets the with vocabulary to Cortex-implemented policy; and stages
  the migration of executor-owned fields into the one-record executor boundary."
sidebar:
  label: "0098. Wire field ownership"
  order: 98
status: proposed
date: 2026-07-20
superseded_by: null
related:
  - docs/ADRs/0025-configured-executor-values.md
  - docs/ADRs/0053-executor-catalog-manifests-and-pulse-bindings.md
  - docs/ADRs/0095-wire-single-record-executor-boundary.md
  - docs/ADRs/0097-wire-static-intent-and-realization-inputs.md
  - docs/Reference/Wire/executor-authorities-and-execution-boundary.md
  - docs/Research-notes/Foundation/2026-07-20-executor-configuration-ownership-and-binding-time.md
---

# ADR 0098 - Wire Node Policy and Executor Field Ownership

## Status

Proposed. This ADR records the decision that resolves the recurring `with`-versus-executor-argument
question surfaced four independent times during the NativePure epic review. It confirms ADR 0095's
one-record executor boundary, diagnoses the remaining defect as mixed ownership inside the global
`with` vocabulary, and stages the correction. One piece is implemented immediately alongside this
ADR: removal of the unenforced `stepBudget` metadata field. The remaining field migration is
deliberately staged behind the obligations below and must not proceed by mechanically moving names.

The full analysis, evidence, and epistemic method live in the research memo
[Executor Configuration Is an Ownership and Binding-Time Product](../Research-notes/Foundation/2026-07-20-executor-configuration-ownership-and-binding-time.md).
This ADR states only the normative decisions.

## Context

ADR 0095 replaced the configured-executor split with one executor argument record plus
consumer-declared binding time, and kept `with { ... }` as Cortex-owned compile-time node policy.
That was correct, but `with`'s vocabulary predates the split: it still carries fields whose
semantics are defined by individual executors (`instructions`, `prompt`, `tools`,
`toolLoopMinSteps`, `maxOutputTokens`, `reasoningEnabled`), preserved for compatibility from the
superseded ADR 0025 surface. The epic review rediscovered this mixed ownership four separate ways: a
binding-time analysis memo predicted it, two implementation reviews found executor semantics in the
global metadata vocabulary beside (but not governed by) the correct per-executor specializer, and
the documentation sweep had to correct examples in opposite directions because authors had no stable
category to reason with.

The root defect is a conflation of two independent properties: **binding time** (when a value must
be available) and **ownership** (which component defines the value's meaning and compatibility).
"Known before node ingress" was treated as equivalent to "Cortex-owned node policy." They are not
equivalent: a literal prompt and a timeout are both available at compile time, yet one is executor
content and the other is scheduler policy.

## Decision

### The field-role model

Every authored field is classified on four independent axes, and its surface location follows from
that classification rather than the reverse:

```text
FieldRole = Owner × BindingTime × Scope × AuthorityStatus
```

The existing surface forms are projections of this product:

```text
with                 = Cortex owner × compile/admission × node scope × no grant
executor static      = executor owner × admission × invocation scope × selector only
executor residual    = executor owner × ingress × invocation scope × data only
static intent        = downstream schema × admission × node/circuit scope × requirement only
host binding         = host owner × realization × environment scope × granted authority
```

Ownership is assigned by the **first-semantic-consumer rule**: the component whose behavior changes
when the value changes owns the field's schema, compatibility, and diagnostics. Binding time is
declared by the consumer signature (the executor projection's `argument_shape` annotations) and
proved by dependency analysis, never inferred from source position or literal syntax.

### The `with` diet

`with` is dieted to fields whose semantics are implemented by the Wire compiler, Circuit boundary,
or Pulse lifecycle:

| Field                    | Ruling                                                                                                                                                        |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `label`                  | keep: Circuit/operator identity and observability metadata                                                                                                    |
| `timeout`                | keep: scheduler/lifecycle policy enforced around the stage                                                                                                    |
| `retry`                  | keep: scheduler recovery policy, not callee semantics                                                                                                         |
| `on`                     | keep: changes the compiled node into a signal boundary                                                                                                        |
| `artifactKind`, `to`     | keep: change the compiled node into an artifact boundary and route substrate egress                                                                           |
| `memory`                 | keep, restricted to the exact Pulse `MemoryStrategy` meaning (stage context/read-surface strategy); product memory vocabularies are executor/intent/binding   |
| `stepBudget`             | **remove now**: no component in the repository enforces it, and serialization without a named enforcer is not ownership                                       |
| `instructions`, `prompt` | migrate to the executor argument record: content interpreted by the selected executor, legitimately ingress-dependent                                         |
| `tools`                  | migrate/split: per-executor selectors become executor admission fields; program-wide permission requirements are static intent; concrete tools are host bound |
| `toolLoopMinSteps`       | migrate to the executor argument record: model/agent loop behavior                                                                                            |
| `maxOutputTokens`        | migrate to the executor argument record: provider/executor request behavior                                                                                   |
| `reasoningEnabled`       | migrate to the executor argument record: provider/executor behavior, meaningless for most executor classes                                                    |

The `stepBudget` removal is implemented with this ADR because it fails the ownership test outright:
the compiler parses, range-validates, and serializes it, and nothing in Pulse, the runtime, or the
lowering path ever reads it. Should a genuine Cortex-enforced step bound arrive later, it re-enters
`with` with a named enforcer and documented operational semantics.

The migrating fields are **not** removed by this ADR. They remain in `with` until the staged
obligations below are met, because a textual move today would lose registered-reference validation
for `tools` and would force phase decisions the executor schemas have not yet declared.

### One record remains correct

The recurrence of this question is not evidence for restoring a static configuration record beside a
runtime record. Two positional records would encode consumer-declared binding-time information a
second time, weaken lexical refactoring (extraction through `let`/`where` would become
phase-sensitive), and recreate the split ADR 0095 removed. The one-record model keeps the
refactoring law: moving a field expression into or out of a lexical binding changes neither
ownership, binding time, admissibility, nor value. `specializeExecutorArgument` is the mechanism
that partitions that one record; it is not applied to `with`, which has a different owner and is
already wholly compile-time.

### Named invariants

The migrated design must maintain, and tests must be able to expose:

- **Ownership exclusivity.** Every semantic field has exactly one schema owner; derived copies cite
  the source field and cannot diverge.
- **Partition totality.** Every declared executor argument property is admission or ingress, never
  both and never neither.
- **Specialization coherence.** For admitted static value `S`, residual expression `R`, authored
  record `A`, and valid ingress environment `rho`: `eval(rho, A) = merge(S, eval(rho, R))`.
- **Executor substitution safety.** Replacing an executor with another projection having the same
  ports rejects fields not meaningful to the replacement; no global optional bag silently survives.
- **Scheduler substitution safety.** Replacing an executor implementation does not change
  Cortex-owned timeout, retry, signal, artifact, or Pulse context semantics.
- **Authority non-forging.** Argument and intent values may designate or request registered
  capability classes; only a host grant/binding authorizes concrete use. Secrets and runnable
  handles never enter Wire static data.
- **Identity inclusion.** Admission-static executor values participate in admitted program/binding
  compatibility identity; residual ingress expressions participate in Circuit meaning; runtime
  inputs do not retroactively change the admitted binding.
- **Unknown-field locality.** An unknown Cortex policy fails against the `with` schema; an unknown
  executor property fails against the selected executor schema; an unknown intent member fails
  against its downstream schema. Diagnostics name the owner.

## Alternatives considered

- **Keep all early-available values in `with`.** Rejected: binding time does not establish
  ownership, the global schema admits nonsensical executor combinations (`reasoningEnabled` on a
  filesystem executor), and every new executor policy would require a Cortex compiler change.
- **Apply `specializeExecutorArgument` directly to `with`.** Rejected: it would let the selected
  executor reinterpret Cortex compiler policy and still leave one mixed record with two owners.
  Dependency-analysis utilities may be shared internally; the semantic namespace may not.
- **Restore a static executor record plus a runtime record.** Rejected: duplicates consumer-declared
  binding-time information, weakens lexical refactoring, and recreates the configured-executor split
  ADR 0095 removed.
- **Put everything under a `cfg` bucket.** Rejected: binding-time partitioning is top-level, so a
  nested bucket forces all-or-nothing staging and degrades a per-executor schema into a generic bag.
  `cfg` remains a convention for fields that genuinely share one phase.
- **Promote tools and memory to Cortex primitives because they are common.** Rejected: frequency is
  not ownership. Cortex may own a generic tool registration protocol and the Pulse
  topological-memory substrate while downstream executors own tool selection and cognitive memory
  semantics.
- **Let the binder inspect arbitrary metadata.** Rejected: destroys closed schemas, registry
  witnessing, local diagnostics, and stable identity.

## Consequences

### Positive

- Field placement questions become decidable by rule instead of recurring per review.
- Executor substitution becomes type-safe: the surface stops representing invalid executor/metadata
  combinations once the migrating fields move behind per-executor schemas.
- The dead `stepBudget` surface stops implying an unimplemented substrate contract.
- Compiler, scheduler, executor, intent, and binding schemas evolve independently under their
  owners.

### Negative

- A second breaking authoring-surface migration follows the ADR 0095 migration, though it is
  narrower and gated on executor schema definitions.
- Executor projections gain schema obligations that were previously absorbed by the global
  allowlist.
- `tools` requires a designed inert-reference value type before it can move; until then the field
  stays in `with` as acknowledged compatibility debt.

### Obligations

- Define per-executor `argument_shape` properties and binding-time annotations for every migrating
  field before removing it from the `with` allowlist; keep independently staged properties at the
  top level until nested staging has explicit semantics.
- Design the inert typed-reference representation for registered tool/config references in executor
  argument values, bound into the registry witness, before migrating `tools`.
- Never accept both authored locations for one field with precedence; any compatibility bridge
  derives the legacy form from the canonical field, asserts equality, and is versioned with a stated
  removal deadline.
- Shrink `validateNodeMetadataFields` and `WireNodeRuntimeOptions` as fields migrate; make pure
  nodes unable to carry executor-flavored metadata by construction.
- Add substitution tests across model, standard IO, native pure, quantum, artifact, and signal nodes
  verifying owner-local unknown-field diagnostics and specialization coherence.
- Sweep ADRs 0053, 0095, and 0097, both Wire references, Architecture chapters 05 and 06, and all
  examples in one change when the migration lands; amend ADR 0025's historical explanation only by
  amendment.
- Document `memory` as the Pulse stage context/read-surface strategy; defer any rename to a later
  breaking window.

## Traceability

- Feature keys: `wire.node_policy_field_ownership`
- Public surface: `Cortex.Wire` node metadata vocabulary; executor `argument_shape` projections;
  [Wire Executor Authorities and Execution Boundary](../Reference/Wire/executor-authorities-and-execution-boundary.md)
- Implementation: `src/Cortex/Wire/Compile.hs` and `src/Cortex/Wire/AST.hs` (`stepBudget` removal);
  the staged field migration has no implementation yet
- Tests: `test/Cortex/Wire/CompileSpec.hs` (`stepBudget` rejection guard)
- Theory/proof: none; the admission proof boundary is unchanged by field relocation

## Related

- [ADR 0025 - Configured Executor Values](0025-configured-executor-values.md) - the superseded
  surface whose compatibility fields this ADR finishes rehoming.
- [ADR 0053 - Executor Catalog Manifests and Pulse Runtime Bindings](0053-executor-catalog-manifests-and-pulse-bindings.md) -
  requirement selectors and binding records the migrated fields feed.
- [ADR 0095 - Wire Single-Record Executor Boundary](0095-wire-single-record-executor-boundary.md) -
  the one-record decision this ADR confirms and completes.
- [ADR 0097 - Wire Static Intent and Realization Inputs](0097-wire-static-intent-and-realization-inputs.md) -
  the static-intent and grant/binding planes that receive the split `tools`/`memory` meanings.
- [Research memo: Executor Configuration Is an Ownership and Binding-Time Product](../Research-notes/Foundation/2026-07-20-executor-configuration-ownership-and-binding-time.md) -
  full analysis, evidence, and method behind this decision.

## Tracking

- [x] Remove the unenforced `stepBudget` field from the `with` allowlist, `actMetadata`, and
      `WireNodeRuntimeOptions`, with a rejection guard test.
- [ ] Define `argument_shape` properties and binding-time annotations for `instructions`, `prompt`,
      `toolLoopMinSteps`, `maxOutputTokens`, and `reasoningEnabled` on the executors that consume
      them.
- [ ] Design and register the inert typed-reference value form for executor-argument tool/config
      references.
- [ ] Migrate the executor-owned fields out of `with`; shrink `validateNodeMetadataFields` and
      `WireNodeRuntimeOptions` accordingly.
- [ ] Split `tools` and non-Pulse `memory` meanings across executor admission, static intent, and
      host binding.
- [ ] Add executor-substitution and unknown-field-locality tests across the six node classes.
- [ ] Sweep canonical docs and examples in one change; amend ADRs 0053 and 0097 where their
      classifications shift.
