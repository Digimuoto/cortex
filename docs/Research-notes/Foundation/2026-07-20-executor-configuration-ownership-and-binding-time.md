---
title: "Research Memo: Executor Configuration Is an Ownership and Binding-Time Product"
description:
  "Resolves the recurring with-versus-executor-argument question by separating semantic ownership,
  binding time, scope, and authority, and gives an explicit field classification and migration
  direction."
date: 2026-07-20
scope: foundation
status: active
related:
  - docs/Research-notes/Foundation/2026-07-19-executor-static-binding-time.md
  - docs/Research-notes/Foundation/2026-07-19-circuit-realization-and-bound-execution.md
  - docs/ADRs/0025-configured-executor-values.md
  - docs/ADRs/0053-executor-catalog-manifests-and-pulse-bindings.md
  - docs/ADRs/0095-wire-single-record-executor-boundary.md
  - docs/ADRs/0097-wire-static-intent-and-realization-inputs.md
  - https://github.com/Digimuoto/cortex/pull/400#issuecomment-5022883199
---

# Research Memo: Executor Configuration Is an Ownership and Binding-Time Product

**Method:** decision archaeology, implementation reading, substitution and counterfactual tests,
phase-separation analysis, information-hiding analysis, capability analysis, and comparison with
partial evaluation and workflow task models. **Confidence profile:** high on the architectural
diagnosis, the ownership rule, and the direction of the `with` diet; high on the classification of
prompt/instructions/tools/model-loop fields; medium on `stepBudget` pending a precise enforced
substrate contract; medium on the migration surface for typed tool references; low on whether a
further source-syntax rename is worth its compatibility cost.

---

## Executive decision

The one-record executor boundary is the right design. Keep it.

The old split between a static executor configuration record and a later runtime input was wrong as
a _semantic_ partition because it made source position stand for several unrelated facts: who owned
the field, when it became available, whether it affected binding, and whether it carried authority.
Replacing those two positions with one record plus consumer-declared binding time corrected that
mistake.

The remaining problem is older compatibility debt preserved in `with`. The current vocabulary still
treats “known before node ingress” as equivalent to “Cortex-owned node policy.” Those are not
equivalent. Staticness is a phase property; ownership is a semantic property.

The explicit call is:

> **Diet `with` to fields whose semantics are implemented by the Wire compiler, Circuit boundary, or
> Pulse lifecycle. Move executor-owned fields into the executor's one argument record. Let the
> executor projection declare which of those fields are admission-time and let
> `specializeExecutorArgument` residualize them. Keep downstream realization requirements and host
> authority in their already separate planes.**

This also corrects a subtle phrase in the final review closure. The compiler should not “point
`specializeExecutorArgument` at `with`.” `with` is already wholly compile-time and has a different
owner. The correct sequence is to relocate executor-owned fields from `with` into the executor
record and then use the existing specializer on that record.

The first field classification should be:

| Current field            | Decision                                                                 | Reason                                                                                                                                                           |
| ------------------------ | ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `label`                  | keep in `with`                                                           | Circuit/operator identity and observability metadata                                                                                                             |
| `timeout`                | keep in `with`                                                           | scheduler/lifecycle policy enforced around the stage                                                                                                             |
| `retry`                  | keep in `with`                                                           | scheduler recovery policy, not callee semantics                                                                                                                  |
| `stepBudget`             | keep only after pinning a Cortex-enforced meaning; otherwise move/remove | the name is substrate-like, but serialization without a named enforcer is not ownership                                                                          |
| `memory`                 | keep only for the exact Pulse `MemoryStrategy` meaning                   | it selects the stage's substrate read surface and is inherited through plan hydration                                                                            |
| `on`                     | keep in `with`                                                           | changes the compiled node into a signal boundary                                                                                                                 |
| `artifactKind`, `to`     | keep in `with`                                                           | change the compiled node into an artifact boundary and route substrate egress                                                                                    |
| `instructions`, `prompt` | move to executor argument                                                | content interpreted by the selected executor; it may legitimately depend on ingress                                                                              |
| `tools`                  | move/split                                                               | per-executor tool selectors are executor admission fields; cross-executor permission requirements are static intent; concrete tools and scopes are host bindings |
| `toolLoopMinSteps`       | move to executor argument                                                | model/agent loop behavior, explicitly described as downstream policy in superseded ADR 0025                                                                      |
| `maxOutputTokens`        | move to executor argument                                                | provider/executor request behavior, not generic stage lifecycle                                                                                                  |
| `reasoningEnabled`       | move to executor argument                                                | provider/executor behavior, meaningless for most executor classes                                                                                                |

