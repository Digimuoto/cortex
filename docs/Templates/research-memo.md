---
title: "Research Memo: {Topic}"
description: "{One-sentence description of the memo's scope.}"
date: YYYY-MM-DD
scope: "{foundation | runtime | wire | applications}"
status: active   # active | superseded | archived
related:
  - "GitHub #NNN"
  - docs/Research-notes/{scope}/...
---

# Research Memo: {Topic}

<!-- Date, scope, status, and related links live in frontmatter. -->

**Method:** {cross-source synthesis | implementation reading | external literature review | combined}
**Confidence profile:** {high on X; medium on Y; low on Z}

---

## Context

<!--
What prompted this memo? What do we already know; what are we trying to
clarify, validate, or synthesize?
-->

## Method

<!--
What sources were examined, what was read or grepped, what external
references were consulted. A reader should be able to reproduce the
investigation path.
-->

**Artifacts examined:**

- `src/Cortex/...`
- `docs/...`
- GitHub #NNN, GitHub #MMM
- external: {papers, specs, standards}

## Findings

<!--
Bullet or numbered findings. Separate observed facts from inferred
conclusions. Flag speculation explicitly.
-->

### Finding 1 — {Title}

**Primary evidence:** `src/Cortex/...:L:L`, GitHub #NNN, `docs/...`.

<!--
Two or three sentences stating what was found and what it implies.
-->

### Finding 2 — {Title}

...

## Open questions

<!--
What the memo does not answer. Questions that would require additional
investigation or a design decision.
-->

- ...

## Recommendations

<!--
What should happen next, if anything. Concrete actions, owner suggestions,
deadlines when known. Keep aspirational claims separate from concrete
recommendations.
-->

## Related

<!--
Other research notes, ADRs, epics, or architecture chapters this memo
informs or depends on.
-->
