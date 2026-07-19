---
title: "ADR 0095 - Wire Single-Record Executor Boundary"
description:
  "Introduces a compatibility-first one-record executor ingress ABI while keeping static node
  metadata distinct from runtime argument evaluation."
sidebar:
  label: "0095. Wire executor boundary"
  order: 95
status: proposed
date: 2026-07-19
superseded_by: null
related:
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0025-configured-executor-values.md
  - docs/ADRs/0053-executor-catalog-manifests-and-pulse-bindings.md
  - docs/ADRs/0060-filesystem-package-and-binding-manifests.md
  - docs/ADRs/0096-certified-native-pure-region-compilation.md
---

# ADR 0095 - Wire Single-Record Executor Boundary

## Status

Proposed and partially implemented. The runtime, registry, manifest, capability, compiled metadata,
and compatible authored source substrate exist additively. Existing authored calls,
`ConfiguredExecutor`, `config_shape`, config-facing APIs, host wrappers, and compiled `config`
metadata remain supported. Canonical formatting and the final breaking removal are a separate last
slice.

## Context

The existing executor boundary splits configuration from a parenthesized source value and also mixes
compiler controls into the configuration record. A single runtime record is easier to validate,
bind, version, and lower. That simplification must not collapse two evaluation phases: graph
admission needs static compiler facts, while an executor argument may depend on values that do not
exist until the node consumes its inputs.

## Decision

The canonical executor ABI is one record. `payload` is the automatic scalar wrapper field and `cfg`
is the conventional location for executor-specific configuration. This normalization is a
compile-time structural decision, but the resulting CorePure expression is evaluated at node
ingress.

The phases are intentionally distinct:

- compiler metadata is statically evaluable and affects graph admission, scheduling, retries,
  budgets, memory, routing, and other compiler-owned policy;
- executor arguments are runtime ingress data and may reference consumed ports, module-level
  CorePure bindings, and node `where` fields;
- after ingress evaluation, the runtime requires an object, validates it against `argument_shape`,
  and passes that exact value to the host binding.

The compatibility slice dual-reads `config_shape` and `argument_shape`, rejecting a manifest that
defines both. Public config-named projection and capability records remain as storage-compatible
views with argument-named adapters. Admission projection v1 continues to round-trip with
`configSchemaRef`; v2 uses `argumentShapeRef`.

Compiled executor tasks dual-write their unchanged legacy `config` envelope and a normalized
`argument` envelope. The latter contains `value`, optional module `bindings`, and optional `where`.
Legacy split calls normalize as follows:

- empty configuration plus `null` input becomes `{}`;
- a non-null input contributes `payload`;
- executor configuration contributes fields below `cfg`;
- both contributions share the same record.

The old `wrapWireStageDefinition` remains available. The additive
`wrapWireStageDefinitionWithArgument` supplies evaluate, validate, exact-delivery semantics. That
runtime substrate did not require authored grammar changes; the compatibility amendment below adds
the future source spelling without removing the old one.

## Compatibility amendment: authored surface

The parser also accepts the future authoring surface without removing the accepted v1 spellings:

```wire
node read -> line: Line = @uart.read_line;

node log with { label = "log line"; timeout = 30; }
  <- line: Line
  = @kernel.log line;
```

Arrows and `=` may delimit port clauses, while legacy port semicolons remain accepted. An executor
authority accepts zero or one bare CorePure argument. Zero arguments normalize to `{}`, an explicit
record remains unchanged, and a non-record value normalizes to `{ payload = value; }`. The record is
still evaluated only when the node consumes its ingress values.

`with { ... }` is a separate statically evaluated record. Its top-level keys are restricted to the
compiler-owned metadata vocabulary (`label`, instruction/prompt, tools, memory, timeout/retry and
budget controls, reasoning control, signal `on`, `artifactKind`, and `to`). Unknown, dynamically
dependent, or incorrectly typed fields fail compilation.

Bare executor authority values and `Executor` kind/form parameters are accepted alongside the legacy
configured-executor value and `ConfiguredExecutor` parameter forms. CorePure records also accept
`inherit (source) field ...;`, which lowers to explicit projections.

The formatter preserves legacy ASTs in their existing canonical spelling during this compatibility
window. It can round-trip the new surface, but the repository-wide canonical switch is deliberately
deferred to the final breaking migration.

## Consequences

- Static evaluation and PureWire runtime evaluation remain separate concepts; a constant executor
  argument is still ingress data, not node metadata.
- Hosts can migrate bindings independently while existing integrations continue to run.
- Conflicting old/new manifest keys fail rather than silently selecting one schema.
- The final migration can remove aliases and legacy envelopes without redesigning the runtime ABI.
- Old and new source forms can coexist in one module and compile to the same normalized ingress
  boundary, allowing packages and editor integrations to migrate independently.

## Traceability

- Feature key: `wire.single_record_executor_boundary`
- Production: `src/Cortex/Wire/{Compile,Executor,Pure,Runtime}.hs`
- Package and capability: `src/Cortex/Wire/Package/Manifest.hs`,
  `src/Cortex/Capability/{Executor,Catalog/AdmissionProjection}.hs`
- Tests: `test/Cortex/Wire/{Compile,Package,Runtime}Spec.hs`,
  `test/Cortex/Capability/CatalogSpec.hs`