“Memory” needs lexical discipline rather than one blanket answer. `memory = classic` versus
`memory = topological { ... }` is currently a Cortex/Pulse choice over the settled graph substrate;
that exact meaning remains in `with`. A model memory class, retrieval corpus, embedding index,
conversation store, or product memory preset is not that meaning. It belongs in executor admission,
static intent, or host binding according to the tests below. The compatibility aliases `analyst`,
`reviewer`, and `planner` in `WalkSpecPreset` are evidence of the old meanings leaking together and
should not be used to justify keeping product vocabulary in the substrate.

No implementation change should begin by mechanically moving names. First record this decision in an
ADR amendment or successor, specify the exact surviving `with` schema, and close the two
representation gaps identified here: inert typed references in executor arguments and the current
top-level-only binding-time partition.

## Why the question keeps recurring

Four discoveries did not coincidentally find the same typo. They observed one missing distinction
through four different projections:

1. the binding-time memo found that phase was being inferred from the wrong surface;
2. the batch-7 implementation review found executor semantics in a global node metadata vocabulary;
3. the batch-8 compiler review found the correct consumer-declared specializer beside, but not
   governing, those fields; and
4. the documentation sweep had to move examples in opposite directions because “static” was the only
   stable mental category available to authors.

This is **ontology debt**, not ordinary documentation drift. A concept that cannot be named in the
model is repeatedly reconstructed from syntax. Each reconstruction chooses a different proxy:

- old executor configuration used _source position_;
- `with` used _early availability_;
- the runtime metadata envelope used _serialization adjacency_;
- examples used _whether a value looked like policy_; and
- the specializer uses the correct proxy: _a consumer-declared availability obligation_.

Because the missing concept crosses the parser, compiler, manifest, binder, runtime, examples, and
docs, independent reviews are expected to rediscover it. Recurrence is positive evidence that the
problem is architectural.

## The missing abstraction

There is no single category called “configuration.” A field must be classified on at least four
independent axes.

### 1. Semantic owner

Who defines the field's meaning and compatibility?

- Cortex/Wire compiler;
- Pulse scheduler and lifecycle;
- one executor projection;
- a downstream intent schema; or
- the host/deployer.

The owner should publish the schema, decide compatibility, produce diagnostics, and be the first
component whose behavior changes when the value changes.

### 2. Binding time

When must the value be available?

- module elaboration;
- graph admission;
- realization/binding;
- node ingress; or
- during executor execution.

Availability does not establish ownership. A literal prompt and a timeout are both available during
compilation. One is still executor content; the other is scheduler policy.

### 3. Scope

What does the value describe?

- a compiler node/boundary;
- one executor invocation;
- a set of nodes or the whole Circuit;
- one realized runtime unit; or
- a host environment/grant.

Node adjacency in source is not sufficient to infer node scope. A tool permission ceiling can apply
to a whole admitted program even when the tool is used first by one node.

### 4. Authority status

Does the value describe, request, select, or grant?

- ordinary data describes an invocation;
- static intent requests a class of realization;
- an admission selector constrains a binding;
- a host grant authorizes a ceiling; and
- a bound handle or fingerprint records the concrete authority.

A string naming `web_search` does not itself grant network authority. Conversely, putting a tool
name in compiler metadata must not make Wire responsible for resolving or authorizing it.

The correct conceptual carrier is therefore a product, not another record position:

```text
FieldRole = Owner × BindingTime × Scope × AuthorityStatus
```

Surface forms are projections of that product:

```text
with                 = Cortex owner × compile/admission × node scope × no grant
executor static      = executor owner × admission × invocation scope × selector only
executor residual    = executor owner × ingress × invocation scope × data only
static intent        = downstream schema × admission × node/circuit scope × requirement only
host binding         = host owner × realization × environment scope × granted authority
```

This is the deeper abstraction the current design had only partly realized.

## Epistemic lenses

