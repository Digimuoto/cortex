---
title: "Plan — {Plan title}"
description: "{One-sentence description of the plan.}"
sidebar:
  label: "{Short label}"
  order: N
status: proposed   # proposed | active | completed | abandoned
related:
  - docs/Architecture/...
  - docs/Reference/...
---

# Plan — {Plan title}

## Goal

<!--
What does the work deliver? One paragraph. Testable.
-->

## Context

<!--
What is the current state of the relevant subsystem? What pressure or
observation motivates this plan now?
-->

## Approach

<!--
The chosen approach in one or two paragraphs. Enough that a reviewer can
understand the shape before diving into steps.
-->

## Steps

<!--
Ordered, specific, mergeable slices. Each step names the files touched and
the acceptance check.
-->

1. **{Step name}** — files: `src/Cortex/...`. Check: {test, build, property}.
2. **{Step name}** — ...

## Verification

<!--
How we know the plan's goal was met. Tests run, manual checks, runtime
observations.
-->

- ...

## Risks

<!--
What might not work and how it would be detected.
-->

- ...

## Related

- `docs/Architecture/...`
- `docs/Reference/...`
- `docs/Roadmap/Epics/{epic}.md` when there is a retained parent epic.
