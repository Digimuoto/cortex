---
title: "Experiment: {Topic}"
description: "{One-sentence description of what was tried.}"
date: YYYY-MM-DD
scope: "{wire | runtime | foundation | applications}"
status: complete   # complete | ongoing | abandoned
related:
  - "GitHub #NNN"
---

# Experiment: {Topic}

**Date:** YYYY-MM-DD
**Type:** {smoke test | dogfood | exploratory trial | benchmark}

## Hypothesis

<!--
What question did we set out to answer? What did we expect to find?
-->

## Setup

<!--
Environment, inputs, tools, configuration. Enough detail that the experiment
could be rerun.
-->

- System state: `src/Cortex/...` at commit `{sha}`.
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
