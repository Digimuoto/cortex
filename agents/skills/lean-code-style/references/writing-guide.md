# Lean Writing Guide

Use this guide when writing or reviewing Lean declarations in Cortex.
It adapts good ideas from Lean/mathlib community style and CS teaching
style, but Cortex is stricter about long-lived proof maintainability.

## Module Shape

- Keep imports minimal. Every import must justify itself by declarations
  used in the file.
- Keep imports grouped and sorted when there is more than one logical
  group. Avoid importing all of Mathlib unless the file is intentionally
  exploratory.
- Preserve the repository's current module-header style unless the
  change is explicitly about header policy. Do not churn headers merely
  to imitate mathlib.
- Each proof module needs a top-level description stating:
  - what structure is modeled,
  - which results are real theorems,
  - which obligations remain,
  - which executable modules or papers it mirrors.
- Theory modules are rendered into the docs site through Verso. Write
  module prose as public documentation, not as scratch notes: introduce
  the mathematical object, name the proof boundary, and keep the section
  order readable when viewed as a book page.

## Namespaces

- Put declarations in the smallest meaningful namespace.
- Avoid duplicated fully qualified names such as
  `Cortex.Graph.Graph.foo` unless matching an existing local convention.
  If a duplicate is intentional, keep any linter suppression local and
  document why.
- Avoid broad `open` commands. Use qualified names when they make proof
  dependencies clearer.
- Avoid global `open Classical`. Prefer explicit `[DecidableEq α]`,
  local `classical`, or `noncomputable section` when needed.

## Declarations

- Public `def`, `abbrev`, `structure`, `inductive`, `class`,
  `instance`, `theorem`, and `lemma` declarations need explicit result
  types.
- Public structures and fields need docstrings. Fields should describe
  the invariant or semantic role, not restate the name.
- Prefer named records and structures when adjacent arguments have the
  same type or when a theorem statement becomes swap-prone.
- Use `where` for structures and instances. Avoid large anonymous record
  literals when field names carry meaning.
- Use `theorem` for exported proof API. Use `lemma` for local support
  facts if the file already follows that convention; otherwise match
  local style.

## Variable Scope

- Keep `variable` blocks close to the declarations that need them.
- Split variables so typeclass assumptions are not in scope for
  declarations that do not use them.
- Prefer `omit [Foo α] in theorem ...` over suppressing
  `unusedSectionVars`.
- Do not rely on `autoImplicit`. Declare every type, value, relation,
  and hypothesis intentionally.

## Naming

- Use Lean-style lower snake case for theorem and definition names.
- Names should encode the main head symbols and theorem direction:
  `foo_empty_left`, `map_overlay`, `denote_connect_decomposition`.
- Hypotheses start with `h` and should be mnemonic:
  `hReady`, `hDeps`, `hij`, `hmem`, `hterminal`.
- Induction hypotheses start with `ih`.
- Avoid shadowing. If an infoview would show daggered variables, rename
  the local binder.
- Avoid names like `this` in long proofs except for a one-line local
  bridge that is consumed immediately.

## Statement Shape

- Put hypotheses to the left of the colon when the proof starts by
  introducing them.
- Keep theorem parameters explicit, especially typeclass assumptions and
  decidability requirements.
- Orient equalities for rewriting from complex/source expression to
  simpler/canonical expression.
- If a theorem is intended as a simp rule, its statement must be a stable
  normalization rule.

## Formatting

- Target 100 columns.
- Put `:= by` at the end of the theorem statement line or final
  continuation line; do not put `by` alone on its own line.
- Indent theorem continuation lines by four spaces and proof bodies by
  two spaces.
- Use focused bullets `·` for generated goals. Do not leave goal changes
  visually implicit.
- Keep parentheses with their argument. Do not orphan closing syntax on
  unrelated lines.

## Comments

- Use docstrings for public API.
- Public theorem docstrings should say why the result matters to the
  substrate contract, not merely paraphrase the formal statement.
- Use ordinary comments only for proof strategy, model limitations, or
  non-obvious correspondence to Haskell/docs.
- Delete comments that narrate tactics or restate code.
