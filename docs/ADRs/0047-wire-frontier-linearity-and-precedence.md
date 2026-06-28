---
title: "ADR 0047 - Wire Frontier Linearity and Topology Operator Precedence"
description:
  "Pins the linear endpoint rule, match determinism, repeated-reference rejection, and a committed
  precedence ladder for Wire topology operators; formally amends ADR 0028."
sidebar:
  label: "0047. Frontier linearity and precedence"
  order: 47
status: proposed
date: 2026-05-05
superseded_by: null
related:
  - docs/Architecture/04-graph-and-circuit.md
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/contracts-ports-and-matching.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0028-wire-topology-composition-and-boundary-labels.md
---

# ADR 0047 - Wire Frontier Linearity and Topology Operator Precedence

## Status

Proposed - this ADR formally amends ADR 0028 by:

- pinning the **linear endpoint rule** on Wire's typed frontier (no implicit clone, no implicit
  aggregation);
- committing **match determinism** for `=>` (each endpoint has zero or one compatible counterpart);
- retiring ADR 0028's "parens required when `<>` and `=>` are mixed" rule and replacing it with a
  committed **precedence ladder**.

It is the semantic foundation for ADR 0048 (`make`) and ADR 0052 (the `*` boundary adapter); both
depend on the rules pinned here.

## Context

ADR 0028 settled `=>` (connect, boundary product) and `<>` (overlay, graph union) but stops short of
two commitments that subsequent design needs:

1. **Endpoint linearity.** ADR 0028 allows one output port to feed several compatible inputs. That
   is incompatible with the substructural reading of Wire's typed frontier - ports are resources,
   not free variables - and it is what makes `make(N, K) => sink` quietly do the wrong thing if it
   is not pinned.
2. **Operator precedence.** The grammar reference rejects unparenthesized `a => b <> c` because ADR
   0028 does not commit to a precedence between `<>` and `=>`. The result: every mixed expression
   takes parens that are not needed by the algebra.

The source grammar can parse mixed composition unambiguously once a precedence rule is pinned.
Whether the parsed expression is admitted is then decided by the linear endpoint rule below. This
keeps parser grouping separate from Mokhov relation laws, which apply only after port identity is
forgotten during lowering. Here, **lowering** means translating the accepted Wire/Circuit frontier
object into the plain Graph relation used for topology algorithms.

ADR 0048 (bounded node generation via `make`) and ADR 0052 (the `*` finite-product boundary adapter)
both need this foundation in place: `make` produces multi-port frontiers that must compose linearly
under `=>`, and `*` adds a new operator whose precedence relative to `<>` and `=>` must be committed
before it can land.

### Algebraic foundation

Wire's topology composition is a **linear refinement of Mokhov's algebra of graphs**. The syntactic
skeleton (`empty`, vertex, overlay, connect) is Mokhov's; the semantic model is not the standard
set-of-vertices reading. A graph value carries a typed **frontier** - a multiset of unmatched
`(direction, label, contract)` ports - and ports are linear resources: each port is consumed exactly
once during composition or remains exposed on the composed boundary; nothing implicitly duplicates
or discards.

Under this reading:

- `<>` (overlay, also written `,` while that alias is admitted) is disjoint union of typed
  frontiers. It is **not** a cloning operator: a repeated graph reference such as `a <> a` is a
  static topology error.
- `=>` (connect) is **boundary contraction**: it consumes matched ports from each side, adds the
  matching edges, and leaves only the complementary unmatched ports exposed on the result. The
  matched ports cease to exist as resources, not just cease to be visible.
- Wire has no implicit duplication primitive. Authors who need N consumers of one value generate N
  output ports (ADR 0048) and pair them through an explicit adapter (ADR 0052).

This grounding makes admission decidable from typing alone: at each composition step the set of
admissible frontier contractions is statically computable from the current signature, and every Wire
operator is a linear transformation on the typed frontier multiset. Fuller treatment belongs in
`docs/Architecture/04-graph-and-circuit.md` and the eventual paper; this ADR uses the
linear-resource language where it sharpens the rules.

## Decision