### Genealogical lens — `with` is a fossilized compatibility envelope

Superseded ADR 0025 already admitted that its “runtime options” record had split ownership. It
called timeout, retry, step budget, and Pulse topological memory substrate concerns, while naming
`toolLoopMinSteps`, `maxOutputTokens`, `reasoningEnabled`, tool policy, and product memory presets
as executor/downstream policy retained for compatibility.

ADR 0095 removed configured-executor values and the config/input positional split, but it retained
the global metadata vocabulary. The breaking migration therefore removed the old container without
fully rehoming its mixed contents. The current problem was exposed by the one-record change; it was
not created by it.

The historical error was not “static executor data followed by runtime data.” Partial evaluation
legitimately separates known input from residual input. The error was encoding that distinction as
two author-chosen positions and treating the first position as one undifferentiated configuration
kind.

### Type lens — global `with` creates false inhabitants

`validateNodeMetadataFields` accepts one closed, global allowlist before the selected executor's
argument schema participates. As a result, combinations such as these are representable in the
surface type:

- `reasoningEnabled` on a filesystem executor;
- `tools` on a native pure node;
- `maxOutputTokens` on a quantum gate; or
- `instructions` on a signal-shaped node until a later path happens to ignore or repurpose it.

The compiler can reject wrong primitive value kinds, but it cannot explain why a field is meaningful
for the selected executor. Only the executor projection can do that. Moving the fields into the one
record turns a global bag of optional metadata into a per-executor sum of valid invocation shapes.

This is a type improvement, not just a tidier serialization.

### Information-hiding lens — schema ownership follows the hidden decision

Parnas's modularity criterion is the relevant grounding: decomposition should follow design
decisions likely to change, not merely execution order. Model reasoning controls change with model
executors and provider adapters. Retry semantics change with Pulse recovery. Topological memory walk
semantics change with the Cortex memory substrate. These are different hidden decisions and should
not share one schema owner.

The practical test is:

> Which module should change when this field gains a new variant or compatibility rule?

If adding a reasoning mode requires editing `Cortex.Wire.Compile`, the abstraction is inverted. If
adding a scheduler retry mode requires changing every executor manifest, the opposite inversion has
occurred.

### Operational lens — ownership belongs to the first semantic consumer

The compiler currently evaluates `with`, lowers selected fields into `actMetadata`, and leaves task
execution to an injected `CircuitPulseBinder`. The core repository does not interpret the model-like
fields as generic semantics. Their location beside `timeoutSeconds` in one JSON object is therefore
an artifact-layout fact, not evidence of common ownership.

Use the first-semantic-consumer rule:

- if the compiler changes node kind or boundary normal form, the field is compiler-owned;
- if Pulse changes scheduling, replay, or context construction, the field is substrate-owned;
- if the binder chooses or specializes one executor implementation, it is an executor admission
  field;
- if the running executor changes its request, it is ingress data;
- if a realizer changes a multi-node/system plan, it is static intent; and
- if access becomes possible, it is grant/binding material.

Serialization may denormalize these values into a convenient artifact, but it must preserve their
owners and source-of-truth identities.

### Substitution lens — replace one component and observe what remains meaningful

This is the most decisive field-placement test.

1. Replace `@review.analyst` with another executor having the same ports. `timeout`, `retry`, and
   Pulse topological memory still have coherent node semantics. `instructions`, reasoning mode,
   output tokens, and tool loop policy may become invalid. Therefore the latter fields belong to the
   executor schema.
2. Replace Pulse with another compliant Circuit scheduler. Prompt and tool selection remain part of
   the executor request. Pulse retry/checkpoint policy may not. Therefore they are not one record
   kind.
3. Fuse or contract several nodes into a realization. A cross-node device class or tool permission
   ceiling remains applicable to the realized unit, while a single call's prompt does not. The
   former is static intent.
4. Rebind the same admitted program on another host. Required tool classes may remain constant while
   endpoints, credentials, and filesystem/network scopes change. The latter are host bindings.

The current global `with` vocabulary fails the first test.

### Phase lens — the specializer is partial evaluation

The implemented algorithm has the standard shape of partial evaluation:

```text
authored executor record + admission-known fields
  -> staticArgument + residual ingress expression
```

