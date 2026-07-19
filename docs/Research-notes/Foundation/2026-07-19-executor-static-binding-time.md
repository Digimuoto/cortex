---
title: "Research Memo: Binding Time, Not Syntax, Splits Executor Configuration"
description:
  "Analyzes the executor-static versus runtime-argument split as a binding-time problem: why the
  split is staging rather than laziness or lifetimes, why the consumer signature and not call-site
  position should declare it, and how the one-record boundary, node metadata, and static intent
  attachments compose into a minimal surface."
date: 2026-07-19
scope: foundation
status: active
related:
  - docs/ADRs/0053-executor-catalog-manifests-and-pulse-bindings.md
  - docs/ADRs/0095-wire-single-record-executor-boundary.md
  - docs/ADRs/0097-wire-static-intent-and-realization-inputs.md
  - docs/Reference/Wire/executors-and-alphabet.md
---

# Research Memo: Binding Time, Not Syntax, Splits Executor Configuration

**Method:** language-design comparison plus implementation reading of Wire parsing, CorePure
evaluation, executor projections, compiled metadata, and runtime argument validation. **Confidence
profile:** high for the binding-time diagnosis and one-record specialization rule; medium for the
first top-level-field annotation surface; open for richer nested or whole-record staging.

## Conclusion

Executor configuration currently creates pressure for two records because some values must exist
before binding while others do not exist until ingress. This is neither a laziness question nor a
lifetime question:

- laziness decides when a computation is demanded within one stage;
- lifetime decides how long a value remains valid; and
- binding time decides the earliest stage at which the value is available.

The executor consumer, not call-site position, owns that requirement. Wire should therefore retain
one authored executor record and let the executor projection declare which fields must be available
at admission. Dependency analysis proves the obligation. Admission-static fields are evaluated,
validated, recorded in compiled identity, and specialized out. The residual record is evaluated and
delivered at ingress.

```wire
let baseTokens = 2048;

node infer
  with { timeout = 30; }
  <- prompt: Prompt
  -> answer: Answer
  = @infer {
      profile = "reasoner";
      maxTokens = baseTokens * 2;
      payload = prompt;
    };
```

The source contains one record. Its registered signature partitions it:

```text
admission: { profile = "reasoner", maxTokens = 4096 }
ingress:   { payload = prompt }
```

## Why another positional record is the wrong declaration

A surface such as the following makes the distinction visible but assigns responsibility to the
wrong place:

```text
@infer with { profile = "reasoner"; } { payload = prompt; }
```

The compiler can already establish whether the first expression depends on runtime roots. Requiring
the author to repeat that fact produces two undesirable states:

1. the declaration agrees with inference and adds no information; or
2. the declaration disagrees and creates an avoidable new error class.

It also makes refactoring stage-sensitive. Moving an expression into a `let`, `where`, or imported
binding should not require moving a qualifier. Consumer-declared obligations preserve that
refactoring law.

## `let ... in` is deliberately stage-polymorphic

Wire already uses one lexical binding form in static and runtime contexts:

```wire
let threshold = 7;

node classify
  <- score: Score
  -> result: Decision
  = let adjusted = score + 1;
    in decide adjusted threshold;
```

`threshold` has no runtime dependency and can be specialized. `adjusted` depends on `score` and
remains runtime. The keyword does not determine either result.

For `let x = e1; in e2`, `x` carries the dependencies of `e1`. Uses of `x` in `e2` inherit those
dependencies. The same rule applies to module bindings and fields introduced by `where`.

This yields the useful invariant:

> Extracting an expression into, or inlining it from, `let` or `where` cannot change its binding
> time, admissibility, or value.

An explicit `static let` would break that invariant while adding no consumer requirement.

## Port closure is necessary, not sufficient

Runtime input ports are the ordinary runtime roots in a Wire node, but absence of a port reference
does not automatically make an expression admissible statically. The complete rule is:

> An admission expression has no dependency on runtime roots and evaluates in the deterministic,
> authority-free static CorePure evaluator.

The second condition excludes effects, host observations, clocks, randomness, secrets, unresolved
deployment data, and unsupported operations. A literal is not static because it looks constant; it
is static only when the consumer requires early availability and the evaluator can satisfy that
obligation.

## Canonical signature

The first surface extends the existing `argument_shape` rather than adding an independently
maintained `static_shape`. A top-level property may carry the versioned Cortex extension
`x-cortex-binding-time = "admission"`. Missing annotations mean `ingress`.

```toml
argument_shape = { schema = { type = "object", required = ["profile", "maxTokens", "payload"], additionalProperties = false, properties = { profile = { type = "string", x-cortex-binding-time = "admission" }, maxTokens = { type = "number", x-cortex-binding-time = "admission" }, payload = { type = "string" } } } }
```

One shape therefore determines a total partition. Independent schemas cannot overlap, omit a field,
or drift. The compiler derives:

- a closed schema containing the admission properties and their required set; and
- a residual ingress schema containing the remaining properties and required set.

