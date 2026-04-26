# Cortex Agent Context

This is the provider-neutral agent handbook for Cortex. Provider files
such as `CLAUDE.md` and `AGENTS.md` are generated symlinks; edit this
file instead.

Cortex is a standalone substrate: a durable runtime plus a
structured-reasoning library above it (see ADR 0015). The runtime is the
canonical public surface. `Cortex.Logoi` is a library on top of the
substrate and depends on it, not the other way round.

## Repository Shape

- `src/Cortex/` - main Haskell library. Canonical substrate roots are
  `Cortex.Graph`, `Cortex.Circuit`, `Cortex.Wire`, `Cortex.Pulse`,
  `Cortex.Memory`, `Cortex.Capability`, `Cortex.Document`, and
  `Cortex.Event`. Implementation-era roots such as `Cortex.Task`,
  `Cortex.Provider`, `Cortex.Research`, and `Cortex.Run` remain only as
  migration surfaces until the Logoi follow-up lands.
- `src-platform/Platform/` - runtime substrate library Cortex depends
  on: `Platform.Observability`, `Platform.DurableTask`,
  `Platform.Database`, `Platform.HTTP.Retry`, `Platform.Text`, etc.
  Exposed as a public Cabal sub-library (`cortex:platform-runtime`).
- `app/cortex-pulse/` - substrate shell executable. Ships with an empty
  task registry; consumers link their own registry when binding.
- `editors/tree-sitter-wire/` - Wire DSL grammar. Consumed by the docs
  site for `wire` blocks and by editor integrations.
- `theory/` - Lean 4 mechanization of substrate guarantees: Mokhov
  graph laws, Pulse frontier safety, Wire rewrite soundness. Builds
  through `just lean-build`.
- `docs/` - canonical Cortex docs. Flat layout, no `/cortex/` prefix.
  Keep product docs out.
- `test/` - hspec-discover driven Cortex-only suite.
- `agents/` - provider-neutral agent context, skills, and setup
  scripts. Provider-specific files are generated from here.

## Build System

All builds go through Nix. Do not invoke `cabal` or `ghc` directly.

```bash
just build          # nix build .#cortex
just build-pulse    # nix build .#cortex-pulse
just test           # run the cortex-test suite
just fmt            # apply repo formatters
just fmt-check      # fail on formatter drift
just lint           # HLint over the full repo
just check          # nix flake check
just ci-check       # CI-aligned local check suite
just docs-build     # static docs site
just docs-check     # frontmatter validation
just docs-dev       # dev server
just update-materialized

just lean-build
just lean-check
just lean-run
just lean-build-exe
just lean-clean
```

GHC 9.10 is pinned via haskell.nix (`compiler-nix-name = "ghc910"` in
`nix/haskell.nix`). Materialized plan-nix caches live under
`nix/materialized/cortex/` and must be regenerated after any Cabal
change. Entering `nix develop` installs repo-local pre-commit hooks for
formatting, HLint, and Lean theory checks.

## Git History Policy

Git history is a maintained artifact, not a raw transcript of every
coordination accident. Merge commits are appropriate when preserving a
parallel line of development is semantically meaningful. Rebase is the
default for ordinary feature work because most feature branches are
private staging areas for a coherent change.

Follow this policy:

- `main` is immutable. Never force-push the shared trunk except for an
  explicit, lease-protected history repair approved by the maintainer.
- Feature branches are rewriteable by their owner. Rebase, squash,
  fixup, and reorder before integration when that makes the branch read
  as a semantic argument.
- Shared feature branches require protocol. Use
  `git push --force-with-lease`, never raw `git push --force`.
- CI must pass after the final rebase or rewrite.
- Integration is fast-forward-only from an already signed branch tip.
  Do not use GitHub's merge, squash, or rebase buttons for Cortex
  `main`. The maintainer ruleset bypass exists only for
  `just integrate-pr <branch-or-pr-number>` after PR review and CI.
- Long-running collaborative, release, vendor, backport, or integration
  branches may use merge commits deliberately when the topology itself
  carries meaning.

## Issue And PR Tracking

Cortex uses GitHub Issues and GitHub Pull Requests for active project
tracking. When starting non-trivial work, prefer an existing GitHub
issue or open one before implementation. Link PRs to issues with
`Closes #<number>` when the PR completes the scope.

Do not use Linear, downstream issue IDs, or downstream product trackers as
active Cortex planning state. Historical research notes and handoffs may
retain those references for provenance, but new Cortex work is tracked
in this repository.

## Commit And Authorship Policy

Every commit in this repo must be signed and verifiable.

- Always commit with `git commit -s -S`.
- Do not create unsigned commits.
- After rewriting or creating commits, verify them with
  `git log --show-signature` or `git verify-commit`.
- Before publishing a branch for integration, run
  `just check-commit-provenance origin/main..HEAD`.

LLMs and coding agents are not authors for copyright purposes.

- Never put an LLM or agent in the author or committer fields.
- Never add `Co-authored-by:` trailers for AI tools.
- Never mention AI tools as legal authors of a commit.

Human developers may use agent tooling to prepare patches, but commits
must remain human-authored and human-signed.

## Canonical Docs Policy

Cortex docs are the source of truth for substrate design. When editing
docs:

- Architecture chapters describe the substrate. Keep reasoning-layer
  content explicitly attributed to `Cortex.Logoi`.
- ADRs are numbered and append-only. New decisions get new ADR files.
- `docs/Consumers/<consumer>/` documents downstream consumer bindings
  and integration contracts, not the frame for Cortex itself.
- Public and canonical docs must present Cortex as the upstream
  substrate. Downstream products may appear as examples only after the
  generic contract is clear.
- `docs/Templates/` is excluded from the docs-site build.

## Agentic Tooling

Repo-local agent context lives under `agents/`.

- Root context: `agents/context.md`.
- Source-tree context: `agents/<repo-path>/context.md`.
- Skills: `agents/skills/<name>/SKILL.md`.
- Provider symlinks are gitignored and regenerated with
  `just agent-link-codex` or `just agent-link-claude`.

Do not edit generated provider files directly. Move reusable guidance
back into provider-neutral context or skills.

## Principles For This Codebase

1. **Type safety.** Distinct newtypes for distinct concepts; no type
   aliases for domain types.
2. **Pure decisions, effectful execution.** Factor decision logic into
   pure functions and ADTs; let thin effectful interpreters drive them.
3. **Exhaustive pattern matches on owned ADTs.** Never wildcard an ADT
   this codebase defines.
4. **Named records for swap-risk parameters.** Any function with more
   than eight parameters or adjacent same-typed pairs gets a record.
5. **Return values, not continuations.** Split "decide" from "continue":
   return a result, let the caller interpret it.
6. **Every DB call gets an error path.** No silent
   `_ <- runTransaction ...` drops.
7. **Formatting.** `just fmt` uses ormolu. Line length is 100.

## Non-Goals

- No downstream product code. Cortex and Platform code only; downstream
  consumers live in their own repos.
- No UI, frontend, or REST server. Cortex is a library plus a Pulse
  executor binary.
- No cross-link to consumer docs from Cortex canon unless the document
  is explicitly discussing downstream integration examples.
- No Linear or downstream product tracker workflow for active Cortex
  issues. Use GitHub Issues.