Its coherence obligation is the ordinary residual-program equation: evaluating the authored record
with all input must agree with merging the admitted static value with evaluation of the residual
record. Binding-time analysis literature names the two outputs “eliminable” and “residual” and
requires consistency so specialization cannot trust a value at the wrong stage.

This explains both why the mechanism is right and why extending it to `with` is wrong. The
specializer partitions one consumer's input. `with` is not input to that consumer; it is a separate
compiler/scheduler control surface. Reusing the dependency walker internally is reasonable. Reusing
the semantic carrier is not.

### Capability lens — tools span three planes, not one

Tools are the strongest adversarial case because the word can mean three different things:

```text
executor selector:  "this invocation may call the search slot"
intent requirement: "this program requires a search capability of class X"
host authority:     "slot X is bound to endpoint E with credential C and scope S"
```

Object-capability work distinguishes designation, permission, and authority precisely because a name
and the ability to act are not interchangeable. Cortex's closed-authority model already makes the
same distinction. A Wire tool reference or selector can constrain admission without embedding the
runnable implementation or secret.

Therefore `tools` cannot simply be renamed and moved as an untyped list. The executor projection
must say what each member denotes, static intent must carry any program-wide permission
requirements, and the binding record must capture concrete resolution and authority fingerprints.

### Workflow-comparison lens — orchestration options are not task arguments

The Amazon States Language is a useful, limited comparison. A `Task` has `Arguments` or `Parameters`
delivered to the invoked work and separate `Retry`, `TimeoutSeconds`, and heartbeat fields
interpreted by the workflow engine. This supports keeping scheduling policy separate from callee
input. Its `Credentials` field also shows where Cortex deliberately needs a stricter boundary:
source may name requirements, but host grants and concrete credentials must remain outside the
admitted program.

The comparison is not evidence that Cortex should copy ASL's syntax. It demonstrates that a generic
workflow task already needs at least task input, orchestration policy, and authority resolution as
separate concepts.

## Repository evidence

### Observed implementation facts

- `loweredNodeFromExecutorCall` evaluates `with` through the general `EvalValue` language, validates
  one global allowlist, and serializes the result through `actMetadata`.
- The same metadata builder is used for pure and effectful task nodes. Executor-flavored optional
  fields therefore exist independently of the selected executor projection.
- `specializeExecutorArgument` runs only after executor resolution. In strict mode it reads that
  executor's one `argument_shape`, finds admission-marked top-level fields, rejects dependency paths
  reaching runtime ports, validates the derived static schema, records `staticArgument`, and leaves
  a residual expression for ingress.
- `CircuitPulseBinder` injects the runnable stage definition. This is the architectural seam where
  compiled requirements and host authority are joined; the Wire compiler does not own the bound
  action.
- `MemoryStrategy` is a real Cortex/Pulse type copied into `StageContext` and inherited during plan
  hydration. This is stronger evidence of substrate ownership than the generic metadata envelope.
- `toolLoopMinSteps`, `maxOutputTokens`, and `reasoningEnabled` have no corresponding generic Pulse
  semantics in this repository. Superseded ADR 0025 explicitly classifies them as compatibility
  serialization for executor/downstream policy.
- The final review's opposite-direction documentation repairs follow exactly from the mixed
  vocabulary: retry and Pulse memory were misplaced in arguments, while instructions were misplaced
  in `with`.

### What the existing mechanism does not yet solve

The final closure says the mechanism already exists. That is directionally true but incomplete in
two important ways.

First, CorePure executor arguments are authority-free and currently represent bare value
identifiers, not imported qualified tool references in the same way the `with` evaluator's
`EvalQName` does. Today's `tools = [webSearch]` surface cannot be moved byte-for-byte into an
executor record while preserving registered-reference validation. The migration must choose one of:

- typed inert reference atoms in the executor argument value language;
- registered constructors which canonicalize to reference values;
- schema-validated string selectors with registry resolution performed by the binder; or
- static intent when the value is really a program-wide capability requirement.

This is not a reason to retain `tools` in `with`. It is a reason to design the replacement value
type rather than doing a textual move.

