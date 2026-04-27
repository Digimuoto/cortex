---
title: "Chapter 09 — Nous Reasoning Library"
description: "How Cortex.Nous sits above the substrate, defines canonical epistemological archetypes, and preserves runtime authority boundaries."
sidebar:
  label: "09. Nous reasoning"
  order: 9
status: active
---

# Chapter 09 — Nous Reasoning Library

`Cortex.Nous` is the structured reasoning library above the Cortex substrate. It
names reusable epistemological modes and ships library-owned catalogs, but it
does not extend the runtime alphabet. Graph, Circuit, Wire, Pulse, capability,
contract, memory, and artifact mechanics remain the substrate. Nous composes
those mechanics into reusable reasoning programs.

## Core model

The split is vertical:

| Layer | Owns | Does not own |
|---|---|---|
| Cortex runtime substrate | Graph algebra, Circuit validation, Wire grammar, Pulse execution, executor and contract registry mechanics, memory query mechanics, artifact provenance. | Product persona, domain policy, concrete reasoning templates. |
| `Cortex.Nous` | Epistemological archetype taxonomy, reusable `.wire` templates, prompt families, memory presets, contract-entry conventions. | Runtime authority, new executor kinds, new contract registry, host tools. |
| Downstream product binding | Domain prompts, product policy, domain tools, approval behavior, product artifact semantics. | Generic substrate mechanics or generic Nous archetype definitions. |

The dependency direction is strict:

```mermaid
flowchart LR
    Product[Downstream product binding] --> Nous[Cortex.Nous<br/>structured reasoning library]
    Nous --> Runtime[Cortex substrate<br/>Graph, Circuit, Wire, Pulse, capabilities]
```

Runtime code must not import Nous. Nous may import runtime types and publish
catalog values or source templates that consumers opt into.

## Detailed structure

### Canonical tree

The canonical module and concept tree is:

```text
Cortex.Nous
|-- Logos     -- discursive reason, argument, symbolic reasoning
|   `-- Capability
|-- Sophia    -- wisdom, judgment, synthesis
|   `-- Capability
|-- Techne    -- craft, engineering, implementation
|   `-- Capability
|-- Episteme  -- knowledge, evidence, research
|   `-- Capability
|-- Kritikos  -- criticism, adversarial review
|   `-- Capability
|-- Themis    -- audit, law, correctness, constraints
|   `-- Capability
`-- Poiesis   -- creative generation, composition
    `-- Capability
```

### Archetype catalog

The first catalog contains seven archetypes:

| Archetype | Role | Typical responsibility | Literature-backed pattern |
|---|---|---|---|
| `Cortex.Nous.Logos` | Discursive reason, argument, symbolic reasoning | Make reasoning explicit as structured claims, premises, inference, and explanation. | Self-consistency, Tree of Thoughts |
| `Cortex.Nous.Sophia` | Wisdom, judgment, synthesis | Weigh competing goods, recognize context, identify salience, and synthesize under uncertainty. | LLM-as-a-judge, multi-agent debate |
| `Cortex.Nous.Techne` | Craft, engineering, implementation | Turn understanding into working artifacts, executable plans, interfaces, tests, and systems. | SWE-agent, CodeAct, tool-use frameworks |
| `Cortex.Nous.Episteme` | Knowledge, evidence, research | Ground cognition in what is known, observed, measured, cited, or otherwise supported. | ReAct, tool-use agents, information retrieval |
| `Cortex.Nous.Kritikos` | Criticism, adversarial review | Apply constructive severity to expose weak claims, hidden assumptions, contradictions, and failure modes. | Constitutional AI, red-teaming |
| `Cortex.Nous.Themis` | Audit, law, correctness, constraints | Ensure reasoning and action remain within defined bounds, contracts, policies, and invariants. | AI safety, Constitutional AI, alignment |
| `Cortex.Nous.Poiesis` | Creative generation, composition | Bring forth new forms, alternatives, narratives, designs, and generative possibilities. | Creative generation, story-telling agents |

The catalog describes reusable modes of cognition. It does not prescribe a
specific provider, model, prompt, tool list, or domain ontology. Those are later
library presets or downstream bindings.

### Capability bundles

An archetype becomes operational when it is implemented as a capability bundle:

```text
Cortex.Nous.<Archetype>.Capability
  = prompt discipline
  + retrieval corpus
  + embedding index
  + tool surface
  + evaluation criteria
  + memory policy
  + runtime contract
```

