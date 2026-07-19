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

Each ADR captures one committed design decision. Files use `NNNN-kebab-slug.md` naming. ADR
lifecycle status values are `proposed`, `accepted`, and `superseded`. ADR 0001 governs the
documentation lifecycle; ADR 0063 governs feature traceability and feature-status joins.

## Current ADRs

| #                                                                  | Title                                                                      | Status     |
| ------------------------------------------------------------------ | -------------------------------------------------------------------------- | ---------- |
| [0001](0001-canonical-documentation-contract.md)                   | Canonical Documentation Contract                                           | accepted   |
| [0002](0002-cortex-downstream-ownership-boundary.md)               | Cortex and Downstream Ownership Boundary                                   | accepted   |
| [0003](0003-pulse-service-and-host-action-boundary.md)             | Pulse Service and Host-Action Boundary                                     | accepted   |
| [0004](0004-graph-native-pulse-execution.md)                       | Graph-Native Pulse Execution                                               | accepted   |
| [0005](0005-budgeted-rewrite-admission-and-materialization.md)     | Budgeted Rewrite Admission and Materialization                             | accepted   |
| [0006](0006-compiled-workflow-artifact-boundary.md)                | Compiled Workflow Artifact Boundary                                        | accepted   |
| [0007](0007-latent-branch-conditional-lowering.md)                 | Latent-Branch Conditional Lowering                                         | accepted   |
| [0008](0008-pulse-operator-visibility-surfaces.md)                 | Pulse Operator Visibility Surfaces                                         | accepted   |
| [0009](0009-rewrite-provenance-and-topology-integrity.md)          | Rewrite Provenance and Topology Integrity                                  | accepted   |
| [0010](0010-wire-closed-authority-and-three-layer-stack.md)        | Wire as Closed-Authority Language over the Graph/Circuit/Wire Stack        | accepted   |
| [0011](0011-compatibility-barriers-and-fresh-run-recovery.md)      | Compatibility Barriers and Fresh-Run Recovery                              | accepted   |
| [0012](0012-topological-memory-as-deterministic-graph-query.md)    | Topological Memory as Deterministic Graph Query                            | accepted   |
| [0014](0014-executor-taxonomy-model-vs-external-call.md)           | Model vs External Call                                                     | proposed   |
| [0016](0016-cortex-roots-and-logos-pattern-extraction.md)          | Cortex Canonical Root Taxonomy                                             | proposed   |
| [0017](0017-wire-executor-and-port-catalog-boundary.md)            | Wire Executor and Port Catalog Boundary                                    | proposed   |
| [0018](0018-canonical-haskell-module-tree.md)                      | Canonical Haskell Module Tree                                              | proposed   |
| [0019](0019-executor-registration-and-binding.md)                  | Executor Registration and Binding                                          | proposed   |
| [0020](0020-wire-pure-output-equations.md)                         | Wire Pure Output Equations                                                 | accepted   |
| [0021](0021-wire-source-elaborates-to-circuits.md)                 | Wire Source Elaborates to Circuits                                         | proposed   |
| [0022](0022-wire-node-clause-grammar.md)                           | Wire Node Clause Grammar                                                   | superseded |
| [0023](0023-corepure-expression-surface.md)                        | CorePure Expression Surface                                                | proposed   |
| [0024](0024-typed-executor-node-interface.md)                      | Typed Executor Node Interface                                              | superseded |
| [0025](0025-configured-executor-values.md)                         | Configured Executor Values                                                 | superseded |
| [0026](0026-wire-failure-taxonomy.md)                              | Wire Failure Taxonomy                                                      | proposed   |
| [0028](0028-wire-topology-composition-and-boundary-labels.md)      | Wire Topology Composition and Boundary Labels                              | proposed   |
| [0029](0029-corepure-structured-serialization.md)                  | CorePure Structured Serialization                                          | proposed   |
| [0030](0030-wire-node-implementation-forms.md)                     | Wire Node Implementation Forms                                             | superseded |
| [0031](0031-wire-binding-forms-and-where-clauses.md)               | Wire Binding Forms and Node Where Clauses                                  | proposed   |
| [0032](0032-wire-boundary-contract-resources.md)                   | Wire Boundary Contracts as Planning Resources                              | proposed   |
| [0033](0033-wire-select-guarded-affine-collapse.md)                | Wire Select as Guarded Affine Collapse                                     | proposed   |
| [0034](0034-wire-pure-select-actualization-authority.md)           | Pure Selectors and Restricted Actualization Authority                      | proposed   |
| [0035](0035-wire-rewrite-algebra-forms.md)                         | Wire Rewrite Algebra Forms                                                 | proposed   |
| [0036](0036-wire-latent-branch-budget-recovery.md)                 | Latent Branch Budget and Recovery Policy                                   | proposed   |
| [0037](0037-wire-latent-structural-control.md)                     | Wire Latent Structural Control Operators                                   | proposed   |
| [0038](0038-wire-proof-track-theorem-ledger.md)                    | Wire Proof-Track Theorem Ledger                                            | proposed   |
| [0039](0039-wire-node-boundary-transform-normal-form.md)           | Wire Node Boundary Transform Normal Form                                   | proposed   |
| [0040](0040-logos-owned-reasoning-surfaces.md)                     | Logos-Owned Reasoning Surfaces                                             | accepted   |
| [0041](0041-wire-cli-command-surface.md)                           | Wire CLI Command Surface                                                   | proposed   |
| [0042](0042-wire-standard-effect-executors.md)                     | Wire Standard Effect Executors                                             | proposed   |
| [0043](0043-pulse-in-memory-runner.md)                             | Pulse In-Memory Runner                                                     | proposed   |
| [0044](0044-wire-namespace-use-imports.md)                         | Wire Namespace Use Imports                                                 | proposed   |
| [0045](0045-wire-compile-time-node-body-kinds.md)                  | Wire Compile-Time Node-Body Kinds                                          | proposed   |
| [0046](0046-wire-compile-time-graph-forms.md)                      | Wire Compile-Time Graph Forms                                              | proposed   |
| [0047](0047-wire-frontier-linearity-and-precedence.md)             | Wire Frontier Linearity and Topology Operator Precedence                   | proposed   |
| [0048](0048-wire-make-bounded-node-generation.md)                  | Wire Compile-Time Make for Bounded Node Generation                         | proposed   |
| [0049](0049-wire-fan-phantom-adapter.md)                           | Wire Phantom Record↔Ports Adapter for Topology Fans                       | superseded |
| [0050](0050-wire-corepure-output-residue.md)                       | Wire CorePure Output Residue                                               | proposed   |
| [0051](0051-wire-source-includes-and-item-generation.md)           | Wire Source Includes and Item Generation                                   | proposed   |
| [0052](0052-wire-bounded-indexed-boundary-products.md)             | Wire Bounded Indexed Boundary Products                                     | proposed   |
| [0053](0053-executor-catalog-manifests-and-pulse-bindings.md)      | Executor Catalog Manifests and Pulse Runtime Bindings                      | proposed   |
| [0054](0054-downstream-wire-packages-and-host-bindings.md)         | Downstream Wire Packages and Host Runtime Bindings                         | proposed   |
| [0055](0055-pulse-runtime-bounded-iteration.md)                    | Pulse Runtime-Bounded Iteration                                            | proposed   |
| [0056](0056-admission-modes-witnessed-and-gas.md)                  | Admission Modes: Witnessed Materialization and Open Rewrite Gas            | proposed   |
| [0057](0057-wire-latent-branch-witnessing-and-closure-charging.md) | Latent Branch Witnessing and Proposal Closure Charging                     | proposed   |
| [0058](0058-pulse-atomic-suspend-settlement.md)                    | Pulse Atomic Suspend Settlement                                            | proposed   |
| [0059](0059-durable-external-call-frontiers-on-pulse.md)           | Durable External-Call Frontiers on Pulse                                   | proposed   |
| [0060](0060-filesystem-package-and-binding-manifests.md)           | Filesystem Package and Binding Manifests                                   | proposed   |
| [0061](0061-corepure-bounded-iteration-primitives.md)              | CorePure Bounded Iteration Primitives                                      | proposed   |
| [0062](0062-typed-effect-variant-output-boundaries.md)             | Typed Effect Variant Output Boundaries                                     | accepted   |
| [0063](0063-adr-traceability-and-feature-status-canon.md)          | ADR Traceability and Feature Status Canon                                  | accepted   |
| [0064](0064-pulse-graph-state-cas.md)                              | Pulse Graph-State Optimistic Concurrency and Single-Writer Ownership       | accepted   |
| [0065](0065-pulse-frontier-concurrency.md)                         | Pulse Concurrent Frontier Execution and Cooperative Cancellation           | proposed   |
| [0066](0066-pulse-resume-recovery.md)                              | Pulse Graph-State-Driven Resume and Recovery Preconditions                 | accepted   |
| [0067](0067-pulse-stage-retry-policy.md)                           | Pulse Per-Stage Retry, Backoff and Replay-Safety Policy                    | proposed   |
| [0068](0068-pulse-scheduler-leasing.md)                            | Pulse Scheduler: Lease Recovery, Fair Claiming and Backpressure Visibility | proposed   |
| [0069](0069-rewrite-planner-drift-witness.md)                      | Haskell-Lean Rewrite Planner Correspondence and Drift Witness              | proposed   |
| [0070](0070-wire-file-imports.md)                                  | Wire File Imports, File-Return Selection and Module Closure Semantics      | proposed   |
| [0071](0071-wire-artifact-emission.md)                             | Artifact-Emission Boundary Node and Durable Artifact-Reference Contract    | proposed   |
| [0072](0072-corepure-stdlib-catalogue.md)                          | CorePure Ergonomic Stdlib Catalogue                                        | proposed   |
| [0073](0073-corepure-division-model.md)                            | CorePure Division Number Model: Finite Float64 and Non-Finite Rejection    | proposed   |
| [0074](0074-wire-canonical-formatter.md)                           | Canonical Wire Source Formatter and wire fmt Command                       | proposed   |
| [0075](0075-pulse-service-config-credentials.md)                   | cortex-pulse Service Config, Runner-Token Minting and Credential Surface   | proposed   |
| [0076](0076-wire-cli-proof-fixtures.md)                            | Wire CLI Proof-Fixture and Grammar-Acceptance Subcommands                  | proposed   |
| [0077](0077-wire-manifest-versioning.md)                           | Wire Package Manifest Versioning and Forward-Compatibility Contract        | proposed   |
| [0078](0078-lean-wire-elaboration-kernel.md)                       | Lean-Owned Wire Elaboration IR and Executable Certifying Admission Kernel  | proposed   |
| [0079](0079-wire-admission-witness-schema.md)                      | Wire Admission Artifact as Haskell-to-Lean Proof-Witness Exchange Schema   | proposed   |
| [0080](0080-wire-binder-construction-boundary.md)                  | Wire Binder Construction and the Contract-Typing Boundary                  | proposed   |
| [0081](0081-wire-endpoint-closure-accounting.md)                   | Wire Endpoint Closure Accounting and Frontier Inspection                   | proposed   |
| [0082](0082-pulse-durable-signals.md)                              | Pulse Durable Signal Primitive                                             | proposed   |
| [0083](0083-pulse-schema-lifecycle.md)                             | Pulse Schema Lifecycle and Migration Policy                                | accepted   |
| [0084](0084-wire-tree-sitter-grammar.md)                           | tree-sitter-wire Grammar Governance                                        | proposed   |
| [0085](0085-wire-contract-schema-as-type-enforcement.md)           | Wire Contract Schema-as-Type Enforcement and the No-Subtyping Ceiling      | proposed   |
| [0086](0086-wire-scoped-graph-construction-rejection.md)           | Wire Scoped Graph Construction: Rejection of the Graph-Block Bundle        | proposed   |
| [0087](0087-wire-edge-as-saturation-event.md)                      | Wire Edge as Saturation Event and the Port-Role Parametrization            | proposed   |
| [0088](0088-pulse-externally-driven-step-admission.md)             | Externally-Driven Step Admission                                           | proposed   |
| [0089](0089-pulse-content-addressed-artifact-store.md)             | Pulse-Owned Content-Addressed Run Artifact Store                           | proposed   |
| [0090](0090-computable-pulse-kernel-and-extraction-boundary.md)    | Computable Circuit-Engine Decision Kernel and Extraction Boundary          | accepted   |
| [0091](0091-lean-hosted-freestanding-wire-c-backend.md)            | Lean-Hosted Freestanding Wire C Backend                                    | accepted   |
| [0092](0092-circuit-engine-runtime-host-boundary.md)               | Circuit Engine and Runtime-Host Boundary                                   | accepted   |
| [0093](0093-versioned-circuit-state-event-control-protocol.md)     | Versioned Circuit State, Event, and Control Protocol                       | accepted   |
| [0094](0094-hosted-x86-64-linux-executable-profile.md)             | Hosted x86_64 Linux Executable Profile                                     | accepted   |
| [0095](0095-wire-single-record-executor-boundary.md)               | Wire Single-Record Executor Boundary                                       | accepted   |
| [0096](0096-certified-native-pure-region-compilation.md)           | Certified NativePure Compilation                                           | proposed   |
| [0097](0097-wire-static-intent-and-realization-inputs.md)          | Wire Static Intent and Realization Inputs                                  | proposed   |