Wire commits to four rules. They apply to every existing topology operator and to the operators
introduced by ADRs 0048 and 0052.

### 1. Linear endpoint rule

Each output port and each input port in a typed frontier is consumed by at most one composition
step. Repeated graph references (`a <> a`, `a => a`) are static topology errors, not implicit
clones.

This sharpens ADR 0028's allowance "one output port to feed several compatible inputs": an output
port may participate in at most one matched edge per composition. Distinct inputs that need the same
value are produced explicitly (multiple output ports on the same producer, or an explicit `*`
adapter introduced by ADR 0052).

### 2. Match determinism for `=>`

`=>` (connect) is boundary contraction with a deterministic match relation:

- Every output endpoint in `∂⁺G` and every input endpoint in `∂⁻H` has zero or one compatible
  counterpart on the opposite side, where compatible means matching `(label, contract)`.
- Zero counterparts: the endpoint remains exposed on the composed frontier — a **carried endpoint**
  (an identity wire for an open boundary; see the [glossary](../glossary.md)).
- One counterpart: the pair is consumed and the matching edge is added.
- More than one counterpart on either side: static error.

Static rejection in the multi-counterpart case is the deterministic rule. Authors disambiguate by
naming their ports.

### 3. Precedence ladder

Wire commits to:

| Tightness | Operators  | Associativity |
| --------- | ---------- | ------------- |
| Tighter   | `<>` / `,` | left          |
| Looser    | `=>` / `*` | left          |

Tighter binds first. `*` is defined by ADR 0052; this table reserves its precedence so the
foundation is forward-compatible.

This is **inverted from Mokhov's `Algebra.Graph` Haskell library**, where connect (the analog of
`=>`) binds tighter than overlay. Wire chooses the inversion because Wire's authoring rhythm puts
parallel branches at the end of a connect chain (`source => transform => a <> b <> c`), and the
inverted ladder makes that natural without parens: the trailing overlay binds first as a single
operand of the final `=>`. The connect still obeys the linear endpoint rule above; if `transform`
exposes one output that would feed all three branches, the expression is rejected rather than
rewritten by source-level distributivity.

This is the **stage-structured pipeline** reading the ladder enables: `<>` forms a same-stage
frontier (stage formation) and `=>` advances to the next stage (stage advancement). See the
[glossary](../glossary.md).

### 4. Retire ADR 0028's parens-when-mixing rule

ADR 0028's rule that `a => b <> c` and similar mixed expressions are syntactically rejected is
retired. Parens are required only to override the natural precedence, never merely to disambiguate
the grammar.

Concretely:

```wire
time => flows => down => some <> things <> parallel
```

parses as `time => flows => down => (some <> things <> parallel)`. The trailing overlay is the right
operand of the final `=>`; the connect succeeds iff `down` exposes three distinct compatible outputs
(linear endpoint rule).

The Wire grammar reference must be updated accordingly.

### Comma overlay shorthand

The comma overlay shorthand is not admitted in current Wire. Authors use `<>` for overlay so graph
composition has one visible parallel operator and record/list comma syntax stays value-local.

## Alternatives considered

- **Standard Mokhov precedence (connect tighter than overlay).** Rejected because Wire's natural
  authoring shape puts parallel branches at the end of a connect chain, and standard Mokhov
  precedence would require parens around every such chain's tail. The inverted ladder is a one-time
  documentation cost in exchange for cleaner source.
- **Keep ADR 0028's parens-when-mixing rule.** Rejected because the algebra is unambiguous given a
  precedence; the rule was conservative defensive programming that costs visual clarity in every
  expression that mixes operators.
- **Allow non-linear endpoints (one output to many inputs implicitly).** Rejected because it breaks
  the substructural reading of the typed frontier and silently makes `make(N, K) => sink` do the
  wrong thing. Authors who need multi-consumption produce multiple output ports explicitly.
- **Defer the linearity rule to the construct ADRs (0048, 0052).** Rejected because both constructs
  need linearity in place to define their semantics; pulling the rule into the foundation keeps each
  construct ADR self-contained.
- **Keep the comma overlay alias.** Rejected. The alias competed visually with value-level list and
  record separators while adding no semantic power over `<>`.

