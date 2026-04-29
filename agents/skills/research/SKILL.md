---
name: research
description: >
  Cross-source research synthesis through the seven archetype lenses. Use after a stretch of work —
  a slice landed, a PR shipped, a sweep completed — to find loose ends, new ideas, design tensions,
  missed abstractions, and research directions across implementation, theory, docs, ADRs, issues,
  and external prior art.

date: 2026-04-30
status: active
---

# Research

Synthesize Cortex context across implementation, the Lean theory track, canonical docs, ADRs,
issues, PRs, and external literature to find high-value discrepancies and connections that only
become visible when multiple layers are read together.

The default mode is read-only. Do not modify code, theorems, or docs unless the user asks for
follow-up changes after the memo lands.

This skill complements `architecture` and `lean-theorem-attack`. Architecture decides the right
shape of a single design question. Theorem-attack stress-tests one formal claim. Research is the
zoomed-out pass that asks "given everything that has shifted, what is now visible that wasn't
before?"

## When to use

Use research when:

- A non-trivial slice has landed and the surrounding picture has changed.
- The user asks for "loose ends", "what's next", "what did we miss", "are there ideas hiding here",
  or "synthesize where we are".
- A paper, draft, or external article needs to be read against the current implementation.
- Multiple ADRs have moved together and downstream coherence needs to be checked.
- A speculative idea needs evaluation against current state.

Do not use research for:

- Single-file code review (use `haskell-code-style` or `lean-code-style`).
- One specific architectural decision (use `architecture`).
- One specific theorem's adequacy (use `lean-theorem-attack`).
- CI repair, doc fixes, or shipping work.

## Invocation modes

Dispatch on whether the user supplied a scope.

### Sweep mode (no args)

Infer the scope from the current state:

1. Branch diff against `main` (commits, changed files, touched modules).
2. Recently changed ADRs and architecture chapters.
3. Recently merged PRs that touch the same area.
4. The conversational topic if obvious.

Sweep mode is the most common use case after a slice lands. Surface findings; do not edit.

### Targeted mode (args supplied)

| Form                             | Meaning                                                                                                               |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `area <path>`                    | Focus on a subsystem or directory (e.g. `area src/Cortex/Wire`, `area theory/Cortex/Pulse`).                          |
| `issue <id>` or `pr <id>`        | Read the issue/PR plus its surrounding technical context (linked docs, code paths, prior decisions).                  |
| `paper <name>` or `draft <path>` | Cross-reference a paper, draft, or research note against current implementation and theory.                           |
| `idea <free text>`               | Evaluate a speculative direction against current Cortex state.                                                        |
| `broad`                          | Full corpus sweep across implementation, theory, docs, ADRs, issues, and external literature. Heavier; use sparingly. |
| free text                        | Steer emphasis on top of any of the above (e.g. `area src/Cortex/Wire "focus on admission/runtime drift"`).           |

Examples:

```text
/research
/research area theory/Cortex/Wire "look for Haskell↔Lean correspondence gaps"
/research pr 111 "what does this PR open up for the next slice"
/research paper mokhov-graphs "compare to our Track 1 algebra"
/research idea "treat where-records as a typed extension of input ports"
/research broad "prioritize cross-layer drift over elegance"
```

## Operating posture

- **Cortex-first.** Frame Cortex as the substrate. Treat Logos and downstream consumers as examples
  or migration pressure, not as the centre of gravity.
- **Implementation reality before abstraction.** Read code, theory, and tests before theorizing.
  Memory is not evidence.
- **Cross-reference is the source of insight.** The strongest findings live at boundaries between
  layers (impl ↔ theory, theory ↔ ADR, ADR ↔ ADR, impl ↔ issue, claim ↔ literature).
- **Separate fact, inference, and hypothesis.** Imagination is welcome; mislabelling it is not.
- **Respect the extension boundary.** A clean abstraction that blocks the next ADR or roadmap phase
  is not clean enough.
- **Evidence current, not remembered.** Re-read the code, the ADR, the lakefile. Do not trust prior
  conversation summaries as authoritative.
- **Do not silently edit.** Surface findings, prioritize, and let the user pick which to act on.

## Required sources

Read only what the scope demands, but always check the layer map before forming a finding.

### Layer 1 — Implementation reality

- `src/Cortex/` — Cortex Haskell library
- private upstream `Digimuoto/haskell-platform` — runtime support package supplied through the
  `haskell-platform-src` flake input
- private downstream `Digimuoto/logos` — downstream reasoning library; Cortex must not import it
- `app/cortex-pulse/` — substrate shell executable
- `editors/tree-sitter-wire/` — Wire grammar
- `test/` — Cortex hspec suite; Platform and Logos tests live in their own repositories
- module export lists, type signatures, partial functions, and `error` calls
- `TODO`, `FIXME`, `HACK`, `XXX`, `-- TODO`, deprecation comments

