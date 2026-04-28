---
title: "ADR 0019 — Wire Pure Nodes"
description:
  "Pure nodes are deterministic Wire-authored computations interpreted by registered pure executors;
  they require labeled same-contract slots but do not add a third executor kind."
sidebar:
  label: "0019. Pure nodes"
  order: 19
status: proposed
date: 2026-04-27
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/contracts-ports-and-matching.md
  - docs/ADRs/0014-executor-taxonomy-model-vs-external-call.md
  - docs/ADRs/0018-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0021-executor-registration-and-binding.md
  - "GitHub #55"
---

# ADR 0019 — Wire Pure Nodes

## Status

Proposed - records the target semantics for pure nodes before implementation. Pure nodes are the
first planned feature family that makes same-contract labeled inputs unavoidable; they are not
needed for the current DeepReport port-profile extraction.

## Context

Wire already has the vocabulary for registered executors, explicit ports, labels, and
contract-polymorphic utility executors in the reference grammar. The current DeepReport shape does
not force that machinery very hard: each node input uses a distinct contract, so contract-only
routing is enough.

Pure computations change the pressure. A simple weighted score needs several inputs with the same
primitive contract but different roles:

```wire
node weighted_score :
  <- evidence_score: Float
  <- recency_score: Float
  <- authority_score: Float
  -> Float
= @pure { expr = "0.5 * evidence_score + 0.3 * recency_score + 0.2 * authority_score"; };
```

Without labels, the structural roles would have to be encoded as distinct contracts such as
`EvidenceScore`, `RecencyScore`, and `AuthorityScore`. That would put graph-local slot identity into
the contract catalog, which is exactly the conflation ADR 0018 rejects.

The same pressure appears in structural primitives:

```wire
node analysis_diff :
  <- baseline: Analysis
  <- candidate: Analysis
  -> AnalysisDelta
= @pure { expr = "diff(baseline, candidate)"; };

node merge_evidence :
  <- primary: EvidenceBundle
  <- secondary: EvidenceBundle
  -> EvidenceBundle
= @pure { expr = "merge(primary, secondary)"; };
```

These examples are not blockers for extracting current DeepReport ports. They are the reason pure
nodes and structural primitives should land with tested label semantics.

## Decision

Wire pure nodes are deterministic, side-effect-free computations authored in Wire and interpreted by
registered pure executors. They do not create a third node-level executor kind. Under ADR 0014, a
pure evaluator is a registered `ExternalCallExecutor` variant with purity, replay-safety, and
side-effect metadata set to the pure/no-effect class.

The expression body is executor config or sugar for executor config, not executor definition. Wire
still does not let source files define new executor authority. For example, this surface:

```wire
node weighted_score :
  <- evidence_score: Float
  <- recency_score: Float
  <- authority_score: Float
  -> Float
= @pure { expr = "0.5 * evidence_score + 0.3 * recency_score + 0.2 * authority_score"; };
```

means: use the host-registered `@pure` evaluator with explicit ports and an expression config. The
host decides whether `@pure` is registered, which pure functions are available, which contracts are
admitted, and how expression errors are reported.

Initial pure-node implementation should obey these constraints:

- Ports are explicit. The compiler should not infer ports from expression variables in the first
  slice.
- Same-contract sibling inputs require explicit labels. Expression variable names bind to labels. A
  single unlabeled input may be exposed as `in`; otherwise pure-node inputs should be labeled to
  bind expression variables explicitly.
- The pure evaluator operates on `WirePayload`-level values, not downstream Haskell application
  types.
- The expression language is closed and deterministic: no IO, time, randomness, model calls, tool
  calls, memory queries, durable-state reads, or host callbacks other than registered pure
  functions.
- Pulse persistence still uses the closed `PayloadKind` framing table from ADR 0018. Pure nodes do
  not install Pulse codecs.
- Runtime output is wrapped and validated through the declared output contract in the normal Wire
  runtime path.

## Boundary With Contracts And Codecs

Pure nodes make the ADR 0018 split concrete.

