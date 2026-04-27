---
title: "ADR 0016 — Canonical Cortex Epistemological Archetypes"
description: "Cortex.Nous defines the canonical epistemological taxonomy for Cortex reasoning modes: Logos, Sophia, Techne, Episteme, Kritikos, Themis, and Poiesis."
sidebar:
  label: "0016. Nous archetypes"
  order: 16
status: proposed
date: 2026-04-27
superseded_by: null
related:
  - docs/Architecture/09-nous-reasoning-library.md
  - docs/ADRs/0015-cortex-logoi-reasoning-layer.md
  - "GitHub #14"
  - "GitHub #31"
  - "GitHub #32"
---

# ADR 0016 — Canonical Cortex Epistemological Archetypes

## Status

Proposed - supersedes ADR 0015's `Cortex.Logoi` naming with `Cortex.Nous` and
establishes the canonical epistemological taxonomy. Concrete prompts, corpora,
embedding indexes, tool surfaces, memory policies, evaluation suites, runtime
contracts, workflow templates, and role-contract refinements remain follow-up
implementation work.

## Context

Cortex needs a stable vocabulary for describing distinct modes of reasoning used
by agents, workflows, tools, and runtime structures. These modes should not be
framed merely as "AI roles" or "personas," because that language is too shallow
for the system being built. Cortex models reasoning as structured work over
evidence, judgment, construction, critique, constraint, and expression.

We therefore define a canonical set of epistemological archetypes under
`Cortex.Nous`. `Nous` represents the broader faculty of intelligence or mind
within Cortex. Its children represent specialized modes of cognition that can be
composed, invoked, constrained, audited, and eventually made concrete as node
classes, agent profiles, tool surfaces, prompt contracts, or workflow policies.

This ADR also supersedes ADR 0015's `Cortex.Logoi` namespace. The vertical split
from ADR 0015 remains: runtime substrate below, structured reasoning library
above. The canonical reasoning namespace is now `Cortex.Nous`.

These archetypes are not decorative names. They define semantic expectations.

```text
Cortex.Nous
|-- Logos
|-- Sophia
|-- Techne
|-- Episteme
|-- Kritikos
|-- Themis
`-- Poiesis
```

## Decision

Adopt the following seven archetypes as the canonical Cortex epistemological
taxonomy under `Cortex.Nous`.

## Archetypes, capabilities, and profiles

The taxonomy separates three meanings:

| Concept | Meaning |
|---|---|
| Archetype | Semantic definition of a reasoning mode. |
| Capability | Concrete implementation bundle for that mode. |
| Agent profile | Composition of activated capabilities into a worker. |

Cortex epistemological archetypes are not merely descriptive labels. Each
archetype may correspond to a concrete capability bundle: curated prompts,
retrieval indexes, embedding spaces, tool permissions, memory policies,
evaluation suites, and runtime contracts. An agent expresses an archetype by
being connected to that bundle, not by carrying a nominal tag.

The canonical capability bundle shape is:

```text
Cortex.Nous.<Archetype>.Capability
|-- Definition
|-- Prompt
|-- Corpus
|-- Embeddings
|-- Tools
|-- MemoryPolicy
|-- Evaluation
`-- RuntimeContract
```

An agent can activate multiple capabilities. A `ResearchAnalyst` may primarily
activate `Episteme`, with supporting activation of `Logos`, `Kritikos`, and
`Sophia`. An implementation agent may primarily activate `Techne`, with
supporting activation of `Themis` and `Logos`.

This design prevents archetypes from becoming loose personality tags. The
archetype affects what context is retrieved, how evidence is weighted, which
tools are available, what prompt discipline is applied, and how the result is
evaluated.

This first implementation slice only lands the taxonomy, Haskell data model, and
module slots. The `Cortex.Nous.<Archetype>.Capability` modules are explicit
stubs until later PRs populate real prompts, corpus selectors, embedding spaces,
tool surfaces, evaluation checks, memory policies, and runtime contracts. A
stub capability bundle is not operational evidence that the archetype has been
implemented.

## `Cortex.Nous.Logos`

