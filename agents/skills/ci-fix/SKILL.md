---
name: ci-fix
description: >
  Diagnose and fix a red CI run on the current PR. Inspects failing jobs, reproduces failures
  locally through `just`/`nix`, applies fixes, and pushes. Use when CI is red on the current branch
  or when the user says "fix CI", "the build is broken", "why is CI failing".
---

# Fix CI

Systematically diagnose and repair a failing CI run. Operates on the current PR's latest run.

## Usage

```
/ci-fix
/ci-fix <pr-number>
/ci-fix --job <job-name>
```

**Arguments:**

- `<pr-number>` — Optional. If omitted, detects from current branch.
- `--job <name>` — Focus on a single failing job (useful when multiple jobs fail and you want to
  tackle one at a time).

## Workflow

### 1. Locate the failing run

```bash
PR=${PR:-$(gh pr view --json number --jq '.number')}
gh pr checks "$PR"
```

Identify:

- which jobs failed
- which were skipped or cancelled
- the latest run ID

For a specific job:

```bash
gh run view <run-id> --json jobs --jq '.jobs[] | select(.conclusion=="failure")'
```

### 2. Pull the failing log

```bash
gh run view <run-id> --log-failed | tail -200
# or per-job:
gh run view <run-id> --job <job-id> --log | tail -200
```

Scan for the first error line, not the last. Earlier failures cascade; fixing the first often clears
several.

### 3. Classify the failure

Match the error signature to one of the canonical Cortex CI failure modes:

| Signature                           | Job            | Likely cause                                                   | Fix path                                                                          |
| ----------------------------------- | -------------- | -------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `error: File is not formatted: …`   | `nix fmt --ci` | ormolu or alejandra drift                                      | `just fmt` locally, commit                                                        |
| `Warning: …` promoted to error      | Haskell build  | `-Werror` unused import / incomplete match / missing export    | Read the specific warning; fix the source                                         |
| `Could not load module 'X'`         | Haskell build  | Missing `build-depends` entry in `cortex.cabal`                | Add the dep under the relevant library/exe stanza                                 |
| `Couldn't match type … with …`      | Haskell build  | Real type error; usually a rel8/hasql/crypton upgrade mismatch | Narrow the package version or adjust the call site                                |
| `Test failed: …`                    | Haskell tests  | Behavior regression                                            | Run the single spec locally: `just test-match "<name>"`                           |
| `HLint: …`                          | Lint           | Banned partial function, style rule                            | Fix the flagged expression or add a targeted `{-# ANN … #-}` if truly unavoidable |
| `hash mismatch … got: …`            | haskell.nix    | `nix/materialized/` drift after a cabal edit                   | `just update-materialized`, commit the regenerated cache                          |
| `docs-site: Downloading wasi-sdk …` | docs-site      | Wrapped `tree-sitter` not in use                               | Check `nix/nixpkgs.nix`; the CLI must receive `TREE_SITTER_WASI_SDK_PATH`         |
| `hlint: exit 1` / style rules       | HLint          | Banned `head`, `fromJust`, `undefined`, partial function       | Replace with safe variant (`listToMaybe`, pattern match, etc.)                    |

If the signature does not match anything above, surface the first error line to the user and stop —
do not guess.

### 4. Reproduce locally

Before editing source, reproduce the failure on your machine. CI-only failures are rare but real; if
the reproduction does not fail locally, the issue may be environmental (cache, materialization,
index-state).

| Failure          | Local reproduction                           |
| ---------------- | -------------------------------------------- |
| Format           | `nix fmt -- --ci`                            |
| Flake check      | `nix flake check --print-build-logs`         |
| Library build    | `nix build .#cortex`                         |
| Platform build   | `nix build .#platform-runtime`               |
| Executable build | `nix build .#cortex-pulse`                   |
| Docs site        | `nix build .#docs-site`                      |
| Tests            | `just test` or `just test-match "<pattern>"` |
| HLint            | `just lint`                                  |

If the failure is only on CI, compare:

- local nix store vs. CI cache (`nix path-info --all | rg <drv>`)
- index-state in `nix/haskell.nix`
- GHC version mismatches

### 5. Apply the fix

Edit the source, not the test, unless the test itself is wrong.

For `-Werror` warnings:

- Unused import → delete or narrow
- Incomplete pattern → add the missing case or make the match exhaustive per Cortex's core
  principles (no wildcards on owned ADTs)
- Missing export list → add `-Wmissing-export-lists` needs explicit
  `module Foo (symbol1, symbol2) where`

For materialization mismatches:

```bash
just update-materialized
git add nix/materialized
git commit -s -m "chore: regenerate haskell.nix materialized plans"
```

For cabal dep issues, check what actually fails to resolve or compile and add the minimum needed.
Avoid sweeping dep additions — Cortex keeps `cortex.cabal` lean.

### 6. Verify locally

```bash
just fmt
just check      # fmt + flake check + build
just test       # if tests were involved
```

Only push once every failing local check passes. Pushing a partial fix just to see what CI says
wastes a run and pollutes the log.

### 7. Commit and push

One logical commit per failure mode. Prefer:

```
fix(ci): <short description>

<one-sentence reason>
```

Push to the same branch:

```bash
git push
```

### 8. Watch the re-run

```bash
gh run watch <new-run-id>
```

Or:

```bash
gh pr checks "$PR" --watch
```

If it fails again on a different signature, re-enter the workflow at step 3. If it fails on the same
signature, the fix was incomplete — re-read the fresh log carefully; do not blindly retry.

## Principles

1. **Fix the first error, not the last.** Later errors usually cascade from the first.
2. **Reproduce locally before pushing.** CI is not an interactive REPL.
3. **One concern per commit.** `fix(ci): treefmt drift` and `fix(ci): missing warp dep` are two
   commits, not one.
4. **Never skip hooks or disable checks.** `--no-verify`, `-Wno-…`, and `allowUnfreePredicate`
   tweaks are cover-ups. Fix the cause.
5. **Materialization is a plan cache, not a feature.** When it breaks, regenerate it and move on —
   don't disable it unless you have a specific reason.

## Output

```
Run: <id> — <n> jobs failed
Cause: <one-line classification>
Fix: <commit hash> — "<commit title>"
Local verify: just check ✓
Pushed: <remote branch>
Next run: <url>
```

If multiple failures stacked, enumerate each cause + fix. Do not leave any unresolved without
calling it out explicitly.
