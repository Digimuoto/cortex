---
name: lean-theorem-attack
description: >
  Adversarial semantic review for Lean theorem statements and proof
  models. Use when asked to attack a theorem, validate runtime
  correspondence, check model soundness, or run a multi-archetype Lean
  review beyond ordinary proof style.
---

# Lean Theorem Attack

Review Lean as a model of the intended substrate contract, not merely as
code that compiles. This skill complements `lean-code-style`: style
checks proof hygiene, while theorem attack checks whether the formal
model is strong enough to support the prose claim.

## Usage

```bash
/lean-theorem-attack [target...]
/lean-theorem-attack --base main theory/Cortex/Pulse
/lean-theorem-attack --multi-agent theory/Cortex/Pulse/Recovery.lean
```

Arguments:

- No arguments: review changed Lean/theory files in the current branch
  against `main`.
- `--base <branch>`: review against another base.
- `--multi-agent`: when the runtime supports subagents and the user has
  explicitly requested multi-agent work, run archetype passes in
  parallel. Otherwise run the same passes sequentially.
- File paths: review those files.
- Directory paths: review `.lean` and theory build files under them.

By default this is a review skill. Apply fixes only when the user asks
for fixes or when the active task is explicitly an implementation task.

## Shared Archetypes

Load these profiles from repo-root paths:

- `agents/archetypes/logos.md`
- `agents/archetypes/episteme.md`
- `agents/archetypes/kritikos.md`
- `agents/archetypes/themis.md`
- `agents/archetypes/techne.md`
- `agents/archetypes/poiesis.md`
- `agents/archetypes/sophia.md`

The skill remains the orchestrator. Archetypes are lenses, not
independent authority to expand scope or edit files.

## References

Read only the references needed for the target:

- `references/model-soundness.md`
- `references/countermodel-patterns.md`
- `references/pulse-runtime-correspondence.md` when reviewing
  `Cortex.Pulse.*`.
- `templates/theorem-attack-report.md` for report shape.

Also load `agents/skills/lean-code-style/SKILL.md` when proof hygiene,
imports, tactics, rendered Theory pages, or validation commands are in
scope.

## Workflow

### 1. Determine Scope

If explicit files or directories are provided, expand directories to:

```bash
rg --files "$DIR" | rg '(^theory/.*\.lean$|^theory/lakefile\.lean$|^theory/lean-toolchain$|^theory/lake-manifest\.json$|^nix/lean\.nix$)'
```

If no files are provided, use branch-diff mode:

```bash
BASE="${BASE:-main}"
git diff --name-only "$BASE"...HEAD -- \
  'theory/**/*.lean' \
  'theory/lakefile.lean' \
  'theory/lean-toolchain' \
  'theory/lake-manifest.json' \
  'nix/lean.nix'
```

If there is no Lean/theory scope, say so directly.

### 2. Build Theorem Dossiers

For each reviewed theorem, definition, invariant, or structure:

1. Quote or summarize the prose claim from module docs, theorem
   docstrings, PR text, issue text, or surrounding architecture docs.
2. Identify the formal declarations intended to carry that claim.
3. List every free relation, total function, status constructor,
   predicate field, and domain set in those declarations.
4. Identify the executable or documented runtime counterpart, if any.
5. Record what the theorem proves, what it assumes, and what remains
   outside the model.

### 3. Run Mechanical Checks

Reuse the `lean-code-style` checks:

```bash
rg -n '\b(sorry|admit|axiom|constant|unsafe|partial)\b|set_option\s+linter\.[A-Za-z0-9_.]+\s+false|set_option\s+autoImplicit\s+true' $FILES
rg -n '\bsimp_all\b|\baesop\b|\bomega\b|\blinarith\b|\bring_nf\b|\bnorm_num\b|\btauto\b' $FILES
rg -n '\|[[:space:]]*_[[:space:]]*=>' $FILES
```

Mechanical checks are not enough. Continue with the semantic passes.

### 4. Run Archetype Passes

Run these passes in this order when working sequentially:

| Pass | Archetype | Required output |
|---|---|---|
| Statement map | Logos | Formal claim, assumptions, quantifiers, theorem boundary |
| Evidence map | Episteme | Runtime/docs/source correspondence and evidence gaps |
| Countermodel search | Kritikos | Minimal models that satisfy hypotheses but violate intent |
| Contract audit | Themis | Validity/invariant coverage matrix |
| Repair sketch | Techne | Smallest plausible encoding or proof repair |
| Alternative encodings | Poiesis | Type-level, predicate-level, and theorem-boundary options |
| Synthesis | Sophia | Prioritized findings and readiness judgment |

In `--multi-agent` mode, spawn subagents only when the user explicitly
asked for multi-agent or parallel agent work. Give each subagent one
archetype pass, a bounded target, and read-only instructions unless a
fix task was explicitly requested. Merge their outputs; do not paste raw
transcripts.

### 5. Attack The Model

Apply the semantic checks from `references/model-soundness.md` and
`references/countermodel-patterns.md`.

Always ask:

- Can an arbitrary relation, function, or predicate satisfy the formal
  assumptions while violating the intended runtime graph?
- Are all endpoints, keys, statuses, outputs, and recovered-state facts
  tied to the topology domain?
- Does every validity predicate include the full recovery or safety
  contract it is named for?
- Does the theorem prove preservation of the desired property or merely
  restate a definition?
- Could an off-domain, stale, missing, duplicated, or impossible value
  pass the current predicate?

### 6. Report

Use this shape:

```markdown
## Lean Theorem Attack: <target>

**Overall:** <one-sentence judgment>
**Mode:** sequential | multi-agent
**Files reviewed:** <N>

### Findings

- [P1] <soundness/model gap> - <file>:<line>
- [P2] <contract coverage/runtime correspondence gap> - <file>:<line>

### Archetype Passes

| Pass | Result |
|---|---|
| Logos | ... |
| Episteme | ... |
| Kritikos | ... |
| Themis | ... |
| Techne | ... |
| Poiesis | ... |
| Sophia | ... |

### Coverage Matrix

| Runtime/prose obligation | Lean declaration | Preserved/proved by | Status |
|---|---|---|---|

### Top Priorities

1. <most important fix>
2. <second>
3. <third>
```

If no issues are found, say so directly and state residual risk.

### 7. Fix Mode

When the user asks for fixes:

1. Prefer strengthening definitions or theorem statements over adding
   ad hoc assumptions to a downstream proof.
2. Make illegal states unrepresentable when the codebase can bear the
   proof cost; otherwise add explicit named domain predicates.
3. Add preservation lemmas for any invariant added to a validity
   predicate.
4. Rerun relevant Lean validation, usually:

```bash
just lean-build
just lean-check
```

Use Nix-wrapped commands when the local environment requires them.
