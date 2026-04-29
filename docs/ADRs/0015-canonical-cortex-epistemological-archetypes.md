---
title: "ADR 0015 — Canonical Cortex Nous Archetypes"
description:
  "Cortex.Nous.Archetypes defines the canonical epistemological taxonomy for Cortex reasoning modes:
  Logos, Sophia, Techne, Episteme, Kritikos, Themis, and Poiesis."
sidebar:
  label: "0015. Nous archetypes"
  order: 15
status: proposed
date: 2026-04-27
superseded_by: null
related:
  - docs/Architecture/09-nous-reasoning-library.md
  - docs/ADRs/0016-cortex-roots-and-nous-pattern-extraction.md
  - "GitHub #14"
  - "GitHub #31"
  - "GitHub #32"
---

# ADR 0015 — Canonical Cortex Nous Archetypes

## Status

Proposed - establishes `Cortex.Nous.Archetypes` as the canonical epistemological taxonomy and
reserves `Cortex.Nous.Thought`, `Cortex.Nous.Memory`, and `Cortex.Nous.Patterns` for model-mediated
cognition. Concrete prompts, corpora, embedding indexes, tool surfaces, memory policies, evaluation
suites, runtime contracts, workflow templates, and role-contract refinements remain follow-up
implementation work.

> **Implementation staging.** Haskell modules currently exist at staging paths such as
> `Cortex.Nous.Logos` and `Cortex.Nous.Logos.Capability`. Canonical paths such as
> `Cortex.Nous.Archetypes.Logos` and `Cortex.Nous.Archetypes.Logos.Activation` land in the migration
> tracked by ADR 0016.

## Context

Cortex needs a stable vocabulary for describing distinct modes of reasoning used by thoughts,
workflows, tools, and runtime structures. These modes should not be framed as durable "agents" or
"personas," because that language is too shallow and too identity-shaped for the system being built.
Cortex models reasoning as structured work over evidence, judgment, construction, critique,
constraint, and expression.

We therefore define a canonical set of epistemological archetypes under `Cortex.Nous.Archetypes`.
`Nous` represents the broader faculty of intelligence or mind within Cortex. Its `Archetypes`
children represent specialized modes of cognition that can be composed, invoked, constrained,
audited, and eventually made concrete as thought frames, tool surfaces, prompt contracts, memory
policy, or workflow policies.

`Cortex.Nous.Thought` is reserved for one model-mediated cognitive evaluation bound to a graph node.
A thought has a frame, policy, prompt/context, memory surface, tool surface, and output contract. It
is not a durable persona.

`Cortex.Nous.Memory` is reserved for cognitive memory: retrieval, ranking, packing, compaction,
topological context, memory tools, and source selection. Pulse owns durable execution state such as
checkpoints, run events, frontier, and persistence. When settled Pulse state is shaped into model
context, the context-building API belongs in Nous memory while Pulse remains the substrate.

`Cortex.Nous.Patterns` is reserved for reusable model-mediated reasoning programs built from those
archetypes. A pattern is not a new runtime primitive; it is a library-owned composition of Wire
programs, contract catalogs, prompt families, memory presets, and evaluation policy interpreted
through the existing substrate. Pattern modules are planned surfaces until their corresponding
implementation slices land.

The reasoning library root is `Cortex.Nous`. It sits above the runtime substrate and does not add a
new runtime registry or authority plane.

These archetypes are not decorative names. They define semantic expectations.

```text
Cortex.Nous
|-- Archetypes
|   |-- Logos
|   |-- Sophia
|   |-- Techne
|   |-- Episteme
|   |-- Kritikos
|   |-- Themis
|   `-- Poiesis
|-- Thought
|-- Memory
`-- Patterns
    `-- DeepReport    -- planned extraction target