### Layer 2 — Formal narratives

- `theory/Cortex/Graph/`, `theory/Cortex/Pulse/`, `theory/Cortex/Wire/` — Lean mechanization
- `theory/README.md` — proof surface and Status table
- `theory/Main.lean`, `theory/lakefile.lean`
- module-level Lean docstrings; named theorems; `axiom` and `sorry` (should be none)

### Layer 3 — Canonical docs and roadmap

- `docs/Architecture/01-overview.md` … `08-artifacts-and-provenance.md`
- `docs/Reference/Wire/*.md`
- `docs/Consumers/Logos/*.md` (downstream surface)
- `docs/Logos/reasoning-library.md`
- `agents/context.md`, `agents/archetypes/*`

### Layer 4 — Decision history

- `docs/ADRs/index.md` plus every ADR file (status field: `proposed`, `accepted`, `superseded`)
- ADR `related:` graph, supersession chains
- `git log` on the affected paths — what shipped, what reverted

### Layer 5 — Live tracking

- GitHub Issues (`gh issue list`, `gh issue view`)
- GitHub PRs (`gh pr view`, `gh pr list`)
- linked discussions, design notes, draft PRs, RFCs

### Layer 6 — External literature and prior art

- Mokhov graph algebra papers
- Temporal / Cadence / durable-execution writeups
- Effect systems, capability-secure design, JSON Schema and contract validation
- Nix language semantics (CorePure)
- Bidirectional type-checking, structural typing, capability-bounded interpretation

Use the layers that exist. Note the layers you did not check and why.

## Archetype baseline

Every research pass runs all seven archetype lenses, but the value is the change of viewpoint, not
seven mini-essays. Keep each lens compact.

| Lens                            | Reads for                                                                                                       | Outputs                                                                                             |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `agents/archetypes/episteme.md` | What is established by current code, theory, docs, tests, ADRs, issues, literature.                             | Evidence brief: sources read, facts established, inferences, unverified assumptions, evidence gaps. |
| `agents/archetypes/logos.md`    | Precise statement of the claims, invariants, and theorem boundaries currently in play.                          | Claim map: what is asserted, what is proved, what is assumed, what is out of scope.                 |
| `agents/archetypes/kritikos.md` | Counterexamples, edge cases, off-domain inputs, layer leaks, broken assumptions, drifted invariants.            | Adversarial findings: where the current system can fail, be misused, or contradict itself.          |
| `agents/archetypes/themis.md`   | Contracts, ownership boundaries, authority surfaces, layer placement, ADR conformance.                          | Contract audit: what is owed by which layer, what is currently enforced, what is only prose.        |
| `agents/archetypes/techne.md`   | Convertibility of findings into concrete artifacts: issues, ADRs, theorems, tests, prototypes, migration notes. | Repair sketches: smallest concrete next step per finding.                                           |
| `agents/archetypes/poiesis.md`  | Alternative framings, encodings, names, decompositions; missing vocabulary; cross-domain analogies.             | Alternative encodings and naming: how else could this be modelled.                                  |
| `agents/archetypes/sophia.md`   | Prioritization, readiness, blocker vs accepted-debt, the next coherent slice.                                   | Decision summary: top priorities, residual risks, next owner or pass.                               |

Skills remain orchestrators. Archetypes do not have authority to expand scope or edit files.

## Finding categories

Read `references/finding-quality.md` before writing the memo. Use these categories on every major
finding:

| Category             | Use when                                                                           |
| -------------------- | ---------------------------------------------------------------------------------- |
| `Correctness Gap`    | A claimed or expected property is not enforced, tested, proved, or true.           |
| `Missed Abstraction` | Several ad hoc mechanisms want one principled interface, algebra, or capability.   |
| `Layer Leak`         | A concept lives at the wrong layer (Platform vs Cortex vs Logos vs downstream).    |
| `ADR Drift`          | An ADR's accepted decision and current code/docs/theory have diverged.             |
| `Novel Idea`         | A new conceptual connection or research angle the synthesis surfaces.              |
| `Design Tension`     | Two legitimate goals pull the design in conflicting directions.                    |
| `Evidence Gap`       | A claim may be true, but the current evidence is weak, partial, or stale.          |
| `Extension Risk`     | A plausible next ADR or roadmap step will break a current invariant or assumption. |
| `Dead End`           | A promising direction looks attractive but does not survive closer analysis.       |
| `Terminology Gap`    | The system lacks the right names for concepts it already relies on.                |

## Workflow

### 1. Determine scope

Use the user's scope if given. Otherwise infer from branch diff, recent commits, and active topic.
Note the scope explicitly in the memo so future readers know what was in frame.

### 2. Assemble context in layers

Walk the layer map above in order. For each layer:

- Read what the scope demands.
- Capture concrete artifacts: file paths, line numbers, ADR ids, theorem names, issue ids, commit
  hashes.
- Note layers that exist but were not read; the memo declares this.

Do not theorize before the implementation reality layer is read.

### 3. Cross-reference between pairs

For every pair of layers that the scope touches, ask:

- **Implementation ↔ Theory.** Does the Lean track witness what the Haskell evaluator does? Where
  does the proof model lag, lead, or diverge from the implementation?
- **Implementation ↔ Canonical docs.** Are docs ahead of code, code ahead of docs, or both telling
  different stories?
- **Theory ↔ ADRs.** Do theorems mechanize what the ADR commits to, or is the ADR ahead of the
  theory?
- **ADR ↔ ADR.** Are accepted decisions consistent? Is a `proposed` ADR conflicting with an
  `accepted` one without supersession?
- **Implementation ↔ Issues.** Are several open issues symptoms of the same structural gap?
- **Architecture ↔ Literature.** Is Cortex rediscovering a known abstraction or moving away from a
  known good pattern?
- **Layer placement.** Does each concept live at the right semantic level: `Platform` vs generic
  Cortex vs Logos vs downstream?

The strongest findings are usually pair findings, not layer findings.

### 4. Run the seven archetypes

Pass the assembled context through each archetype lens, in this order. Keep each output short (one
paragraph or a few bullets). The lens result is a viewpoint, not a report.

1. `episteme` — what is established, what is assumed, what is unverified
2. `logos` — claim map, theorem boundaries, what is in/out of scope
3. `kritikos` — countermodels, drift, broken assumptions
4. `themis` — contract coverage, layer ownership, ADR conformance
5. `techne` — convert each finding into a concrete next step
6. `poiesis` — alternative framings worth recording even if not adopted
7. `sophia` — prioritize and decide

### 5. Build findings with evidence discipline

Every major finding must include:

- title (one precise sentence)
- category (from the table above)
- status: `Observed`, `Inferred`, or `Speculative`
- confidence: `High`, `Medium`, or `Low`
- primary evidence (files, line numbers, ADRs, theorems, issues, literature)
- cross-reference (the pair or layers from which the finding emerges)
- why it matters (impact on correctness, extensibility, performance, clarity, or scientific
  contribution)
- recommended next step (issue, ADR draft, theorem, test, prototype, literature check, parked note)

### 6. Prioritize and write the memo

Rank findings by impact, novelty, actionability, and confidence. Group results into:

- **Act now** — must move before the next slice or before something else lands.
- **Design next** — a coherent next ADR, theorem, or implementation slice.
- **Write up** — papers, blog posts, ADRs that capture insight already implicit in the work.
- **Parked** — not now; recorded so the synthesis is not lost.

Use `templates/research-memo.md` as the output shape. Compress when the scope is small; preserve
evidence discipline either way.

## Output shape

Default to the memo template at `templates/research-memo.md`. The minimum surface is:

- executive summary (2-6 sentences)
- per-finding cards with evidence, archetype lens that surfaced it, and next step
- archetype synthesis box (one line per lens)
- recommended actions in the four buckets
- known unknowns / evidence gaps

Compressed memos are fine for narrow scopes — keep the evidence discipline.

## Quality bar

- Cite paths, theorem names, ADR ids, issue numbers — not vague memory.
- Default to 5-8 major findings; fewer is fine, more usually means the memo is doing two jobs.
- No more than 20-30% of findings should be Speculative or Low confidence.
- Every Speculative finding has a validation path attached.
- Every novel idea has at least one cross-reference and one experiment that would settle it.
- Prefer one strong finding over three weak observations.
- Negative results count: a recorded dead end prevents the team from re-treading it.

## Anti-patterns

- Theorizing before reading code or theory.
- Treating one surprise as one bug.
- Presenting speculation as established fact.
- Listing observations without prioritizing.
- Proposing abstractions for single instances.
- Praising the current cleanliness while ignoring the next roadmap phase.
- Failing to record what was not checked.
- Writing seven archetype reports instead of seven viewpoints.

## Validation

Research is read-only by default. If the user asks for follow-up edits after the memo:

- treat each follow-up as a separate skill (architecture, lean-theorem-attack, doc-review-and-fix,
  impl, etc.) rather than blurring research into editing
- run the relevant validators per the target skill (`just fmt`, `just docs-check`,
  `just lean-build`, `just check`, etc.)
- never silently edit ADRs, theorems, or canonical docs while a research pass is in progress

## References

- `references/finding-quality.md` — evidence discipline, finding bar, traceability rules
- `references/archetype-lenses.md` — how each archetype reads in research mode, with worked prompts
- `references/cortex-source-map.md` — Cortex-specific layer map with file paths and pitfalls
- `templates/research-memo.md` — memo output shape with archetype synthesis section