`Logos` represents discursive reason: argument, symbolic reasoning, explanation,
formal structure, and coherent inference. It is the archetype responsible for
making reasoning explicit. Where other archetypes may gather evidence, judge
consequences, build artifacts, or generate possibilities, `Logos` turns thought
into structured claims that can be followed, challenged, and refined.

In Cortex, `Logos` is the natural home for theorem-like reasoning, argument
chains, decomposition, formal comparison, symbolic manipulation, and explanatory
synthesis. A `Logos`-oriented agent should prefer clarity over flourish,
explicit premises over intuition, and traceable inference over opaque
conclusion. It is the archetype of "show the reasoning as structure."

`Logos` should be used when the task requires argumentation, derivation,
conceptual analysis, formalization, or the transformation of messy thought into
disciplined reasoning.

## `Cortex.Nous.Sophia`

`Sophia` represents wisdom, judgment, synthesis, and practical discernment. It
is not merely knowledge and not merely logic; it is the capacity to weigh
competing goods, recognize context, identify what matters, and make a sound
judgment under uncertainty.

In Cortex, `Sophia` is the archetype most closely associated with high-level
synthesis and executive understanding. It integrates outputs from other modes:
the evidence of `Episteme`, the arguments of `Logos`, the constraints of
`Themis`, the critique of `Kritikos`, the implementation realities of `Techne`,
and the generative possibilities of `Poiesis`. Its role is to decide what is
salient, balanced, timely, and wise.

`Sophia` should be used when the task requires prioritization, strategic
judgment, synthesis across domains, trade-off analysis, or deciding what
conclusion best survives complexity.

## `Cortex.Nous.Techne`

`Techne` represents craft, engineering, implementation, construction, and
skillful making. It is the archetype of turning understanding into working
artifacts. Where `Logos` reasons and `Sophia` judges, `Techne` builds.

In Cortex, `Techne` governs implementation-oriented agents and workflows:
writing code, designing systems, producing operational plans, defining
interfaces, constructing tests, shaping infrastructure, and turning abstract
designs into executable reality. A `Techne`-oriented agent should be concrete,
practical, precise, and sensitive to failure modes that appear only when ideas
meet machinery.

`Techne` should be used when the task requires engineering execution, artifact
production, code generation, system design, operational planning, refactoring,
or the conversion of a specification into a working form.

## `Cortex.Nous.Episteme`

`Episteme` represents knowledge, evidence, research, and justified belief. It is
the archetype responsible for grounding cognition in what is known, observed,
measured, cited, or otherwise supported. Its concern is not merely to answer,
but to know why an answer deserves to be trusted.

In Cortex, `Episteme` is the natural archetype for research agents, evidence
gatherers, source evaluators, retrieval systems, factual grounding, literature
review, market data analysis, and empirical validation. A task operating under
`Episteme` should distinguish between fact, inference, assumption, uncertainty,
and speculation. It should prefer verifiable claims and explicitly mark weak
evidence.

`Episteme` should be used when the task requires research, evidence gathering,
factual validation, source comparison, empirical grounding, or the construction
of a knowledge base.

## `Cortex.Nous.Kritikos`

`Kritikos` represents criticism, adversarial review, stress testing, and
disciplined doubt. It is the archetype responsible for attacking claims, finding
hidden assumptions, exposing contradictions, and identifying where a system or
argument may fail.

In Cortex, `Kritikos` should be used to create adversarial branches, red-team
analyses, counterarguments, failure-mode reviews, thesis attacks, security
critiques, and robustness checks. A `Kritikos`-oriented agent is not merely
negative; its purpose is constructive severity. It strengthens the system by
refusing to let weak reasoning, fragile design, or unsupported confidence pass
unchallenged.

`Kritikos` should be used when the task requires opposition, falsification,
stress testing, risk discovery, adversarial review, or critique of an existing
claim, design, workflow, or artifact.

## `Cortex.Nous.Themis`

`Themis` represents audit, law, correctness, constraint, procedure, and
legitimacy. It is the archetype responsible for ensuring that reasoning and
action remain within defined bounds. Where `Kritikos` attacks weakness,
`Themis` enforces order.

In Cortex, `Themis` governs correctness checks, policy enforcement, compliance
review, type discipline, runtime invariants, audit trails, contract validation,
permissions, safety boundaries, and procedural guarantees. A `Themis`-oriented
agent should care about whether something is allowed, whether it satisfies its
contract, whether it is reproducible, whether it leaves evidence, and whether
the system can defend its behavior after the fact.

