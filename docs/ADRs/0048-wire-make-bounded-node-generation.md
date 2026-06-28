---
title: "ADR 0048 - Wire Compile-Time Make for Bounded Node Generation"
description:
  "Adds make(N, K), a compile-time macro that elaborates to N fresh vertices from a kind reference
  with deterministic source-stable identities."
sidebar:
  label: "0048. Make"
  order: 48
status: proposed
date: 2026-05-05
superseded_by: null
related:
  - docs/Architecture/04-graph-and-circuit.md
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/ADRs/0045-wire-compile-time-node-body-kinds.md
  - docs/ADRs/0046-wire-compile-time-graph-forms.md
  - docs/ADRs/0047-wire-frontier-linearity-and-precedence.md
  - docs/ADRs/0052-wire-bounded-indexed-boundary-products.md
---

# ADR 0048 - Wire Compile-Time Make for Bounded Node Generation

## Status

Proposed - the iteration successor that ADR 0046 explicitly deferred. Forms (ADR 0046) and node-body
kinds (ADR 0045) have landed; this ADR adds the bounded-N node generator that authors a fresh family
of vertices from one kind reference. It depends on ADR 0047 for the frontier linearity rules that
govern how generated families compose. ADR 0052 proposes an indexed source view and finite-product
adapter over this generated family; this ADR's lowered identity scheme remains the source of stable
generated node identity.

## Context

