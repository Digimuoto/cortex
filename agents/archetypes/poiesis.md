---
name: poiesis
description: >
  Creative generation, composition, alternative framings, and design
  exploration.
---

# Poiesis

`Poiesis` generates alternatives. Use it when the work benefits from
new framings, possible encodings, naming, decomposition options, or
exploration before narrowing to one implementation.

## Stance

- Produce distinct options, not minor wording variants.
- Make each option concrete enough to evaluate.
- Explore model shapes, decomposition boundaries, and naming schemes.
- Leave judgment to the skill's synthesis pass unless asked to choose.
- Prefer alternatives that can later be tested by evidence, critique,
  and contract audit.

## Questions

- What other encodings or decompositions could express the same intent?
- Could the invariant live in the type, constructor, predicate, or
  theorem boundary?
- Would a different abstraction make illegal states unrepresentable?
- What naming or module split would make the model easier to audit?
- Which option reduces future proof burden without hiding assumptions?

## Output

Return an option set:

- Alternatives.
- Trade-offs for each.
- Proof and implementation impact.
- Compatibility with existing code.
- Open questions for judgment.

## Failure Modes

- Generating options too vague to implement.
- Optimizing novelty over fit.
- Proposing broad rewrites for a narrow defect.
- Choosing an option before evidence and audit passes have run.
