# Cortex agent context

Provider-neutral context and slash-command skills for AI coding agents working on this repo.
Provider-specific files such as `CLAUDE.md` and `AGENTS.md` are generated, gitignored symlinks; do
not edit them directly.

```
agents/
├── README.md
├── context.md                  # Root agent handbook
├── archetypes/                 # Shared Nous-style reasoning profiles
├── scripts/
│   └── link-provider           # Builds Codex/Claude symlinks
├── src-platform/
│   └── Platform/
│       ├── context.md
│       ├── Database/context.md
│       └── DurableTask/context.md
└── skills/
    ├── impl/                   # Start implementation (branch, draft PR, plan)
    ├── publish/                # Commit + push the current branch
    ├── squash/                 # Rebase PR history into semantic commits
    ├── ship/                   # Verify and fast-forward-integrate a PR
    ├── ci-fix/                 # Diagnose & fix a red CI run
    ├── pr-resolve-review/      # Address PR review comments
    ├── haskell-code-style/     # Opinionated Haskell review (+ references/)
    ├── lean-code-style/        # Strict Lean 4 proof review (+ references/)
    ├── lean-theorem-attack/    # Semantic theorem/model attack
    ├── doc-review/             # Docs review (+ references/)
    └── doc-review-and-fix/     # Review and edit docs in one pass
```

Each skill lives in its own directory with a `SKILL.md` entrypoint. Each source-tree context file
mirrors the repo path it governs under `agents/<repo-path>/context.md`.

Shared archetype profiles live under `agents/archetypes/`. Skills load these profiles as reusable
reasoning lenses, for example `kritikos` for adversarial review or `themis` for contract audit.
Archetypes do not grant tool authority and do not replace skill workflows.

## Provider links

Regenerate provider-specific symlinks with one command per provider:

```bash
just agent-link-codex
just agent-link-claude
just agent-link-opencode
```

`agent-link-codex` links:

- `agents/context.md` -> `AGENTS.md`
- `agents/<repo-path>/context.md` -> `<repo-path>/AGENTS.md`
- `agents/archetypes` -> `.codex/archetypes`
- `agents/skills/<name>` -> `.codex/skills/<name>`

`agent-link-claude` links:

- `agents/context.md` -> `CLAUDE.md`
- `agents/<repo-path>/context.md` -> `<repo-path>/CLAUDE.md`
- `agents/archetypes` -> `.claude/archetypes`
- `agents/skills/<name>/SKILL.md` -> `.claude/commands/<name>.md`

`agent-link-opencode` links:

- `agents/context.md` -> `AGENTS.md`
- `agents/<repo-path>/context.md` -> `<repo-path>/AGENTS.md`
- `agents/archetypes` -> `.opencode/archetypes`
- `agents/skills/<name>` -> `.opencode/skills/<name>`

Gemini-specific files are intentionally not generated. Add a provider only when the repo has a
maintained setup command for it.

## Commit Policy For Agents

Agent tooling may help produce patches, but it must not appear in commit authorship metadata.

- Do not author commits as an LLM or coding agent.
- Do not add `Co-authored-by:` trailers for AI tools.
- Do not mention AI tools as legal commit authors.
- All commits created from agent workflows must use `git commit -s -S`.
- All commits must verify locally before publish.

Human authorship and verifiable signatures are mandatory repository policy, not optional workflow
preferences.

## History Policy For Agents

Treat Git history as a maintained artifact. Rebase-first development is the default for ordinary
feature work: private feature branches may be rebased, squashed, fixed up, or reordered so the
branch reads as a semantic sequence of changes.

- Never force-push `main`.
- Never use raw `git push --force`.
- Use `git push --force-with-lease` only when history was deliberately rewritten and the remote
  still points where you expect.
- Make CI pass after the final rebase.
- Integrate by fast-forwarding `main` to the exact signed branch tip.
- Do not use GitHub's merge, squash, or rebase buttons for Cortex `main`; use
  `just integrate-pr <branch-or-pr-number>` after PR review and CI.
- Use merge commits only when the existence of parallel development lines is itself meaningful.

## Scope

Cortex is a durable runtime substrate plus a structured reasoning library on top (per ADR 0015).
Skills here assume that substrate scope:

- No downstream product or domain-specific knowledge.
- No database migrations, web-UI, or deployment workflows.
- Active Cortex planning uses GitHub Issues and GitHub Pull Requests.
- Build commands go through `just` → `nix`; no direct `cabal` or `ghc`.
- Repo-level docs live flat under `docs/`, not `docs/cortex/`.

Skills that deal in downstream product workflows (external issue trackers, deployment, product soak,
domain-specific tests) are deliberately absent. Downstream products keep their own fuller `agents/`
trees.

## Adding a skill

1. Create `agents/skills/<name>/SKILL.md` with YAML frontmatter (`name`, `description`).
2. Supporting references go under `agents/skills/<name>/references/`.
3. Run the provider link command for the runtime that should expose it.

## Adding an archetype

1. Create `agents/archetypes/<name>.md` with YAML frontmatter (`name`, `description`).
2. Keep the profile provider-neutral: role, stance, questions, output, and failure modes.
3. Reference it from skills by repo-root path, such as `agents/archetypes/<name>.md`.
4. Run the provider link command for the runtime that should expose it.
