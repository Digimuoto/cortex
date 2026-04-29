# Research Memo: {scope}

**Date:** {date} **Scope:** {what was analyzed} **Branch / PR:** {branch or PR if applicable}
**Layers examined:** {implementation, theory, docs, ADRs, issues, literature — list which} **Layers
skipped:** {layers not read, with reason} **Method:** Cross-source synthesis through the seven
archetype lenses **Confidence profile:** {brief note on evidence quality and uncertainty}

---

## Executive Summary

{2-6 sentences. The single thing the user should pick up if they read no further. Name the biggest
finding, the biggest opportunity, and the residual uncertainty.}

---

## Archetype Synthesis

| Lens     | One-line read                             |
| -------- | ----------------------------------------- |
| Episteme | {what the layered evidence established}   |
| Logos    | {the load-bearing claim structure}        |
| Kritikos | {the sharpest counterexample or drift}    |
| Themis   | {the contract or layer ownership finding} |
| Techne   | {the smallest concrete next step}         |
| Poiesis  | {the most useful alternative framing}     |
| Sophia   | {the priority decision}                   |

---

## Key Findings

### [P1] {Finding title}

**Category:** {Correctness Gap | Missed Abstraction | Layer Leak | ADR Drift | Novel Idea | Design
Tension | Evidence Gap | Extension Risk | Dead End | Terminology Gap} **Status:** {Observed |
Inferred | Speculative} **Confidence:** {High | Medium | Low} **Surfaced by:** {episteme | logos |
kritikos | themis | techne | poiesis | sophia, plus any cross-lens agreement} **Primary evidence:**
{file:line, theorem name, ADR id, issue id, commit, paper §} **Cross-reference:** {the layer pair
the finding emerged from — e.g. "implementation ↔ theory", "ADR 0023 ↔ ADR 0031"}

{Precise description of the finding. Quote or cite. Avoid paraphrase.}

**Why it matters:** {Impact on correctness, extensibility, performance, clarity, scientific
contribution.}

**Next step:** {Concrete artifact: issue draft, ADR amendment, theorem statement, test, prototype,
literature check, parked note. Name the skill that owns the follow-up if any.}

### [P2] {Finding title}

**Category:** {...} **Status:** {...} **Confidence:** {...} **Surfaced by:** {...} **Primary
evidence:** {...} **Cross-reference:** {...}

{Description}

**Why it matters:** {Impact}

**Next step:** {Action}

{Continue P3, P4, … as needed. Default to 5-8 major findings.}

---

## Missed Abstractions

{Compact narrative or table. Each entry names the multiple ad hoc mechanisms and what shared
interface they want.}

| Multiple sites           | Shared shape | Proposed name | Cost of unifying |
| ------------------------ | ------------ | ------------- | ---------------- |
| {site A, site B, site C} | {shape}      | {name}        | {cost}           |

## Evidence Gaps

| Claim   | Source   | Current evidence | Missing evidence | Recommended validation |
| ------- | -------- | ---------------- | ---------------- | ---------------------- |
| {claim} | {source} | {evidence}       | {gap}            | {validation}           |

## Design Tensions

{Two legitimate goals pulling against each other. Analyze the real trade-off rather than picking a
winner.}

## Novel Ideas & Hypotheses

{Speculative ideas that earn a place because the synthesis surfaced them. Each one has a validation
path.}

- **{Idea}** — {one-paragraph description}. **Validation path:** {test, theorem, prototype,
  literature check}.

## Dead Ends / Rejected Directions

{Useful things that look elegant but do not survive. Recording them prevents re-treading.}

- **{Direction}** — {why it fails}.

---

## Recommended Actions

### Act now

- [ ] {Action} — owner: {skill or person}; cost: {S/M/L}.

### Design next

- [ ] {Action} — typically an ADR draft, theorem slice, or implementation sketch.

### Write up

- [ ] {Action} — paper section, blog post, ADR that captures insight already implicit in the work.

### Parked

- {Idea} — {why deferred}; revisit when {condition}.

---

## Optional Sections

### Known Unknowns

{What could not be checked, why, and what it would take to settle.}

### Claim-to-Evidence Matrix

| Claim   | Artifact that supports it | Artifact that weakens it | Verdict   |
| ------- | ------------------------- | ------------------------ | --------- |
| {claim} | {support}                 | {weakener}               | {verdict} |

### Cortex layer placement check

| Concept   | Currently lives in                       | Should live in | Reason                          |
| --------- | ---------------------------------------- | -------------- | ------------------------------- |
| {concept} | {Platform / Cortex / Logos / downstream} | {target layer} | {ADR, layer rule, or invariant} |

### ADR conformance check

| ADR    | Status                             | Implementation | Theory    | Docs      | Drift?              |
| ------ | ---------------------------------- | -------------- | --------- | --------- | ------------------- |
| {NNNN} | {accepted / proposed / superseded} | {summary}      | {summary} | {summary} | {yes/no, with note} |