## Consequences

### Positive

- Mixed topology expressions read clean without parens.
- Linear endpoints make `make(N, K) => sink` a static error rather than silently incorrect.
- Match determinism is committed in one place; `*` (ADR 0052) inherits it without restating.
- The frontier-as-multiset reading has a single canonical home.

### Negative

- Authors familiar with Mokhov's Haskell library face the inverted precedence and must learn it.
- ADR 0028's mixing rule is retired; existing source that relied on parens for visual grouping
  continues to work but reads differently to a reader fluent in the new ladder.
- `=>` no longer permits one output to feed several compatible inputs. Existing source that depended
  on that allowance is now a static error and must be rewritten with multiple output ports or an
  explicit adapter (ADR 0052).

### Obligations

- Update `docs/Reference/Wire/grammar.md` to document the precedence ladder and remove the
  parens-when-mixing rule.
- Update `docs/Reference/Wire/contracts-ports-and-matching.md` to pin the linear endpoint rule and
  reject one-output-to-many-inputs.
- Update `docs/Architecture/04-graph-and-circuit.md` to reflect Wire as a linear refinement of
  Mokhov's algebra (frontier as typed multiset, ports as linear resources).
- Update the formatter to a conservative stance on parentheses: preserve authored parens until large
  examples settle the idiom.
- Update the tree-sitter grammar to recognize the new precedence and `*` topology operator.
- Update the `wire-code-style` skill.
- Add tests for: linear endpoint violations (`a <> a`, `a => a`, repeated reference inside form
  bodies), match-determinism violations (multiple compatible counterparts), unparenthesized mixed
  expressions parsing per the new ladder, and trailing-overlay connect chains that are admitted only
  when each branch has a distinct compatible output.
- Prove or document that admission preservation under the new rules is unchanged for existing
  programs that did not rely on retired allowances.

## Open questions

- **Comma overlay alias longevity.** `,` currently aliases `<>` and inherits its precedence and
  semantics under this ADR. Whether to deprecate `,` in a later cleanup is open; for now the alias
  stays admitted under the rule above.
- **Formatter strictness.** v1 preserves authored parentheses conservatively. The right idiom
  emerges only with large real Wire examples; the formatter's stance can tighten once those exist.
  This is formatter policy, not language semantics.

## Traceability

- Feature keys: `wire.frontier_linearity`
- Public surface: `Cortex.Wire`, `docs/Reference/Wire/grammar.md`,
  `docs/Reference/Wire/contracts-ports-and-matching.md`
- Implementation: `src/Cortex/Wire/Parser.hs` (`exprConnectLevel`, `exprOverlayLevel` — the
  overlay-tighter-than-connect/star precedence ladder), `src/Cortex/Wire/Compile.hs`
  (`linearBoundaryMatches`, `connectFragments`, `flattenConnectChain`)
- Tests: `test/Cortex/Wire/ParserSpec.hs` (overlay binds tighter than connect; star adapters at
  connect precedence; comma overlay shorthand rejected)
- Theory/proof: [Source linear port carrier row](../Reference/proof-status.md) (Lean
  `CertifiedGraph.BoundaryMatchTrace.determined`, `overlay_preserves_portLinear` in
  `theory/Cortex/Wire/PortLinearity.lean` and `theory/Cortex/Wire/GraphElaboration.lean`)

## Related

- [ADR 0024 - Typed Executor Node Interface](./0024-typed-executor-node-interface.md)
- [ADR 0028 - Wire Topology Composition and Boundary Labels](./0028-wire-topology-composition-and-boundary-labels.md)
- [ADR 0048 - Wire Compile-Time Make for Bounded Node Generation](./0048-wire-make-bounded-node-generation.md)
- [ADR 0052 - Wire Bounded Indexed Boundary Products](./0052-wire-bounded-indexed-boundary-products.md)
- [Chapter 04 - Graph and Circuit](../Architecture/04-graph-and-circuit.md)
- [Chapter 05 - Wire Language](../Architecture/05-wire-language.md)
- [Wire Grammar Reference](../Reference/Wire/grammar.md)
