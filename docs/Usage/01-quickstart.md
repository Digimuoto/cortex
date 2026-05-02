---
title: Quickstart
description: Build Cortex, inspect the Pulse executable, and find the next working step.
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
just test
just docs-check
```

## Build The Library

```bash
just build
```

This builds the Cortex Haskell library: Algebra, Wire, Pulse, and Capability.

## Build The Pulse Binary

```bash
just build-pulse
```

The `cortex-pulse` executable is the substrate runtime shell. It starts Pulse with an empty task
registry. That is intentional: Cortex does not ship downstream tasks, model providers, or host
tools.

Inspect its runtime options:

```bash
./result/bin/cortex-pulse --help
```

`nix run .#cortex-pulse -- --help` also works and rebuilds the flake output if needed.

## Understand The Boundary

For a useful run, a consumer binary must provide:

- a task registry
- a Postgres database
- secret files for runner tokens and service credentials
- task definitions or compiled circuits inserted through the host integration path

The rest of this Usage chapter sketches those pieces in order.

## Next Step

If you are trying to author workflows, read [Your first Wire workflow](02-first-wire-workflow.md).

If you are trying to operate the runtime, read [Running Pulse](03-running-pulse.md).
