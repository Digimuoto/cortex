# Lean Proof Patterns

This file defines Cortex's standard for robust Lean proofs.

## Axiom And Sorry Policy

- New mechanization work should reduce the axiom surface.
- A new `axiom` is allowed only in an explicit scaffold file and only
  when the corresponding proof obligation is listed in `theory/README.md`.
- Never replace a hard proof with `sorry`, `admit`, `axiom`, or
  `constant` to make CI pass.
- If a theorem is intentionally postponed, name the obligation precisely
  and document the semantic gap.

## Tactic Discipline

Use tactics as transparent proof construction, not as an opaque search
button.

Prefer:

- `rfl`, `exact`, `refine`, `constructor`, `cases`, `induction`,
  `simp only`, `simpa only`, and short `calc` blocks.
- Small helper lemmas with reusable names.
- Explicit `rw` lists when the rewrite sequence is the point of the
  proof.
- `simp [local_def]` for definitional closure over local definitions.

Use cautiously:

- `simp_all`: acceptable in throwaway local proof cleanup, suspicious in
  exported theorems because it rewrites from the entire context.
- `aesop`, `omega`, `linarith`, `ring_nf`, `norm_num`, `tauto`: useful
  when the theorem is exactly in their domain and the surrounding proof
  isolates their job.
- Repeated `<;>` chains: fine for tiny symmetric goals, but split goals
  explicitly when each side has semantic content.

Avoid:

- Broad `simp` relying on a large imported simp set when `simp only`
  would be stable.
- `first | ...` tactic search ladders in public proofs.
- Proofs that succeed only because a transient hypothesis has a lucky
  generated name.

## External Library Use

Prefer robust maintained theory over bespoke local proof infrastructure.

- Look first in `Std` and `Mathlib` for algebraic structures, orders,
  finite sets/maps, relations, quotients, graph-adjacent abstractions,
  well-founded recursion, arithmetic, and rewrite support.
- Import the narrowest module that provides the needed theorem or
  structure. Do not import broad namespaces to make search tactics
  succeed.
- Use library theorem names directly when they express the proof idea.
  Wrap them only when Cortex needs a domain-specific statement,
  orientation, or namespace.
- Do not build a local abstraction merely to avoid learning an existing
  one. A smaller proof today is not a win if it isolates Cortex from
  the maintained Lean ecosystem.
- Add new Lake dependencies only when they materially reduce proof risk
  or replace a fragile local development path. Pin them through the same
  toolchain path as the rest of `theory/`.

## Simp Rules

Before adding `@[simp]`, answer:

1. Does this rewrite reduce to a canonical form?
2. Can it loop with existing simp rules?
3. Does it erase information a downstream proof may need?
4. Is the theorem name and orientation obvious from the statement?

If any answer is unclear, do not add `@[simp]`. Use the theorem
explicitly with `rw` or `simp [theorem_name]`.

## Attributes And Instances

- Keep attributes near declarations.
- Avoid global attributes for local proof convenience.
- Named instances should follow local Lean conventions and expose the
  class being implemented in the name when ambiguity is possible.
- Do not add an instance merely to make a single proof shorter if it
  changes global typeclass search for downstream modules.

## Pattern Matching

- Pattern-match owned inductives explicitly when the constructor set is
  semantically meaningful.
- A wildcard branch is allowed only when all remaining constructors have
  the same meaning and that meaning is obvious from the function name.
- In proofs, avoid `_` branches that hide which cases were discharged.

## Definitional Equality

- Use `rfl` when the definition truly computes to the target.
- Do not contort definitions solely to make one proof `rfl` if it harms
  the model's semantic shape.
- Prefer theorem-level simplification over changing a domain definition
  to satisfy a local proof.

## Classical And Decidability

- Prefer constructive definitions and explicit decidability assumptions.
- Use local `classical` for proofs that need choice or decidable
  propositions.
- If a data structure such as `Finset` requires `[DecidableEq α]`, keep
  that assumption explicit in declarations that need it and out of
  declarations that do not.

## Proof Factoring

Factor when:

- a tactic block is longer than roughly 15 lines,
- the same rewrite pattern appears twice,
- a local `have` names a reusable concept,
- a proof mixes domain reasoning and algebraic cleanup.

Do not factor into names like `aux`, `helper`, or `foo'` unless the
result is private and adjacent. Good helper names describe the fact.
