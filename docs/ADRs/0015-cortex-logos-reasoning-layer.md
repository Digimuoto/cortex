---
title: "ADR 0015 — Structured Reasoning Above the Cortex Substrate"
description: "Cortex is a durable runtime substrate with a structured reasoning library above it. Cortex.Logos is a namespace and library on top of the substrate, not a peer layer."
sidebar:
  label: "0015. Structured reasoning"
  order: 15
status: proposed
date: 2026-04-24
superseded_by: null
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

Proposed — establishes the vertical split between runtime substrate and reasoning, and names the reasoning layer. Follow-up ADRs will cover role semantics, per-run admission policy, and the library integration model.

## Context

Cortex conflates two concerns in its public narrative: a generic durable runtime substrate (Graph, Circuit, Wire grammar, Pulse execution, rewrite algebra, memory mechanics, contract registry infrastructure) and an opinionated reasoning stack (contract vocabularies, role semantics, reasoning templates, memory presets, executor palettes). This conflation hurts two stories at once. A consumer wanting the runtime alone for non-reasoning durable workflows has to ignore reasoning baggage. A third party wanting to build their own reasoning system on Cortex cannot see where the seams are.

The current architecture book reinforces the conflation. Chapters 03–08 are runtime-centric, but reasoning-facing concepts — role taxonomies, memory presets, template programs — sit awkwardly inside those chapters.

A first sketch proposed a new "Cortex.Logos" layer as a peer of Graph / Circuit / Wire / Pulse. That proposal duplicated ownership of executors, contracts, and memory — the substrate already owns those mechanisms under ADR 0010 and the chapter 08 contract registry. The useful residue is not a new substrate layer; it is an opinionated library of reasoning patterns built on top of the closed authority the substrate already defines.

## Decision

Cortex is explicitly two things:

- a **durable runtime substrate** — Graph algebra, Circuit validation, Wire grammar and compiler, Pulse execution, rewrite admission and materialization, memory query substrate, envelope mechanics, contract registry infrastructure;
- a **structured reasoning library** built on that substrate — executor families, contract entries and their meanings, role taxonomy, reasoning templates, memory strategy presets, reasoning policy.

The split is **vertical, not horizontal**. `Cortex.Logos` is a namespace and library on top of the substrate, not a peer of Graph / Circuit / Wire / Pulse. Dependency direction is strict: runtime never imports Logos; Logos depends on runtime.

**Logos introduces no new runtime registries.** The runtime has two: executors (per ADR 0014) and contracts (per chapter 08). Logos does not add a third. What Logos libraries ship instead are **library-owned catalogs** — code, data, and source artifacts exported by stable names and imported by consumer programs:

| Logos artifact       | Shape                                    | Discovery                                            |
|----------------------|------------------------------------------|------------------------------------------------------|
| Template programs    | `.wire` source modules                   | Imported by consumer `.wire` programs by module path. |
| Memory-strategy presets | Library-exposed `WalkSpec` / `MemoryStrategy` values | Referenced in `.wire` by stable name (e.g. `preset = "reviewer"`). |
| Role tag conventions | Metadata tags on executor registrations and on nodes | Optional field on existing executor-registration records; no new registry. |

Templates are not registered — they are authored source shipped by libraries. Presets are not registered — they are Haskell values exposed by libraries. Role tags extend the *existing* executor-registration metadata with an optional field; they do not create a parallel registration surface.

Three concepts straddle the Runtime/Logos line and must be consciously partitioned:

| Concept        | Runtime                                   | Logos                                                                       |
|----------------|-------------------------------------------|-----------------------------------------------------------------------------|
| Wire           | Grammar, compiler, port-matching algebra  | Concrete `.wire` programs; vocabulary of registered names                    |
| Contracts      | Registry mechanics, schemas, codecs, lint | Entries and their meanings (`thesis_claim`, `verdict`)                       |
| Memory         | `queryMemory` substrate, stage-entry snapshot binding, scoring pipeline | Strategy preset catalog (`analystWalkSpec`, `reviewerWalkSpec`), per-role defaults |

