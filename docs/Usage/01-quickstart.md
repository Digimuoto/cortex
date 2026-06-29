---
title: Quickstart
description: Build Cortex, inspect the CLIs, run the first local Wire example, and choose a path.
sidebar:
  label: 01. Quickstart
  order: 1
---

# Quickstart

This page gets you from a checkout to the main Cortex surfaces. It does not assume you know the
architecture yet.

## Prerequisites

Cortex builds through Nix. Use the repository `just` commands rather than calling Cabal or GHC
directly.

```bash
just --list
```

The common development checks are:

```bash
just build
just build-pulse
just build-wire
just test
just docs-check
```

## Build The Library And CLIs

```bash
just build
just build-wire
just build-pulse
```

`just build` builds the Cortex Haskell library: Algebra, Wire, Pulse, and Capability.
`just build-wire` builds the local Wire CLI. `just build-pulse` builds the durable Pulse service
shell.

## Inspect The Commands

```bash
./result/bin/cortex-pulse --help
nix run .#wire -- --help
```

`cortex-pulse` is the durable runtime shell. It starts with an empty task registry because Cortex
does not ship downstream tasks, model providers, or host tools. `wire` is the source-language CLI
for local compile/build/run workflows.

## Run A Workflow Locally

You do not need Postgres, a task registry, or a deployment to run a small Wire program. Build the
`wire` CLI and run a ready-made example in-process:

```bash
nix run .#wire -- run examples/wire/pure-stdlib-report.wire
```

This is the local, non-durable run path: it compiles the `.wire` source and runs the compiled
circuit once in this process. It is enough for first-run examples whose headers use `wire run ...`
or the repo-local `nix run .#wire -- run ...` form, and whose leaves are CorePure plus standard
`std.io` effects. See [First local Wire run](03-first-local-wire-run.md) for how to read what each
example needs.

The example prints a Markdown report and writes the same report to `./wire-stdlib-report.md`.

## When You Need More Than The Local Runner

Local `wire run` keeps nothing: it runs a circuit once and exits. For a durable run - persistence,
resume, signal waits, and leases — a consumer binary must provide:

- a task registry
- a Postgres database
- secret files for runner tokens and service credentials
- task definitions or compiled circuits inserted through the host integration path

Postgres is required for that durable path, not for local `wire run`. The rest of this Usage chapter
sketches those pieces in order.

## Next Step

If you are trying to choose a runtime, read [Execution modes](02-execution-modes.md).

If you are trying to author workflows, read [Writing Wire workflows](04-writing-wire-workflows.md).

If you are trying to operate the runtime, read [Running durable Pulse](08-running-durable-pulse.md).
