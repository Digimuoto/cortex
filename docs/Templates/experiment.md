---
title: "Experiment: {Topic}"
description: "{One-sentence description of the controlled run.}"
date: YYYY-MM-DD
scope: "{wire | runtime | foundation | applications}"
status: complete   # complete | ongoing | abandoned
related:
  - "Roadmap epic or plan path"
  - "GitHub #NNN"
---

# Experiment: {Topic}

<!-- Date, scope, status, and related links live in frontmatter. -->

**Type:** {controlled smoke test | dogfood run | exploratory trial | benchmark}

## Owning Epic

<!--
Name the active roadmap epic or plan that authorizes this experiment. Do not
start standalone experiment logs without a current coordination surface.
-->

- Epic or plan: [../../Roadmap/Epics/{epic}.md](../../Roadmap/Epics/{epic}.md)

## Hypothesis

<!--
What question did we set out to answer? What did we expect to find?
-->

## Setup

<!--
Environment, inputs, tools, configuration. Enough detail that the experiment
could be rerun from the current state.
-->

- System state: current `main` or named branch at commit `{sha}`.
- Configuration: ...
- Inputs: ...

## Method

<!--
What was actually done. A numbered or bulleted sequence.
-->

1. ...
2. ...

## Results

<!--
What happened. Quantitative where possible, qualitative where not. Include
runtime observations, error messages, unexpected behavior.
-->

## Interpretation

<!--
What the results mean. Did they confirm, reject, or complicate the
hypothesis? What new questions arose?
-->

## Lessons

<!--
What we took away that should influence future work. Keep concrete.
-->

## Follow-ups

<!--
What to do next: further experiments, design decisions, bug fixes, research
memos to write.
-->

- ...

## Related

- GitHub #{issue}
- [../../Research-notes/{scope}/...](../../Research-notes/{scope}/...)
