---
title: "Paper 7 — Keyed Frontier Calculus"
description:
  Landing page for the flagship frontier-calculus paper. Abstract, status, structure, and related
  material.
sidebar:
  label: Paper 7
  order: 7
status: draft
date: 2026-06-10
updated: 2026-06-10
related:
  - docs/Publications/glossary.md
  - docs/Publications/Paper-3-graph-substitution-semantics/
  - docs/Publications/Paper-4-wire-language/
  - docs/Publications/Paper-6-executable-diagrams/
  - docs/Reference/proof-status.md
  - theory/Cortex/Wire/PortLinearity.lean
  - theory/Cortex/Wire/GeneratedForms.lean
  - theory/Cortex/Wire/SelectAdmission.lean
---

# Paper 7 — Keyed Frontier Calculus

The flagship paper: the Wire calculus stated on paper in standard notation — keyed connect with
carried frontiers, certified elaborations, and the single admitted referent — with metatheory cited
to the Lean mechanization and the compiler (with enforced artifact-to-circuit binding) as the
implementation claim. Port linearity is presented as inherited lineage (interaction nets), not as
the contribution.

## Status

Complete draft, pre-submission: all sections drafted, four Mermaid figure sources checked in;
typeset export and figure exports happen at submission freeze. Target: ICFP-tier venue (deadline
~Feb-Mar 2027); a POPL-shaped distillation is deliberately deferred until reviews identify the novel
core.

## Structure

1. Motivation (compressed from Paper 4: closed alphabets, open composition, registered authority).
2. Definitions (shared-glossary-consistent, Paper 3 glossary-first template).
3. **The calculus** — worked example first, then syntax, frontier typing (the judgment produces the
   diagram, edges included), port linearity, forgetful lowering, and the latent/actualized layer.
   The genuinely new on-paper work. Dynamics are deliberately NOT part of the core calculus.
4. Metatheory — theorems stated in the paper's notation, discharged by citation to the Lean track,
   including the boundary resource algebra (one-slot epochs) and the five-dimensional graded
   budgets.
5. Executing admitted diagrams (application section) — staged reduction + admitted substitution
   imported from Papers 1 and 3; the certifying admission boundary (mirrored contracts + structural
   binding check); Wire CLI, examples, the quantum-eraser demonstration.
6. Related work with theorem-level deltas (Mokhov, cospans, string diagrams, linear logic, graded
   types, session types, certifying compilation, durable execution).

## Related

- [manuscript.md](manuscript.md) — the draft.
- [Figures/index.md](Figures/index.md) — figure inventory.
- [../Paper-3-graph-substitution-semantics/](../Paper-3-graph-substitution-semantics/) — metatheory
  source (absorption decision pending).
- [../Paper-4-wire-language/](../Paper-4-wire-language/) — motivation source (absorption decision
  pending).
- [../../Reference/proof-status.md](../../Reference/proof-status.md) — verification ground truth.
