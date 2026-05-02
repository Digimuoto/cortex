---
title: Cortex Usage Guide
description:
  Practical guide for installing Cortex, writing a first Wire workflow, running Pulse, and deploying
  a consumer-bound runtime.
sidebar:
  label: Usage
  order: 1
---

# Cortex Usage Guide

This chapter is for people who want to use Cortex before they study its architecture.

Cortex has three practical jobs:

1. Write workflow topology in Wire.
2. Bind that topology to registered executors.
3. Run the compiled circuit with Pulse.

You do not need the graph algebra or Lean proof story to start. Those explain why the substrate is
shaped the way it is. This guide starts with the working path and links to the deeper material only
when it matters.

## The Working Model

```text
.wire source
  -> compiled circuit
  -> Pulse task definition
  -> durable run state
  -> events, outputs, checkpoints, and provenance
```

Wire is the authoring language. Pulse is the durable runtime. A host or consumer library provides
the executor registry that gives node bodies their authority.

The stock `cortex-pulse` binary is intentionally a substrate shell with an empty task registry. It
is useful for checking the runtime surface and health behavior. Real deployments usually link Cortex
from a consumer repo and pass a populated registry to `Cortex.Pulse.runPulse`.

## Reading Path

| If you want to...                     | Start with                                                 |
| ------------------------------------- | ---------------------------------------------------------- |
| Build the repo and see the surfaces   | [Quickstart](01-quickstart.md)                             |
| Understand the shape of a Wire file   | [Your first Wire workflow](02-first-wire-workflow.md)      |
| Learn what Pulse needs at runtime     | [Running Pulse](03-running-pulse.md)                       |
| Prepare an operator-facing service    | [Deploying Pulse](04-deploying-pulse.md)                   |
| Embed Cortex in another Haskell repo  | [Integrating from Haskell](05-integrating-from-haskell.md) |
| Diagnose common failures              | [Troubleshooting](06-troubleshooting.md)                   |
| Check proof and correspondence status | [Proof status](../Reference/proof-status.md)               |
| Look up exact syntax or schemas       | [Reference](../Reference/)                                 |
| Understand the design commitments     | [Architecture overview](../Architecture/01-overview.md)    |

## What This First Pass Covers

This Usage chapter is intentionally a light working guide. It deliberately avoids becoming the Wire
book. Writing Wire deserves its own teaching sequence because the language has nodes, ports,
contracts, CorePure expressions, executor authority, configured executor values, signals, and
rewrites. The Usage chapter should teach the shortest operational path; the Wire book should teach
the language properly.

## What Is Proven

Cortex has a machine-checked proof surface for graph safety, fixed-topology Pulse safety, CorePure
evaluation boundaries, node ingress/body/egress normal form, rewrite admission, and selected-branch
actualization. The [proof status](../Reference/proof-status.md) dashboard separates those Lean
claims from Haskell implementation correspondence so you can see which guarantees are closed,
hooked, or still open.

## Related

- [../Reference/](../Reference/) - exact rules and schemas.
- [../Architecture/](../Architecture/) - why the substrate is designed this way.
- [../Consumers/](../Consumers/) - examples of downstream bindings.
