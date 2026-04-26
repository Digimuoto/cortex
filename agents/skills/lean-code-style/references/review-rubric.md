# Lean Review Rubric

Use this rubric for Cortex Lean 4 code. The score is secondary; the
priority findings are what matter.

## Priority Levels

**[P1] Block merge**

- New `sorry`, `admit`, `axiom`, `constant`, `unsafe`, or `partial`
  outside a deliberately tracked scaffold.
- A proof that depends on an invalid theorem statement, over-generalized
  precondition, missing side condition, or false simplification lemma.
- A `simp` attribute or theorem orientation that can loop, erase
  information, or make downstream proofs unstable.
- A broad linter suppression, `autoImplicit`, or namespace/import change
  that hides real proof debt.
- A theorem whose trusted base grows unintentionally through new axioms,
  global classical reasoning, or opaque dependencies.
- A build-file change that makes local Lake, Nix, or CI disagree about
  Lean/mathlib versions.

**[P2] Must address or explicitly track**

- Heavy automation where the proof boundary is opaque and likely to
  break under harmless import or simp-set changes.
- Missing explicit argument or result types on public definitions.
- Public declarations without docstrings or unclear theorem names.
- Unnecessary classical scope, global `open`, or broad variable scope.
- Non-minimal imports, unpinned dependency changes, or generated
  manifest drift without an intentional Lake change.
- Local definitions or lemmas that duplicate mature `Std`/`Mathlib`
  abstractions and make later proofs less compatible with the ecosystem.
- Theorem APIs that are hard to rewrite with: wrong orientation,
  avoidable anonymous binders, or hypotheses buried right of `:`.

**[style] Local cleanup**

- Indentation, line wrapping, naming, short comments, duplicate namespace
  names, or cosmetic proof simplifications.
- Small opportunities to use a clearer local lemma, `simp only`, or
  `rfl`/`simpa` instead of a longer tactic block.

## Scoring

Start each file at 10 and subtract:

- 5 for each P1.
- 2 for each P2.
- 0.5 for each repeated style issue.

Do not let a file with any P1 score above 5. Do not let a file with new
untracked proof debt score above 6.

## Review Axes

### Soundness

The theorem states exactly the intended property. All side conditions
are explicit. Definitions do not smuggle assumptions through typeclass
search, `Classical`, impossible branches, or unreviewed attributes.

Review exported theorems for trusted-base drift. When the change claims
to discharge scaffold debt or reduce assumptions, inspect theorem
dependencies with Lean's axiom reporting tools and make sure the result
actually depends on less than before.

### Proof Robustness

Proof scripts should survive benign import ordering and simp-set changes.
Prefer small lemmas, stable rewrites, and explicit local reasoning over
large tactic blasts.

### API Shape

Names, namespaces, theorem direction, and attributes should make the
next proof easier. A theorem that compiles but cannot be reused cleanly
is not finished.

### Readability

Reviewers should be able to follow the proof state transitions from the
source. Use comments only for proof strategy or non-obvious mathematical
intent.

### Build Integrity

The Lean toolchain, Lake manifest, and Nix packaging must describe the
same dependency story. CI must run the same proof surface the developer
expects locally.

External dependencies are welcome when they replace brittle local proof
work with maintained theory, but every dependency must be pinned through
Lake/Nix and have a clear proof-level reason to exist.
