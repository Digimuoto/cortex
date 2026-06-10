---
title: Publications Glossary
description:
  Canonical one-line definitions for terms shared across Cortex publication manuscripts. Each
  paper's local glossary must be a consistent subset of this page.
sidebar:
  label: Glossary
  order: 2
status: active
date: 2026-06-10
related:
  - docs/Publications/index.md
  - docs/glossary.md
  - docs/Architecture/03-formalism-stack.md
---

# Publications Glossary

Canonical definitions for the load-bearing vocabulary the papers share. The DIALOCO'26 review of
Paper 6 demonstrated the cost of using these terms before defining them; every manuscript defines
the subset it uses, in wording consistent with this page, before first substantive use.

## Graph and frontier vocabulary

- **frontier**: the multiset of typed port instances exposed on the boundary of a graph expression —
  the ports not yet consumed by composition. Composition operators are read as frontier
  transformers.
- **port instance**: one occurrence of a typed, direction-tagged endpoint (node, port name,
  contract, optional label) owned by a node.
- **carried endpoint**: a frontier endpoint that crosses a composition unmatched and remains on the
  result's frontier, acting as an open-boundary identity wire.
- **port linearity** (also "node-boundary linearity"; Lean: `PortLinear`): every owned port instance
  is either consumed by exactly one internal edge or exposed on the frontier with multiplicity one —
  never both, never duplicated. There is no ambient copying or contraction.
- **latent**: declared and admitted but not yet instantiated in the running circuit — select arm
  bodies before selection, generated-form templates before expansion.
- **actualized**: instantiated as a port/node of the running circuit; the actualized layer carries
  its own closed linearity discipline (Lean: `ClosedPortLinear`).
- **overlay (`<>`)**: union of fragments with disjoint node sets; frontiers union.
- **connect (`=>`)**: port-key-matched composition — an edge forms between a left output and a right
  input only when their `(contract, label)` match keys agree uniquely; direction is enforced by
  matching outputs against inputs, and unmatched endpoints are carried. Deliberately not Mokhov's
  cross-product connect.
- **phantom adapter**: the generated node that the `*` operator elaborates to, crossing one product
  constructor between a singular record/indexed port and its distinct leaf endpoints, without
  introducing a copying rule.
- **generated form**: nodes produced by compile-time bounded generation (`make`, `makeEach`),
  certified against the source expression that generated them.

## Admission and artifact vocabulary

- **admitted**: accepted by the relevant admission check (graph admission, select admission, rewrite
  admission); admitted objects are the ones theorems quantify over.
- **single admitted referent**: the discipline that source typing, the compiler's executable
  artifact, the runtime's replay and provenance, and proof-facing validation all refer to one
  admitted diagram, with the correspondence compiler-enforced by the binding check.
- **compiled circuit / compiled workflow artifact**: the executable result of lowering source into a
  graph package — topology, node definitions, typed interfaces, compatibility witness.
- **admission artifact**: the proof-shaped evidence record the compiler attaches to a compiled
  circuit, validated for internal consistency and bound to the circuit it travels with.
- **compatibility witness**: a fingerprint or derivation witness tying a compiled artifact to the
  semantics that produced it; in the substitution-semantics paper's notation
  $\kappa = (\nu, \lambda, h)$ — lowering family, contract/interface regime, and digest of the
  normalized source under both.

## Execution vocabulary

- **Pulse**: the durable runtime that schedules, journals, and replays execution over the admitted
  graph.
- **CorePure**: the deterministic pure sublanguage that shapes payloads; effects stay behind
  registered executors.
- **materialized run state**: the currently executable graph and node/output state obtained by
  applying a lineage prefix to an original compiled artifact.
- **lineage**: append-only history of admitted substitutions.
- **materialization**: durable installation of admitted substitutions into the graph state.
- **replay**: deterministic re-execution over the journaled durable prefix; fixed recorded outcomes
  are reused rather than re-observed.
- **provenance**: the recorded derivation of a value or topology change, referring back to the
  admitted diagram.
- **substitution**: splicing a fragment into a graph through an explicit boundary contract.
- **fragment**: a graph package intended to be substituted into another graph.

## Sources

Wording is aligned with the Paper 3 glossary (substitution vocabulary), the architecture chapters
([../Architecture/03-formalism-stack.md](../Architecture/03-formalism-stack.md),
[../Architecture/05-wire-language.md](../Architecture/05-wire-language.md)), and the Lean
definitions cited by [../Reference/proof-status.md](../Reference/proof-status.md) (`PortLinear`,
admission artifact contracts).
