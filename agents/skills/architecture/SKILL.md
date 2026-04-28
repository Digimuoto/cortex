---
name: architecture
description: >
  Analyze hard Cortex architecture and semantics questions with archetype lenses, classify the
  decision into an inline answer / ADR / supersession / split-discussion path, and point to the
  canonical docs that govern the topic.

date: 2026-04-29
status: active
---

# Architecture

Use this skill for hard design questions: source-language semantics, graph/circuit/runtime
boundaries, executor authority, proof obligations, public contracts, canonical documentation, and
cross-module architecture. The goal is to prevent design drift by deciding the right shape of
discussion before writing code or docs.

Do not use this skill for ordinary implementation debugging, style review, or CI repair unless the
question has become an architecture decision.

## Operating posture

- Cortex-first. Keep downstream consumers as examples or migration pressure, not as the frame.
- Separate current implementation, target design, proof model, and migration path.
- State the smallest precise claim that answers the question.
- Prefer typed boundaries, explicit authority, and audit trails over prose convention.
- Do not silently create or edit ADRs when the user is still exploring. Classify first, then ask or
  proceed according to the user's instruction.
- If the user explicitly asks to make the ADR or docs, implement it instead of stopping at a plan.

## Required sources

Start local. Read only the sources needed for the topic, but check the map before answering.

Core map:

- `docs/ADRs/index.md` - current ADR status and numbering.
- `docs/Architecture/01-overview.md` - public substrate framing.
- `docs/Architecture/02-ownership-and-boundaries.md` - Cortex / consumer ownership.
- `docs/Architecture/03-formalism-stack.md` - algebraic and proof-layer vocabulary.
- `docs/Architecture/04-graph-and-circuit.md` - graph and circuit boundary.
- `docs/Architecture/05-wire-language.md` - Wire language architecture.
- `docs/Architecture/06-pulse-runtime.md` - runtime, frontier, and durable execution.
- `docs/Architecture/07-rewrites-and-materialization.md` - rewrite admission and materialization.
- `docs/Architecture/08-artifacts-and-provenance.md` - artifact and provenance contracts.
- `docs/Architecture/09-nous-reasoning-library.md` - reasoning-layer boundary.

Wire map:

- `docs/Reference/Wire/grammar.md`
- `docs/Reference/Wire/executors-and-alphabet.md`
- `docs/Reference/Wire/contracts-ports-and-matching.md`
- `docs/Reference/Wire/partials-and-execution-boundary.md`
- `docs/Reference/Wire/pure-execution.md`
- `docs/Reference/Wire/conditionality.md`
- `docs/Reference/Wire/modules-imports-and-file-returns.md`

Agent reasoning map:

- `agents/archetypes/README.md`
- `agents/archetypes/episteme.md`
- `agents/archetypes/logos.md`
- `agents/archetypes/kritikos.md`
- `agents/archetypes/themis.md`
- `agents/archetypes/poiesis.md`
- `agents/archetypes/sophia.md`
- `agents/archetypes/techne.md`

Use `rg` to find specific existing ADRs or docs by concept before relying on memory.

## Archetype baseline

Use archetypes as lenses, not as long separate reports. Load the relevant files by path when their
lens is needed.

Default pass for every architecture question:

- `episteme` - what do the docs, code, tests, and ADRs already establish?
- `logos` - what exact claim or invariant is being proposed?
- `sophia` - what decision or next action matters most now?

Add lenses as needed:

- `kritikos` for counterexamples, degenerate cases, or adversarial semantics.
- `themis` for contracts, authority, invariants, provenance, process, or policy.
- `poiesis` for alternative encodings, naming, or decomposition.
- `techne` when the answer must become a patch, test, migration, or ADR artifact.

Keep the synthesis compact. The final answer should not paste seven archetype mini-essays; it should
show their effect in the recommendation.

## Decision lattice

Classify the question into exactly one primary path. Mention the classification explicitly.

### 1. Small Detail - Propose Inline

Use when the question:

- clarifies terminology, naming, or a local example;
- does not change public syntax, runtime semantics, proof obligations, or ownership boundaries;
- is consistent with accepted ADRs and reference docs;
- can be answered with one or two canonical anchors.

Output:

- concise recommendation;
- why it follows from existing canon;
- affected docs or code if any;
- residual caveat if implementation still needs a small patch.

Do not create an ADR. If a small reference-doc patch is obviously needed and the user asked for
changes, make it.

### 2. Needs ADR - Prompt For ADR Generation

