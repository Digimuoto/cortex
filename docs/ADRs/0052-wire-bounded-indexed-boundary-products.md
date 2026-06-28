---
title: "ADR 0052 - Wire Bounded Indexed Boundary Products"
description:
  "Introduces bounded indexed graph families and finite-product boundary adapters so homogeneous
  generated frontiers can gather and scatter without weakening Wire's endpoint-linearity rule."
sidebar:
  label: "0052. Indexed products"
  order: 52
status: proposed
date: 2026-05-08
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/contracts-ports-and-matching.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0028-wire-topology-composition-and-boundary-labels.md
  - docs/ADRs/0039-wire-node-boundary-transform-normal-form.md
  - docs/ADRs/0047-wire-frontier-linearity-and-precedence.md
  - docs/ADRs/0048-wire-make-bounded-node-generation.md
  - docs/ADRs/0050-wire-corepure-output-residue.md
---

# ADR 0052 - Wire Bounded Indexed Boundary Products

## Status

Proposed - this ADR is the single decision for Wire's `*` boundary adapter. It absorbs ADR 0049's
record↔ports adapter mechanics and generalizes them into a finite-product boundary adapter, and it
amends ADR 0048's source view of generated families. It does not change ADR 0047's linear endpoint
rule or the meaning of `=>`.

## Context

ADR 0047 makes the Wire frontier linear: an endpoint resource is either exposed or consumed by one
edge, and `=>` rejects a connect when either side has several compatible counterparts. ADR 0048 then
adds `make(N, K)`, which creates a bounded fresh node family from a kind. The `*` operator was first
introduced as an explicit record↔ports adapter (now merged into this ADR), partly to make generated
frontiers usable without implicit fan-in or fan-out.

That first slice works for nominal records, but it conflates two different shapes:

- **record flattening**, where one port carrying `{a: A, b: B}` is viewed as two labelled ports
  `a: A` and `b: B`;
- **homogeneous bounded fan**, where a generated family exposes `N` values of the same contract and
  a downstream boundary wants a bounded indexed aggregate such as `[T; N]`.

The current record-only `*` can encode a homogeneous family as a nominal record with generated field
names, for example `{workers_0: Sample, workers_1: Sample, workers_2: Sample}`. That is a workable
implementation strategy, but it is not the right source abstraction. The real object is an indexed
family with leaves such as `workers[0].out`, `workers[1].out`, and `workers[2].out`.

The motivating question is whether a node that produces an aggregate such as `[T]` may fan out to a
frontier `b <> c <> d`. The answer is not "yes by `=>`". If ordinary `=>` inferred the fan from the
right-hand frontier, edge semantics would become nonlocal and order-sensitive. The answer is that a
bounded product adapter may explicitly unfold a finite aggregate into a finite set of linear leaves.
The topology remains static; runtime values may still fail validation if an executor produces the
wrong aggregate shape.

## Decision

Wire adds **bounded indexed boundary products** as a source and elaboration concept.

### 1. Boundary shapes are finite products with linear leaves

A boundary shape is one of:

- a scalar contract, whose boundary has one linear leaf;
- a nominal record contract, whose immediate fields form a finite named product;
- a bounded indexed product `[T; N]`, whose immediate children form the finite index set
  `0 .. N - 1`, each with element contract `T`.

`N = 0` is valid and denotes the empty finite product. It exposes no `T` leaves. It is not a graph
operator identity; it is an aggregate boundary shape that can be folded or unfolded only by an
explicit `*` adapter.

Linearity is checked on the leaves, not on the aggregate handle. A port carrying `[T; 3]` may be
unfolded into three leaf endpoints only by an explicit adapter. Each leaf endpoint is then consumed
at most once by ordinary one-to-one `=>` contractions.

Unbounded list syntax such as `[T]` is not a topology-shaping boundary product in this ADR. It is a
value contract, if admitted by a host registry at all. It must not cause graph shape or fan arity to
be inferred from adjacent topology.

### 2. `make` binds an indexed graph family

`make(N, K)` may be bound as an indexed family:

```wire
let workers[] = make(3, worker);
```

The binding introduces the family `workers` and static projections:

```text
workers[0]
workers[1]
workers[2]
```

Rules:

- `N` remains static, as in ADR 0048.
- `workers[i]` is valid only when `i` is a compile-time integer literal in range.
- `workers` in graph position denotes the overlay of every generated child, preserving the current
  `let workers = make(...)` behavior.
