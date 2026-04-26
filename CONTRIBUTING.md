# Contributing to Cortex

Cortex is a standalone substrate repository. Contributions need to keep
the code, docs, and commit history legally clean and mechanically
verifiable.

## Core Rules

1. All commits must be signed and verifiable.
2. LLMs and coding agents must not be listed as authors or co-authors.
3. Human git identity must be real and stable.
4. `main` advances only by fast-forwarding already signed commits.
5. Builds and checks go through the repo's `just` and Nix surfaces.

## Authorship and Copyright

Commits in this repository must be authored and committed by a human
developer using that developer's real configured git identity.

Because of copyright and provenance requirements:

- Do not add `Co-authored-by:` trailers for LLMs, coding agents, or AI
  assistants.
- Do not put AI tools in the author or committer fields.
- Do not mention LLMs as legal authors of code, docs, or commits.

Agents may help produce patches, but they are tooling. They are not
authors.

## Signed and Verified Commits

Every commit must be created with both:

- a developer signoff (`-s`)
- a cryptographic signature (`-S`)

Use:

```bash
git commit -s -S -m "type: summary"
```

Signed is not enough. The signature must also verify.

Recommended checks:

```bash
git log --show-signature --max-count=5
git verify-commit HEAD
just check-commit-provenance origin/main..HEAD
```

For SSH signing, configure an allowed signers file so Git can verify
local history, for example:

```bash
git config gpg.format ssh
git config user.signingkey ~/.ssh/signing-key.pub
git config gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
git config commit.gpgsign true
```

## Git History

Git history is maintained project material. It should preserve the
semantic shape of a change, not every intermediate coordination accident.

Default policy:

- Rebase ordinary feature branches before integration when that makes
  the commit sequence easier to review, bisect, or audit.
- Keep `main` immutable. Never force-push trunk except for an explicit,
  lease-protected history repair approved by the maintainer.
- Use `git push --force-with-lease` after deliberate branch rewrites.
  Do not use raw `git push --force`.
- CI must pass after the final rebase or rewrite.
- Integrate PRs by fast-forwarding `main` to the exact signed branch tip.
  Do not use GitHub's merge, squash, or rebase buttons as the Cortex
  integration protocol.
- Use merge commits deliberately for release branches, vendor branches,
  backports, long-running integration branches, large collaborative
  features, or audit cases where the parallel topology matters.

Merge is not forbidden. Uncontrolled merge is the antipattern.

## PR Integration

GitHub's PR buttons manufacture commit objects for merge and squash
flows. Rebase-and-merge also rewrites commits on GitHub's side. Those
objects do not preserve the local author, committer, signature, and
signoff that Cortex requires for `main`.

The repository therefore keeps GitHub's merge settings in a deliberately
constrained state:

- merge commits disabled
- squash merge disabled
- rebase merge left enabled only because GitHub requires at least one
  merge method for PRs
- branch rules require signed commits, linear history, PR checks, and
  rebase-only PR integration
- branch rules grant an explicit maintainer/integration bypass so the
  reviewed branch tip can be pushed by local fast-forward after checks

With signed commits required, the remaining GitHub rebase button should
not be used. Integration is local fast-forward:

```bash
just integrate-pr <branch-or-pr-number>
```

The helper verifies the commits introduced by the branch, checks that
the branch is a fast-forward from `main`, merges with `--ff-only`, and
pushes `main`.

That bypass is only for this integration path or an explicit
lease-protected history repair. It is not permission to bypass CI,
signature checks, signoff checks, or review.

Hard checks:

```bash
just check-commit-provenance origin/main..HEAD
just check-github-merge-policy
```

`check-commit-provenance` rejects GitHub/web-flow identities,
non-Digimuoto author or committer emails, missing matching
`Signed-off-by` trailers, unverifiable signatures, and merge commits.
`check-github-merge-policy` rejects repository settings or branch rules
that would re-enable GitHub-manufactured merge or squash commits.

## Build and Check Workflow

Use the repo commands:

```bash
just build
just test
just fmt
just fmt-check
just lint
just check
just lean-build
just lean-check
just ci-check
```

If you change Cabal inputs that affect the Haskell plan, regenerate the
materialized Nix plan:

```bash
just update-materialized
```

## Agent Use

Repo-local agent workflows live under `agents/`. If you use an agent:

- follow `agents/context.md` and `agents/README.md`
- regenerate provider symlinks with `just agent-link-codex` or
  `just agent-link-claude`; generated provider symlinks are gitignored
- preserve human authorship on commits
- preserve signed, verifiable history
- do not add AI attribution to commit messages or trailers
- respect the repo-local pre-commit hooks installed by `nix develop`

## Scope Discipline

Cortex is substrate code, not Portman product code.

- `Cortex.*` and `Platform.*` belong here
- Portman-specific product logic does not
- canonical docs live under `docs/`

## Before You Push

- `just fmt` is clean
- `just fmt-check` passes
- `just lint` passes when Haskell changed
- `just lean-check` passes when theory or Nix/Lean wiring changed
- relevant build/test commands pass
- commits are signed
- `git log --show-signature` verifies the commits you are pushing
- `just check-commit-provenance origin/main..HEAD` passes
- no AI authorship or co-authorship appears anywhere in commit metadata