Second, binding-time annotations currently partition only top-level properties. The conventional
`cfg` bucket is therefore a poor home for a mixture of admission and ingress fields. Marking `cfg`
admission would force the entire nested record early; leaving it unmarked makes every nested field
ingress. Until nested staging has explicit semantics, executor schemas should put fields that need
independent phases at the top level. “One record” does not imply “one nested config bucket.”

## Field-by-field interpretation

### Definite Cortex `with` fields

`label`, `timeout`, `retry`, `on`, `artifactKind`, and `to` pass both the owner and substitution
tests. Some are generic node policy; others select special compiled boundary kinds. They should
remain a closed vocabulary with Cortex-defined types and diagnostics.

`memory` also remains when it denotes the exact `MemoryStrategy` algebra implemented by Pulse. The
name should be documented as “stage context/read-surface strategy,” not as a generic cognitive
memory hook. A later breaking window could rename it to `memoryStrategy` or `contextStrategy` for
clarity, but ownership can be corrected without requiring that rename now.

### Definite executor argument fields

`prompt` and `instructions` are invocation content. They should normally be ingress fields because
they may be constructed from upstream values. A particular executor may mark a stable system
instruction or template identifier admission-time if its binder genuinely specializes on it, but the
global language must not force all prompt content static.

`toolLoopMinSteps`, `maxOutputTokens`, and `reasoningEnabled` are behavior of model/agent executors.
Their exact types, defaults, compatibility, and availability obligations belong in those executor
projections. A provider may accept them per request; a binder may require some early. The signature,
not Wire, decides.

### Fields which split by meaning

`tools` is not one field role:

- the executor-specific slot/selector set can be an admission-marked executor property;
- a program-wide allowed vocabulary or required permission class is static intent;
- the concrete implementation, endpoint, credential, and filesystem/network scope are host grant and
  binding data; and
- tool call inputs/results during execution are runtime data and artifacts.

`memory` likewise splits:

- the Pulse settled-graph read strategy stays in `with`;
- an executor-specific retrieval/profile selector is an admission or ingress property;
- a cross-node memory-class requirement is static intent; and
- a concrete store, corpus, index, credentials, and access scope are host binding.

`stepBudget` needs a decision by operational semantics, not by name. If it bounds Pulse scheduling,
rewrite execution, or another persisted lifecycle transition and the runtime enforces it uniformly,
keep it in `with`. If it bounds an agent's internal reasoning/tool loop, it is executor policy. If
no component enforces it, remove it or mark it explicitly reserved; opaque serialization is not a
semantic contract.

## Why one executor record remains correct

The recurrence may tempt a return to two records. That would repair visibility while reintroducing
the original mistake.

Two positional records would encode an inferred fact twice. The executor projection already knows
which fields are required at admission, and dependency analysis can prove whether an authored
expression satisfies that requirement. An author-maintained split can agree and add no information,
or disagree and create a new error class. It also makes extracting through `let` or `where`
artificially phase-sensitive.

The one-record model has the stronger refactoring law:

> Moving a field expression into or out of a lexical binding does not change ownership, binding
> time, admissibility, or value.

It also supports executors with no early specialization, all-static specialization, or a mixed
record without multiplying call forms.

The proper decomposition is therefore not:

```text
static record + runtime record
```

but:

```text
Cortex node policy
+ one executor-owned record with a declared phase partition
+ optional downstream intent
+ later host binding/grant
```

## Required invariants

The design should be accepted only with named invariants that tests and artifacts can expose.

### Ownership exclusivity

Every semantic field has exactly one schema owner. Derived copies may exist for indexing or runtime
ergonomics, but they cite the source field and cannot diverge.

### Partition totality

Every declared executor argument property is admission or ingress, never both and never neither.

### Specialization coherence

For admitted static value `S`, residual expression `R`, authored record `A`, and valid ingress
environment `rho`:

```text
eval(rho, A) = merge(S, eval(rho, R))
```

The runtime binding need not receive the reconstruction, but compilation and provenance must be able
to establish the relation.

### Executor substitution safety

Replacing an executor with another projection having the same ports rejects fields not meaningful to
the replacement. No global optional bag silently survives the substitution.

### Scheduler substitution safety

Replacing an executor implementation does not change Cortex-owned timeout, retry, signal, artifact,
or Pulse context semantics.

### Authority non-forging