Use when the question introduces or changes:

- public Wire syntax or evaluator semantics;
- graph, circuit, Pulse, rewrite, provenance, executor, or artifact invariants;
- contract, port, payload, authority, or host-binding boundaries;
- proof obligations or theorem statements;
- canonical architecture language that future implementation must follow.

Output:

- proposed ADR title and one-sentence decision;
- canonical sources to relate;
- key decision points and rejected alternatives;
- implementation and proof consequences;
- prompt: `This should become an ADR. Do you want me to draft it now?`

If the user already asked to add the ADR, create the ADR instead of prompting.

### 3. Existing ADR Concern - Ask Mutate Or Supersede

Use when the proposed change touches an existing ADR's accepted decision, status, examples, or
scope.

Rules:

- ADRs are append-only for decisions.
- Do not rewrite accepted history except for typo fixes, link repairs, status metadata, or an
  explicit forward pointer.
- If an accepted decision changes, prefer a new numbered ADR with `supersedes` / `superseded_by`
  metadata or explicit related links.
- If a proposed ADR is still under active review, editing it in place may be appropriate.

Output:

- the existing ADR(s) and their current status;
- the exact conflict or ambiguity;
- options: amend proposed ADR, add clarifying note, or supersede with a new ADR;
- prompt:
  `This concerns ADR NNNN. Should I amend it in place, add a new ADR, or mark it superseded and write the replacement?`

If the user explicitly chose the path, implement that path.

### 4. Scope Too Big - Split Or Discuss

Use when one topic contains multiple independent decisions, crosses several layers, or mixes target
design with migration and implementation.

Signals:

- the answer needs more than one public invariant;
- several teams or layers own different obligations;
- alternatives require different proofs or migration plans;
- one ADR would contain several unrelated decisions;
- implementation cannot start without narrowing the semantic target.

Output:

- warning that the scope is too large for one decision;
- a split map with candidate ADRs or discussion threads;
- dependencies between the pieces;
- the smallest next question to settle first.

Ask the user whether to split into ADRs, run another design pass, or choose one slice for
implementation.

## Analysis workflow

1. Restate the candidate decision in one sentence.
2. Identify the Cortex layer: Graph/Circuit, Wire, Pulse, Capability, Artifact, Platform, Nous, or
   docs/process.
3. Gather local evidence from the required source map.
4. Run the archetype baseline.
5. Classify with the decision lattice.
6. Name the canonical anchors that support or constrain the answer.
7. State proof, runtime, docs, migration, and test consequences when relevant.
8. Decide whether to answer inline, propose an ADR, amend/supersede an ADR, or split the scope.

## Output shapes

### Inline Answer

```markdown
Classification: Small Detail

Recommendation: ...

Canonical anchors:

- `path`: relevant rule

Reasoning: ...

Follow-up: ...
```

### ADR Prompt

```markdown
Classification: Needs ADR

Proposed ADR: ADR NNNN - <title>

Decision: ...

Why ADR:

- ...

Canonical anchors:

- ...

Open decisions:

- ...

Do you want me to draft this ADR now?
```

### Existing ADR Prompt

```markdown
Classification: Existing ADR Concern

Relevant ADRs:

- `docs/ADRs/NNNN-...md` - status, decision

Conflict: ...

Options:

1. Amend proposed ADR ...
2. Add clarifying ADR ...
3. Supersede accepted ADR ...

Which path should I take?
```

### Scope Split

```markdown
Classification: Scope Too Big

Why too large: ...

Candidate splits:

1. ADR: ...
2. ADR: ...
3. Migration note: ...

First question to settle: ...
```

## Quality bar

- Cite paths, not vague memory.
- Name invariants and ownership boundaries before proposing syntax.
- Include at least one adversarial or degenerate case for semantics changes.
- Separate "accepted", "proposed", "implemented", and "desired" claims.
- Prefer new ADRs over mutating accepted ADRs.
- Keep examples generic Cortex unless a downstream consumer is explicitly framed as a consumer.
- Avoid agent-framework vocabulary when graph/dataflow terms are more precise.
- Avoid metaphors that conflict with formal graph terminology.
- Never let prose convention substitute for a typed boundary, compiler check, runtime validation, or
  process gate.

## Validation when editing

When this skill results in doc or ADR edits:

- run `just fmt`;
- run `just docs-check`;
- run `just fmt-check`;
- run `git diff --check`;
- if committing, use `git commit -s -S`;
- verify with `just check-commit-provenance origin/main..HEAD` before publishing.
