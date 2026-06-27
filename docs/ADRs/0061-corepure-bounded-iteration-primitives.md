---
title: "ADR 0061 - CorePure Bounded Iteration Primitives"
description:
  "Admits range, fold, and foldRight into CorePure as total primitives bounded by a fixed
  deterministic cap, refining the fold deferral in ADR 0020 and ADR 0023."
sidebar:
  label: "0061. CorePure bounded iteration"
  order: 61
status: proposed
date: 2026-06-26
superseded_by: null
related:
  - docs/Reference/Wire/pure-execution.md
  - docs/ADRs/0020-wire-pure-output-equations.md
  - docs/ADRs/0023-corepure-expression-surface.md
  - docs/ADRs/0050-wire-corepure-output-residue.md
  - docs/ADRs/0056-admission-modes-witnessed-and-gas.md
  - "GitHub #295"
  - "GitHub #301"
---

# ADR 0061 - CorePure Bounded Iteration Primitives

## Status

Proposed - refines the `fold` deferral in ADR 0020 and ADR 0023. Those ADRs remain canon; this ADR
narrows when reduction and finite generation are admitted into CorePure. It does not edit them.

## Context

CorePure (ADR 0023) is the closed, total, authority-free expression layer Wire authors use for
JSON-shaped report and value logic. Its builtin set already iterates finite input structure (`map`,
`filter`, `sum`, `zipWith`, `all`, `any`), but it has no general reducer and no way to generate a
finite sequence from a count. Without those, real list/string report logic — the kind that currently
forces a Haskell extension such as `Cortex.Quantum.Qec.renderReport` — cannot be written in pure
Wire (issue #295).

Two earlier decisions gated exactly these primitives:

- ADR 0023 disallows "unbounded `fold`" and states `fold` "can be reconsidered only after budget
  accounting is solid enough to state its cost model".
- ADR 0020 lists "unbounded `fold`" out of scope and records that "budget exhaustion is a typed
  evaluator error", with "bounded `fold` after budget accounting is tested" as future work.

The gate is about _cost_, not termination. A list-driven `fold` always terminates, but a general
accumulator function can grow the accumulator super-linearly (a step that doubles its input reaches
`2^n` after `n` elements), and `range(0, N)` materialises `N` elements from a scalar argument. Both
turn a small input into unbounded work. Meanwhile ADR 0056 deliberately keeps CorePure budget-free:
its gas account governs rewrite and Pulse-iteration admission, and "no fourth budget is introduced"
for CorePure, which "stays total".

So the open question is narrow: how can `fold`/`range` be admitted while keeping CorePure total and
without introducing the operator-tunable budget ADR 0056 declined.

## Decision

Admit three bounded-iteration builtins into the closed CorePure environment, each a total
`CorePureBuiltinPureValue` on the existing builtin-call path (no AST or parser change):

- `range(start, end)` - the half-open integer sequence `[start, end)`;
- `fold(f, init, list)` - left reduction, `f acc item`;
- `foldRight(f, init, list)` - right reduction, `f item acc`.

Their cost is bounded by a single **fixed deterministic cap**, `corePureBoundedIterationCap`, a
compile-time constant in the evaluator. It is a _totality guard_, not a budget: it is not authored,
not configured, and not operator-tunable, so it does not reintroduce the gas account ADR 0056 keeps
out of CorePure. Exhausting it is a typed evaluator failure, `PureBoundExceeded`, consistent with
ADR 0020's "budget exhaustion is a typed evaluator error".

The cap binds the two cost vectors that argument _values_ (not input _structure_) control:

- `range` rejects when `end - start` exceeds the cap (`PureBoundExceeded "range span"`);
- `fold`/`foldRight` reject when the running accumulator exceeds the cap measured as value cost -
  one per JSON node plus string lengths, number magnitudes, and object key lengths, so structural
  nesting, string concatenation, numeric growth, and key growth are all caught
  (`PureBoundExceeded "fold accumulator"`). The seed is guarded before the loop and a
  function-valued accumulator is rejected, so the accumulator is always a within-cap JSON value. The
  guard short-circuits, so it stays bounded itself.

CorePure therefore stays total: every admitted program either produces a value or fails with a typed
error in bounded work. This satisfies the ADR 0023 cost-model precondition by stating the cost model
explicitly (a fixed node/element ceiling) rather than deferring to an accounting system.

The accompanying ergonomic stdlib (issue #295 batch 1: `reverse`, `sort`, `sortBy`, `take`, `drop`,
search, string, and record builtins) is _not_ gated by this ADR. Those iterate finite input
structure, exactly the termination class of the existing `map`/`filter`/`sum`, and need no cap.

`sortBy(keyFn, list)` is admitted: it sorts by a deterministic key projection under a fixed total
order over JSON values, so it is not the "sort with user comparators" ADR 0023 defers. A free
comparator form (`sortWith(cmp, list)`) remains deferred, because a user comparator can be non-total
or inconsistent and would make the sort result undefined.

## Alternatives considered

- **A global evaluation fuel counter threaded through the whole evaluator.** A per-reduction step
  budget would bound all CorePure cost uniformly, including the fold accumulator pathology. Rejected
  for this change: it is an evaluator-wide refactor of a hot path and its fast paths for a problem
  with only two new unbounded vectors, and a per-step _count_ edges closer to the tunable budget ADR
  0056 excludes than a fixed structural ceiling does. The cap can be promoted to a fuel model later
  without changing the authored surface.
- **Admit `fold`/`range` with structural bounds only and no cap.** Simplest, but leaves the
  documented super-linear-accumulator and scalar-driven-`range` holes open, contradicting the ADR
  0023 cost-model precondition. Rejected.
- **Keep `fold`/`range` deferred and ship only the ungated stdlib.** Delivers most of the list and
  string ergonomics, but leaves Wire unable to reduce to a custom accumulator or generate a sequence
  from a count - the structural gap issue #295 set out to close. Rejected.

## Consequences

### Positive

- Pure Wire can author general list/string/record report logic end to end, including reduction and
  finite generation, removing the need to compile that logic into a Haskell extension.
- CorePure stays total and authority-free; the new failure mode is typed and deterministic.
- The cost model is stated, not deferred, satisfying the ADR 0023 precondition with a single legible
  constant.
- The policy is enforced by a typed boundary module (`Cortex.Wire.Pure.Bounds`) whose result types
  (`FoldAccumulator`, `ClampedIndex`, `RangePlan`, `CostCheck`) have hidden constructors and are
  only built through smart constructors that apply the cap. The bounded-iteration builtins cannot
  iterate from an unguarded seed or step result, narrow a range before the span decision, or compare
  a raw cost count incorrectly, and the policy cannot be re-derived with ad-hoc conditionals at each
  call site. QuickCheck properties back the invariants.

### Negative

- A fixed cap can reject a legitimately large in-memory computation; the bound is a constant, not
  tunable per run. CorePure is intentionally not the place for very large iteration - that is
  Pulse-admitted bounded iteration (ADR 0055).
- The fold accumulator guard measures value cost each step, a small constant-factor overhead on
  reduction.
- **The cap is per-operation, not a global allocation budget.** It bounds each `range` span and each
  `fold`/`foldRight` accumulator. It does not bound the combined cost of composed or nested
  expressions: a `range` may generate a cap-sized array that `map`/`enumerate`/`split`/`replace`
  then amplifies by a constant factor, and nesting a generator inside `map` (for example
  `range 0 n |> map (i: range 0 n)`) multiplies costs and can allocate a large intermediate before
  any single operation trips. These are bounded but can be large; for an authored expression they
  are a footgun, not a data-driven amplification (data-derived `range`/`fold` are themselves
  capped). A true total-allocation bound is a global cost budget, deferred as the fuel-model work
  below and tracked in GitHub #301.

### Obligations

- The Lean proof-side closed-builtin signature mirror (`theory/Cortex/Wire/Pure.lean`) tracks the
  Haskell `corePureBuiltinSignature`; both list the new builtins. No new termination theorem is
  required because every builtin is total and the cap bounds cost.
- `docs/Reference/Wire/pure-execution.md` documents the new builtins, the cap, and the
  `PureBoundExceeded` failure.
- If CorePure later needs a total-allocation bound across composed expressions, or tunable or larger
  iteration, promote the fixed per-operation cap to a stated global fuel model rather than widening
  it silently. Tracked in GitHub #301.

## Traceability

- Feature keys: `corepure.bounded_iteration`
- Public surface: `Cortex.Wire`,
  [`docs/Reference/Wire/pure-execution.md`](../Reference/Wire/pure-execution.md)
- Implementation: `src/Cortex/Wire/Pure/Bounds.hs` (`IterationCap`, `corePureBoundedIterationCap`,
  `FoldAccumulator`, `mkFoldAccumulator`, `RangePlan`, `planRange`, `checkValueCost`,
  `ClampedIndex`), `src/Cortex/Wire/Pure.hs` (`corePureRange`, `corePureFold`, `corePureFoldRight`,
  `foldAccumulatorOf`)
- Tests: `test/Cortex/Wire/PureSpec.hs`
  (`batch 1 list, string, record, and bounded-iteration builtins`: range/fold/foldRight, cap
  exhaustion, accumulator/range overflow, function-accumulator rejection;
  `Cortex.Wire.Pure.Bounds typed boundary`)
- Theory/proof:
  [the CorePure builtin-authority signature-mirror row — `proof-status.md`](../Reference/proof-status.md#matrix)
  (`range`/`fold`/`foldRight` mirrored in `theory/Cortex/Wire/Pure.lean`)
- Tracking: GitHub #295

## Related

- [0020 - Wire Pure Output Equations](0020-wire-pure-output-equations.md) - original `fold` deferral
  and the typed-budget-exhaustion principle.
- [0023 - CorePure Expression Surface](0023-corepure-expression-surface.md) - the closed surface and
  the cost-model precondition this ADR satisfies.
- [0050 - Wire CorePure Output Residue](0050-wire-corepure-output-residue.md) - CorePure stays total
  and non-recursive.
- [0056 - Admission Modes: Witnessed Materialization and Open Rewrite Gas](0056-admission-modes-witnessed-and-gas.md)
  - CorePure introduces no tunable budget; the cap here is a totality guard, not gas.
- [Wire Reference - Pure Execution](../Reference/Wire/pure-execution.md) - builtin catalogue and
  failure surface.