The archetype is the semantic definition. The capability is the concrete bundle
of assets and policies that implement that mode. An agent profile composes one
or more capability activations into a worker.

Current implementation status: this first PR lands the type shape and module
slots only. The `Cortex.Nous.<Archetype>.Capability` modules expose explicit
stub bundles until later PRs attach real prompts, corpora, embedding indexes,
tool surfaces, memory policies, evaluation checks, and runtime contracts.

For example, `Cortex.Nous.Episteme.Capability` is the home for evidence-grounded
prompts, source-quality rules, retrieval strategies, source-ranking heuristics,
uncertainty policy, citation discipline, and validation tests. A
`Cortex.Nous.Kritikos.Capability` bundle is the home for adversarial-review
prompts, failure-mode corpora, contradiction checks, falsification discipline,
and red-team evaluation. A `Cortex.Nous.Techne.Capability` bundle is the home
for codebase-local implementation memory, architecture conventions, build and
test patterns, and implementation checks.

This makes the vocabulary operational. A node is not just tagged with
`Episteme`; it runs with the Episteme substrate active. The bundle shapes what
context is retrieved, which tools are available, which prompt discipline is
applied, which memory policy is used, and how the result is evaluated.

The stub bundles in this PR are not yet operational substrates. They are public
slots and expected component lists for follow-up implementation.

Retrieval is profile-aware rather than a single global index per archetype. A
bundle can combine canonical corpus, local project corpus, examples, failures,
contracts, and tool docs with task-specific weights. A `Techne` capability for
Cortex code and a `Techne` capability for another domain share the archetype but
activate different local corpora and tool surfaces.

### Catalog artifacts

Nous can expose the following catalog artifacts:

| Artifact | Shape | Runtime relationship |
|---|---|---|
| Archetype definitions | Haskell data values under `Cortex.Nous` | Metadata only. No runtime registration. |
| Capability bundle slots | Prompts, corpus selectors, embeddings, tools, memory policy, evaluation, runtime contract | Stubbed in this PR; later activated by profiles and interpreted through existing substrate APIs. |
| Template programs | `.wire` modules shipped by Nous | Imported by consumers and compiled by the normal Wire compiler. |
| Memory presets | Haskell values naming query and walk strategy defaults | Passed through existing memory substrate APIs. |
| Contract conventions | Stable contract entries and documentation | Implemented through the existing contract registry. |
| Prompt families | Text builders or source artifacts | Bound to executors by consumers or library templates. |

The important rule is that each artifact is interpreted by an existing
substrate mechanism. Nous catalogs do not add a hidden resolver.

## Boundaries and invariants

Nous is correct when these invariants hold:

- Runtime modules do not import `Cortex.Nous` modules.
- Archetype names never grant tool access, model access, side effects, or host
  authority.
- Capability bundles can request tool surfaces and runtime contracts, but those
  requests are still admitted through existing executor, contract, and host
  authority boundaries.
- A node's executable authority still comes from its registered executor and its
  configured tool scope.
- A node's payload obligations still come from its contracts and runtime
  validation.
- Archetypes classify epistemic function and reusable program shape; contracts
  define data obligations; capabilities bundle operational assets; executors
  define runnable authority.

What Nous intentionally does not enforce in this first slice:

- role-contract refinement typing
- per-run admission policy for reasoning templates
- canonical `.wire` program set
- downstream domain semantics

Those are follow-up decisions and implementation work, not prerequisites for the
taxonomy to exist.

## Extensibility

New archetypes require an ADR because they change the public epistemological
vocabulary. Downstream products do not need an ADR to create product-specific
roles; they should map those roles to the nearest Nous archetype when using
generic templates.

Program templates extend the library by composing existing runtime authority:

- choose archetypes for structural role clarity
- bind concrete executors through the normal executor registry
- bind contracts through the normal contract registry
- attach memory presets through existing memory substrate values
- compile and run through Wire, Circuit, and Pulse unchanged

## Related

- [ADR 0015 — Structured Reasoning Above the Cortex Substrate](../ADRs/0015-cortex-logoi-reasoning-layer.md)
- [ADR 0016 — Canonical Cortex Epistemological Archetypes](../ADRs/0016-canonical-cortex-epistemological-archetypes.md)
- [Chapter 02 — Ownership and boundaries](02-ownership-and-boundaries.md)
- [Chapter 05 — Wire language](05-wire-language.md)
- [Chapter 08 — Artifacts and provenance](08-artifacts-and-provenance.md)
- GitHub #14, #31, and #32 for the first role-contract, debate, and critique
  workflows that need this vocabulary.
