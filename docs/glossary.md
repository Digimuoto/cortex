---
title: Cortex Glossary
description:
  Definitions of Wire and Cortex terms readers will encounter across the docs. Normative definitions
  live in Reference/terminology.md; this page is a quick-reference pointer.
sidebar:
  label: Glossary
  order: 4
---

# Cortex Glossary

Quick-reference terms. Normative and complete definitions live in
[Reference/terminology.md](Reference/terminology.md); this page exists for casual lookup and
orientation.

> **Single source of truth.** This page **points, it does not re-define.** Every entry is at most a
> one-line gloss plus a link to its canonical home (`Reference/terminology.md`, or
> `Reference/Wire/grammar.md` for grammar-level constructs, or `Reference/proof-status.md` for
> proof-side terms). If a gloss here would state a rule, threshold, field list, or "shallow/deep"
> semantics, that detail belongs in the canonical page only and must be removed here. A term must
> not appear in this glossary unless it is also defined in `Reference/terminology.md`; if it is
> missing there, add it there first. Drift between this page and its canonical home is a
> documentation-canon defect, not an editorial choice; mechanical docs-lint coverage is tracked as a
> follow-up guard.

## Core substrate

- **Cortex** — the upstream, consumer-neutral runtime substrate these docs describe. See
  [terminology.md](Reference/terminology.md#substrate-layers).
- **Algebra** — the lowest pure layer of graph and relation laws, carrying no evaluation semantics
  (the `Graph` topology type lives within it). See
  [terminology.md](Reference/terminology.md#substrate-layers).
- **Circuit** — the validated executable topology a Wire source compiles to, ready for execution.
  See [terminology.md](Reference/terminology.md#substrate-layers).
- **Wire** — the source language for authoring executable topology; its compiled circuit form is
  what Pulse executes. See [terminology.md](Reference/terminology.md#substrate-layers).
- **Pulse** — the durable runtime that schedules and executes a compiled Circuit. See
  [terminology.md](Reference/terminology.md#substrate-layers).
- **Capability** — the substrate layer that registers executor authority and exposes native
  pure-executor surfaces to execution. See
  [terminology.md](Reference/terminology.md#substrate-layers).

## Wire language — core

- **Contract** — a named, nominal typed interface that flows through a port. See
  [terminology.md](Reference/terminology.md).
- **Node** — an explicit graph vertex with typed ports and an implementation body. See
  [terminology.md](Reference/terminology.md).
- **Port** — a contract-typed slot on a node. See [terminology.md](Reference/terminology.md).
- **Port key** — the port-identity key that `=>` matches on. See
  [terminology.md](Reference/terminology.md).
- **Label** — a port's routing identity, not decoration. See
  [terminology.md](Reference/terminology.md).
- **Sum group** — an output-port mutual-exclusion form. See
  [terminology.md](Reference/terminology.md).
- **Configured executor value** — executor authority plus inert config, reusable in node bodies. See
  [terminology.md](Reference/terminology.md).
- **Wire value** — any graph-kind value usable in graph position. See
  [terminology.md](Reference/terminology.md).
- **Port-boundary** — a wire's unconnected input and output ports. See
  [terminology.md](Reference/terminology.md).
- **Frontier (Wire)** — the Wire port-boundary multiset, distinct from the Pulse scheduling
  frontier. See [terminology.md](Reference/terminology.md).
- **Frontier transformer** — the frontier-to-frontier reading of a Wire expression. See
  [terminology.md](Reference/terminology.md).
- **Carried endpoint** — an unmatched endpoint that stays exposed across `=>`. See
  [terminology.md](Reference/terminology.md).
- **Stage-structured pipeline** — the staged frontier-flow reading of a Wire pipeline. See
  [terminology.md](Reference/terminology.md).
- **File-return expression** — the last expression in a `.wire` file, which becomes the file's
  value. See [terminology.md](Reference/terminology.md).
- **Evaluation-boundary check** — the runnable-wire gate checked at evaluation-preparation. See
  [terminology.md](Reference/terminology.md).
- **Endpoint / port instance** — a concrete occurrence of a port on a node; the unit `=>` and
  linearity range over. See [terminology.md](Reference/terminology.md).
- **Edge** — the saturation event at the typed layer; a bare ordered pair at the algebra layer. See
  [terminology.md](Reference/terminology.md#core-forms).
- **Saturation (Wire)** — the `=>` match predicate over two endpoints; distinct from Pulse scheduler
  saturation. See [terminology.md](Reference/terminology.md#core-forms).
- **Port role** — the (designed) parametrization of an endpoint for matching; ADR 0087. See
  [terminology.md](Reference/terminology.md#core-forms).
- **Linear port graph** — the typed IR seam between Wire source and pure Graph. See
  [terminology.md](Reference/terminology.md).
- **CorePure** — Wire's deterministic, side-effect-free expression language. See
  [terminology.md](Reference/terminology.md).

## Wire language — abstraction & staging

- **`kind`** — compile-time node-body abstraction. See
  [terminology.md](Reference/terminology.md#compile-time-abstraction-forms-axis-2).
- **`form`** — compile-time graph abstraction. See
  [terminology.md](Reference/terminology.md#compile-time-abstraction-forms-axis-2).
- **`make` / `makeEach`** — bounded compile-time node generation. See
  [terminology.md](Reference/terminology.md#compile-time-abstraction-forms-axis-2).
- **`select`** — guarded-affine choice over latent branches. See
  [terminology.md](Reference/terminology.md#compile-time-abstraction-forms-axis-2).
- **Latent branch** — closed-world conditional continuation that stays sealed until selection. See
  [terminology.md](Reference/terminology.md#core-forms).

## Composition algebra

- **`<>` overlay** — set union of nodes and edges across two wires. See
  [terminology.md](Reference/terminology.md#composition-algebra).
- **`=>` connect** — port-key-matched edge addition over wire boundaries. See
  [terminology.md](Reference/terminology.md#composition-algebra).
- **`*` finite-product adapter** — explicit finite-product adapter node inserted between two
  operands. See [terminology.md](Reference/terminology.md#composition-algebra).
- **`//` merge** — right-biased record merge. See
  [terminology.md](Reference/terminology.md#value-operators).
- **`|` sum constructor** — output-port mutual-exclusion constructor. See
  [terminology.md](Reference/terminology.md#value-operators).
- **`@` application** — stages registered executor authority with config. See
  [terminology.md](Reference/terminology.md#value-operators).
- **Mokhov algebra** — the four-constructor algebraic basis for Wire's graph expressions. See
  [terminology.md](Reference/terminology.md#composition-algebra).

## Runtime

- **Artifact reference** — a runtime value that references a durable artifact owned by a consumer or
  host boundary. See [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Envelope** — the runtime JSON carrier every Wire value travels in. See
  [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Payload kind** — a contract's runtime category, selecting validation and rendering. See
  [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Contract registry** — the Haskell-owned authoritative contract definitions. See
  [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Provenance** — the runtime record of where a value came from. See
  [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Rewrite** — a bounded runtime topology edit over a live Circuit ("rewire" is an alias). See
  [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Gas** — the structural-change budget consumed by rewrites. See
  [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Topological memory** — downstream Logos.Memory context built from settled upstream Pulse state.
  See [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Materialized graph** — the plan graph plus all admitted rewrites — the live topology a run
  executes over. See [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Plan graph** — the initial Circuit compiled from Wire source, before any rewrites. See
  [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Rewrite log** — the append-only record of rewrite proposals and admission decisions. See
  [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Watermark** — the monotone rewrite id up to which rewrites have been materialized. See
  [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Anchor** — the existing node a rewrite attaches to. See
  [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Rewrite slot** — the exclusive, one-shot authority to transform a boundary at an anchor in one
  planning epoch. See [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Boundary law** — the explicit rule a rewrite class obeys at a boundary. See
  [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Materialization** — the atomic durable installation of admitted rewrites into graph state. See
  [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Admit / admission** — runtime acceptance of a proposed rewrite after all admission checks pass.
  See [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Selected-cost** — the gas policy where only the selected latent branch spends rewrite budget.
  See [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Run** — the unit of durable execution identity in Pulse. See
  [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Stage** — a single admitted transition in a Circuit's stage plan, the unit Pulse drives forward.
  See [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Checkpoint** — persisted run state at a stage boundary. See
  [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Lease** — a scheduler ownership claim over a run; only the holder advances it. See
  [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Ephemeral / Durable profile** — Pulse's two execution profiles — ephemeral in-memory vs durable
  persisted. See [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Replay** — deterministic re-execution over a run's journaled durable prefix. See
  [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Compatibility witness** — a family+digest fingerprint tying a compiled Circuit to the durable
  state it may resume against. See [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Compatibility barrier** — an explicit resume barrier that turns checkpoint version/shape
  mismatches into typed failures, recovering via a fresh run. See
  [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Settled state / settled-state query** — completed upstream run state exposed as a deterministic
  query surface. See [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Actualized port graph** — the runtime concrete port-instance view of the materialized Circuit.
  See [terminology.md](Reference/terminology.md#runtime-vocabulary).
- **Executor** — a registered recipe that turns a node's inputs into outputs. See
  [terminology.md](Reference/terminology.md#executors-and-registry).
- **Executor alphabet** — the closed, globally-ambient set of registered executor names. See
  [terminology.md](Reference/terminology.md#executors-and-registry).

## Proof-side vocabulary

- **Admits** — the inductive judgment that the certifying elaborator accepts a core graph
  expression. See [terminology.md](Reference/terminology.md#proof-side-vocabulary).
- **FrontierTyped** — the mechanized frontier-typing judgment over a Wire expression's port
  boundary. See [terminology.md](Reference/terminology.md#proof-side-vocabulary).
- **CertifiedGraph** — a graph object bundled with its Admits acceptance proof. See
  [terminology.md](Reference/terminology.md#proof-side-vocabulary).
- **AdmissionArtifact / Sound** — the serialized admission artifact and its soundness proposition.
  See [terminology.md](Reference/terminology.md#proof-side-vocabulary).
- **Admission witness** — proof-shaped evidence attached at admission to discharge a proof contract.
  See [terminology.md](Reference/terminology.md#proof-side-vocabulary).
- **Proof contract** — a mechanized safety surface whose terms lead the runtime implementation. See
  [terminology.md](Reference/terminology.md#runtime-vocabulary).

## Downstream Logos

- **Logos library** — the downstream structured reasoning library above Cortex; owns reusable
  LLM-shaped catalogs, not runtime authority. See
  [terminology.md](Reference/terminology.md#downstream-logos).
- **Logos.Archetypes** — the Logos catalog classifying reusable epistemological modes of cognition.
  See [terminology.md](Reference/terminology.md#downstream-logos).
- **Logos.Thought** — one bounded model-mediated cognitive evaluation bound to a graph node; not a
  durable persona. See [terminology.md](Reference/terminology.md#downstream-logos).
- **Logos.Memory** — the Logos subsystem owning cognitive memory and context construction. See
  [terminology.md](Reference/terminology.md#downstream-logos).
- **Logos.Patterns** — the Logos catalog of reusable reasoning programs (e.g. DeepReport). See
  [terminology.md](Reference/terminology.md#downstream-logos).
- **Logos archetype** — the `Logos.Archetypes.Logos` archetype for discursive reason and argument
  (not the Logos library). See [terminology.md](Reference/terminology.md#downstream-logos).
- **Logos activation bundle** — the operational implementation of an archetype that makes it
  runnable. See [terminology.md](Reference/terminology.md#downstream-logos).

## Doc kinds

- **Canonical chapter** — `NN-*` file under `Architecture/`; part of the architecture book. See
  [terminology.md](Reference/terminology.md#doc-kind-vocabulary).
- **Reference** — normative spec under `Reference/`; consultable, rule-precise. See
  [terminology.md](Reference/terminology.md#doc-kind-vocabulary).
- **ADR** — `NNNN-*` file under `ADRs/`; one committed design decision. See
  [terminology.md](Reference/terminology.md#doc-kind-vocabulary).
- **Epic** — long-running engineering initiative under `Roadmap/Epics/`. See
  [terminology.md](Reference/terminology.md#doc-kind-vocabulary).
- **Plan** — implementation plan under `Roadmap/Plans/`. See
  [terminology.md](Reference/terminology.md#doc-kind-vocabulary).
- **Research note** — dated synthesis/design memo under `Research-notes/{scope}/`. See
  [terminology.md](Reference/terminology.md#doc-kind-vocabulary).
- **Experiment** — controlled run under `Experiments/{scope}/`, started from an active epic or plan.
  See [terminology.md](Reference/terminology.md#doc-kind-vocabulary).
- **Manuscript** — paper under `Publications/Paper-N-*/manuscript.md`. See
  [terminology.md](Reference/terminology.md#doc-kind-vocabulary).

## See also

- [Reference/terminology.md](Reference/terminology.md) — normative definitions.
- [taxonomy.md](taxonomy.md) — how these terms cluster and relate.
- [Architecture/01-overview.md](Architecture/01-overview.md) — the canonical overview.
