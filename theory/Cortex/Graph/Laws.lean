import Cortex.Graph.Core

/-!
## Overview

The eight axioms that characterize Mokhov's graph algebra. Together
they make the type a (commutative idempotent) semiring under
`overlay` and a left-zero semigroup under `connect` with `empty` as a
two-sided unit, plus the decomposition law that ties them together.

## Context

We state every law as a proposition the rest of the substrate is
allowed to assume. The propositions do **not** hold definitionally on
the raw AST (`overlay g empty` and `g` are different constructor
trees). Discharging them requires a denotational quotient: define
`vertexSet` and `edgeSet`, prove the laws hold up to set equality on
the denotation, and lift the algebra to a `Quotient` type.

Until the quotient lands in `Cortex.Graph.Quotient` (TODO), each law
is admitted as an `axiom`.

## Theorem Split

The page separates unit laws, algebraic laws, and operator restatements.
The split makes the trusted scaffold explicit until quotient lifting
replaces these assumptions with theorems.

## Status

| Law                                    | Status        |
|----------------------------------------|---------------|
| `overlay_empty`                        | axiom (TODO)  |
| `connect_empty_left`                   | axiom (TODO)  |
| `connect_empty_right`                  | axiom (TODO)  |
| `overlay_comm`                         | axiom (TODO)  |
| `overlay_assoc`                        | axiom (TODO)  |
| `connect_assoc`                        | axiom (TODO)  |
| `connect_distrib_overlay_left`         | axiom (TODO)  |
| `connect_distrib_overlay_right`        | axiom (TODO)  |
| `connect_decomposition`                | axiom (TODO)  |

Discharging the axioms is the actual work — see Track 1 in
`theory/README.md`.

## References

- Mokhov, "Algebraic Graphs with Class", §3 (Theorems 1–8).
- Cortex `src/Cortex/Graph/Core.hs` — the laws are exercised but not
  proven on the Haskell side.
-/

namespace Cortex.Graph
namespace Graph

/-! ## Unit Laws (Axiomatized) -/

/-- `overlay_empty` states that `empty` is a two-sided identity for `overlay`. -/
axiom overlay_empty {α : Type} (g : Graph α) :
    overlay empty g = g ∧ overlay g empty = g

/-- `connect_empty_left` states that `connect empty g` is identity. -/
axiom connect_empty_left {α : Type} (g : Graph α) :
    connect empty g = g

/-- `connect_empty_right` states that `connect g empty` is identity. -/
axiom connect_empty_right {α : Type} (g : Graph α) :
    connect g empty = g

/-! ## Algebraic Laws (Axiomatized) -/

/-- `overlay_comm` states that overlay is commutative. Mokhov Theorem 1. -/
axiom overlay_comm {α : Type} (g h : Graph α) :
    overlay g h = overlay h g

/-- `overlay_assoc` states that overlay is associative. Mokhov Theorem 2. -/
axiom overlay_assoc {α : Type} (g h k : Graph α) :
    overlay (overlay g h) k = overlay g (overlay h k)

/-- `connect_assoc` states that connect is associative. Mokhov Theorem 4. -/
axiom connect_assoc {α : Type} (g h k : Graph α) :
    connect (connect g h) k = connect g (connect h k)

/-- `connect_distrib_overlay_left` states left distribution over overlay. Mokhov Theorem 6. -/
axiom connect_distrib_overlay_left {α : Type} (g h k : Graph α) :
    connect g (overlay h k) = overlay (connect g h) (connect g k)

/-- `connect_distrib_overlay_right` states right distribution over overlay. -/
axiom connect_distrib_overlay_right {α : Type} (g h k : Graph α) :
    connect (overlay g h) k = overlay (connect g k) (connect h k)

/-- `connect_decomposition` states `g · h · k = g · h ⊕ g · k ⊕ h · k`.

Mokhov Theorem 8. The law distinguishes Mokhov's algebra from a plain
semiring; load-bearing for circuit simplification. -/
axiom connect_decomposition {α : Type} (g h k : Graph α) :
    connect (connect g h) k =
      overlay (overlay (connect g h) (connect g k)) (connect h k)

end Graph

/-! ## Operator Restatements

Same axioms re-expressed against the Lean operator surface (`+`, `*`)
for downstream proofs that prefer the compact algebraic notation.
-/

theorem overlay_comm_plus {α : Type} (g h : Graph α) :
    g + h = h + g :=
  Graph.overlay_comm g h

theorem connect_assoc_mul {α : Type} (g h k : Graph α) :
    g * h * k = g * (h * k) :=
  Graph.connect_assoc g h k

theorem connect_decomposition_mul {α : Type} (g h k : Graph α) :
    g * h * k = (g * h) + (g * k) + (h * k) :=
  Graph.connect_decomposition g h k

end Cortex.Graph