## By category

A browse-by-concern view of the current ADRs. The superseded 0049 is omitted. Numbering is the
stable ADR identifier space, not a category ranking. A few ADRs cross-cut; only the primary category
is shown here.

- **Boundary & governance** (9): [0001](0001-canonical-documentation-contract.md),
  [0002](0002-cortex-downstream-ownership-boundary.md),
  [0003](0003-pulse-service-and-host-action-boundary.md),
  [0006](0006-compiled-workflow-artifact-boundary.md),
  [0016](0016-cortex-roots-and-logos-pattern-extraction.md),
  [0018](0018-canonical-haskell-module-tree.md), [0040](0040-logos-owned-reasoning-surfaces.md),
  [0063](0063-adr-traceability-and-feature-status-canon.md),
  [0080](0080-wire-binder-construction-boundary.md)
- **Pulse runtime & durability** (15): [0004](0004-graph-native-pulse-execution.md),
  [0008](0008-pulse-operator-visibility-surfaces.md),
  [0011](0011-compatibility-barriers-and-fresh-run-recovery.md),
  [0012](0012-topological-memory-as-deterministic-graph-query.md),
  [0043](0043-pulse-in-memory-runner.md), [0055](0055-pulse-runtime-bounded-iteration.md),
  [0058](0058-pulse-atomic-suspend-settlement.md),
  [0059](0059-durable-external-call-frontiers-on-pulse.md), [0064](0064-pulse-graph-state-cas.md),
  [0065](0065-pulse-frontier-concurrency.md), [0066](0066-pulse-resume-recovery.md),
  [0067](0067-pulse-stage-retry-policy.md), [0068](0068-pulse-scheduler-leasing.md),
  [0082](0082-pulse-durable-signals.md), [0083](0083-pulse-schema-lifecycle.md)