- Contract catalogs define value meaning such as `Float`, `Analysis`, or `Evidence`.
- Port labels define graph-local roles such as `baseline`, `candidate`, `primary`, or `secondary`.
- The pure evaluator sees decoded `WirePayload` values according to payload kind and schema, not
  Haskell types such as `ResearchPlan`.
- Host application codecs remain for host executors that work over Haskell types. They are not used
  to make pure expressions type-check.

This keeps pure nodes portable. A future cross-language executor can evaluate the same pure
expression over the same contract and schema catalog without importing Portman Haskell types.

## Relationship To Structural Primitives

Pure nodes and structural primitives should share the same label discipline, but they do not have to
ship in one implementation PR.

- `@pure` evaluates deterministic expressions.
- `@identity`, `@const`, `@pack`, `@unpack`, `@merge`, and `@compare` are registered pure utility
  executors or sugar over the same pure-evaluator family.
- Contract-polymorphic utilities must still compile through explicit port declarations and known
  contract ids.
- Utilities that combine several values of the same contract must use labels to distinguish roles.

This is why label testing belongs with pure/structural utility work, not with the current DeepReport
port extraction.

## Implementation Sequence

1. Keep current DeepReport port extraction simple: move existing generic `WirePorts` values into
   `Cortex.Nous.Patterns.DeepReport.Ports` without new syntax or label semantics.
2. Add pure-node reference tests for same-contract labeled inputs, expression variable binding,
   deterministic evaluation, output wrapping, and schema/kind validation.
3. Register the first `@pure` evaluator through the normal executor-registration path as a pure
   `ExternalCallExecutor` variant.
4. Add structural primitives only after the pure evaluator and same-contract label tests are stable.

## Alternatives considered

- **Make pure nodes a third executor kind.** Rejected because ADR 0014 already splits node executors
  by production mode. A pure evaluator is non-model host execution with stronger replay and
  side-effect metadata.
- **Infer contracts and ports from expression variables.** Rejected for the first slice because it
  hides boundary shape. Explicit ports keep Wire's structural type-checking visible.
- **Invent role-specific contracts for every primitive input.** Rejected because `EvidenceScore`,
  `RecencyScore`, and `AuthorityScore` are graph-local roles over the same value shape. Labels, not
  contracts, should distinguish them.
- **Evaluate pure expressions over downstream Haskell types.** Rejected because it makes pure Wire
  programs language-specific and collapses the catalog/binder split from ADR 0018.
- **Allow host callbacks inside pure expressions.** Rejected because it turns pure nodes into hidden
  tool calls and breaks deterministic replay expectations.

## Consequences

### Positive

- Pure scoring, comparison, thresholding, and structural plumbing can be authored without
  introducing product host actions for every small computation.
- Labels get a concrete motivating feature: same-contract slots with distinct structural roles.
- Pure nodes preserve ADR 0014 by staying inside the registered executor model.
- Pure expressions remain portable because they operate over `WirePayload` and contract/schema
  catalogs rather than Haskell application types.

### Negative

- The pure expression language needs its own syntax, static checks, evaluator, and determinism
  tests.
- Schema access for JSON contracts must be specified carefully, or pure nodes will become ad hoc
  JSON-path scripts.
- The feature can grow into a general programming language if the evaluator is not kept small.

### Obligations

- Specify the pure expression grammar before implementation.
- Add conformance tests for same-contract labeled inputs.
- Add replay determinism tests for every built-in pure function.
- Keep `@pure` registration outside `.wire` source; Wire source may configure the registered
  evaluator but must not define new executor authority.
- Keep pure-node runtime failures observable through the existing executor error path rather than
  inventing a separate failure channel.

## Related

- [ADR 0014 — Model vs External Call](./0014-executor-taxonomy-model-vs-external-call.md)
- [ADR 0018 — Wire Executor and Port Catalog Boundary](./0018-wire-executor-and-port-catalog-boundary.md)
- [ADR 0021 — Executor Registration and Binding](./0021-executor-registration-and-binding.md)
- [Chapter 05 — Wire Language](../Architecture/05-wire-language.md)
- [Wire Grammar](../Reference/Wire/grammar.md)
- [Wire Reference — Contracts, Ports, and Matching](../Reference/Wire/contracts-ports-and-matching.md)
- GitHub #55
