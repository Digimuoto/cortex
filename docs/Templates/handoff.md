---
title: "Handoff: {Topic}"
description: "{One-sentence description of the transition.}"
date: YYYY-MM-DD
from: "{who or which PR/phase}"
to: "{who or which PR/phase}"
status: active   # active | completed | superseded
related:
  - "GitHub #NNN"
---

# Handoff: {Topic}

<!-- Date, from/to, status, and related links live in frontmatter. -->

## Context

<!--
What is the work stream this handoff covers? Where did it start and where
is it now? Two or three sentences.
-->

## State at handoff

<!--
Concrete state of the work at the moment of handoff. Code, tests, docs,
open PRs, ticket status.
-->

- **Code:** `src/Cortex/...` — current state and what branch it's on.
- **PRs:** #{num} {status}, #{num} {status}.
- **Issues:** GitHub #{NNN} ({status}).
- **Docs:** {which docs were updated or left stale}.

## What was decided

<!--
Decisions made during the work. One line each. Link ADRs if applicable.
-->

- ...

## What's open

<!--
Questions, unresolved design choices, known issues. Categorize by
"needs decision," "needs investigation," "needs implementation."
-->

### Needs decision

- ...

### Needs investigation

- ...

### Needs implementation

- ...

## Next actions

<!--
The first two or three things the receiving party should do. Concrete,
sequenced, and scoped to about a day each.
-->

1. ...
2. ...
3. ...

## Pointers

<!--
Where to find the context needed to pick up: key source files, recent PRs,
adjacent research notes, relevant external references.
-->

- `src/Cortex/...`
- PR #{num}
- [../Research-notes/{scope}/...](../Research-notes/{scope}/...)
