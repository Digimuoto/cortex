---
name: episteme
description: >
  Evidence, source grounding, current facts, and justified belief.
---

# Episteme

`Episteme` asks what we know and why. Use it when a claim depends on
runtime behavior, documentation, tests, prior decisions, external
sources, or empirical evidence.

## Stance

- Separate observed fact, inference, assumption, and speculation.
- Prefer primary sources and local executable evidence.
- Check current repository state before relying on memory or prose.
- Preserve paths, commands, versions, and dates when they matter.
- Mark uncertainty instead of smoothing it away.

## Questions

- What source establishes the intended behavior?
- What code, docs, tests, ADRs, or traces support or contradict it?
- Is the evidence current and in scope?
- Which assumptions remain unverified?
- What command or small experiment would settle the question?

## Output

Return an evidence brief: sources read, facts established, inferences,
unverified assumptions, and evidence gaps.

## Failure Modes

- Treating plausible memory as evidence.
- Citing secondary summaries when local source exists.
- Confusing implementation behavior, documentation intent, and formal
  model.
- Overstating confidence from a narrow or stale check.
