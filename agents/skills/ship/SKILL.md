---
name: ship
description: >
  Ship a reviewed Cortex PR by verifying CI, reviews, documentation,
  commit provenance, and rebase state, then integrating with the local
  fast-forward-only `just integrate-pr` workflow. Use when the user says
  ship, merge, land, integrate, or close a ready PR.
---

# Ship

Ship a Cortex PR without manufacturing new commit objects. Cortex `main`
is fast-forward-only: do not use GitHub's merge, squash, or rebase
buttons. The final branch tip must already contain the exact signed,
signed-off commits that will become `main`.

## Usage

```
/ship [pr-number-or-branch]
```

If no argument is given, detect the PR from the current branch:

```bash
gh pr view --json number --jq .number
```

If detection fails, ask for the PR number or branch name.

## Hard Rules

- Never use GitHub PR buttons for Cortex `main`.
- Never create a merge commit while shipping.
- Never squash on GitHub. If history needs cleanup, rebase or fix up the
  PR branch locally, then push with `--force-with-lease`.
- Never raw force-push. Use `git push --force-with-lease` only after a
  deliberate local rewrite.
- Never integrate unsigned, unverifiable, GitHub-authored, or
  GitHub-committed objects.
- After any rebase or history rewrite, CI must run and pass again.
- `main` advances only through `just integrate-pr <pr-or-branch>` from a
  clean worktree after review and CI.

## Workflow

### 1. Identify the PR

```bash
PR="${PR:-$(gh pr view --json number --jq .number 2>/dev/null || true)}"
gh pr view "$PR" \
  --json number,title,state,isDraft,baseRefName,headRefName,headRepositoryOwner,mergeStateStatus,reviewDecision,url
```

Stop if:

- the PR is not open
- the PR is draft
- the base branch is not `main`
- the PR comes from a fork that cannot be safely integrated by local
  fast-forward without fetching the exact head ref

Check out the PR branch if needed:

```bash
gh pr checkout "$PR"
```

### 2. Fetch current refs

```bash
git fetch origin main
git fetch origin "$(gh pr view "$PR" --json headRefName --jq .headRefName)"
```

Confirm the worktree is clean before any rebase, verification, or
integration:

```bash
git status --short
```

If dirty, stop and report the local changes. Do not stash or commit
unrelated work unless the user explicitly asks.

### 3. Inspect readiness

```bash
gh pr checks "$PR"
gh pr view "$PR" --json reviewDecision,mergeStateStatus
```

Stop if required checks are failing, pending without an explicit reason
to wait, or if reviews request changes.

The expected review state is `APPROVED` or no required review decision
with an explicit maintainer instruction to ship. The expected merge
state is clean or behind-only.

### 4. Review documentation parity

Inspect changed files:

```bash
gh pr diff "$PR" --name-only
```

Block shipping if the PR changes public or canonical behavior without
docs or an explicit no-docs-needed rationale in the PR:

- Wire syntax, grammar, or examples
- Pulse API, state, events, host actions, or persistence semantics
- graph, Circuit, memory, capability, provider, or artifact contracts
- build, CI, signing, release, or contributor workflow
- public README or docs-site navigation

Docs-only changes should still pass `just docs-check` or the CI docs
job.

### 5. Review commit shape

Inspect the exact commits that would enter `main`:

```bash
git log --reverse --decorate --oneline origin/main..HEAD
git log --reverse --format='%h%x09%s%n%b' origin/main..HEAD
git diff --stat origin/main...HEAD
```

Look for process noise before shipping:

- `fixup!`, `squash!`, `wip`, `tmp`, `review`, or CI retry commits
- commits that only repair an immediately previous commit
- tests split from code in a way that leaves an intermediate commit
  broken
- generated files separated from the source change that produced them
- unrelated themes that should have been separate PRs
- too many commits for the actual semantic surface

If the branch already reads as a minimal semantic sequence, continue.

If it should be squashed or reordered, stop and ask before rewriting:

```markdown
The PR history should be cleaned before shipping.

Recommended final sequence:
1. `<type>: <scope>`
2. `<type>: <scope>`

Run `/squash <pr-number>` with this plan?
```

If the PR is thematically mixed, recommend splitting it and ask the user
whether to split or keep one PR. Do not split or rewrite history without
approval.

### 6. Rebase when needed

Check whether the PR branch is already based on current `origin/main`:

```bash
git merge-base --is-ancestor origin/main HEAD
```

If this fails, rebase locally:

```bash
git rebase origin/main
```

After any rebase:

```bash
just check-commit-provenance origin/main..HEAD
git push --force-with-lease
```

Then wait for CI to rerun and pass:

```bash
gh pr checks "$PR" --watch
```

Do not ship a branch immediately after rewriting it unless the new tip
has passed CI.

### 7. Verify commit provenance

Run the hard local provenance gate against the exact commits that would
enter `main`:

```bash
git fetch origin main
just check-commit-provenance origin/main..HEAD
```

This rejects merge commits, GitHub/web-flow identities,
non-Digimuoto email, missing matching `Signed-off-by` trailers, and
unverifiable signatures.

When repo or ruleset configuration changed, also run:

```bash
just check-github-merge-policy
```

### 8. Integrate by fast-forward

From a clean worktree, integrate with the repo helper:

```bash
just integrate-pr "$PR"
```

The helper fetches the PR branch, verifies provenance for the introduced
commits, checks that `main` can fast-forward, merges with `--ff-only`,
and pushes `main`.

If integration fails because the branch is not a fast-forward, rebase
the PR branch onto `origin/main`, push with `--force-with-lease`, wait
for CI, and retry.

### 9. Verify GitHub state

After pushing `main`, confirm GitHub recognized the PR as merged:

```bash
gh pr view "$PR" --json state,mergedAt,mergeCommit,url
```

If GitHub has not closed the PR even though `main` contains the branch
tip, report that manual PR state cleanup is needed. Do not close a PR
as unmerged unless the user explicitly asks.

Confirm linked GitHub issues closed automatically when the PR body uses
`Closes #<number>`:

```bash
gh pr view "$PR" --json closingIssuesReferences
```

If issues remain open because the PR lacked closing keywords, report
the issue numbers and ask before closing them manually.

## Blocked Report

When shipping is blocked, report the blocker and the exact recovery:

```markdown
Ship blocked.

- PR: #<number> <title>
- Blocker: <CI failing | review requested changes | needs rebase | provenance failed | docs missing>
- Recovery: <command or concrete next action>
```

## Ship Report

When shipping succeeds, report:

```markdown
Shipped PR #<number>: <title>

- Integrated by: `just integrate-pr <number>`
- Main tip: `<sha>`
- Commits introduced: `<count>`
- Checks: passed
- Provenance: passed
- Docs: updated / not needed (<reason>)
- Issues: closed #<n> / none
```
