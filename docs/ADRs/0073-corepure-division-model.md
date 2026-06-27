---
title: "ADR 0073 — CorePure Division Number Model: Finite Float64 and Non-Finite Rejection"
description:
  "CorePure division alone leaves the exact-decimal number domain: it evaluates in finite Float64
  and rejects non-finite results with a dedicated error distinct from divide-by-zero."
sidebar:
  label: "0073. CorePure division model"
  order: 73
status: proposed
date: 2026-06-27
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/pure-execution.md
  - docs/ADRs/0020-wire-pure-output-equations.md
  - docs/ADRs/0023-corepure-expression-surface.md
  - "GitHub #304"
---

# ADR 0073 — CorePure Division Number Model: Finite Float64 and Non-Finite Rejection

## Status

Proposed — records the number model already implemented for the CorePure `/` operator. The decision
is shipped substrate behavior; capability state is tracked in
[`feature-status.md`](../Reference/feature-status.md) under `corepure.division_model`.

## Context

CorePure is the closed, authority-free expression language from
[ADR 0023](./0023-corepure-expression-surface.md). It carries numbers as JSON values, which means a
CorePure number is an arbitrary-precision decimal (`Scientific`, the payload of `Aeson.Number`). The
non-division arithmetic operators stay inside that exact-decimal domain: `+`, `-`, and `*` are
evaluated directly on `Scientific` and lose no precision.

Division does not fit the same shape. An exact-decimal quotient does not exist in general — `1 / 3`
has no terminating decimal expansion, and constructing it as a `Scientific` forces a non-terminating
decimal expansion rather than a finite value. So division must choose a representable answer, and
that choice is a genuine number-model decision, not a free consequence of the other operators.

The governing CorePure ADRs never made that choice explicit:

- [ADR 0020](./0020-wire-pure-output-equations.md) lists "division by zero" as a typed evaluator
  error and treats statically reducible divide-by-zero as an elaboration-time failure. It says
  nothing about how a non-zero quotient is represented.
- [ADR 0023](./0023-corepure-expression-surface.md) lists "divide by zero" in its required failure
  set and lists arithmetic operators in the surface, but does not name a numeric width or a
  non-finite case.

That leaves two facts uncovered by any decision record even though both are observable in CorePure
output values and in the evaluator's failure taxonomy:

1. **Width.** Division's result width — `Scientific` vs `Float64` — was never decided. It is the
   only CorePure operator whose result is not exact over its operands, so the choice is load-bearing
   for replay: the same operands must produce the same value byte-for-byte.
2. **Non-finite case.** Float64 division admits non-finite results (`±Infinity`, `NaN`) that have no
   JSON-number representation. Divide-by-zero is only one route to a non-finite result; finite
   operands can also overflow the Float64 range. The evaluator needs a defined answer for every such
   case, and "divide-by-zero fails" does not cover it.

The implementation already commits to a specific answer for both. This ADR records that answer as
canon so the number model is governed rather than incidental.

## Decision

CorePure division evaluates in **finite Float64** and **rejects any non-finite result** with a
dedicated typed error that is distinct from divide-by-zero. Division is the only CorePure arithmetic
operator that leaves the exact-decimal number domain.

The operator dispatch routes `CorePureDivide` to `numericFloatDivide` in `src/Cortex/Wire/Pure.hs`,
which evaluates in this order:

1. Read both operands as numbers (a non-number operand is the existing `PureTypeMismatch`).
2. If the denominator is exactly `0`, fail with `PureDivisionByZero`. Zero is tested on the exact
   `Scientific` denominator before any float conversion, so the zero check does not depend on
   Float64 rounding.
3. Otherwise convert both operands to `Double` (`Scientific.toRealFloat`) and compute the Float64
   quotient.
4. Require the numerator, the denominator, and the result to all be finite, where finite means
   `not (isNaN value || isInfinite value)`. If all three are finite, the result is the finite
   `Double` re-encoded as a JSON number (`Scientific.fromFloatDigits`). Otherwise fail with
   `PureNonFiniteFloatDivision`, carrying the rendered numerator and denominator operands.

### Lossy by construction

The Float64 round-trip is lossy by design, and that is the point of the decision. `1 / 3` evaluates
to the finite `Double` nearest to one-third, re-encoded as a JSON number, rather than to a
non-terminating exact decimal. The alternative — exact `Scientific` division — has no finite result
for such quotients and so is not a total operation over CorePure numbers. Choosing Float64 keeps
division total over its finite domain at the cost of decimal precision.

### A division-specific error, not a reused one

`PureNonFiniteFloatDivision` is a distinct `PureEvalError` constructor, separate from
`PureDivisionByZero`. It carries a `PureNonFiniteFloatDivisionOperands` record holding the
canonically rendered numerator and denominator, and renders a message that names the finite-range
violation. The two failures are kept apart because they describe different facts: divide-by-zero is
a domain error on the denominator, while non-finite rejection is a range error on operands or result
even when the denominator is non-zero (for example, finite operands whose Float64 quotient
overflows). Collapsing them would lose the distinction a caller needs to explain the failure.

