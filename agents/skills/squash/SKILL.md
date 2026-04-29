---
name: squash
description: >
  Rewrite a Cortex PR branch into the minimum coherent sequence of signed, buildable commits before
  integration. Use when the user asks to squash, clean up commits, rebase history, fix process-noise
  commits, or prepare a PR history for fast-forward shipping.
---

# Squash

Clean a PR branch by rebasing it into a small semantic commit sequence. Do not blindly squash the
whole PR. The goal is the minimum number of commits that still tells the correct story and leaves
`main` working at every commit.

## Hard Rules

- Ask before rewriting branch history.
- Never rewrite `main`.
- Never use GitHub squash, merge, or rebase buttons.
- Never raw force-push. Use `git push --force-with-lease` after an approved rewrite.
- Every final commit must be signed, signed off, and verifiable.
- Every final commit must build with the relevant CI-aligned checks.
- Keep tests and code together when separating them would leave an intermediate commit broken.
- If the PR is thematically mixed, propose splitting the PR and ask the user. Do not split without
  approval.

## Usage

```
/squash [pr-number-or-branch]
```

If no argument is given, use the current branch and detect its PR:

```bash
gh pr view --json number --jq .number
```

## Workflow

### 1. Establish the rewrite target

```bash
git status --short
git branch --show-current
git fetch origin main
```

Stop if the worktree is dirty. Do not stash, commit, or discard local changes unless the user
explicitly asks.

Confirm the active branch is not `main`:

```bash
test "$(git branch --show-current)" != main
```

Inspect the PR when available:

```bash
gh pr view --json number,title,baseRefName,headRefName,state,isDraft,url
gh pr diff --name-only
```

### 2. Inventory the current commits

```bash
git log --reverse --decorate --oneline origin/main..HEAD
git log --reverse --format='%h%x09%s%n%b' origin/main..HEAD
git diff --stat origin/main...HEAD
git diff --name-status origin/main...HEAD
```

For each commit, inspect its shape:

```bash
git show --stat --oneline --find-renames <sha>
git show --name-only --format=fuller <sha>
```

Look for:

- `fixup!`, `squash!`, `wip`, `tmp`, `review`, `ci`, or retry commits
- commits that only repair immediately previous commits
- commits that mix unrelated docs, CI, source, and generated files
- tests split after code in a way that leaves earlier commits untested
- dependency or generated-output changes that must precede source changes
- merge commits, unsigned commits, or GitHub-authored commits

### 3. Propose a semantic commit plan

Write a proposed final sequence before changing history:

```markdown
Proposed squash plan:

1. `ci: configure GitHub Pages docs build`
   - includes workflow and Nix docs-site plumbing
   - validation: `just docs-check`

2. `docs: condense consumer example`
   - includes consumer doc deletion and replacement page
   - validation: `just docs-check`

3. `docs: add Cortex ship and squash skills`
   - includes agent skill docs and provider links
   - validation: `just fmt-check`
```

Rules for the plan:

- Prefer one commit for one independently reviewable concern.
- Use the fewest commits that preserve reviewability and bisectability.
- Put enabling infrastructure before code that depends on it.
- Put schema/type/API changes before implementations only when the intermediate commit still builds.
- Keep docs with the feature when the docs are part of the same semantic change; use a separate docs
  commit when the docs are independent.
- Keep generated files with the source change that produced them.
- Do not create a commit that knowingly breaks build, tests, docs, or theory.

If the branch contains two or more unrelated themes that would be better reviewed independently,
stop and ask:

```markdown
This PR is thematically mixed. I recommend splitting it before shipping.

- Chunk A: <scope>
- Chunk B: <scope>

Do you want me to split the PR, or keep it as one branch and squash into separate commits?
```

### 4. Rewrite only after approval

After the user approves the plan, use local Git tools. Prefer interactive rebase for
reordering/fixups:

```bash
git rebase -i origin/main
```

For mechanical fixups, `--autosquash` is allowed when commits are already marked:

```bash
git rebase -i --autosquash origin/main
```

For a full manual regrouping, use a soft reset only on the feature branch:

```bash
git reset --soft origin/main
git reset
```

Then stage each planned chunk explicitly and commit it:

```bash
git add <paths-for-chunk>
git commit -s -S -m "<type>: <summary>"
```

Do not use `--no-verify`. Do not include AI authorship or `Co-authored-by` trailers for tools.

### 5. Verify every final commit

First verify provenance for the whole rewritten range:

```bash
just check-commit-provenance origin/main..HEAD
```

Then verify each final commit in a temporary worktree so the current checkout remains stable:

```bash
for sha in $(git rev-list --reverse origin/main..HEAD); do
  check_dir="$(mktemp -d)"
  git worktree add --detach "$check_dir" "$sha"
  (
    cd "$check_dir"
    just fmt-check
    just check
  )
  git worktree remove --force "$check_dir"
done
```

If the branch is docs-only, `just docs-check` may replace `just check`. If the branch touches Lean
theory, include `just lean-check`. If the branch touches docs rendering, include `just docs-check`.
State any reduced check surface in the final report.

If any intermediate commit fails, fix the plan and rewrite again. Do not publish a sequence where
only the final tip works.

### 6. Publish the rewritten branch

Push with a lease after successful verification:

```bash
git push --force-with-lease
```

Then wait for PR CI on the new tip:

```bash
gh pr checks --watch
```

Do not ship until the rewritten commit sequence has passed CI.

## Report

When finished, report:

```markdown
Squash complete.

- Branch: `<branch>`
- Base: `origin/main`
- Final commits:
  1. `<sha>` `<subject>`
  2. `<sha>` `<subject>`
- Push: `--force-with-lease`
- Per-commit validation: passed (`<commands>`)
- PR CI: passed / pending / not checked
```

If blocked, report the exact blocker and recovery:

```markdown
Squash blocked.

- Blocker: <dirty tree | mixed scope | conflict | commit failed validation>
- Recovery: <ask user | split PR | fix commit N | re-run checks>
```
