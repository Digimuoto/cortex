---
name: impl
description: >
  Start implementation on an issue: create a feature branch, open a draft
  PR, and enter plan mode for design. Use when beginning new work on a
  GitHub issue or a freshly defined piece of scope.
---

# Start Implementation

Begin implementing a piece of work: create a branch, open a draft PR,
and enter plan mode. This is the entrypoint for any non-trivial change.

## Usage

```
/impl [issue-number-or-description]
```

**Arguments:**
- `[issue-number]` — GitHub issue number (e.g. `42`). PR will `Closes #42`.
- `[description]` — If no issue exists yet, a short description
  ("wire v1 error recovery"). You will be prompted whether to also open
  a tracking issue.

**Examples:**
```
/impl 42                              # Work against existing issue
/impl "pulse timeout retry policy"    # New scope; no issue yet
/impl                                 # Prompts for input
```

---

## Workflow

### 1. Gather context

If an issue number is provided:

```bash
gh issue view <number> --json number,title,body,labels,assignees
```

Extract:

- `title` → branch-name slug, PR title seed
- `body` → PR description seed
- `labels` → area hints (`substrate`, `wire`, `pulse`, `docs`)
- `assignees` → confirm you own this work

If no issue was given and the user provides a description instead, ask
whether to open a tracking issue first. For small fixes or
experimentation, proceed without one.

### 2. Classify the work by Cortex layer

Cortex is vertically split per ADR 0015. Name the layer explicitly in
your plan:

- `Cortex.Graph` / `Cortex.Circuit` — pure topology and compiled shape
- `Cortex.Wire` / `Cortex.Wire.V1` — source language + rewrite algebra
- `Cortex.Pulse.*` — durable execution runtime
- `Cortex.Memory.*` — memory substrate
- `Cortex.Capability.*` / `Cortex.Provider.*` — model + tool abstractions
- `Cortex.Task.*` — task orchestration primitives
- `Platform.*` — generic runtime substrate (observability, durable task,
  database, crypto, HTTP retry). Lives in `src-platform/`.

If the work would introduce reasoning-layer concerns (role taxonomies,
reasoning templates, memory presets), it probably belongs in a future
`Cortex.Logos` module set — not in the runtime substrate. Flag this and
stop to discuss before coding.

### 3. Prerequisites

**Check for blockers (linked issues):**

```bash
gh issue view <number> --json projectItems,body | jq '.body' | rg -i 'blocked by|depends on|needs #'
```

**Check for existing branch:**

```bash
git branch -a | rg -i "<issue-number>|<slug>" | head
```

If a branch already exists, ask whether to continue on it, start fresh
(destructive — confirm before deleting), or cancel.

**Clean working tree:**

```bash
git status --porcelain
```

If non-empty, stop. Ask the user to commit or stash first.

### 4. Create the feature branch

```bash
git checkout main
git pull --ff-only origin main
git checkout -b <branch-name>
```

Branch naming:

- With issue: `<number>-<slug>` (e.g. `42-pulse-timeout-retry`)
- Without: `<slug>` or `<topic>/<slug>` (e.g. `pulse/timeout-retry`)

Slug: lowercase title, spaces → hyphens, max ~50 chars, no punctuation.

### 5. Open a draft PR

Create an empty placeholder commit so there is something to push:

```bash
git commit --allow-empty -s -m "chore: start work on <slug>"
git push -u origin HEAD
```

Then open the PR with a HEREDOC body (avoids `\n` escape bugs):

```bash
gh pr create --draft --base main --title "<type>: <title>" --body "$(cat <<'EOF'
## Summary
<short description of intent>

## Plan
- [ ] <step 1>
- [ ] <step 2>

## Checklist
- [ ] Implementation complete
- [ ] Tests added/updated
- [ ] `just check` passes locally
- [ ] Ready for review

## Issue
Closes #<number>
EOF
)"
```

Prefix types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `ci`,
`perf`. Keep the title under 70 characters; detail goes in the body.

### 6. Enter plan mode

Use `EnterPlanMode` to design the implementation before coding. In plan
mode:

1. Read the relevant Cortex layer(s) to understand existing patterns.
2. Identify files to create or modify — list concrete paths, not vague
   areas.
3. Note test-suite touch points (`test/Cortex/<area>/*Spec.hs`).
4. Decide whether the change needs a new ADR (cross-layer design
   decisions almost always do).
5. Write the plan for user approval.
6. Exit plan mode to implement.

Before exiting plan mode, verify the plan respects the substrate/reasoning
split from ADR 0015: runtime never imports the reasoning layer or
consumer-specific code.

### 7. Implement incrementally

After plan approval:

1. Create a todo list mirroring the plan steps.
2. Implement one step at a time; commit often with `-s`.
3. Commit-message format:

```
<type>: <short description>

<optional body explaining the why>

Issue: #<number>
```

4. Run `just fmt` before every commit (pre-commit hooks enforce this).
5. Run `just check` before marking the PR ready — or at minimum
   `just build` + `just test`.

### 8. Debugging workflow

When behavior only reproduces at runtime, use Cortex's native debug path:

```bash
just build                   # nix build .#cortex
just build-pulse             # nix build .#cortex-pulse
just test-match "<pattern>"  # filtered hspec run
./result/bin/cortex-pulse --help
```

For deeper investigation of Pulse execution, bring up a local Postgres
(separate setup — Cortex does not manage database lifecycle) and
exercise the substrate-shell binary with `--db-host` / `--db-name` flags
pointing at it. Consumers (Portman) test the integration surface in
their own repo.

## Principles

1. **Small commits, one concern each.** Reviewers can follow a story,
   and the exact signed branch tip may become `main`.
2. **Plan before coding.** Plan mode surfaces the shape before you sink
   hours into the wrong one.
3. **Respect the layer boundary.** Runtime never imports reasoning or
   consumer code. If a change tempts you across the line, it is a
   design signal, not an implementation detail.
4. **Cite the issue in every commit.** Future-you reading `git log`
   will thank you.

## Report

At the end of `/impl`, confirm:

```
Branch: <name>
PR: #<number> (draft) — <url>
Plan: approved / pending
Next step: <first todo item>
```