- Lowered node identities remain source-stable and may continue to use the existing `<binding>_<i>`
  encoding. Diagnostics and source-level reasoning should prefer the structured spelling
  `workers[i]`.
- Generated endpoint paths are structured as `workers[i].portLabel` at the source level, even if the
  compiler lowers them to ordinary node and port names.

ADR 0048's rejection of bracket naming remains correct for lowered node identity. This ADR admits
bracket projection as source syntax over the same stable identity scheme.

### 3. `*` becomes a finite-product boundary adapter

The `*` operator is generalized from "record↔ports" to **finite-product fold/unfold**:

```text
aggregate product port  *  product-shaped frontier
```

It still elaborates to an explicit generated adapter vertex plus ordinary `=>` edges on both sides.
No new edge semantics are introduced.

For records, the named-product case is:

```text
pair: Pair  <->  a: A <> b: B
```

For bounded indexed products, the homogeneous case is:

```text
samples: [Sample; 3]  <->  sample[0]: Sample <> sample[1]: Sample <> sample[2]: Sample
```

The exact source spelling for indexed leaf labels on the multi-side is the indexed family path when
the multi-side comes from `make`:

```wire
let workers[] = make(3, worker);

node sink
  <- samples: [Sample; 3];
  -> done: Done = @review.sink (samples);

workers * sink
```

The adapter pairs `workers[0]`, `workers[1]`, and `workers[2]` with the three positions of
`samples: [Sample; 3]`. The compiled topology contains one generated adapter and ordinary one-to-one
edges. If `sink` expects `[Sample; 2]` or `[Other; 3]`, admission rejects the `*` expression.

### 4. `=>` remains scalar leaf matching

This ADR does not allow:

```wire
source => consumer_a <> consumer_b <> consumer_c
```

to unfold a list, record, or generated family by context. `=>` continues to match compatible exposed
leaf endpoints by `(label, contract)` and rejects multiple compatible counterparts. Authors use `*`
or an explicit adapter node when an aggregate boundary must be folded or unfolded.

### 5. Nested products unfold one constructor at a time

Product adapters are **shallow by default**. One `*` crosses one product constructor:

```wire
contract Pair {
  a: A;
  b: B;
};

contract Envelope {
  pair: Pair;
  meta: Meta;
};
```

Unfolding `Envelope` exposes:

```text
pair: Pair
meta: Meta
```

It does not automatically expose `pair.a` and `pair.b`. Authors who need deeper exposure compose
adapters or write an explicit pure projection node. Recursive flattening is deferred because it can
overexpose nominal structure and create poor diagnostics for large nested values.

### 6. Node-local egress projection is separate

Node egress may intentionally produce several output ports from local data, as described by
ADR 0039. That is not topology fan-out. This ADR concerns graph-boundary adapters between aggregate
ports and multi-port frontiers. Node-local egress projection remains a separate follow-up.

## `*` adapter mechanics

The `*` operator elaborates to a single **phantom adapter vertex** inserted between its two
operands; ordinary `=>` does all the wiring. The defining equivalence is:

```text
a * b   ≡   a => phantom => b
```

Both `=>` edges are ordinary boundary contractions under ADR 0047. The phantom node has two
boundaries:

- the **multi-side**, mirroring the product-shaped frontier of whichever operand carries one — each
  port is a regular cardinality-one port matched by ordinary `=>`;
- the **aggregate side**, a single port of the product contract (a nominal record or a bounded
  indexed product).

There is no spoke vocabulary at the topology layer. Pairing happens by field or index inside the
phantom's CorePure body, which performs the only aggregate projection in the entire elaboration. The
phantom belongs to a parametric family of structural adapters indexed by product shape: the closed
alphabet contains the family, and `*` selects the instance whose shape matches the call site — the
same parametric move that makes `Option[T]` part of the language without admitting user-defined
generics.

### Product discriminator

The phantom's body and multi-side shape are determined by the **aggregate side's product contract**:

- a nominal record `{label_1: T_1, ..., label_N: T_N}` synthesizes multi-side ports `label_i: T_i`
  and pairs by label;
- a bounded indexed product `[T; N]` synthesizes `N` element ports and pairs by index `0 .. N-1`.

The multi-side operand's exposed port set must match the product's fields or indices exactly — same
labels or arity, same contracts. A mismatch is a static error. An aggregate side whose contract is
neither a nominal record nor a bounded indexed product is a static error.