```

## Decision

Adopt the following seven archetypes as the canonical Cortex epistemological taxonomy under
`Cortex.Nous.Archetypes`, and reserve the rest of the top-level Nous tree for thought execution,
cognitive memory, and reusable reasoning patterns.

The canonical public roots are:

| Root                     | Owns                                                                                                                      |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------- |
| `Cortex.Nous.Archetypes` | Semantic reasoning modes and their activation bundles.                                                                    |
| `Cortex.Nous.Thought`    | One model-mediated node evaluation: frame, policy, prompt/context, tool loop, structured output, and thought events.      |
| `Cortex.Nous.Memory`     | Cognitive memory, retrieval, packing, compaction, topological context, and memory tools.                                  |
| `Cortex.Nous.Patterns`   | Reusable LLM-shaped reasoning programs assembled from archetypes, contracts, prompts, memory presets, and Wire templates. |

The default target for LLM-shaped reasoning modules is `Cortex.Nous`, but exact homes are resolved
per module by ADR 0016's migration table. This ADR decides the conceptual taxonomy; it does not
claim that every current `Cortex.Agent`, `Cortex.Task`, `Cortex.Research`, `Cortex.Run`, or
`Cortex.Memory` module has already been audited and moved.

## Archetypes, activations, and thoughts

The taxonomy separates three meanings:

| Concept              | Meaning                                                                                            |
| -------------------- | -------------------------------------------------------------------------------------------------- |
| Archetype            | Semantic definition of a reasoning mode.                                                           |
| Archetype activation | Concrete implementation bundle for that mode.                                                      |
| Thought frame        | Composition of activated archetypes, memory, tools, and model policy for one cognitive evaluation. |

Cortex epistemological archetypes are not merely descriptive labels. Each archetype may correspond
to a concrete activation bundle: curated prompts, retrieval indexes, embedding spaces, tool
permissions, memory policies, evaluation suites, and runtime contracts. A thought expresses an
archetype by being connected to that activation, not by carrying a nominal tag.

The canonical activation bundle shape is:

```text
Cortex.Nous.Archetypes.<Archetype>.Activation
|-- Definition
|-- Prompt
|-- Corpus
|-- Embeddings
|-- Tools
|-- MemoryPolicy
|-- Evaluation
`-- RuntimeContract
```

A thought frame can activate multiple archetypes. A research-analysis thought may primarily activate
`Episteme`, with supporting activation of `Logos`, `Kritikos`, and `Sophia`. An implementation
thought may primarily activate `Techne`, with supporting activation of `Themis` and `Logos`.

This design prevents archetypes from becoming loose personality tags. The archetype affects what
context is retrieved, how evidence is weighted, which tools are available, what prompt discipline is
applied, and how the result is evaluated.

This first implementation slice only lands the taxonomy, Haskell data model, and module slots.
Current `Cortex.Nous.<Archetype>.Capability` modules are staging stubs. The canonical target is
`Cortex.Nous.Archetypes.<Archetype>.Activation`, populated by later PRs with real prompts, corpus
selectors, embedding spaces, tool surfaces, evaluation checks, memory policies, and runtime
contracts. A stub activation bundle is not operational evidence that the archetype has been
implemented.

## `Cortex.Nous.Archetypes.Logos`

`Logos` represents discursive reason: argument, symbolic reasoning, explanation, formal structure,
and coherent inference. It is the archetype responsible for making reasoning explicit. Where other
archetypes may gather evidence, judge consequences, build artifacts, or generate possibilities,
`Logos` turns thought into structured claims that can be followed, challenged, and refined.

In Cortex, `Logos` is the natural home for theorem-like reasoning, argument chains, decomposition,
formal comparison, symbolic manipulation, and explanatory synthesis. A `Logos`-oriented thought
should prefer clarity over flourish, explicit premises over intuition, and traceable inference over
opaque conclusion. It is the archetype of "show the reasoning as structure."

`Logos` should be used when the task requires argumentation, derivation, conceptual analysis,
formalization, or the transformation of messy thought into disciplined reasoning.

## `Cortex.Nous.Archetypes.Sophia`

`Sophia` represents wisdom, judgment, synthesis, and practical discernment. It is not merely
knowledge and not merely logic; it is the capacity to weigh competing goods, recognize context,
identify what matters, and make a sound judgment under uncertainty.

