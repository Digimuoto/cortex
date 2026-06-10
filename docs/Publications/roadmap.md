---
title: Publications Roadmap
description:
  Publication portfolio and dependency sketch for Cortex papers and companion research plans.
sidebar:
  label: Roadmap
  order: 1
status: active
---

# Publications Roadmap

Plan and state of the current Cortex publication portfolio.

## Paper status

| #   | Title                                                                 | Status         | Role                                                              |
| --- | --------------------------------------------------------------------- | -------------- | ----------------------------------------------------------------- |
| 1   | [Staged reduction](Paper-1-staged-reduction/)                         | Draft          | Lead submission: fixed-topology runtime + algebra (absorbing 2)   |
| 2   | [Algebraic foundations](Paper-2-algebraic-foundations/)               | Superseded     | Merged into Paper 1; directory retained until submission freeze   |
| 3   | [Graph substitution semantics](Paper-3-graph-substitution-semantics/) | Draft          | Dynamic substitution theory; metatheory source for Paper 7        |
| 4   | [Wire language](Paper-4-wire-language/)                               | Draft          | Authoring-layer design narrative; motivation source for Paper 7   |
| 5   | [Causal programming](Paper-5-Causal-Programming/)                     | Draft          | Paradigm umbrella over Papers 1–4; vision-venue / journal target  |
| 6   | [Executable causal diagrams](Paper-6-executable-diagrams/)            | Rewriting      | Short diagrams-workshop paper (rejected at DIALOCO'26; in rework) |
| 7   | [Typed linear frontier calculus](Paper-7-frontier-calculus/)          | Complete draft | Flagship: the Wire calculus on paper, ICFP-tier target            |

## Supporting research plans

| Plan                                                                                             | Status    | Role                                                |
| ------------------------------------------------------------------------------------------------ | --------- | --------------------------------------------------- |
| [Lean mechanization](../Roadmap/Plans/lean-mechanization.md)                                     | Delivered | Machine-checked support for the fixed-topology core |
| [Rewrite materialization and recovery](../Roadmap/Plans/rewrite-materialization-and-recovery.md) | Proposed  | Runtime-grounded rewrite and recovery theory        |

## Dependency sketch

Paper 1 is the lead submission; Paper 5 is the paradigm umbrella; Paper 7 is the planned flagship.

- Paper 1 absorbs Paper 2: the runtime-grounded fixed-topology story gains the algebraic framing,
  the extension-boundary analysis, and a results table citing the delivered Lean mechanization
  (closure laws, recovery safety, classification exhaustiveness are proven, not proof debt).
- Paper 3 extends the theory from fixed topology to compiled artifacts, substitution, and
  lineage-plus-materialization semantics. Its core obligations are now substantially mechanized in
  the Lean rewrite track; the manuscript cites those theorems. Paper 3 remains a draft until Paper 7
  shows how much of its metatheory the flagship absorbs.
- Paper 4 explains the authoring layer: closed authority registration, endpoint-typed composition,
  partial reuse, and bounded proposal authoring. Its design narrative seeds Paper 7's motivation; it
  remains a draft pending the same absorption decision.
- Paper 5 articulates causal programming and temporal honesty as the paradigm the other papers
  instantiate, with Wire/Pulse as the existence proof. Vision venue or journal.
- Paper 6 extracts the diagrammatic-computation story from Wire. The DIALOCO'26 submission was
  rejected for presentation (undefined-before-use vocabulary, informal invariant statement,
  unengaged prior work); the rework defines terms first, formalizes the linearity invariant, and
  states precise deltas against Mokhov's algebra and open-graph composition.
- Paper 7 is the flagship: the keyed frontier calculus stated in standard notation — syntax, typing
  rules, small-step semantics — with metatheory cited to the Lean track and the compiler (enforced
  artifact-to-circuit binding) as the implementation claim. Targets the ICFP tier first; a
  POPL-shaped distillation is deliberately deferred until reviews identify the novel core.
- The rewrite materialization and recovery plan connects Paper 3's substitution theory back to
  runtime recovery and admission policy.

## Working notes

Idea memos and working-stage material that feed the manuscripts live in [Notes/](Notes/). Current
notes:

- **[Notes/frontier-ideas.md](Notes/frontier-ideas.md)** — raw idea bank; items move into specific
  papers and plans as they mature.
- **[Notes/deterministic-multi-rewrite-admission.md](Notes/deterministic-multi-rewrite-admission.md)**
  — current runtime semantics and validation questions for same-wave multi-proposal admission.
- **[Notes/mined-contributions.md](Notes/mined-contributions.md)** — inventory of contributions
  present in the Lean proofs and implementation but not yet claimed by any manuscript, with evidence
  and proposed homes.

## Related

- [index.md](index.md) — publications landing.
- [../Roadmap/Plans/](../Roadmap/Plans/) — companion research plans.
- [../Architecture/03-formalism-stack.md](../Architecture/03-formalism-stack.md) — architecture
  chapter consolidating the papers' claims.
