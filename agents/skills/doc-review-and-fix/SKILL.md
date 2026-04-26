---
name: doc-review-and-fix
description: >
  Review and fix Markdown docs in this repo in one pass. Use when asked
  to review-and-edit architecture/spec/research/publication/blog docs,
  repair frontmatter or staleness, improve Mermaid/math/code blocks,
  tighten claims, or make docs more concise while preserving intent.
date: 2026-04-25
status: active
---

# Document Review and Fix

Edit-first companion to `doc-review`.

Before reviewing, read:

- `../doc-review/SKILL.md`
- `../doc-review/references/writing-standards.md` when canonical-doc
  policy, publication-grade, or reference-grade support matters

Use the same classification, staleness, severity, and output rules as
`doc-review`, but default to making the fixes yourself instead of
stopping at findings.

## Default behavior

Unless the user explicitly asks for review-only output:

1. classify the document
2. check frontmatter and staleness first
3. review the document in the appropriate mode
4. fix the issues that are safe and in scope
5. rerun a short review on the edited result
6. report what changed, what remains, and any unresolved questions

## What to fix directly

Fix directly when intent is clear:

- missing or malformed frontmatter
- stale status, replacement links, and obvious `related` issues
- broken or misleading headings
- verbosity, repetition, weak lead sentences
- misplaced content that can be cleanly moved within the same file
- inconsistent terminology when the canonical term is clear
- canonical docs that frame Cortex as a subsystem of a downstream
  product instead of an independent system
- canonical docs that can be cleanly rewritten from repo-local paths
  and issue references to stable conceptual names
- malformed or weak Mermaid blocks, including diagrams that violate
  the slate cycle composition rules in the doc-review skill (cosmetic
  `classDef`, awkward node counts, oversized labels, flat sprawl past
  eight nodes)
- math notation cleanup when the intended meaning is clear
- code-fence languages, obviously broken examples, canonical example
  drift
- examples that violate the document's own declared rules

## When to pause and report

Don't silently rewrite when the fix depends on an open design choice.

Prefer findings over edits when:

- the document exposes a real architectural fork
- current code and target design intentionally diverge and the desired
  canon is unclear
- fixing the issue would require broad file moves or cross-doc
  reorganization
- claims need external or implementation verification you cannot
  complete in this pass
- multiple plausible rewrites exist and would materially change meaning

In those cases, make the safest local fixes, then report the remaining
design questions explicitly.

## Editing principles

- **Preserve the document's role.** Don't turn a research memo into a
  spec.
- **Be more aggressive in specs and publications than in research notes.**
- **In canonical docs, preserve Cortex-first framing** and strip
  repo-local detail. Cortex is a standalone substrate; don't let
  downstream consumers become the default frame.
- **Keep edits compact.** Prefer deletion, tightening, and
  restructuring over adding more prose.
- **If a paragraph is historically useful but misplaced,** shorten it
  and move it behind a note, appendix, or link.
- **If a canonical example is wrong, fix the example or the rule.**
  Don't leave them inconsistent.

## Validation

After editing:

- rerun a short `doc-review` pass on the final text
- use local docs tooling when renderability matters:

```bash
just docs-build
just docs-dev      # interactive preview
```

Use `docs-build` when diagrams, math, or markdown rendering changed.

## Final output

When this skill is used, the response should usually contain:

1. classification and review mode
2. `Fixed` — a short list of the most important fixes made
3. `Still Open` — findings left open, with severity + file/line refs
4. `Validation` — whether you ran docs-build / docs-dev and why

If no edits were needed, say so explicitly and fall back to a normal
review.

Use those labels literally when they help scanability:

```
Classification: <kind>, <canonical|internal>
Review mode: <mode>

Fixed:
- ...

Still Open:
- [Major] path:line — ...

Validation:
- Ran `just docs-build`; diagrams rendered clean.
```
