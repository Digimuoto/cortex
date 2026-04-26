# Contributing to Cortex

Cortex is a standalone substrate repository. Contributions need to keep
the code, docs, and commit history legally clean and mechanically
verifiable.

## Core Rules

1. All commits must be signed and verifiable.
2. LLMs and coding agents must not be listed as authors or co-authors.
3. Human git identity must be real and stable.
4. Builds and checks go through the repo's `just` and Nix surfaces.

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
- Keep `main` immutable. Never force-push trunk.
- Use `git push --force-with-lease` after deliberate branch rewrites.
  Do not use raw `git push --force`.
- CI must pass after the final rebase or rewrite.
- Prefer fast-forward or squash integration into trunk.
- Use merge commits deliberately for release branches, vendor branches,
  backports, long-running integration branches, large collaborative
  features, or audit cases where the parallel topology matters.

Merge is not forbidden. Uncontrolled merge is the antipattern.

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
- no AI authorship or co-authorship appears anywhere in commit metadata
