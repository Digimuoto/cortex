---
title: "ADR 0015 — Structured Reasoning Above the Cortex Substrate"
description: "Cortex is a durable runtime substrate with a structured reasoning library above it. Cortex.Logoi is a namespace and library on top of the substrate, not a peer layer."
sidebar:
  label: "0015. Structured reasoning"
  order: 15
status: superseded
date: 2026-04-24
superseded_by: docs/ADRs/0016-canonical-cortex-epistemological-archetypes.md
related:
  - docs/Architecture/01-overview.md
  - docs/Architecture/02-ownership-and-boundaries.md
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/Architecture/08-artifacts-and-provenance.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0014-executor-taxonomy-model-vs-external-call.md
---

# ADR 0015 — Structured Reasoning Above the Cortex Substrate

## Status

Superseded by
[ADR 0016 — Canonical Cortex Epistemological Archetypes](./0016-canonical-cortex-epistemological-archetypes.md).
ADR 0015 recorded the first vertical split between the runtime substrate and a
structured reasoning library. ADR 0016 keeps that split, replaces the `Logoi`
namespace with `Cortex.Nous`, and defines the canonical archetypes.

## Context

Cortex conflates two concerns in its public narrative: a generic durable runtime substrate (Graph, Circuit, Wire grammar, Pulse execution, rewrite algebra, memory mechanics, contract registry infrastructure) and an opinionated reasoning stack (contract vocabularies, role semantics, reasoning templates, memory presets, executor palettes). This conflation hurts two stories at once. A consumer wanting the runtime alone for non-reasoning durable workflows has to ignore reasoning baggage. A third party wanting to build their own reasoning system on Cortex cannot see where the seams are.

The current architecture book reinforces the conflation. Chapters 03–08 are runtime-centric, but reasoning-facing concepts — role taxonomies, memory presets, template programs — sit awkwardly inside those chapters.

A first sketch proposed a new "Cortex.Logoi" layer as a peer of Graph / Circuit / Wire / Pulse. That proposal duplicated ownership of executors, contracts, and memory — the substrate already owns those mechanisms under ADR 0010 and the chapter 08 contract registry. The useful residue is not a new substrate layer; it is an opinionated library of reasoning patterns built on top of the closed authority the substrate already defines.

## Decision

Cortex is explicitly two things:

- a **durable runtime substrate** — Graph algebra, Circuit validation, Wire grammar and compiler, Pulse execution, rewrite admission and materialization, memory query substrate, envelope mechanics, contract registry infrastructure;
- a **structured reasoning library** built on that substrate — executor families, contract entries and their meanings, role taxonomy, reasoning templates, memory strategy presets, reasoning policy.

The split is **vertical, not horizontal**. `Cortex.Logoi` is a namespace and library on top of the substrate, not a peer of Graph / Circuit / Wire / Pulse. Dependency direction is strict: runtime never imports Logoi; Logoi depends on runtime.

**Logoi introduces no new runtime registries.** The runtime has two: executors (per ADR 0014) and contracts (per chapter 08). Logoi does not add a third. What Logoi libraries ship instead are **library-owned catalogs** — code, data, and source artifacts exported by stable names and imported by consumer programs:

| Logoi artifact | Shape | Discovery |
|---|---|---|
| Template programs | `.wire` source modules | Imported by consumer `.wire` programs by module path. |
| Memory-strategy presets | Library-exposed `WalkSpec` / `MemoryStrategy` values | Referenced in `.wire` by stable name (e.g. `preset = "reviewer"`). |
| Role tag conventions | Metadata tags on executor registrations and on nodes | Optional field on existing executor-registration records; no new registry. |

Templates are not registered — they are authored source shipped by libraries. Presets are not registered — they are Haskell values exposed by libraries. Role tags extend the *existing* executor-registration metadata with an optional field; they do not create a parallel registration surface.

Three concepts straddle the Runtime/Logoi line and must be consciously partitioned:

| Concept | Runtime | Logoi |
|---|---|---|
| Wire | Grammar, compiler, port-matching algebra | Concrete `.wire` programs; vocabulary of registered names |
| Contracts | Registry mechanics, schemas, codecs, lint | Entries and their meanings (`thesis_claim`, `verdict`) |
| Memory | `queryMemory` substrate, stage-entry snapshot binding, scoring pipeline | Strategy preset catalog (`analystWalkSpec`, `reviewerWalkSpec`), per-role defaults |

