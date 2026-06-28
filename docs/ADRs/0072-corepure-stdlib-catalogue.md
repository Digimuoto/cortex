---
title: "ADR 0072 - CorePure Ergonomic Stdlib Catalogue"
description:
  "Records and governs the ergonomic CorePure stdlib batch (list, search, string, record, and option
  builtins) as a closed, total, authority-free extension admitted under ADR 0023's stdlib
  discipline."
sidebar:
  label: "0072. CorePure stdlib catalogue"
  order: 72
status: proposed
date: 2026-06-27
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/pure-execution.md
  - docs/ADRs/0023-corepure-expression-surface.md
  - docs/ADRs/0061-corepure-bounded-iteration-primitives.md
  - docs/ADRs/0020-wire-pure-output-equations.md
---

# ADR 0072 - CorePure Ergonomic Stdlib Catalogue

## Status

Proposed - records the governing decision for the ergonomic stdlib batch, which ADR 0023 left to
"admission discipline" and ADR 0061 explicitly named only to disclaim governing. ADR 0023 remains
canon; this ADR does not edit it. It states that the catalogue is admitted under 0023's existing
discipline and records which members reuse the ADR 0061 index clamp.

## Context

CorePure (ADR 0023) is the closed, total, authority-free expression layer Wire authors use for
JSON-shaped value and report logic. ADR 0023 fixed an intentionally small initial stdlib (`map`,
`filter`, `zipWith`, `sum`, `all`, `any`, `length`, `min`, `max`, `abs`, `clamp`, `concat`,
`toString`, `joinWith`, and the later `toJson`/`fromJson`) and recorded three constraints rather
than a closed final list:

- "The stdlib must remain deliberately small; useful functions will need admission discipline."
- "Future stdlib additions must preserve data-last ordering."
- The surface stays closed, total, and authority-free, with typed deterministic failures.

The ergonomic stdlib work then added a large batch so that real list/string/record report logic
could be written in pure Wire rather than compiled into a Haskell extension. That batch roughly
tripled the builtin surface: the implemented closed environment now lists 49 builtins against the
roughly 18 of the 0023 core (`corePureBuiltinSpecs` in `src/Cortex/Wire/Pure.hs`).

Governance of that batch fell into a gap. ADR 0061 governs only the three value-driven
bounded-iteration primitives (`range`, `fold`, `foldRight`) and their fixed cost cap; it names the
rest of the batch precisely to **disclaim** governing it, stating the "accompanying ergonomic stdlib
(`reverse`, `sort`, `sortBy`, `take`, `drop`, search, string, and record builtins) is _not_ gated by
ADR 0061" because "those iterate finite input structure, exactly the termination class of the
existing `map`/`filter`/`sum`, and need no cap." ADR 0023 set the discipline but predates the batch.
So the ergonomic catalogue is shipped, tested, and documented, yet no ADR records the decision to
admit it. This ADR closes that gap without reopening the 0023 surface decision.

## Decision

Record that the ergonomic stdlib catalogue is admitted into CorePure under ADR 0023's existing
stdlib discipline, and name it as the capability governed by the feature key
`corepure.stdlib_catalogue`. The catalogue is the batch **excluding** the bounded-iteration trio,
which stays governed by ADR 0061. It comprises 28 builtins in five groups, registered in
`corePureBuiltinSpecs` (`src/Cortex/Wire/Pure.hs`):

- **List shape (7):** `reverse`, `sort`, `sortBy`, `take`, `drop`, `enumerate`, `mapIndexed`.
- **List search (5):** `find`, `findIndex`, `contains`, `indexOf`, `count`.
- **String (11):** `split`, `replace`, `substring`, `trim`, `toLower`, `toUpper`, `startsWith`,
  `endsWith`, `strLength`, `lines`, `unlines`.
- **Record (3):** `keys`, `values`, `entries`.
- **Option / null (2):** `withDefault`, `isNull`.

The admission is disciplined, not a relaxation of ADR 0023. Each member satisfies the same
invariants the 0023 core does:

- **Closed and authority-free.** Every member is registered through the `builtin` helper with
  authority `CorePureBuiltinPureValue`, so the `corePureBuiltinAuthorityFree` invariant holds over
  the whole environment and no member receives host authority. The Lean signature mirror in
  `theory/Cortex/Wire/Pure.lean` lists every catalogue member, and `closedBuiltinEnv_authorityFree`
  proves the closed environment carries no authority-bearing entry.
- **Total without a cost cap.** Every member iterates only finite input structure - the same
  termination class as `map`/`filter`/`sum` - so none introduces a value-driven cost vector and none
  is gated by the ADR 0061 cap. The three cap-gated primitives (`range`, `fold`, `foldRight`) are
  deliberately **not** part of this catalogue; their cost is ADR 0061's decision, not this one.