The initial form is intentionally top-level. Nested staging requires a later decision about partial
record construction, field-path identity, and whether enclosing aggregates are copied, split, or
reconstructed.

## Compilation algorithm

For each strict-registry executor call:

1. normalize zero/scalar/record source syntax to the canonical record;
2. load the witnessed executor projection and read the field obligations;
3. group authored fields by top-level property;
4. trace free identifiers through local `let`, module bindings, and `where` fields;
5. reject any admission field reaching an input port, reporting the dependency chain;
6. evaluate admission fields with no port environment using CorePure's existing semantics;
7. validate the resulting record against the derived closed static schema;
8. persist it as compiled `staticArgument` data so it participates in program identity and binding;
9. remove those fields from the CorePure ingress expression; and
10. evaluate and validate only the residual record when the node consumes its inputs.

Permissive registry mode cannot prove a consumer signature and therefore performs no specialization.
All fields remain ingress values.

Example diagnostic:

```text
static field profile <- binding selected <- runtime port prompt;
admission fields must be independent of runtime ports
```

This names the failed obligation and its causal path. The `let` itself is not blamed.

## Semantic obligation

The load-bearing property is specialization coherence. If `S` is the admitted static projection, `R`
is the residual expression, and `merge` reconstructs the authored record, then for every valid
ingress environment `rho`:

```text
eval(rho, authoredArgument) = merge(S, eval(rho, R))
```

The runtime binding receives `eval(rho, R)`, not the reconstruction. It cannot observe whether a
static value was written literally, obtained from a module `let`, or calculated through a
port-closed local binding. A binder or generated artifact may consume `S` explicitly before
execution.

Three proof and test obligations follow:

1. **Dependency soundness:** a field accepted as admission-static has no runtime root.
2. **Partition totality:** every declared field is in exactly one derived schema.
3. **Specialization coherence:** evaluating then partitioning agrees with partitioning then
   evaluating the residual, for the supported CorePure subset.

## Ownership remains separate from stage

Several values are admission-static without belonging to the same mechanism:

| Surface or artifact        | Owner               | Purpose                                                    |
| -------------------------- | ------------------- | ---------------------------------------------------------- |
| node `with { ... }`        | Cortex              | compiler and scheduler controls                            |
| executor admission fields  | executor projection | bind or specialize this executor invocation                |
| static intent attachment   | downstream schema   | executor-independent graph/system realization requirements |
| package manifest invariant | package             | reusable vocabulary and invariant capability requirements  |
| platform grant and binding | host/deployer       | available authority and selected concrete implementation   |
| residual executor argument | executor/runtime    | values delivered when the node consumes ingress            |

This answers the apparent duplication between `with`, executor-static configuration, and ADR 0097:
they may share a stage but not an owner or scope.

## Consequences for the current `with` vocabulary

The implemented `with` allowlist includes executor-flavored fields such as `prompt`, `tools`,
`memory`, `maxOutputTokens`, and `reasoningEnabled`. That is compatibility debt. The final breaking
migration should classify each field:

- retain it in `with` only if Cortex scheduling or lifecycle semantics own it;
- move it to an executor admission field if it selects or specializes one binding; or
- move it to static intent if it expresses executor-independent system requirements.

There should be no generic `cfg` escape hatch in `with`.

## Adversarial cases

- **A field is annotated with an unknown phase.** Manifest loading rejects it.
- **A required admission field is absent.** Static-schema validation rejects compilation.
- **An admission field references a port through several lets.** Dependency tracing rejects it at
  the consumer field and prints the chain.
- **A port-closed `where` field feeds an admission field.** It evaluates statically; the residual
  argument does not contain the consuming field.
- **A runtime `where` field feeds an admission field.** Dependency tracing rejects it.
- **Every field is admission-static.** The residual executor record is `{}`.
- **No field is annotated.** Existing one-record ingress behavior is unchanged.
- **The projection is unchecked or permissive.** No static claim is trusted or inferred.
- **A field name is `cfg`.** It has no special phase; the projection must declare its obligation.

## Downstream interpretation

- **wireOS:** executor-specific device selectors may be admission fields; whole-system components,
  resources, mappings, and ownership remain static intent.
- **Logos:** a model profile or bounded context option may specialize an executor; tool authority,
  reusable cross-node policy, and host credentials remain intent/grant/binding concerns.
- **CortexQC:** a per-invocation backend-compatible static option may specialize a quantum executor;
  gate angles and measurement inputs remain ingress, while device-class and cross-region realization
  constraints remain intent.

## Recommendation

Keep the language surface minimal:

```text
one executor record
+ one consumer-declared field partition
+ stage-polymorphic let/where
+ dependency checking
+ semantics-preserving specialization
```

Do not add a second positional record, `static let`, `comptime`, or `env` keyword for this problem.
Those spell the stage where the language can infer it, while failing to identify the consumer whose
availability requirement gives the stage meaning.
