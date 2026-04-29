---
title: Architecture Decision Records
description:
  Numbered ADRs capturing committed Cortex design decisions. Each ADR states one decision with
  context, alternatives considered, and consequences.
sidebar:
  label: ADRs
  order: 3
---

# Architecture Decision Records

Each ADR captures one committed design decision. Files use `NNNN-kebab-slug.md` naming. Status
values: `proposed`, `accepted`, `superseded`, `deprecated`.

## Current ADRs

| #                                                               | Title                                                               | Status   |
| --------------------------------------------------------------- | ------------------------------------------------------------------- | -------- |
| [0001](0001-structured-report-ir.md)                            | Structured Document IR                                              | accepted |
| [0002](0002-cortex-downstream-ownership-boundary.md)            | Cortex and Downstream Ownership Boundary                            | accepted |
| [0003](0003-pulse-service-and-host-action-boundary.md)          | Pulse Service and Host-Action Boundary                              | accepted |
| [0004](0004-graph-native-pulse-execution.md)                    | Graph-Native Pulse Execution                                        | accepted |
| [0005](0005-budgeted-rewrite-admission-and-materialization.md)  | Budgeted Rewrite Admission and Materialization                      | accepted |
| [0006](0006-compiled-workflow-artifact-boundary.md)             | Compiled Workflow Artifact Boundary                                 | accepted |
| [0007](0007-latent-branch-conditional-lowering.md)              | Latent-Branch Conditional Lowering                                  | accepted |
| [0008](0008-pulse-operator-visibility-surfaces.md)              | Pulse Operator Visibility Surfaces                                  | accepted |
| [0009](0009-rewrite-provenance-and-topology-integrity.md)       | Rewrite Provenance and Topology Integrity                           | accepted |
| [0010](0010-wire-closed-authority-and-three-layer-stack.md)     | Wire as Closed-Authority Language over the Graph/Circuit/Wire Stack | accepted |
| [0011](0011-compatibility-barriers-and-fresh-run-recovery.md)   | Compatibility Barriers and Fresh-Run Recovery                       | accepted |
| [0012](0012-topological-memory-as-deterministic-graph-query.md) | Topological Memory as Deterministic Graph Query                     | accepted |
| [0013](0013-report-provenance-artifact-contract.md)             | Artifact Provenance Contract                                        | accepted |
| [0014](0014-executor-taxonomy-model-vs-external-call.md)        | Model vs External Call                                              | proposed |
| [0015](0015-canonical-logos-archetypes.md)                      | Canonical Logos Archetypes                                          | proposed |
| [0016](0016-cortex-roots-and-logos-pattern-extraction.md)       | Cortex Roots and Logos Pattern Extraction                           | proposed |
| [0017](0017-wire-executor-and-port-catalog-boundary.md)         | Wire Executor and Port Catalog Boundary                             | proposed |
| [0018](0018-canonical-haskell-module-tree.md)                   | Canonical Haskell Module Tree                                       | proposed |
| [0019](0019-executor-registration-and-binding.md)               | Executor Registration and Binding                                   | proposed |
| [0020](0020-wire-pure-output-equations.md)                      | Wire Pure Output Equations                                          | accepted |
| [0021](0021-wire-source-elaborates-to-circuits.md)              | Wire Source Elaborates to Circuits                                  | proposed |
| [0022](0022-wire-node-clause-grammar.md)                        | Wire Node Clause Grammar                                            | proposed |
| [0023](0023-corepure-expression-surface.md)                     | CorePure Expression Surface                                         | proposed |
| [0024](0024-typed-executor-node-interface.md)                   | Typed Executor Node Interface                                       | proposed |
| [0025](0025-configured-executor-values.md)                      | Configured Executor Values                                          | proposed |
| [0026](0026-wire-failure-taxonomy.md)                           | Wire Failure Taxonomy                                               | proposed |
| [0027](0027-typed-llm-output-binding.md)                        | Typed LLM Output Binding                                            | proposed |
| [0028](0028-wire-topology-composition-and-boundary-labels.md)   | Wire Topology Composition and Boundary Labels                       | proposed |
| [0029](0029-corepure-structured-serialization.md)               | CorePure Structured Serialization                                   | proposed |
| [0030](0030-wire-node-implementation-forms.md)                  | Wire Node Implementation Forms                                      | proposed |
| [0031](0031-wire-binding-forms-and-where-clauses.md)            | Wire Binding Forms and Node Where Clauses                           | proposed |

## Writing a new ADR

Use the [template](../Templates/adr.md). Key discipline:

- Each ADR is about **one** decision. If you find yourself writing two decisions in one ADR, split
  them.
- Frontmatter lists `status`, `date`, and `related` issues.
- Body has `Context`, `Decision`, `Consequences` sections at minimum.
- An accepted ADR is canon — supersede it with a new numbered ADR rather than editing the original,
  except to update `status` and add a forward-pointer.

## Related

- [../Architecture/](../Architecture/) — canonical chapters that cite ADRs.
- [../Roadmap/](../Roadmap/) — active work whose settled decisions become ADRs.