- **Data-last and total over bad input.** Functions intended for pipe use carry their collection or
  string last, preserving the ADR 0023 data-last invariant. `take`, `drop`, and `substring` clamp
  out-of-range indices instead of failing or scanning unboundedly, and they do so by reusing the
  guarded index clamp introduced by ADR 0061: the `boundedIndex` helper unwraps a `ClampedIndex`
  from `Cortex.Wire.Pure.Bounds`, so an out-of-range count cannot escape the valid `[0, length]`
  range. This is the ADR 0061 clamp reused for ordinary catalogue ergonomics, distinct from the
  unrelated numeric `clamp` builtin from ADR 0023.

No new authority class, AST node, parser form, or evaluation budget is added. The catalogue is a
pure extension of the closed builtin table.

## Alternatives considered

- **Fold the catalogue into ADR 0023 as an edit.** Rejected - ADRs are append-only, and 0023's
  "deliberately small" framing was an admission-discipline rule, not a promise of a frozen count.
  Editing 0023 would rewrite a shipped decision rather than record the follow-on one.
- **Extend ADR 0061 to govern the whole batch.** Rejected - 0061 is one decision about a cost cap
  for value-driven iteration, and it deliberately disclaims the rest of the batch. Pulling 28
  cap-free builtins into it would conflate the cost-model decision with the catalogue-admission
  decision.
- **Leave the catalogue ungoverned.** Rejected - it is shipped, tested, and reference-documented
  substrate with no ADR recording why it is admitted, which is exactly the status drift ADR 0063
  made expressible. A `proposed` ADR over `implemented` code is the honest record.

## Consequences

### Positive

- The shipped ergonomic catalogue has a governing decision, so the `corepure.stdlib_catalogue`
  feature-status row can name a governing ADR instead of `pending`.
- Pure Wire can author list/search/string/record report logic without compiling it into a Haskell
  extension, while CorePure stays closed, total, and authority-free.
- The authority-free invariant is mechanically checked: the Haskell `corePureBuiltinAuthorityFree`
  flag and the Lean `closedBuiltinEnv_authorityFree` theorem both range over the catalogue members.

### Negative

- A larger closed surface is more to keep synchronized: every new member must be added to
  `corePureBuiltinSpecs`, the two `PureSpec` golden signature/authority lists, and the Lean
  signature mirror, or the cross-checks fail.
- A bigger stdlib raises the authoring surface area Wire readers must learn, the cost ADR 0023's
  "deliberately small" caution was guarding against. The discipline now lives in this ADR's
  admission criteria rather than in a fixed count.

### Obligations

- Any further CorePure stdlib member must meet the admission criteria above (closed, authority-free,
  total over finite input structure or explicitly capped, data-last) and either fall under this
  catalogue or carry its own governing ADR if it introduces a new cost vector.
- Keep the Haskell `corePureBuiltinSpecs`, the `PureSpec` golden lists, and the Lean signature
  mirror in sync; the existing signature-equality and authority-free checks enforce this.
- `docs/Reference/Wire/pure-execution.md` stays the authored catalogue and failure-surface
  reference.

## Traceability

- Feature keys: `corepure.stdlib_catalogue`
- Public surface: `Cortex.Wire`, `docs/Reference/Wire/pure-execution.md`
- Implementation: `src/Cortex/Wire/Pure.hs` (`corePureBuiltinSpecs`, `boundedIndex`),
  `src/Cortex/Wire/Pure/Bounds.hs` (`ClampedIndex`, `clampIndex`)
- Tests: `test/Cortex/Wire/PureSpec.hs`
- Theory/proof: [CorePure builtin authority](../Reference/proof-status.md) - the closed-builtin
  signature mirror and `closedBuiltinEnv_authorityFree` theorem range over the catalogue; no
  catalogue-specific termination theorem is required, since every member iterates finite input
  structure.

## Related

- [0023 - CorePure Expression Surface](0023-corepure-expression-surface.md) - the closed surface and
  the "deliberately small / admission discipline" rule this catalogue is admitted under.
- [0061 - CorePure Bounded Iteration Primitives](0061-corepure-bounded-iteration-primitives.md) -
  governs the cap-gated `range`/`fold`/`foldRight` trio and disclaims the ergonomic batch; this ADR
  records that batch and reuses 0061's `ClampedIndex` clamp.
- [0020 - Wire Pure Output Equations](0020-wire-pure-output-equations.md) - the typed deterministic
  failure principle the catalogue's clamping and errors follow.
- [Wire Reference - Pure Execution](../Reference/Wire/pure-execution.md) - the authored builtin
  catalogue and failure surface.
- [Chapter 05 - Wire Language](../Architecture/05-wire-language.md) - where CorePure sits in the
  Wire layer.

## Tracking

- #295 — ergonomic CorePure stdlib batch.