This ADR fixes the split and the naming. Decisions that follow from the split — the role-authority guardrail, the canonical program set, the library integration model, per-run admission policy, and the reorganized reasoning-facing documentation — are scoped as follow-up ADRs or plans so each can be amended or superseded independently.

## Alternatives considered

- **Logos as a peer substrate layer beside Graph / Circuit / Wire / Pulse.** Rejected because the sketch duplicated ownership of executors, contracts, and memory mechanics that the substrate already owns. The useful residue is not a new layer but a library of opinionated patterns on top of the closed authority already defined.
- **No separation — keep the reasoning stack unnamed inside the substrate narrative.** Rejected because the runtime story (extraction, non-reasoning workflow reuse, third-party integration) becomes incoherent when reasoning-specific taxonomy sits inside substrate chapters.
- **Multiple peer reasoning namespaces** (for example `Cortex.Clerk`, `Cortex.Logos`, `Cortex.Reasoning.Finance` at the same level). Rejected because reasoning is one layer with product bindings below it. Horizontal fragmentation at the reasoning level hides the single registration model integrators need.
- **Introduce a new Logos-specific registry** for templates, presets, and role tags. Rejected because it duplicates the runtime registration surface without adding semantics; library-owned catalogs referenced by stable name are simpler and sufficient.

## Consequences

### Positive

- Runtime stays extractable for non-reasoning durable workflows; the chapter 02 extraction story remains coherent.
- Public framing crystallizes: *Cortex is a durable runtime substrate; Cortex.Logos is its structured reasoning library.*
- The library-owned-catalog model explains how third parties extend reasoning without opening a new registration surface: ship Haskell values and `.wire` modules; consumers import by name.
- Portman's Clerk splits cleanly in follow-up work: a generic conversational pattern lives in Logos; finance persona, finance tools, and product policy stay in Portman.

### Negative

- Three existing concepts (Wire, contracts, memory) acquire dual identity and must be consciously partitioned in docs and code. Ambiguity here will leak responsibilities back across the line.
- The name "Logos" carries connotations (λόγος = structured speech / reasoning) that must be actively defended against drift into vague "intelligence layer" framing.
- Several consequential decisions — role semantics, canonical program set, integration model, admission policy, doc IA — are explicitly out of scope here and must land as separate ADRs or plans before the split becomes operational.

### Obligations

- Partition the three straddlers with explicit statements in chapter 05 (Wire), chapter 08 (contracts), and chapter 06 (memory).
- Write follow-up ADRs before the split can be shipped operationally:
  - **Role authority guardrail** — establish that roles are node metadata, not authority bearers.
  - **Canonical Logos program set** — fix the reference programs (conversational suspended wire, batch, planner-driven) that libraries build against.
  - **Library integration and per-run admission policy** — how libraries register, how `.wire` composes registered authority, and how per-run admission bounds what a single assistant run can do.
- Treat any proposal to introduce a new Logos-specific runtime registry as a supersession of this ADR; default is to extend existing executor and contract registries with reasoning metadata.
- Defer the reasoning-facing documentation layout (`docs/reasoning/` or equivalent) to a plan, not an ADR — structure is execution, not decision.

## Related

- [0010-wire-closed-authority-and-three-layer-stack.md](./0010-wire-closed-authority-and-three-layer-stack.md) — Logos inherits closed authority; this ADR extends the principle upward.
- [0014-executor-taxonomy-model-vs-external-call.md](./0014-executor-taxonomy-model-vs-external-call.md) — Logos uses this taxonomy; it does not introduce new executor kinds.
- [../Architecture/01-overview.md](../Architecture/01-overview.md), [../Architecture/02-ownership-and-boundaries.md](../Architecture/02-ownership-and-boundaries.md) — ownership model; Logos extends it upward without changing the runtime extraction story.
- [../Architecture/05-wire-language.md](../Architecture/05-wire-language.md) — site of the Wire straddle.
- [../Architecture/08-artifacts-and-provenance.md](../Architecture/08-artifacts-and-provenance.md) — site of the contract-registry straddle.
