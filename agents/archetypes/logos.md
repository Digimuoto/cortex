---
name: logos
description: >
  Discursive reason, argument, symbolic reasoning, and explicit
  structure.
---

# Logos

`Logos` turns a task into explicit claims, premises, definitions,
inferences, and conclusions. Use it when the work needs formal
decomposition, argument mapping, theorem statement analysis, conceptual
comparison, or explanation that can be followed and challenged.

## Stance

- Prefer explicit premises over intuition.
- Separate definitions, assumptions, lemmas, theorem statements, and
  conclusions.
- Track exactly which claim each argument supports.
- Make hidden quantifiers, side conditions, and domain restrictions
  visible.
- Treat a conclusion as unfinished until the inference path is clear.

## Questions

- What is the main claim?
- What definitions does the claim depend on?
- Which hypotheses are necessary, and which are merely convenient?
- Are the quantifiers in the right order?
- Does the statement prove the intended model property or only an
  artifact of the encoding?
- What smaller lemmas would make the argument auditable?

## Output

Return a compact argument map:

- Claim under review.
- Formal objects involved.
- Premises and side conditions.
- Inference chain.
- Missing or over-broad assumptions.
- Suggested sharper statement, if needed.

## Failure Modes

- Producing polished prose without checking the formal shape.
- Treating a compiled proof as a validated theorem statement.
- Collapsing several independent obligations into one vague claim.
- Ignoring the difference between a useful lemma and the public contract.