In Cortex, `Sophia` is the archetype most closely associated with high-level synthesis and executive
understanding. It integrates outputs from other modes: the evidence of `Episteme`, the arguments of
`Logos`, the constraints of `Themis`, the critique of `Kritikos`, the implementation realities of
`Techne`, and the generative possibilities of `Poiesis`. Its role is to decide what is salient,
balanced, timely, and wise.

`Sophia` should be used when the task requires prioritization, strategic judgment, synthesis across
domains, trade-off analysis, or deciding what conclusion best survives complexity.

## `Cortex.Nous.Archetypes.Techne`

`Techne` represents craft, engineering, implementation, construction, and skillful making. It is the
archetype of turning understanding into working artifacts. Where `Logos` reasons and `Sophia`
judges, `Techne` builds.

In Cortex, `Techne` governs implementation-oriented thoughts and workflows: writing code, designing
systems, producing operational plans, defining interfaces, constructing tests, shaping
infrastructure, and turning abstract designs into executable reality. A `Techne`-oriented thought
should be concrete, practical, precise, and sensitive to failure modes that appear only when ideas
meet machinery.

`Techne` should be used when the task requires engineering execution, artifact production, code
generation, system design, operational planning, refactoring, or the conversion of a specification
into a working form.

## `Cortex.Nous.Archetypes.Episteme`

`Episteme` represents knowledge, evidence, research, and justified belief. It is the archetype
responsible for grounding cognition in what is known, observed, measured, cited, or otherwise
supported. Its concern is not merely to answer, but to know why an answer deserves to be trusted.

In Cortex, `Episteme` is the natural archetype for research thoughts, evidence gatherers, source
evaluators, retrieval systems, factual grounding, literature review, market data analysis, and
empirical validation. A task operating under `Episteme` should distinguish between fact, inference,
assumption, uncertainty, and speculation. It should prefer verifiable claims and explicitly mark
weak evidence.

`Episteme` should be used when the task requires research, evidence gathering, factual validation,
source comparison, empirical grounding, or the construction of a knowledge base.

## `Cortex.Nous.Archetypes.Kritikos`

`Kritikos` represents criticism, adversarial review, stress testing, and disciplined doubt. It is
the archetype responsible for attacking claims, finding hidden assumptions, exposing contradictions,
and identifying where a system or argument may fail.

In Cortex, `Kritikos` should be used to create adversarial branches, red-team analyses,
counterarguments, failure-mode reviews, thesis attacks, security critiques, and robustness checks. A
`Kritikos`-oriented thought is not merely negative; its purpose is constructive severity. It
strengthens the system by refusing to let weak reasoning, fragile design, or unsupported confidence
pass unchallenged.

`Kritikos` should be used when the task requires opposition, falsification, stress testing, risk
discovery, adversarial review, or critique of an existing claim, design, workflow, or artifact.

## `Cortex.Nous.Archetypes.Themis`

`Themis` represents audit, law, correctness, constraint, procedure, and legitimacy. It is the
archetype responsible for ensuring that reasoning and action remain within defined bounds. Where
`Kritikos` attacks weakness, `Themis` enforces order.

In Cortex, `Themis` governs correctness checks, policy enforcement, compliance review, type
discipline, runtime invariants, audit trails, contract validation, permissions, safety boundaries,
and procedural guarantees. A `Themis`-oriented thought should care about whether something is
allowed, whether it satisfies its contract, whether it is reproducible, whether it leaves evidence,
and whether the system can defend its behavior after the fact.

`Themis` should be used when the task requires validation, auditability, legal or policy review,
correctness checking, invariant enforcement, permissioning, or constraint-aware execution.

## `Cortex.Nous.Archetypes.Poiesis`

`Poiesis` represents creative generation, composition, imagination, and the bringing-forth of new
forms. It is the archetype responsible for producing possibilities that did not previously exist in
the graph.

