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

Repo-local agent context lives under `agents/`. Provider files such as `AGENTS.md` and `CLAUDE.md`
are generated, gitignored symlinks:

```bash
just agent-link-codex
just agent-link-claude
```

## Before Publishing

Run the checks relevant to the change:

- Haskell or Nix changes: `just fmt-check`, `just lint`, `just test`, and `just check` as
  appropriate.
- Docs changes: `just docs-check`.
- Theory changes: `just lean-check`.
- Commits must be signed and verifiable; see the repository `CONTRIBUTING.md`.
