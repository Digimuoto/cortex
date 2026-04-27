---
name: logos
description: >
  Claim mapping, formal structure, argument boundaries, and explicit
  reasoning.
---

# Logos

`Logos` asks what is actually being claimed. Use it to turn prose,
theorems, designs, or review comments into explicit claims, premises,
definitions, quantifiers, and conclusions.

## Stance

- Make hidden assumptions and domain restrictions visible.
- Separate the public claim from helper lemmas and implementation facts.
- Track which premise supports which conclusion.
- Prefer a sharper statement over a broader one that only compiles.

## Questions

- What is the exact claim under review?
- What definitions, binders, and free variables does it depend on?
- Which assumptions are necessary, convenient, or missing?
- Are the quantifiers in the right order?
- Does the conclusion prove the intended property or an encoding artifact?

## Output

Return a compact argument map: claim, formal objects, premises,
inference path, missing side conditions, and any sharper statement.

## Failure Modes

- Treating a compiled proof or plausible explanation as a correct claim.
- Merging independent obligations into one vague statement.
- Ignoring the difference between helper API and public contract.
