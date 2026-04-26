---
name: publish
description: >
  Publish the current branch: review git state, commit what should be
  committed (signed), iterate until pre-commit hooks pass, and push to
  the remote. Use when the user says publish, push, ship the branch, or
  when work is done and should be pushed.
---

# Publish

Publish the current branch cleanly: inspect the worktree, commit what
should be committed, and push to the tracked remote.

## Usage

```
/publish
/publish "split refactor and CI repair into separate commits"
```

Optional free text can steer how staged work is grouped into commits.
Default behavior is to infer from the current diff.

## Workflow

### 1. Review git state

```bash
git status --short
git branch --show-current
git remote -v
git diff --stat
git diff --cached --stat
```

Confirm:

- which branch is active (not `main` unless intentional)
- whether there are staged/unstaged changes worth pushing
- whether the branch has an upstream

### 2. Commit everything that should be published

Inspect, group, and commit. Use small semantic commits, not one giant
dump. Every commit:

- Uses `git commit -s -S`
- Follows the conventional prefix scheme: `feat:`, `fix:`, `refactor:`,
  `docs:`, `test:`, `chore:`, `ci:`, `perf:`
- Mentions the issue or PR in the body when relevant
- Must verify after creation (`git verify-commit` or
  `git log --show-signature`)
- Must not mention LLMs or agents in author, committer, or
  `Co-authored-by:` trailers

Iterate until pre-commit hooks pass. Do not skip hooks
(`--no-verify`) — fix the underlying issue.

Do not sweep unrelated local changes into the publish. If the worktree
has drift that is not part of the intended publish, stash or leave it
alone and call it out in the report.

### 3. Push to the remote

```bash
git push
```

If the branch has no upstream:

```bash
git push -u origin "$(git branch --show-current)"
```

History is a maintained artifact in this repo. Rebase-first development
is the default for ordinary feature work: make the branch read as a
semantic sequence before publishing. Use `--force-with-lease` only when
history was intentionally rewritten (rebase, squash, fixup, amend after
review) and a normal push is rejected. Never use raw `--force` against
shared branches; never force-push `main`.

### 4. Verify

```bash
git status --short
git rev-parse --short HEAD
git branch -vv
```

Expected end state:

- push succeeded
- worktree clean (or any leftovers explicitly called out)
- local branch tracks the intended remote

## Principles

1. **Commit before push.** Publishing means the remote reflects the
   current intended local state. Do not leave validated work only in
   the worktree.
2. **Hooks are part of publishing.** If pre-commit fails, fix the
   issue — don't bypass. Publishing is not done until the commit lands
   and the push succeeds.
3. **Preserve user changes.** Don't auto-stage unrelated drift. When in
   doubt, ask.
4. **Semantic history.** Prefer a small number of meaningful commits.
   Rebase or fix up private branch history when it removes process noise.
   The branch usually gets squash-merged; optimize for review clarity,
   bisectability, and the final artifact.

## Output

Report:

- branch name
- commit hash(es) pushed
- whether push used normal push or `--force-with-lease`
- worktree state afterwards (clean / noted drift)
