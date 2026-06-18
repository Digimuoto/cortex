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
  - docs/ADRs/0039-wire-node-boundary-transform-normal-form.md
  - docs/ADRs/0047-wire-frontier-linearity-and-precedence.md
  - docs/ADRs/0048-wire-make-bounded-node-generation.md
  - docs/ADRs/0049-wire-fan-phantom-adapter.md
  - docs/ADRs/0050-wire-corepure-output-residue.md
  - "GitHub #170"
  - "GitHub #173"
  - "GitHub #181"
---

# ADR 0052 - Wire Bounded Indexed Boundary Products

## Status

Proposed - this ADR amends ADR 0048's source view of generated families and extends ADR 0049's
record-only adapter into a finite-product boundary adapter. It does not change ADR 0047's linear
endpoint rule or the meaning of `=>`.

## Context

ADR 0047 makes the Wire frontier linear: an endpoint resource is either exposed or consumed by one
edge, and `=>` rejects a connect when either side has several compatible counterparts. ADR 0048 then
adds `make(N, K)`, which creates a bounded fresh node family from a kind. ADR 0049 adds `*` as an
explicit record↔ports adapter, partly to make generated frontiers usable without implicit fan-in or
fan-out.

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

For records, the current ADR 0049 behavior is the named-product case:

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
ports and multi-port frontiers. Issue #170 remains the right home for node-local egress projection.

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
- Existing ADR 0049 language about "fan" becomes misleading unless updated to say "finite-product
  adapter".
- Diagnostics must distinguish source family paths (`workers[1].out`) from lowered names
  (`workers_1.out`) without hiding the stable lowering.

### Obligations

- Update ADR 0048 to describe indexed family bindings and `workers[i]` projection.
- Update ADR 0049 to describe `*` as a finite-product boundary adapter, not only a nominal-record
  adapter.
- Extend the Wire grammar and tree-sitter grammar for `let name[] = make(...)`, static family
  projection, and bounded indexed product contract syntax.
- Add compiler tests for valid `workers[i]`, out-of-range projection, whole-family overlay,
  homogeneous `*` gather/scatter, mismatched arity, mismatched element contract, and rejection of
  implicit `=>` fan.
- Add nested-product tests showing that one `*` unfolds only one constructor.
- Extend the Lean proof track with a `ProductAdapterWitness` or a generalization of
  `PhantomAdapterWitness` over finite product shapes.
- Update issue #173 so certification covers indexed products as well as record adapters.
- Update the DIALOCO paper draft to stop presenting record-form `*` as the general homogeneous fan
  answer.

## Related

- [ADR 0039 - Wire Node Boundary Transform Normal Form](./0039-wire-node-boundary-transform-normal-form.md)
- [ADR 0047 - Wire Frontier Linearity and Topology Operator Precedence](./0047-wire-frontier-linearity-and-precedence.md)
- [ADR 0048 - Wire Compile-Time Make for Bounded Node Generation](./0048-wire-make-bounded-node-generation.md)
- [ADR 0049 - Wire Phantom Record↔Ports Adapter for Topology Fans](./0049-wire-fan-phantom-adapter.md)
- [ADR 0050 - Wire CorePure Output Residue](./0050-wire-corepure-output-residue.md)
- [Chapter 05 - Wire Language](../Architecture/05-wire-language.md)
- [Wire Grammar Reference](../Reference/Wire/grammar.md)
- [Wire Contracts, Ports, and Matching Reference](../Reference/Wire/contracts-ports-and-matching.md)
- [GitHub #170 - ADR: define Wire egress projection and binding phases](https://github.com/Digimuoto/cortex/issues/170)
- [GitHub #173 - Lean: certify makeEach and star elaboration](https://github.com/Digimuoto/cortex/issues/173)
- [GitHub #181 - Design bounded graph iteration for Wire forms](https://github.com/Digimuoto/cortex/issues/181)