- **Circuit engine & hosted targets** (7):
  [0090](0090-computable-pulse-kernel-and-extraction-boundary.md),
  [0091](0091-lean-hosted-freestanding-wire-c-backend.md),
  [0092](0092-circuit-engine-runtime-host-boundary.md),
  [0093](0093-versioned-circuit-state-event-control-protocol.md),
  [0094](0094-hosted-x86-64-linux-executable-profile.md),
  [0096](0096-certified-native-pure-region-compilation.md)
- **Rewrite admission & budget** (8):
  [0005](0005-budgeted-rewrite-admission-and-materialization.md),
  [0009](0009-rewrite-provenance-and-topology-integrity.md),
  [0034](0034-wire-pure-select-actualization-authority.md),
  [0036](0036-wire-latent-branch-budget-recovery.md),
  [0056](0056-admission-modes-witnessed-and-gas.md),
  [0057](0057-wire-latent-branch-witnessing-and-closure-charging.md),
  [0069](0069-rewrite-planner-drift-witness.md),
  [0088](0088-pulse-externally-driven-step-admission.md)
- **Conditionals, selection & rewrite algebra** (4):
  [0007](0007-latent-branch-conditional-lowering.md),
  [0033](0033-wire-select-guarded-affine-collapse.md), [0035](0035-wire-rewrite-algebra-forms.md),
  [0037](0037-wire-latent-structural-control.md)
