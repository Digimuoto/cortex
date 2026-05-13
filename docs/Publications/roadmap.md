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

| #   | Title                                                                 | Status | Role                                               |
| --- | --------------------------------------------------------------------- | ------ | -------------------------------------------------- |
| 1   | [Staged reduction](Paper-1-staged-reduction/)                         | Draft  | Runtime-grounded fixed-topology paper              |
| 2   | [Algebraic foundations](Paper-2-algebraic-foundations/)               | Draft  | Core fixed-topology theory                         |
| 3   | [Graph substitution semantics](Paper-3-graph-substitution-semantics/) | Draft  | Dynamic substitution theory                        |
| 4   | [Wire language](Paper-4-wire-language/)                               | Draft  | Authoring language and authority-composition paper |
| 6   | [Executable causal diagrams](Paper-6-executable-diagrams/)            | Draft  | Short artifact paper on executable causal diagrams |

## Supporting research plans

| Plan                                                                                             | Status   | Role                                                |
| ------------------------------------------------------------------------------------------------ | -------- | --------------------------------------------------- |
| [Lean mechanization](../Roadmap/Plans/lean-mechanization.md)                                     | Proposed | Machine-checked support for the fixed-topology core |
| [Rewrite materialization and recovery](../Roadmap/Plans/rewrite-materialization-and-recovery.md) | Proposed | Runtime-grounded rewrite and recovery theory        |

## Dependency sketch

Paper 2 is the keystone paper.

- Paper 1 sharpens the fixed-topology runtime story and narrows the structural-safety claim to what
  the runtime actually needs.
- The Lean mechanization plan supports Papers 1 and 2 with machine-checked closure and recovery
  obligations.
- Paper 3 extends the theory from fixed topology to compiled artifacts, substitution, and
  lineage-plus-materialization semantics.
- Paper 4 explains the authoring layer above that substrate: closed authority registration,
  endpoint-typed composition, partial reuse, and bounded proposal authoring.
- Paper 6 extracts the diagrammatic-computation story from Wire: source causal diagrams, typed
  linear frontiers, circuit lowering, durable replay, and proof-facing accepted objects.
- The rewrite materialization and recovery plan connects Paper 3's substitution theory back to
  runtime recovery and admission policy.

## Working notes

Idea memos and working-stage material that feed the manuscripts live in [Notes/](Notes/). Current
notes:

- **[Notes/frontier-ideas.md](Notes/frontier-ideas.md)** — raw idea bank; items move into specific
  papers and plans as they mature.
- **[Notes/deterministic-multi-rewrite-admission.md](Notes/deterministic-multi-rewrite-admission.md)**
  — current runtime semantics and validation questions for same-wave multi-proposal admission.

## Related

- [index.md](index.md) — publications landing.
- [../Roadmap/Plans/](../Roadmap/Plans/) — companion research plans.
- [../Architecture/03-formalism-stack.md](../Architecture/03-formalism-stack.md) — architecture
  chapter consolidating the papers' claims.
