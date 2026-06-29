---
title: Troubleshooting
description: Route common Wire, local runner, and durable Pulse symptoms to the right checks.
sidebar:
  label: 11. Troubleshooting
  order: 11
---

# Troubleshooting

This page maps common symptoms to the part of Cortex that owns the answer.

## The Wire File Does Not Parse

Check the exact grammar first:

- [Wire grammar](../Reference/Wire/grammar.md)
- [Modules, imports, and file returns](../Reference/Wire/modules-imports-and-file-returns.md)

The parser error should tell you where syntax stopped matching. If the source parses but does not
compile, move to the next section.

## The Wire File Parses But Does Not Compile

Common causes:

- an executor name is not in scope or not in the registry;
- a package manifest is missing for an extension namespace;
- a contract name is not declared or registered;
- a required singular input is not connected;
- output ports do not match downstream input requirements;
- a pure expression references a name outside its scope.

Relevant references:

- [Package manifests and extensions](06-package-manifests-and-extensions.md)
- [Contracts, ports, and matching](../Reference/Wire/contracts-ports-and-matching.md)
- [Executors and alphabet](../Reference/Wire/executors-and-alphabet.md)
- [Configured executors](../Reference/Wire/configured-executors-and-execution-boundary.md)
- [Pure execution](../Reference/Wire/pure-execution.md)

## `wire run` Rejects The Graph

Local `wire run` is deliberately smaller than durable Pulse. It runs CorePure nodes and standard
`std.io` leaves, but it does not run configured consumer executors, durable signal waits, service
state, leases, or generated durable-only nodes.

If the graph needs consumer authority, run it through a consumer runtime. If the graph needs durable
state, use [Running durable Pulse](08-running-durable-pulse.md).

## `wire run` Did Not Persist, Resume, Or Signal

This is a mode mismatch, not a failure. Local `wire run` compiles a circuit and runs it once in this
process. It does not write checkpoints, wait on durable signals, take leases, or expose resumable
run state. Those are durable Pulse semantics, and Pulse keeps them in Postgres.

## Pulse Starts But Does No Useful Work

The stock `cortex-pulse` binary has an empty task registry. If the process is healthy but no task
kinds can run, confirm that you are using a consumer binary that passes a populated registry to
`runPulse`.

Also check:

- database connection settings;
- schema provisioning or migrations;
- `--lease-owner`;
- task definition rows;
- scheduler polling interval (`--poll-interval`);
- per-task-type concurrency limits.

## Pulse Reports Missing Schema Or Objects

For a new database, run the consumer-owned provisioning path before execution. For an existing
database, apply the forward migrations from `migrations/` and then validate the current schema
shape. `provisionPulseSchema` is not a general migration runner for deployed stale schemas.

## A Run Is Waiting

Waiting is usually explicit. Check signal state and host delivery:

- [Signals](../Reference/Pulse/signals.md)
- [Host actions](../Reference/Pulse/host-actions.md)
- [Events](../Reference/Pulse/events.md)

## A Run Fails During Resume

Resume failures usually indicate a persisted state or compatibility problem. Check:

- checkpoint envelope version;
- graph state consistency;
- task definition availability;
- executor registry compatibility;
- whether the run is already terminal or live-running under another owner.

Relevant references:

- [Operating Pulse](10-operating-pulse.md)
- [Pulse schema](../Reference/Pulse/schema.md)
- [Pulse types](../Reference/Pulse/types.md)
- [Pulse events](../Reference/Pulse/events.md)
