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

Proposed and partially implemented. The runtime, registry, manifest, capability, and compiled
metadata substrate exists additively. Existing authored calls, `config_shape`, config-facing APIs,
host wrappers, and compiled `config` metadata remain supported. The compatible source surface and
the final breaking removal are separate later slices.

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
`wrapWireStageDefinitionWithArgument` supplies evaluate, validate, exact-delivery semantics. No
authored grammar changes are part of this slice.

## Consequences

- Static evaluation and PureWire runtime evaluation remain separate concepts; a constant executor
  argument is still ingress data, not node metadata.
- Hosts can migrate bindings independently while existing integrations continue to run.
- Conflicting old/new manifest keys fail rather than silently selecting one schema.
- The final migration can remove aliases and legacy envelopes without redesigning the runtime ABI.

## Traceability

- Feature key: `wire.single_record_executor_boundary`
- Production: `src/Cortex/Wire/{Compile,Executor,Pure,Runtime}.hs`
- Package and capability: `src/Cortex/Wire/Package/Manifest.hs`,
  `src/Cortex/Capability/{Executor,Catalog/AdmissionProjection}.hs`
- Tests: `test/Cortex/Wire/{Compile,Package,Runtime}Spec.hs`,
  `test/Cortex/Capability/CatalogSpec.hs`