## Boundary Rules

- Division is the sole exception to CorePure's exact-decimal arithmetic. `+`, `-`, `*`, negation,
  and the numeric comparisons remain exact over `Scientific`; only `/` rounds.
- Every division outcome is one of exactly three: a finite JSON number, `PureDivisionByZero`, or
  `PureNonFiniteFloatDivision`. There is no path on which CorePure emits a non-finite JSON number.
- The decision constrains the operator semantics, not the host's float behavior. The model relies on
  IEEE-754 Float64 round-to-nearest being evaluated identically wherever a lowered pure task runs;
  the substrate does not itself prove cross-host float reproducibility, so that reliance is recorded
  here rather than claimed as a guarantee.

## Alternatives considered

- **Exact `Scientific` division.** Rejected because it is not total over CorePure numbers: a
  quotient such as `1 / 3` has no terminating decimal, so the result either fails to construct or
  forces a non-terminating expansion. Keeping the other operators exact while making division total
  requires a representable result type, which Float64 provides and exact decimals do not.
- **Reuse `PureDivisionByZero` for non-finite results.** Rejected because it conflates a denominator
  domain error with an operand/result range error. A finite-operand overflow is not a
  divide-by-zero, and a caller that wants to report or branch on the cause would lose the
  distinction.
- **Emit non-finite JSON sentinels (`Infinity`, `NaN`).** Rejected because neither is a JSON number;
  they would either break the JSON value contract that CorePure outputs honor or smuggle a
  non-decimal value into downstream Wire contracts. Failing closed keeps every produced number
  representable.
- **Round divide-by-zero to a large finite float.** Rejected because divide-by-zero is already a
  typed failure in ADR 0020 and ADR 0023; turning it into a value would silently change
  long-standing semantics.

## Consequences

### Positive

- CorePure division is total over its finite domain: every non-zero, in-range division yields a
  representable JSON number, and the two out-of-domain cases are named, typed failures.
- Non-finite results can never escape into a CorePure output value or a downstream Wire contract.
- The divide-by-zero versus non-finite distinction is preserved in the error taxonomy, so a caller
  can tell a denominator domain error from a range error.

### Negative

- Division is lossy where the rest of CorePure arithmetic is exact, so `a / b` and an algebraically
  equal exact expression can differ in the last decimal places. Authors who need exact ratios cannot
  get them from `/`.
- The model's replay-stability rests on host IEEE-754 Float64 behavior, which the substrate relies
  on but does not verify.
- The collection fast paths for division do not route through `numericFloatDivide`; see Obligations.

### Obligations

- Keep `PureNonFiniteFloatDivision` distinct from `PureDivisionByZero` in the evaluator and in
  `renderPureEvalError`; do not collapse the two.
- Reconcile the collection fast paths with this model. `divideScientific` and `numericJsonDivide` in
  `src/Cortex/Wire/Pure.hs` — selected by the `zipWith`/numeric-expression fast paths — divide in
  exact `Scientific` and only check for a zero denominator. They neither round to Float64 nor can
  emit `PureNonFiniteFloatDivision`, so a division reached through a fast path can diverge from the
  generic path's number model. The pure-execution reference requires fast paths to preserve the same
  JSON output equality and error taxonomy as generic evaluation, so this divergence is an open
  obligation, not a settled part of the decision.
- Add an evaluator test that exercises `PureNonFiniteFloatDivision` directly. The current `PureSpec`
  covers divide-by-zero and the finite `1 / 3` rounding case, but not the non-finite rejection path.

## Traceability

- Feature keys: `corepure.division_model`
- Public surface: `Cortex.Wire`,
  [`docs/Reference/Wire/pure-execution.md`](../Reference/Wire/pure-execution.md)
- Implementation: `src/Cortex/Wire/Pure.hs` (`numericFloatDivide`, `finiteFloat`,
  `PureNonFiniteFloatDivision`, `PureNonFiniteFloatDivisionOperands`)
- Tests: `test/Cortex/Wire/PureSpec.hs`
- Theory/proof: none
- Tracking: GitHub #304

## Related

- [ADR 0020 — Wire Pure Output Equations](./0020-wire-pure-output-equations.md) — establishes
  divide-by-zero as a typed evaluator error; this ADR fills in the non-zero number model.
- [ADR 0023 — CorePure Expression Surface](./0023-corepure-expression-surface.md) — defines the
  closed CorePure surface whose arithmetic operators this ADR refines for division.
- [Wire Pure Execution Reference](../Reference/Wire/pure-execution.md) — documents the `/` finite
  Float64 rule and the non-finite-float-division failure in the pure failure surface.
- [Chapter 05 — Wire Language](../Architecture/05-wire-language.md)
