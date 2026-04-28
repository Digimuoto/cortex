---
name: lean-code-style
description: >
  Strict Lean 4 review and authoring guide for Cortex theory work. Use when asked to review Lean,
  check proof style, write or edit .lean files, mechanize axioms, refactor proofs, evaluate
  mathlib/tactic usage, or assess theory/lake/Nix changes for correctness, maintainability, and
  proof robustness.
---

# IRONCLAD Lean Code Style

Review or write Lean 4 code as a proof artifact, not as executable notation that happens to compile.
The standard is intentionally stricter than generic Lean style: Cortex proofs must be stable,
explicit, well-named, and easy to audit months later.

## Usage

```
/lean-code-style [target...]
```

Arguments:

- No arguments: review changed Lean/theory files in the current branch against `main`.
- `--base <branch>`: review the branch diff against another base.
- File paths: review those files.
- Directory paths: review `.lean` and theory build files under them.

Examples:

```bash
/lean-code-style
/lean-code-style --base main theory/Cortex/Graph
/lean-code-style theory/Cortex/Pulse/Frontier.lean
```

In authoring mode, apply the same rules while editing Lean code. Do not wait for review to enforce
them.

## IRONCLAD Standard

- No untracked trusted-base expansion.
- No proof debt hidden behind automation, wildcard cases, or linter suppression.
- No local reinvention of mature `Std` or `Mathlib` theory when a robust external library supplies
  the right abstraction.
- No theorem statement that proves an artifact of the encoding instead of the intended model.
- No public proof API that compiles today but is hard to reuse tomorrow.

## Workflow

### 1. Determine Scope

If explicit files or directories are given, expand directories to:

```bash
rg --files "$DIR" | rg '(^theory/.*\.lean$|^theory/lakefile\.lean$|^theory/lean-toolchain$|^theory/lake-manifest\.json$|^nix/lean\.nix$)'
```

If no files are given, use branch-diff mode:

```bash
BASE="${BASE:-main}"
git diff --name-only "$BASE"...HEAD -- \
  'theory/**/*.lean' \
  'theory/lakefile.lean' \
  'theory/lean-toolchain' \
  'theory/lake-manifest.json' \
  'nix/lean.nix'
```

If no theory files are found, report that there is no Lean/theory scope to review and exit.

### 2. Run Mechanical Checks

Run these before manual review:

```bash
just lean-lint
rg -n '\b(sorry|admit|axiom|constant|unsafe|partial)\b|set_option\s+linter\.[A-Za-z0-9_.]+\s+false|set_option\s+autoImplicit\s+true' $FILES
rg -n '\bsimp_all\b|\baesop\b|\bomega\b|\blinarith\b|\bring_nf\b|\bnorm_num\b|\btauto\b' $FILES
rg -n '\|[[:space:]]*_[[:space:]]*=>' $FILES
```

Interpret results manually:

- `just lean-lint` is the CI-enforced mechanical gate. It strips Lean comments and strings before
  rejecting trusted-base/debt keywords, linter suppressions, `autoImplicit true`, wildcard match
  arms, overlong Lean lines, trailing whitespace, and missing umbrella/root imports. A failure is
  **[P1]** unless the user explicitly scoped the turn to changing the gate itself.
- New `sorry`, `admit`, `axiom`, `constant`, `unsafe`, or `partial` in executable Lean code is not
  allowed. Do not normalize new scaffold debt.
- New linter suppression is not allowed. Prefer fixing the code or using local `omit`, namespaces,
  or proof restructuring.
- Heavy automation and wildcard patterns are review triggers, not automatic failures. They must have
  a small, stable proof surface.

### 3. Load References

Read these reference files before giving a substantive review:

- `references/review-rubric.md`: scoring and priority levels.
- `references/writing-guide.md`: declarations, names, imports, docstrings, theorem statements, and
  proof style.
- `references/proof-patterns.md`: tactics, simp discipline, automation, theorem API shape, and axiom
  policy.
- `references/theory-architecture.md`: Cortex-specific Lean track boundaries, validation commands,
  and build-file expectations.

### 4. Read the Code

In branch-diff mode, read the diff first:

```bash
git diff "$BASE"...HEAD -- "$FILE"
```

Then read the full current file. Lean review cannot be done from a small hunk alone because variable
scopes, namespace shape, imports, attributes, and local notation alter proof meaning.

In explicit-target mode, review the whole target file or directory.

### 5. Review

Apply the rubric and make findings concrete. Prioritize:

- Logical soundness and trusted-kernel hygiene.
- Explicit theorem statements and stable proof scripts.
- Minimal imports and correct dependency management.
- Namespace/API shape suitable for later theorem reuse.
- `simp`/attribute discipline.
- Rendered Theory page quality: each Lean file should read as a standalone Markdown-backed theorem
  note with useful `/-! ... -/` prose and sectioning where needed.
- Elimination of scaffold debt rather than normalization of new debt.
- Validation through both Lake and Nix where relevant.

Treat "compiles" as the floor. A proof can compile and still be too fragile, too implicit, or too
opaque for Cortex.

### 6. Report

Use this shape:

```markdown
## Lean Style Review: <branch> vs <base>

**Files reviewed:** N **Overall:** one-sentence assessment

### <filename>

**Score:** X/10

**Findings:**

- [P1] <correctness/soundness issue> - line N
- [P2] <robustness/API/architecture issue> - line N
- [style] <local cleanup> - line N

**Good:**

- <specific strong choice>

### Summary

| File | Score | Key Issue |
| ---- | ----: | --------- |
| ...  |  X/10 | ...       |

**Top priorities:**

1. <most important fix>
2. <second>
3. <third>
```

If there are no findings, say so directly and state any residual risk or test gap.

### 7. Offer Fixes

After review, ask whether to apply findings. When the user asks for fixes, edit narrowly and rerun
validation. Prefer proving a smaller lemma or improving theorem shape over adding automation until
the error goes away.