Argument and intent values may designate or request registered capability classes, but only a host
grant/binding can authorize concrete use. Secrets and runnable handles never enter Wire static data.

### Identity inclusion

Admission-static executor values participate in admitted program/binding compatibility identity.
Residual ingress expressions participate in Circuit meaning. Runtime inputs do not retroactively
change the admitted binding.

### Unknown-field locality

An unknown Cortex policy fails against the `with` schema. An unknown executor property fails against
the selected executor schema. An unknown intent member fails against its downstream schema. The
diagnostic names the owner rather than reporting a generic metadata failure.

## Recommended migration sequence

No code change was made by this memo. The next implementation should follow this order.

1. **Record the decision.** Amend ADR 0095 or accept a successor ADR defining the product model,
   surviving `with` vocabulary, split meanings of tools/memory, and the `stepBudget` ruling. Amend
   ADR 0097 only where static-intent classifications change.
2. **Inventory semantic consumers, not string occurrences.** For every current metadata field, name
   the compiler, scheduler, binder, executor, or downstream consumer which changes behavior. A field
   with no consumer is dead or reserved, not automatically Cortex-owned.
3. **Define executor schemas first.** Add per-executor `argument_shape` properties and binding-time
   annotations before removing the compatibility fields. Keep independently staged properties at the
   top level until nested staging is designed.
4. **Close the inert-reference gap.** Decide how registered tool/config references become canonical,
   authority-free argument values. Bind their identities into the registry witness; do not smuggle
   host handles into CorePure.
5. **Migrate source and artifacts.** Rewrite prompts/instructions and model controls into executor
   records. Split tool and non-Pulse memory meanings across executor admission, static intent, and
   bindings. Preserve only the exact Pulse memory strategy in `with`.
6. **Avoid two sources of truth.** If a compatibility release temporarily emits legacy metadata
   beside `staticArgument`, derive it from the canonical executor field, assert equality, version
   the bridge, and remove it on a stated deadline. Never accept both authored forms with precedence.
7. **Shrink the allowlist.** Remove executor-specific fields from `validateNodeMetadataFields` and
   from `WireNodeRuntimeOptions`; make pure nodes unable to carry them by construction.
8. **Update binders and provenance.** Binders consume `staticArgument` under the witnessed executor
   projection and residual ingress through the runtime evaluator. Concrete tool/model/memory
   resolutions remain in binding records.
9. **Run substitution tests.** Test at least model, standard IO, native pure, quantum, artifact, and
   signal nodes. Verify owner-local unknown-field diagnostics and specialization coherence.
10. **Sweep canonical docs together.** Update ADR 0025's historical explanation only by amendment if
    needed; align ADRs 0053, 0095, and 0097, both Wire references, Architecture 05/06, examples,
    proposal fixtures, and downstream migration notes in one change.

If the NativePure epic is still gated from `main`, this is the cleanest remaining breaking window.
If compatibility must be preserved, prefer an explicit, time-bounded compiler migration diagnostic
over silently supporting both planes.

## Rejected directions

### Keep all early values in `with`

Rejected because binding time does not establish ownership, the global schema admits nonsensical
executor combinations, and every new executor policy would require a Cortex compiler change.

### Apply the executor specializer directly to `with`

Rejected because it would let the selected executor reinterpret Cortex compiler policy and would
still leave one mixed record with two owners. Share dependency-analysis utilities if useful, but do
not share the semantic namespace.

### Restore a static executor record plus a runtime record

Rejected because it duplicates consumer-declared binding-time information, weakens lexical
refactoring, and recreates the configured-executor split ADR 0095 removed.

### Put everything under `cfg`

Rejected for the current design because binding-time partitioning is top-level. It also turns a
useful per-executor schema into a generic bag. `cfg` can remain a convention for fields which truly
share one phase; it is not a universal home.

### Make tools and memory Cortex primitives because they are common

Rejected. Frequency is not ownership. Cortex may own a generic tool registration protocol and the
Pulse topological-memory substrate while downstream executors own tool selection and cognitive
memory semantics.

### Let the binder inspect arbitrary metadata

Rejected because it destroys closed schemas, registry witnessing, local diagnostics, and stable
identity. The binder should consume typed admitted artifacts, not recover semantics from a JSON bag.

## External grounding

