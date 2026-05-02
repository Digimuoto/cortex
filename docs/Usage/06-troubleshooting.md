---
title: Troubleshooting
description: First-pass map from common usage symptoms to the right Cortex reference surface.
sidebar:
  label: 06. Troubleshooting
  order: 6
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

- an executor name is not in the registry
- a contract name is not declared or registered
- a required singular input is not connected
- output ports do not match downstream input requirements
- a pure expression references a name outside its scope

Relevant references:

- [Contracts, ports, and matching](../Reference/Wire/contracts-ports-and-matching.md)
- [Executors and alphabet](../Reference/Wire/executors-and-alphabet.md)
- [Configured executors](../Reference/Wire/configured-executors-and-execution-boundary.md)
- [Pure execution](../Reference/Wire/pure-execution.md)

## Pulse Starts But Does No Useful Work

The stock `cortex-pulse` binary has an empty task registry. If the process is healthy but no task
kinds can run, confirm that you are using a consumer binary that passes a populated registry to
`runPulse`.

Also check:

- database connection settings
- `--lease-owner`
- task definition rows
- scheduler polling interval (`--poll-interval`)
- per-task-type concurrency limits

## A Run Is Waiting

Waiting is usually explicit. Check signal state and host delivery:

- [Signals](../Reference/Pulse/signals.md)
- [Host actions](../Reference/Pulse/host-actions.md)
- [Events](../Reference/Pulse/events.md)

## A Run Fails During Resume

Resume failures usually indicate a persisted state or compatibility problem. Check:

- checkpoint envelope version
- graph state consistency
- task definition availability
- executor registry compatibility

Relevant references:

- [Pulse schema](../Reference/Pulse/schema.md)
- [Pulse types](../Reference/Pulse/types.md)
- [Pulse events](../Reference/Pulse/events.md)