This ADR fixes the split and the naming. Decisions that follow from the split — the role-authority guardrail, the canonical program set, the library integration model, per-run admission policy, and the reorganized reasoning-facing documentation — are scoped as follow-up ADRs or plans so each can be amended or superseded independently.

## Alternatives considered

- **Logoi as a peer substrate layer beside Graph / Circuit / Wire / Pulse.** Rejected because the sketch duplicated ownership of executors, contracts, and memory mechanics that the substrate already owns. The useful residue is not a new layer but a library of opinionated patterns on top of the closed authority already defined.
- **No separation — keep the reasoning stack unnamed inside the substrate narrative.** Rejected because the runtime story (extraction, non-reasoning workflow reuse, third-party integration) becomes incoherent when reasoning-specific taxonomy sits inside substrate chapters.
- **Multiple peer reasoning namespaces** (for example `Cortex.Assistant`, `Cortex.Logoi`, `Cortex.Reasoning.Domain` at the same level). Rejected because reasoning is one layer with product bindings below it. Horizontal fragmentation at the reasoning level hides the single registration model integrators need.
- **Introduce a new Logoi-specific registry** for templates, presets, and role tags. Rejected because it duplicates the runtime registration surface without adding semantics; library-owned catalogs referenced by stable name are simpler and sufficient.

## Consequences

### Positive

- Runtime stays extractable for non-reasoning durable workflows; the chapter 02 extraction story remains coherent.
- Public framing crystallizes: *Cortex is a durable runtime substrate; Cortex.Logoi is its structured reasoning library.*
- The library-owned-catalog model explains how third parties extend reasoning without opening a new registration surface: ship Haskell values and `.wire` modules; consumers import by name.
- Downstream assistants split cleanly in follow-up work: generic conversational patterns live in Logoi; domain persona, domain tools, and product policy stay in the product binding.

### Negative

- Three existing concepts (Wire, contracts, memory) acquire dual identity and must be consciously partitioned in docs and code. Ambiguity here will leak responsibilities back across the line.
- The name "Logoi" carries connotations (λόγοι = structured speech / reasoning forms) that must be actively defended against drift into vague "intelligence layer" framing.
- Several consequential decisions — role semantics, canonical program set, integration model, admission policy, doc IA — are explicitly out of scope here and must land as separate ADRs or plans before the split becomes operational.

### Obligations

- Partition the three straddlers with explicit statements in chapter 05 (Wire), chapter 08 (contracts), and chapter 06 (memory).
- Write follow-up ADRs before the split can be shipped operationally:
  - **Role authority guardrail** — establish that roles are node metadata, not authority bearers.
  - **Canonical Logoi program set** — fix the reference programs (conversational suspended wire, batch, planner-driven) that libraries build against.
  - **Library integration and per-run admission policy** — how libraries register, how `.wire` composes registered authority, and how per-run admission bounds what a single assistant run can do.
- Treat any proposal to introduce a new Logoi-specific runtime registry as a supersession of this ADR; default is to extend existing executor and contract registries with reasoning metadata.
- Defer the reasoning-facing documentation layout (`docs/reasoning/` or equivalent) to a plan, not an ADR — structure is execution, not decision.

## Related

- [0016-canonical-cortex-epistemological-archetypes.md](./0016-canonical-cortex-epistemological-archetypes.md) — supersedes this ADR with the canonical `Cortex.Nous` namespace and taxonomy.
- [0010-wire-closed-authority-and-three-layer-stack.md](./0010-wire-closed-authority-and-three-layer-stack.md) — Logoi inherits closed authority; this ADR extends the principle upward.
- [0014-executor-taxonomy-model-vs-external-call.md](./0014-executor-taxonomy-model-vs-external-call.md) — Logoi uses this taxonomy; it does not introduce new executor kinds.
- [../Architecture/01-overview.md](../Architecture/01-overview.md), [../Architecture/02-ownership-and-boundaries.md](../Architecture/02-ownership-and-boundaries.md) — ownership model; Logoi extends it upward without changing the runtime extraction story.
- [../Architecture/05-wire-language.md](../Architecture/05-wire-language.md) — site of the Wire straddle.
- [../Architecture/08-artifacts-and-provenance.md](../Architecture/08-artifacts-and-provenance.md) — site of the contract-registry straddle.