### No mixed forms

There is no Wire contract that combines a nominal record with a positional list. Authors who want
partially-uniform aggregates compose multiple `*` calls or write the adapter by hand. The exclusion
of mixed forms is a corollary of the product discriminator.

### Degenerate cases

The phantom is **always generated**, including the degenerate cases:

- **Empty product** (multi-side has zero ports; a record with no fields or `[T; 0]`): the phantom is
  generated with an empty multi-side and an aggregate-side port of the empty product contract. The
  two `=>` edges connect normally; the empty multi-side contributes no edges. The elaborator emits a
  lint warning at synthesis ("`*` over an empty product generates a degenerate phantom; consider
  whether the empty case was intended"), firing at synthesis rather than parse so non-literal-zero
  `N` is caught too.
- **Singleton product** (multi-side has one port): the phantom is generated. Authors who do not want
  the phantom for `N = 1` use `=>` directly.

### Port-clash diagnostic

A port clash on the synthesized phantom is a static error: "phantom would have two outputs of the
same (label, contract); rename or use a product contract." The diagnostic points at the `*` call
site and at the phantom's synthesized boundary. Clashes only matter once the phantom is synthesized;
multi-side operand label collisions are handled there, not at the operand site.

### Match determinism

Under phantom insertion, all topology-level wiring is ordinary `=>` boundary contraction, so match
determinism for `*` reduces to ADR 0047's rule for `=>`: every endpoint has zero or one compatible
counterpart, and more than one is a static error. No new tiebreak surface is introduced.

### Canonical rule

`*` expands only to ordinary graph vertices and ordinary valid port edges: exactly one phantom
vertex and two `=>` edges, one to each operand. The phantom's body performs the only aggregate
projection, confined to CorePure. There are no hidden adapters, no implicit aggregation, no changes
to `=>` semantics, and no surface vocabulary for spokes.

### Static errors

- The aggregate side's contract is neither a nominal record nor a bounded indexed product.
- The multi-side operand's exposed port set does not exactly match the product's fields or indices
  (label, arity, or contract mismatch).
- Phantom synthesis would produce a port clash.
- Both sides are flat singletons: "`*` requires a multi-element frontier on at least one side; for
  1:1 wiring use `=>`."
- Both sides carry multi-element frontiers: "`*` requires exactly one aggregate side."

### Contract surface

`*` reads product shapes from the host contract registry or from source declarations: records of the
form `contract Name { field: Contract; };` and bounded indexed product contract syntax (`[T; N]`).
Source fields resolve through the `use` scope visible at the declaration point. This keeps the
aggregate side declared without adding implicit topology copying or unbounded list-shaped topology.

### Lean correspondence

`LinearPortGraph.PhantomAdapterWitness` models the source-linearity side; `PhantomRecordShape` pins
the generated adapter to one phantom node with a declared multi/aggregate boundary, exhibited as
that phantom object plus two certified bulk contractions. The bounded-indexed generalization is
`ProductAdapterWitness`, a generalization of `PhantomAdapterWitness` over finite product shapes. The
executable Haskell expander, discriminator diagnostics, and witness production remain separate
correspondence work.

## Alternatives considered

- **Namespace port matching by node.** Rejected. Endpoint identity is already `(node, port)`, but
  compatibility should remain a port-label/contract fact. If node identity becomes part of matching,
  downstream interfaces depend on upstream provenance names and form-generated prefixes.
- **Infer bounded fan from adjacent `=>` topology.** Rejected. Although the adjacent frontier gives
  a static arity, plain `=>` would become order-sensitive and nonlocal. Product unfolding must be
  visible through `*` or an explicit adapter node.
- **Keep homogeneous fans encoded as nominal records.** Rejected as the canonical model. It is a
  useful lowering strategy, but source programs should not have to invent field names such as
  `workers_0`, `workers_1`, and `workers_2` for a homogeneous indexed product.
- **Flatten nested records recursively by default.** Rejected. Recursive flattening weakens nominal
  boundaries, surprises authors of nested contracts, and makes diagnostics harder. Shallow adapters
  compose.
- **Let unbounded `[T]` shape topology.** Rejected. Runtime-length values must not decide topology.
  If a runtime list must be split, an executor or adapter with a declared static arity must validate
  the length and fail when the value does not match.

## Consequences

### Positive

- Homogeneous generated families get a source abstraction that matches their proof model:
  `Fin N`-indexed children rather than generated flat record names.
- `*` becomes principled: it is a finite-product boundary adapter, with records and bounded indexed
  products as two product constructors.
- Wire keeps ADR 0047's linear frontier intact. All fan-like behavior still lowers to fresh leaves
  and ordinary one-to-one contractions.
- Nested structure gets a conservative rule: one adapter crosses one product constructor.

### Negative

- Wire gains another source-level family binding form, `let name[] = ...`.
- Contract syntax must eventually admit bounded indexed products such as `[T; N]` or an equivalent
  nominal spelling.
- Diagnostics must distinguish source family paths (`workers[1].out`) from lowered names
  (`workers_1.out`) without hiding the stable lowering.

### Obligations

- Update ADR 0048 to describe indexed family bindings and `workers[i]` projection.
- Reserve `*` under ADR 0047's precedence slot; document the phantom-insertion equivalence and the
  parametric product-adapter family in `docs/Reference/Wire/grammar.md`, and amend
  `docs/Architecture/04-graph-and-circuit.md` to record the family as part of Wire's closed
  alphabet.
- Extend the Wire grammar and tree-sitter grammar for `let name[] = make(...)`, static family
  projection, and bounded indexed product contract syntax.
- Add expansion tests for the degenerate empty/singleton products, the port-clash diagnostic, and
  the flat-singleton and double-multi `*` rejections, alongside the indexed-product cases below.
- Add compiler tests for valid `workers[i]`, out-of-range projection, whole-family overlay,
  homogeneous `*` gather/scatter, mismatched arity, mismatched element contract, and rejection of
  implicit `=>` fan.
- Add nested-product tests showing that one `*` unfolds only one constructor.
- Extend the Lean proof track with a `ProductAdapterWitness` or a generalization of
  `PhantomAdapterWitness` over finite product shapes.
- Update the certification follow-up so it covers indexed products as well as record adapters.
- Update the DIALOCO paper draft to stop presenting record-form `*` as the general homogeneous fan
  answer.

## Traceability

- Feature keys: `wire.indexed_boundary_products`
- Public surface: `Cortex.Wire`, `docs/Reference/Wire/grammar.md`,
  `docs/Reference/Wire/contracts-ports-and-matching.md`
- Implementation: `src/Cortex/Wire/Syntax.hs` (`ExprStar`, `ExprFamilyProjection`),
  `src/Cortex/Wire/Parser.hs` (`recordIndexedFamily`, indexed-family expansion),
  `src/Cortex/Wire/Compile.hs` (`buildStarPhantomNode`, `phantomAdapterArtifactFromPlan`),
  `src/Cortex/Wire/AdmissionArtifact.hs` (`ProductShapeArtifact`, `PhantomAdapterArtifact`)
- Tests: `test/Cortex/Wire/CompileSpec.hs` (phantom-adapter and indexed-product artifact admission),
  `test/Cortex/Wire/ParserSpec.hs` (indexed `make` bindings and static family projection; bounded
  indexed product contracts in port positions; out-of-range projection rejection)
- Theory/proof: [Bounded fan composition row](../Reference/proof-status.md) (Lean
  `LinearPortGraph.PhantomAdapterWitness`, `LinearPortGraph.ProductAdapterKind` in
  `theory/Cortex/Wire/PhantomAdapter.lean`)

## Related

- [ADR 0039 - Wire Node Boundary Transform Normal Form](./0039-wire-node-boundary-transform-normal-form.md)
- [ADR 0047 - Wire Frontier Linearity and Topology Operator Precedence](./0047-wire-frontier-linearity-and-precedence.md)
- [ADR 0024 - Typed Executor Node Interface](./0024-typed-executor-node-interface.md)
- [ADR 0028 - Wire Topology Composition and Boundary Labels](./0028-wire-topology-composition-and-boundary-labels.md)
- [ADR 0048 - Wire Compile-Time Make for Bounded Node Generation](./0048-wire-make-bounded-node-generation.md)
- [ADR 0050 - Wire CorePure Output Residue](./0050-wire-corepure-output-residue.md)
- [Chapter 05 - Wire Language](../Architecture/05-wire-language.md)
- [Wire Grammar Reference](../Reference/Wire/grammar.md)
- [Wire Contracts, Ports, and Matching Reference](../Reference/Wire/contracts-ports-and-matching.md)

## Tracking

- #170 — node-local egress projection.
- #173 — certification coverage for product adapters.