In Cortex, `Poiesis` governs ideation, drafting, naming, design language, narrative construction,
conceptual invention, speculative synthesis, and creative composition. It is especially important in
workflows that need to explore a space before narrowing it. A `Poiesis`-oriented thought should
generate rich alternatives, discover latent patterns, and create expressive forms that can later be
judged by `Sophia`, grounded by `Episteme`, sharpened by `Kritikos`, constrained by `Themis`,
formalized by `Logos`, or built by `Techne`.

`Poiesis` should be used when the task requires invention, composition, naming, storytelling, design
exploration, creative synthesis, or generative expansion of the possibility space.

## Alternatives considered

- **No fixed archetype set.** Rejected because reusable Nous templates would keep accumulating
  near-duplicate local role names, making structural comparisons across programs harder.
- **Downstream-specific roles only.** Rejected because evidence, reasoning, judgment,
  implementation, critique, audit, and generation are reusable modes of cognition. A downstream
  product may specialize them, but the generic taxonomy belongs in Nous.
- **Archetypes as a runtime registry.** Rejected because runtime authority stays in the existing
  executor and contract registries. Archetypes are semantic expectations and catalog entries, not a
  third registry.
- **Archetypes as nominal tags only.** Rejected because tag-only roles do not change retrieval,
  tools, evaluation, memory, or runtime obligations. The taxonomy therefore reserves
  activation-bundle slots, while this PR clearly marks those slots as non-operational stubs.

## Consequences

This taxonomy gives Cortex a stable, philosophically coherent language for modeling reasoning roles
without reducing them to generic "AI assistant" categories. It allows thoughts, nodes, workflows,
prompts, tools, and memory contexts to be described in terms of epistemic function rather than
surface behavior.

Those descriptions become operational through archetype activations. A node is not "a Logos" or "an
Episteme" in the abstract; it runs with one or more Nous activations active. Runtime assembly can
then retrieve from archetype-specific indexes, inject archetype-specific prompt discipline, restrict
or enable tools, apply memory policy, and evaluate output under the activation's contract.

The module stubs in this PR do not yet provide those operational assets. They establish the public
paths and expected component shape so follow-up PRs can fill in one activation at a time without
revisiting the taxonomy.

The taxonomy also supports composition. A deep research workflow may begin with `Episteme`, pass
through `Logos`, be attacked by `Kritikos`, constrained by `Themis`, implemented through `Techne`,
and synthesized by `Sophia`. A creative product workflow may begin in `Poiesis`, be structured by
`Logos`, judged by `Sophia`, and realized by `Techne`.

The archetypes are intentionally broad enough to remain stable as Cortex evolves, while precise
enough to guide implementation, naming, module boundaries, thought contracts, and workflow
semantics.

### Obligations

- Expose archetype module stubs at exactly the canonical paths under `Cortex.Nous.Archetypes`.
- Expose activation-bundle stubs at `Cortex.Nous.Archetypes.<Archetype>.Activation`.
- Use `Cortex.Nous.Patterns` for reusable LLM-shaped reasoning programs.
- Move existing direct `Cortex.Nous.<Archetype>` and `Cortex.Nous.<Archetype>.Capability` staging
  modules to the canonical `Cortex.Nous.Archetypes.<Archetype>` and
  `Cortex.Nous.Archetypes.<Archetype>.Activation` paths before accepting this ADR.
- Keep archetype names semantic rather than persona labels.
- Preserve the authority boundary: archetypes do not grant executor, tool, provider, contract, or
  host authority.
- Future workflow templates must choose archetypes by epistemic function.

## Related

- [../Architecture/09-nous-reasoning-library.md](../Architecture/09-nous-reasoning-library.md) is
  the canonical architecture chapter for the taxonomy.
- [0016-cortex-roots-and-nous-pattern-extraction.md](./0016-cortex-roots-and-nous-pattern-extraction.md)
  defines the root namespace target and module migration table.
- GitHub #14, #31, and #32 are the immediate role-typing, debate, and critique pressures that need a
  stable vocabulary.
