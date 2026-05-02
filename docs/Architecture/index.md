---
title: Cortex Architecture
description:
  Canonical architecture chapters for Cortex. Read top-to-bottom for the full story, or follow the
  evaluator path for a fast first pass.
sidebar:
  label: Architecture
  order: 1
---

# Cortex Architecture

Canonical explanation chapters. Enumerated `NN-` for reading order. Each chapter explains how the
system fits together at its layer and what its design commitments are.

If you are trying to build, run, or deploy Cortex before reading the design story, start with
[Usage/](../Usage/) instead.

## Reading paths

If you are evaluating Cortex as a system to adopt or build on, start here:

1. [01-overview.md](01-overview.md)
2. [05-wire-language.md](05-wire-language.md)
3. [06-pulse-runtime.md](06-pulse-runtime.md)
4. [07-rewrites-and-materialization.md](07-rewrites-and-materialization.md)
5. [08-artifacts-and-provenance.md](08-artifacts-and-provenance.md)

Then read these for the deeper rationale and host-boundary contract:

1. [02-ownership-and-boundaries.md](02-ownership-and-boundaries.md)
2. [03-formalism-stack.md](03-formalism-stack.md)

| #   | Chapter                                                            | Topic                                                                                                       |
| --- | ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------- |
| 01  | [Overview](01-overview.md)                                         | Three-layer model, ownership boundary, what Cortex owns.                                                    |
| 02  | [Ownership and boundaries](02-ownership-and-boundaries.md)         | Substrate/host boundary, dependency direction, and what stays downstream.                                   |
| 03  | [Algebraic foundations](03-formalism-stack.md)                     | Why the topology model is algebraic and why rewrites can stay law-preserving.                               |
| 04  | [Graph and Circuit](04-graph-and-circuit.md)                       | Pure topology vs validated executable topology.                                                             |
| 05  | [Wire language](05-wire-language.md)                               | Source-language architecture: registered authority, boundary typing, configured executors, runtime handoff. |
| 06  | [Pulse runtime](06-pulse-runtime.md)                               | Durable execution service, service boundary, task types, checkpoints.                                       |
| 07  | [Rewrites and materialization](07-rewrites-and-materialization.md) | Bounded dynamic graph evolution, gas, admission policy.                                                     |
| 08  | [Artifacts and provenance](08-artifacts-and-provenance.md)         | Runtime outputs, contract envelopes, provenance chains.                                                     |

Normative grammar details (operators, port signatures, type-checking) live in
[Reference/Wire/](../Reference/Wire/), not here. Chapters point into references where precision is
needed.

## Related

- [../Reference/](../Reference/) — normative specs.
- [../Usage/](../Usage/) — practical guide for building, running, and deploying.
- [../ADRs/](../ADRs/) — decision records.
- [../Consumers/Logos/](../Consumers/Logos/) — downstream reasoning-library docs built on Cortex.
- [../Roadmap/](../Roadmap/) — active engineering work.
