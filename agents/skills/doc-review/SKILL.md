---
name: doc-review
description: >
  Review Markdown docs in this repo with doc-type-aware standards. Use
  when asked to review architecture/spec/reference/research/ADR/
  publication/blog docs, check frontmatter and staleness, assess
  Mermaid/math/code blocks, verify claims, improve compactness, or
  enforce Cortex-first canonical docs.
date: 2026-04-25
status: active
---

# Document Review

Read-only review passes over repo documentation under `docs/`.

When the user asks for review **and** edits in one pass, use
`doc-review-and-fix` instead.

Read `references/writing-standards.md` when you need a compact reminder
of the canonical-doc policy or publication/reference writing
expectations.

## Review order

Always review in this order:

1. classify the document
2. choose review mode
3. check frontmatter integrity and staleness
4. run the content and format review for that doc class
5. report findings first, then open questions, then a short summary

## Classification

Classify both the document kind and its audience/stability class.

**Kinds:**

- architecture or reference spec
- ADR
- research note
- roadmap, plan, handoff, or experiment
- publication or public-facing paper
- blog post, explainer, or guide

**Audience and stability:**

- `canonical` — stable Cortex docs that should survive repo moves and
  downstream-product changes
- `internal` — historical, design-process, or implementation-facing

Treat these as `canonical` by default unless the document says otherwise:

- `docs/Architecture/**`
- `docs/Reference/**`
- top-level canon: `index.md`, `glossary.md`, `taxonomy.md`, `map.md`
- `docs/Publications/**` (intended to stand on their own)

Treat these as `internal` by default:

- `docs/Research-notes/**`
- `docs/ADRs/**`
- `docs/Roadmap/**`
- `docs/Handoffs/**`
- `docs/Experiments/**`

Tune strictness to the class:

- **research notes** — loose; structure and clarity matter more than polish
- **ADRs** — concise, decision-focused, historically grounded
- **architecture and reference** — strict on scope, terminology,
  examples, and internal consistency
- **publications** — strictest on claims, figures, notation, and prose

## Review mode

State one explicitly near the top of the review:

- `current-state conformance`
- `target-design critique`
- `historical or migration review`

If the user doesn't specify, infer and say which mode you used. Don't
collapse a target-design spec into an implementation audit.

If the review is scoped to one section, still run a quick file-level
metadata and staleness pass unless the user explicitly says
section-only.

## Frontmatter and staleness

Check first, report first.

**Frontmatter:**

- present, parseable, and intact
- `title`, `description`, and class-expected fields make sense
- `related`, `status`, `date` exist when the doc class expects them
- `related` repo paths resolve

**Staleness:**

- status/date don't obviously contradict the body
- the doc doesn't send readers to moved, deleted, or superseded docs
- if a doc predates the canonical doc it points to, only call it stale
  when the newer canon now overrides its claims and the older doc
  doesn't say so
- if a doc is obsolete, it should say what replaced it

For old canonical docs, focus on alignment and cleanup before stylistic
polish.

## Canonical Cortex policy

Apply this aggressively in `canonical` docs.

- Cortex should read as an independent system, not as a subsystem of
  any consumer (Portman or otherwise).
- Downstream products may appear as consumers, integration examples, or
  motivating use cases, but not as the frame through which Cortex is
  defined.
- Prefer stable subsystem names (`Pulse runtime`, `graph layer`,
  `Wire language`, `memory substrate`) over repo-local module and file
  paths.
- Avoid issue IDs, PR references, commit hashes, branch names, live
  repo paths, and transient package/module layout in canonical docs
  unless the document is specifically about migration or repo
  structure.
- If a canonical doc depends on those details, treat it as a real
  content-placement issue, not a nit.

In `internal` docs, issue links, repo paths, and implementation
references are allowed when they improve traceability.

## Content checks

Review with the strictness appropriate to the class.

- scope fit for the doc kind
- content placement: right content in the right doc, especially Cortex
  canon vs. consumer notes vs. historical/internal records
- terminology consistency
- factual claims vs. speculation vs. inferred design intent
- contradictions with sibling docs or the file's own rules
- compactness and scannability
- whether examples actually support the surrounding prose

Compactness serves clarity. Don't cut material if doing so would make
the document harder to understand.

## Normative docs

For specs, reference docs, and architecture chapters that declare rules,
add an explicit example sanity pass.

Check that canonical examples obey:

- precedence and associativity rules
- naming and binding rules
- stated invariants and typing claims
- module, import, and evaluation rules

If the examples and the rules disagree, that's at least a **Major**
finding.

## Format checks

- heading structure and section order
- Mermaid syntax, diagram type choice, labeling, and styling
- math notation, variable naming, display quality
- code fence language tags and whether examples look plausible
- link targets and cross-reference quality

Mermaid standard:

- use the right diagram type for the concept
- avoid anonymous gray-box diagrams when typed structure or styled
  grouping would clarify meaning
- diagrams should be clean enough to survive printing or design review

## Implementation and claim checks

When the review mode or doc class requires grounding, verify against
the code instead of guessing.

For Cortex symbol checks, use targeted searches:

```bash
rg -n "SymbolName|OtherSymbol" src src-platform
```

Mismatches between canonical docs and implementation are findings, but
do not force implementation conformance when the document is clearly a
target-design spec.

## Severity ladder

Use consistently:

- `Blocker` — the doc is structurally broken or architecturally misleading
- `Major` — a real correctness, scope, or canon-placement problem
- `Minor` — clarity, consistency, or polish issue that should be fixed
- `Nit` — optional wording or formatting improvement

## Output

Findings come first. Format:

```
[Major] path:line — Finding. Why it matters. Recommendation.
```

Then, when useful:

- `Open Questions`
- `Summary`

Always include:

- the document classification
- the review mode
- whether frontmatter was intact
- whether the doc appears stale

If no findings remain, say so explicitly and mention any residual risk
or validation gap.