`Themis` should be used when the task requires validation, auditability, legal
or policy review, correctness checking, invariant enforcement, permissioning, or
constraint-aware execution.

## `Cortex.Nous.Poiesis`

`Poiesis` represents creative generation, composition, imagination, and the
bringing-forth of new forms. It is the archetype responsible for producing
possibilities that did not previously exist in the graph.

In Cortex, `Poiesis` governs ideation, drafting, naming, design language,
narrative construction, conceptual invention, speculative synthesis, and
creative composition. It is especially important in workflows that need to
explore a space before narrowing it. A `Poiesis`-oriented agent should generate
rich alternatives, discover latent patterns, and create expressive forms that
can later be judged by `Sophia`, grounded by `Episteme`, sharpened by
`Kritikos`, constrained by `Themis`, formalized by `Logos`, or built by
`Techne`.

`Poiesis` should be used when the task requires invention, composition, naming,
storytelling, design exploration, creative synthesis, or generative expansion of
the possibility space.

## Alternatives considered

- **No fixed archetype set.** Rejected because reusable Nous templates would
  keep accumulating near-duplicate local role names, making structural
  comparisons across programs harder.
- **Downstream-specific roles only.** Rejected because evidence, reasoning,
  judgment, implementation, critique, audit, and generation are reusable modes
  of cognition. A downstream product may specialize them, but the generic
  taxonomy belongs in Nous.
- **Archetypes as a runtime registry.** Rejected because ADR 0015 keeps runtime
  authority in the existing executor and contract registries. Archetypes are
  semantic expectations and catalog entries, not a third registry.
- **Archetypes as nominal tags only.** Rejected because tag-only roles do not
  change retrieval, tools, evaluation, memory, or runtime obligations. The
  taxonomy therefore reserves capability-bundle slots, while this PR clearly
  marks those slots as non-operational stubs.

## Consequences

This taxonomy gives Cortex a stable, philosophically coherent language for
modeling reasoning roles without reducing them to generic "AI assistant"
categories. It allows agents, nodes, workflows, prompts, tools, and memory
contexts to be described in terms of epistemic function rather than surface
behavior.

Those descriptions become operational through capability bundles. A node is not
"a Logos" or "an Episteme" in the abstract; it runs with one or more Nous
bundles active. Runtime assembly can then retrieve from archetype-specific
indexes, inject archetype-specific prompt discipline, restrict or enable tools,
apply memory policy, and evaluate output under the bundle's contract.

The module stubs in this PR do not yet provide those operational assets. They
establish the public paths and expected component shape so follow-up PRs can
fill in one capability at a time without revisiting the taxonomy.

The taxonomy also supports composition. A deep research workflow may begin with
`Episteme`, pass through `Logos`, be attacked by `Kritikos`, constrained by
`Themis`, implemented through `Techne`, and synthesized by `Sophia`. A creative
product workflow may begin in `Poiesis`, be structured by `Logos`, judged by
`Sophia`, and realized by `Techne`.

The archetypes are intentionally broad enough to remain stable as Cortex
evolves, while precise enough to guide implementation, naming, module
boundaries, agent contracts, and workflow semantics.

### Obligations

- Expose module stubs at exactly the canonical paths under `Cortex.Nous`.
- Expose capability-bundle stubs at `Cortex.Nous.<Archetype>.Capability`.
- Keep archetype names semantic rather than persona labels.
- Preserve the authority boundary: archetypes do not grant executor, tool,
  provider, contract, or host authority.
- Future workflow templates must choose archetypes by epistemic function.

## Related

- [0015-cortex-logoi-reasoning-layer.md](./0015-cortex-logoi-reasoning-layer.md)
  is superseded by this ADR. It established the vertical split; this ADR keeps
  the split and renames the structured reasoning namespace to `Cortex.Nous`.
- [../Architecture/09-nous-reasoning-library.md](../Architecture/09-nous-reasoning-library.md)
  is the canonical architecture chapter for the taxonomy.
- GitHub #14, #31, and #32 are the immediate role-typing, debate, and critique
  pressures that need a stable vocabulary.
