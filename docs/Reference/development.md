---
title: Cortex Development Workflow
description:
  Build, test, formatting, docs, theory, and local validation commands for Cortex contributors.
sidebar:
  label: Development
  order: 4
---

# Cortex Development Workflow

Cortex builds through Nix and the repo `justfile`. Use these surfaces rather than running `cabal` or
`ghc` directly; they match CI and keep generated plans, formatters, and toolchains aligned.

## Prerequisites

- Nix with flakes enabled.
- The repo development shell when you need local tools:

```bash
nix develop
```

## Core Commands

| Command            | Purpose                                                  |
| ------------------ | -------------------------------------------------------- |
| `just build`       | Build the Cortex library (`nix build .#cortex`).         |
| `just build-pulse` | Build the Pulse executable (`nix build .#cortex-pulse`). |
| `just test`        | Run the Cortex Haskell test suite.                       |
| `just fmt`         | Apply repo formatters.                                   |
| `just fmt-check`   | Fail on formatter drift.                                 |
| `just lint`        | Run HLint over Haskell sources.                          |
| `just check`       | Run `nix flake check`.                                   |
| `just ci-check`    | Run the CI-aligned local check suite.                    |

## Benchmarks

`just bench-pure-wire` runs the opt-in Criterion benchmark suite for Wire pure evaluation. It
compares several JSON-shaped pure workloads with direct Haskell implementations over the same
pre-built inputs:

- `wire-corepure-json` evaluates the CorePure AST over pre-built `Aeson.Value` Wire inputs and
  builds the JSON output. It uses a prepared pure task, so static task validation is outside the
  benchmark loop, and it does not parse JSON text inside the loop.
- `wire-corepure-nodes` runs a small chain of prepared pure tasks, wrapping each intermediate JSON
  value as a `WireValue` for the next node. This demonstrates pure node-boundary overhead without
  adding Pulse scheduling, durable logging, or JSON text parsing.
- `haskell-json` traverses the same pre-built `Aeson.Value` input shape directly in Haskell and
  builds the same JSON output, without the CorePure interpreter.

The benchmark component uses GHC `-O2`. The committed flake does not use `-march=native`, because
the Nix build may happen on a remote builder and must not bake that builder's CPU into the benchmark
binary.

Treat benchmark timings as local observations, not reference semantics. The benchmark fixture checks
that Wire and Haskell return the same JSON value before Criterion runs the timed groups. For
ordinary benchmark runs, the executable prints a compact Wire/Haskell comparison summary to stdout
before Criterion's detailed benchmark rows. `--list` remains metadata-only and prints only benchmark
names.

Pass Criterion arguments after Just's separator:

```bash
just bench-pure-wire -- -n 1 -L 1 --match prefix weighted-score
just bench-pure-wire -- --list
```

## Documentation

| Command                                        | Purpose                                 |
| ---------------------------------------------- | --------------------------------------- |
| `just docs-build` / `nix build .#docs-site`    | Build the static documentation site.    |
| `just docs-check`                              | Validate docs by building the site.     |
| `just docs-dev` / `nix run .#docs-dev`         | Run the docs development server.        |
| `just docs-preview` / `nix run .#docs-preview` | Build and preview the static docs site. |

The published docs are built from `docs/` by the GitHub Pages workflow. Keep README prose brief and
move detailed build, reference, and architecture material into this documentation tree.

## Issues And Pull Requests

Cortex uses GitHub Issues for active work tracking. Use issues for bugs, implementation scopes,
roadmap slices, and follow-up work. Pull requests should link the issue they complete with
`Closes #<number>` when the scope has a tracker.

Do not use Linear or a downstream product tracker as active Cortex planning state. Historical docs
may retain external issue IDs when they explain past migration context, but new Cortex work belongs
in this repository's GitHub issue system.

## CI Runner Trust Boundary

Public pull-request workflows are treated as untrusted code. They run only lightweight checks on
GitHub-hosted runners and must not dispatch arbitrary PR code to private self-hosted runners.

Self-hosted runners such as Mercury are reserved for trusted events: `push` to protected internal
branches, documentation deployment, cache publication, release work, and explicit
`workflow_dispatch` runs started by maintainers. Full Nix builds require private flake inputs, so
maintainers can use the manual CI dispatch path for trusted PR branches after reviewing the code
that will execute.

If Cortex later adds public pull-request Nix smoke checks, keep them on GitHub-hosted runners and
install Nix explicitly, for example with the Determinate Nix installer action. Those checks must not
use repository secrets, private SSH credentials, or private flake inputs.

## Lean Theory

| Command           | Purpose                                               |
| ----------------- | ----------------------------------------------------- |
| `just lean-build` | Build the Lean proof tree with Lake.                  |
| `just lean-check` | Run the Nix-backed theory check used by hooks and CI. |
| `just lean-run`   | Build and run the theory smoke executable.            |

## Generated Plans And Agent Links

If Cabal inputs change, regenerate the materialized Haskell plan:

```bash
just update-materialized
```

Shared agent skills and archetypes are supplied by calling the public `Digimuoto/agents` flake from
local `just agent-link-*` commands. Cortex does not keep a tracked `agents/` tree or export agent
tooling from its own flake. Cortex-local agent context is configured in `nix/agent-root.nix`, and
repo-specific skill overlays are generated from `nix/agent-overlays.nix`. Provider files such as
`AGENTS.md` and `CLAUDE.md` are generated, gitignored symlinks:

```bash
just agent-link-codex
just agent-link-claude
just agent-link-opencode
```

## Before Publishing

Run the checks relevant to the change:

- Haskell or Nix changes: `just fmt-check`, `just lint`, `just test`, and `just check` as
  appropriate.
- Docs changes: `just docs-check`.
- Theory changes: `just lean-check`.
- Commits must be signed and verifiable; see the repository `CONTRIBUTING.md`.
