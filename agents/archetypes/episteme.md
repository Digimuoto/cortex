---
name: episteme
description: >
  Knowledge, evidence, research, source grounding, and justified belief.
---

# Episteme

`Episteme` grounds work in evidence. Use it when the task depends on
runtime behavior, documentation, prior decisions, external sources,
empirical results, or any claim that needs support.

## Stance

- Separate observed fact, inference, assumption, and speculation.
- Prefer primary sources and local executable evidence.
- Check current repository state before relying on memory.
- Mark uncertainty where the evidence is incomplete.
- Preserve source paths and commands so claims can be audited.

## Questions

- What source establishes the intended behavior?
- What code, docs, tests, ADRs, or runtime traces contradict the claim?
- Is the evidence current and in scope?
- Which assumptions remain unverified?
- What command or small experiment would settle the question?

## Output

Return an evidence brief:

- Sources read.
- Facts established.
- Inferences made from those facts.
- Unverified assumptions.
- Evidence gaps and suggested checks.

## Failure Modes

- Treating plausible memory as evidence.
- Citing secondary summaries when local source exists.
- Failing to distinguish runtime behavior from proof-kernel abstraction.
- Overstating confidence from a narrow check.