- **Wire contracts & resources** (4): [0032](0032-wire-boundary-contract-resources.md),
  [0081](0081-wire-endpoint-closure-accounting.md),
  [0085](0085-wire-contract-schema-as-type-enforcement.md),
  [0087](0087-wire-edge-as-saturation-event.md)
- **Wire language & grammar** (8): [0010](0010-wire-closed-authority-and-three-layer-stack.md),
  [0022](0022-wire-node-clause-grammar.md), [0026](0026-wire-failure-taxonomy.md),
  [0031](0031-wire-binding-forms-and-where-clauses.md), [0044](0044-wire-namespace-use-imports.md),
  [0070](0070-wire-file-imports.md), [0086](0086-wire-scoped-graph-construction-rejection.md),
  [0097](0097-wire-static-intent-and-realization-inputs.md)
- **Wire executor & node interface** (6): [0017](0017-wire-executor-and-port-catalog-boundary.md),
  [0024](0024-typed-executor-node-interface.md), [0025](0025-configured-executor-values.md),
  [0030](0030-wire-node-implementation-forms.md),
  [0039](0039-wire-node-boundary-transform-normal-form.md),
  [0062](0062-typed-effect-variant-output-boundaries.md)
- **Wire elaboration & compile-time generation** (4):
  [0021](0021-wire-source-elaborates-to-circuits.md),
  [0045](0045-wire-compile-time-node-body-kinds.md), [0046](0046-wire-compile-time-graph-forms.md),
  [0051](0051-wire-source-includes-and-item-generation.md)
