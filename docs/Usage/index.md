---
title: Cortex Usage Guide
description:
  Practical guide for building Cortex, running Wire locally, embedding Cortex, and operating durable
  Pulse.
sidebar:
  label: Usage
  order: 1
---

# Cortex Usage Guide

This chapter is for people who want to use Cortex before they study its architecture. It is a task
guide: commands, decision points, expected observations, and links to the exact reference surface
when a rule matters.

Cortex has three practical jobs:

1. Write workflow topology in Wire.
2. Bind that topology to registered executors.
3. Run the compiled circuit with Pulse.

You do not need the graph algebra or Lean proof story to start. Those explain why the substrate is
shaped the way it is. Usage starts with the working path and routes deeper questions to
[Architecture](../Architecture/) and [Reference](../Reference/).

## The Working Model

You author topology in Wire, then run the compiled circuit one of two ways:

```text
.wire source
  -> compiled circuit
       -> local run with `wire run`   (in-process, non-durable)
       -> durable Pulse run           (Postgres: checkpoints, resume, signals, provenance)
```

Wire is the authoring language. Pulse is the durable runtime. A host or consumer library provides
the registry that gives executor nodes their authority. The right execution mode depends on whether
you need only a local one-shot run or durable state in Postgres.

## Reading Path

| Page                                                                       | Start here when you want to...                                            |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| [Quickstart](01-quickstart.md)                                             | Build the repo, inspect the CLIs, and run the first command.              |
| [Execution modes](02-execution-modes.md)                                   | Choose local `wire run`, managed Pulse, or durable Pulse service.         |
| [First local Wire run](03-first-local-wire-run.md)                         | Run the report example and check the produced output.                     |
| [Writing Wire workflows](04-writing-wire-workflows.md)                     | Learn the practical source shape before using the grammar reference.      |
| [Running Wire examples](05-running-wire-examples.md)                       | Pick an example by prerequisites, side effects, and runtime mode.         |
| [Package manifests and extensions](06-package-manifests-and-extensions.md) | Load non-standard Wire namespaces such as quantum packages.               |
| [Integrating from Haskell](07-integrating-from-haskell.md)                 | Compile Wire with strict registries and embed managed or service Pulse.   |
| [Running durable Pulse](08-running-durable-pulse.md)                       | Start the Postgres-backed runtime path and understand its inputs.         |
| [Deploying Pulse](09-deploying-pulse.md)                                   | Prepare a consumer-bound runtime for production.                          |
| [Operating Pulse](10-operating-pulse.md)                                   | Diagnose live runs, leases, signals, events, schema state, and retention. |
| [Troubleshooting](11-troubleshooting.md)                                   | Route common symptoms to the right check or reference page.               |

## What Belongs Here

Usage pages should lead with runnable commands, concrete outcomes, and operational choices. They may
summarize rules, but exact language syntax belongs in [Wire reference](../Reference/Wire/) and exact
runtime semantics belong in [Pulse reference](../Reference/Pulse/).

## Related

- [Architecture overview](../Architecture/01-overview.md) - why the substrate is designed this way.
- [Wire reference](../Reference/Wire/) - exact language rules.
- [Pulse reference](../Reference/Pulse/) - exact runtime rules.
- [Proof status](../Reference/proof-status.md) - proof and implementation-correspondence status.
- [Consumers](../Consumers/) - downstream binding examples.