ADR 0046 added compile-time forms for fixed-shape multi-node fragments and explicitly deferred
iteration ("Add static graph conditionals and loops at the same time. Rejected ... Forms should land
first as finite non-recursive instantiation"). Forms have landed; the deferred shape - "I want N
fresh nodes from this kind" - has no syntactic surface today.

Authors who need bounded replication today write N `node` declarations by hand. Quantum sweeps,
per-shot sampling, per-claim evidence gathering, and per-shard materialization all hit this shape.
CorePure `map` is the wrong tool: it lifts a function over a list inside a single node body,
producing list-shaped data on one output port. It cannot mint vertices.

The constraint that anchors the design: **the count is static**. ADR 0046's rejection of dynamic
graph shape stands; if an author needs a runtime-determined count, they rewrite the program.

## Decision

Wire adds a built-in `make(N, K)` node-generation macro.

`make(N, K)` elaborates at compile time to N fresh vertices, each instantiated from the node-body
kind `K` (ADR 0045) under a deterministic, source-stable identity. The result is a `Graph` value
(ADR 0046's existing class) and composes with all topology operators under ADR 0047's rules.

```wire
let workers = make(10, sample);
```

### N is static

`N` must be a non-negative integer literal or a closed compile-time-resolvable Value. Anything that
requires runtime evaluation is a static error pointing at the argument. There is no fallback to
runtime shape.

### K is a kind reference

`K` is a **kind reference**, not a kind application. It is resolved in the kind namespace and is
valid only as the second argument of `make`; it is not a Wire value, graph value, or CorePure value.

Kinds intended for `make` must expose a single generated port-label parameter that `make` supplies
per index. Kinds that take additional `Value`/`Contract`/`ConfiguredExecutor` parameters are
accommodated by binding a wrapping form (ADR 0046) that closes over those arguments and exposes the
single generated-label kind to `make`.

### Identity scheme

Each generated vertex gets a deterministic name derived from the binding the `make` result is bound
to: `<binding>_0`, `<binding>_1`, ... `<binding>_(N-1)`. With the example above, `workers` produces
nodes named `workers_0` through `workers_9`. The identity scheme nests under ADR 0046's
form-instantiation prefix when `make` appears inside a form body.

For each generated child, `make` supplies the same `<binding>_<i>` token as the generated port
label. This makes the children's exposed boundaries align naturally with the record case of the `*`
boundary adapter (ADR 0052), which pairs by label.

ADR 0052 later admits `workers[i]` as source projection over these generated children. That
projection is a source view, not the lowered node identity.

### Empty and singleton

`make(0, K)` is legal and produces an empty graph. `make(1, K)` is legal and produces a single
vertex named `<binding>_0`; the binding name still parameterizes identity.

### Unbound inline use is rejected

`make(...)` is rejected in graph position when not bound by `let` / `export let`, for the same
reason ADR 0046 rejects unbound inline form applications: there is no source name to derive
identities from.

## Alternatives considered

- **Dynamic N (runtime-shaped families).** Rejected. ADR 0046 rules out runtime topology; this ADR
  keeps the rule.
- **Allow inline `make(...)` in graph position with a synthetic prefix.** Rejected for the same
  reason ADR 0046 rejected inline form applications: identity should come from source structure, not
  synthetic counters.
- **Multi-port generated label per child (kinds expose more than one parameterized label).**
  Deferred. v1 supports one generated label per child; multi-label generation is a future extension
  if real workloads need it.
- **Variant naming schemes (`<binding>[i]`, `<binding>(i)`, etc.).** Rejected for lowered identity.
  `<binding>_<i>` matches ADR 0046's prefix convention and is unambiguous in source text. ADR 0052
  later admits `binding[i]` as source projection over the same stable lowered identities.

## Consequences

### Positive

- Bounded replication becomes compact and readable.
- Generated identities are deterministic and source-bisectable, matching ADR 0046's rules.
- The static-topology invariant is preserved.

### Negative

- One new built-in identifier (`make`) enters the Wire surface.
- **`make(N, K) => sink` is rejected for N > 1 unless every generated child exposes a distinct
  output matching a distinct sink input.** Under ADR 0047's linear endpoint rule, several generated
  children all exposing `out: T` cannot all feed one cardinality-one input port, and one output
  cannot be implicitly copied. Authors hitting this surprise compose with `*` (ADR 0052) instead,
  which inserts the adapter that aggregates the children's outputs into one product-shaped port the
  sink can consume. The language tour and `wire-code-style` skill must call this out prominently; it
  is the first surprise authors will hit.

### Obligations

- Reserve `make` as a built-in topology form.
- Reject dynamic-N arguments at the expander with a precise diagnostic.
- Reject unbound inline `make(...)` in graph position; require a binding.
- Document the identity scheme and the generated port-label convention in
  `docs/Reference/Wire/grammar.md`.
- Update the tree-sitter grammar to recognize `make` as a built-in form.
- Update the `wire-code-style` skill: kinds intended for `make` should expose the generated port
  label that `make` supplies, so `*` can pair generated families with the corresponding finite
  product shape.
- Add expansion tests for: `make(0, K)`, `make(1, K)`, large-N, nested `make` inside form bodies,
  `make` inside `make`, unbound-inline rejection, `make(N, K) => sink` rejection for N > 1 when
  generated outputs collide with the sink's cardinality-one inputs.
- Prove or document the preservation claim: after `make` expansion, the resulting Wire program
  admits unchanged under all existing graph, port, authority, and runtime invariants.

Lean note: `LinearPortGraph.MakeWitness` models the source-linearity side of this obligation. A
`make` expansion is a certified `LinearPortObject` built from open node ports, with generated nodes
owned by a shared binding projection and generated ports exact against the kind-derived child port
sets. Distinct binding namespaces supply the domain-disjointness witness needed for later overlay.
The executable Haskell expander and diagnostics remain separate correspondence work.

## Open questions

- **`make(1, K)` identity.** Keep the uniform `<binding>_0` suffix, or special-case to `<binding>`?
  Recommendation: keep `<binding>_0`. Uniform generation is better for proofs, diagnostics, and
  nested expansion; the visual clutter for the single-instance case is the smaller cost.

## Traceability

- Feature keys: `wire.bounded_node_generation`
- Public surface: `Cortex.Wire`, `docs/Reference/Wire/grammar.md`
- Implementation: `src/Cortex/Wire/Parser.hs` (`expandMakeBinding`, `GeneratedMakeChild`,
  `overlayGeneratedChildren`), `src/Cortex/Wire/Syntax.hs` (`ExprFamilyProjection`)
- Tests: `test/Cortex/Wire/ParserSpec.hs` (bound `make` expands into generated nodes and a graph
  binding; `make` with a preceding static count binding; `makeEach` duplicate-label rejection)
- Theory/proof: [Bounded fan composition row](../Reference/proof-status.md) (Lean
  `LinearPortGraph.MakeWitness`, `LinearPortGraph.Make.accept_portLinear` in
  `theory/Cortex/Wire/Make.lean` and `theory/Cortex/Wire/GeneratedForms.lean`)

## Related

- [ADR 0024 - Typed Executor Node Interface](./0024-typed-executor-node-interface.md)
- [ADR 0028 - Wire Topology Composition and Boundary Labels](./0028-wire-topology-composition-and-boundary-labels.md)
- [ADR 0045 - Wire Compile-Time Node-Body Kinds](./0045-wire-compile-time-node-body-kinds.md)
- [ADR 0046 - Wire Compile-Time Graph Forms](./0046-wire-compile-time-graph-forms.md)
- [ADR 0047 - Wire Frontier Linearity and Topology Operator Precedence](./0047-wire-frontier-linearity-and-precedence.md)
- [ADR 0052 - Wire Bounded Indexed Boundary Products](./0052-wire-bounded-indexed-boundary-products.md)
- [Chapter 05 - Wire Language](../Architecture/05-wire-language.md)
- [Wire Grammar Reference](../Reference/Wire/grammar.md)