- **Wire topology composition** (4): [0028](0028-wire-topology-composition-and-boundary-labels.md),
  [0047](0047-wire-frontier-linearity-and-precedence.md),
  [0048](0048-wire-make-bounded-node-generation.md),
  [0052](0052-wire-bounded-indexed-boundary-products.md)
- **CorePure** (7): [0020](0020-wire-pure-output-equations.md),
  [0023](0023-corepure-expression-surface.md), [0029](0029-corepure-structured-serialization.md),
  [0050](0050-wire-corepure-output-residue.md),
  [0061](0061-corepure-bounded-iteration-primitives.md), [0072](0072-corepure-stdlib-catalogue.md),
  [0073](0073-corepure-division-model.md)
- **Capability & executors** (4): [0014](0014-executor-taxonomy-model-vs-external-call.md),
  [0019](0019-executor-registration-and-binding.md), [0042](0042-wire-standard-effect-executors.md),
  [0053](0053-executor-catalog-manifests-and-pulse-bindings.md)
- **Artifact & provenance** (2): [0071](0071-wire-artifact-emission.md),
  [0089](0089-pulse-content-addressed-artifact-store.md)
- **Packaging, CLI & tooling** (8): [0041](0041-wire-cli-command-surface.md),
  [0054](0054-downstream-wire-packages-and-host-bindings.md),
  [0060](0060-filesystem-package-and-binding-manifests.md),
  [0074](0074-wire-canonical-formatter.md), [0075](0075-pulse-service-config-credentials.md),
  [0076](0076-wire-cli-proof-fixtures.md), [0077](0077-wire-manifest-versioning.md),
  [0084](0084-wire-tree-sitter-grammar.md)
- **Proof track** (3): [0038](0038-wire-proof-track-theorem-ledger.md),
  [0078](0078-lean-wire-elaboration-kernel.md), [0079](0079-wire-admission-witness-schema.md)

## Writing a new ADR

Use the [template](../Templates/adr.md). Key discipline:

- Each ADR is about **one** decision. If you find yourself writing two decisions in one ADR, split
  them.
- Start substantial design work with a `proposed` ADR. Issues, epics, and PRs are downstream
  execution surfaces derived from the ADR, not substitutes for the design record.
- While an ADR is proposed, implementation may refine its wording, obligations, traceability, and
  open questions. Acceptance happens only after dependencies are met, implementation/docs evidence
  is current, and temporary tracker state is removed.
- Frontmatter lists `status`, `date`, and durable `related` canon/source references.
- Body has `Context`, `Decision`, `Consequences` sections at minimum. Feature/runtime/language/proof
  ADRs add a `Traceability` block (ADR 0063); governance and meta ADRs omit it.
- Proposed ADRs may end with a temporary `## Tracking` section for issue/PR planning state. Delete
  that section before moving the ADR to `accepted`; accepted ADRs should cite durable artifacts, not
  issue-tracker archaeology.
- Before accepting an ADR, reconcile the living docs that should synthesize it: Architecture,
  Reference, Usage, feature-status/proof-status when applicable, and consumer docs if the decision
  changes a downstream-facing boundary.
- An accepted ADR is canon — supersede it with a new numbered ADR rather than editing the original,
  except to update `status` and add a forward-pointer.

## Related

- [../Architecture/](../Architecture/) — canonical chapters that cite ADRs.
- [../Roadmap/](../Roadmap/) — active work whose settled decisions become ADRs.