- Neil Jones, Carsten Gomard, and Peter Sestoft's
  [_Partial Evaluation and Automatic Program Generation_](https://www.itu.dk/~sestoft/pebook/pebook.html)
  gives the established static-input/residual-program model. Jens Palsberg's
  [“Correctness of Binding-Time Analysis”](https://doi.org/10.1017/S0956796800000770) emphasizes
  consistency of binding-time information. Cortex's `staticArgument` plus residual ingress
  expression is an instance of this pattern.
- David Parnas's
  [“On the Criteria To Be Used in Decomposing Systems into Modules”](https://doi.org/10.1145/361598.361623)
  grounds schema ownership in hidden design decisions rather than temporal processing order. It
  supports separating Pulse lifecycle, executor behavior, downstream intent, and host binding.
- The official [Amazon States Language Task specification](https://states-language.net/spec.html)
  and
  [AWS Task state reference](https://docs.aws.amazon.com/step-functions/latest/dg/state-task.html)
  separate task arguments/parameters from retry, timeout, and heartbeat policy. Cortex additionally
  separates credentials and grants from admitted source.
- Drossopoulou, Noble, Miller, and Murray's
  [“Permission and Authority Revisited”](https://research.google/pubs/permission-and-authority-revisited-towards-a-formalization/)
  supplies precise permission/authority distinctions. The important application here is negative: a
  tool selector or intent requirement is not the authority to use the resolved tool.
- The Kubernetes
  [Pod API](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/) offers a
  secondary systems comparison by separating container `args`, resource requirements, and security
  context. It reinforces the broader point that values adjacent in one deployment document can still
  have different semantic owners.

These sources support the decomposition but do not determine Cortex's syntax. The repository's own
compiler/binder boundary and accepted ADRs are the primary evidence for the decision.

## Final answer to the three hypotheses

### Did coupling old static executor config with runtime input go wrong?

Yes, but not because static specialization is invalid. The wrong part was using two author-chosen
positions as the semantic model and letting the static position accumulate scheduler policy,
executor selectors, downstream intent, and compatibility fields. The one-record plus
consumer-declared partition is the correction.

### Is there a deeper unrealized abstraction?

Yes. “Configuration” must be replaced by owner-indexed, phase-indexed obligations with explicit
scope and authority status. ADR 0097 already names most planes; this memo makes their product nature
and field-placement rule explicit.

### Should the design be grounded more strongly in generic systems?

Yes. The established names are:

- **binding-time analysis, specialization, and residualization** for admission versus ingress;
- **information hiding/schema ownership** for which component defines a field;
- **workflow/orchestration policy versus task arguments** for `with` versus executor input;
- **requirements/selectors versus grants/bindings** for tools, models, memory, and devices; and
- **scope-indexed intent** for facts applying across a node, Circuit, or realization.

With those names, the hole is no longer ambiguous. The architecture does not need another executor
record. It needs the remaining compatibility vocabulary moved to the owner and phase the existing
architecture already provides.

## Related repository surfaces

- `src/Cortex/Wire/Compile.hs` — `validateNodeMetadataFields`, `actMetadata`, and
  `specializeExecutorArgument`.
- `src/Cortex/Wire/Executor.hs` — the one authoritative argument schema and total top-level
  admission/ingress partition.
- `src/Cortex/Wire/Circuit/Lowering.hs` — `CircuitPulseBinder`, the injected runtime binding seam.
- `src/Cortex/Pulse/Memory/Types.hs` and `src/Cortex/Pulse/Plan.hs` — the actual substrate-owned
  `MemoryStrategy` and its stage-context semantics.
- `docs/ADRs/0025-configured-executor-values.md` — historical evidence that the old metadata record
  already had split ownership.
- `docs/ADRs/0095-wire-single-record-executor-boundary.md` — accepted one-record and compiler-policy
  decision.
- `docs/ADRs/0097-wire-static-intent-and-realization-inputs.md` — the separate static-intent and
  grant/binding planes.
- `docs/Research-notes/Foundation/2026-07-19-executor-static-binding-time.md` — the prediction this
  memo resolves into an explicit field decision.
- [NativePure epic final review closure](https://github.com/Digimuoto/cortex/pull/400#issuecomment-5022883199)
  — the four independent rediscoveries which prompted this memo.
