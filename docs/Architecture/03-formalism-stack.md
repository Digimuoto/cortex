---
title: "Chapter 03 — Algebraic Foundations"
description:
  "Why the Cortex topology model is algebraic, what laws it preserves, and why rewrites can stay
  structural rather than ad hoc."
sidebar:
  label: "03. Algebraic foundations"
  order: 3
status: active
---

# Chapter 03 — Algebraic Foundations

Cortex is a stack of algebras chosen so that each layer adds exactly one kind of authority. The
Graph layer contributes pure topology. The Circuit layer adds validation. Wire adds a surface syntax
whose operators refine the algebraic primitives one level below. Rewrites are structural edits
stated over the same algebra that authored the topology. This chapter records the formal basis of
that stack and the laws it preserves; proofs live in the publications and are only referenced here.

If you are evaluating Cortex rather than studying the foundations in detail, the core model below is
the important part. The later sections explain why the rewrite story and topology model stay
coherent under that surface.

## Core model

Three layers, each defined over the previous:

| Layer   | Object                                                | Algebra                                                             |
| ------- | ----------------------------------------------------- | ------------------------------------------------------------------- |
| Graph   | Pure topology: vertices and edges over a carrier set. | `Empty \| Vertex \| Overlay \| Connect`, per Mokhov.                |
| Circuit | Validated executable topology: nodes plus wires.      | Graph plus DAG invariant plus port-contract compatibility.          |
| Wire    | Source language that authors Circuits.                | `<>` (overlay) and `=>` (port-key-matched connect), plus value ops. |

Pulse is the durable runtime that executes Circuits. It is not a new algebra; it interprets the
Circuit object and applies admitted rewrites at runtime. The algebraic stack itself ends at Circuit
— Pulse is the mechanical realization of its semantics.

The load-bearing property across these layers is **composition closure**. A wire value composed with
another wire value under `<>` or `=>` is itself a wire value. The class is closed under its own
operators. This is what makes source authoring, configured executor reuse, and rewriting tractable:
authors and rewrites manipulate the same kind of object the compiler consumes.

Composition closure is graph-theoretic, not the whole resource story. Wire also tracks **boundary
obligations**: the input/output contract boundary that an operation consumes, preserves, or
transforms. Boundary resources sit above Mokhov graph equality. They say whether a rewrite,
conditional, or planner certificate has accounted for the exposed contract boundary it promises,
while the graph algebra still says what topology denotes.

## Detailed structure

### Mokhov's algebraic graph model

Wire's graph expressions inherit their primitive constructor set from Mokhov's _Algebraic Graphs
with Class_ (2017): `Empty | Vertex | Overlay | Connect`. Any finite directed graph can be
constructed from these four constructors, and the denotational object (vertex set plus edge set) is
determined by the laws of overlay (commutative monoid with `Empty` as identity) and connect
(associative, distributes over overlay, decomposes into overlay plus the edge fringe).

Cortex treats this algebra as axiomatic at the Graph layer. `Cortex.Graph` lowers the
four-constructor expression to a `Relation` carrier via `foldg`; every downstream layer operates on
that denotation. The laws hold by construction because the interpretation is the standard one. For
their algebraic statement and the proof obligations they carry into the staged-execution setting,
see [`paper 2`](../Publications/Paper-2-algebraic-foundations/manuscript.md).

### Wire's `<>` and `=>` as refinements

Wire's two graph operators correspond directly to Mokhov's primitives, but refine them:

- **`<>` (overlay)** is exactly Mokhov's Overlay. Set-union of vertices and edges across two wires.
  It inherits the Mokhov laws unchanged: commutative monoid with `Empty` as identity, idempotent
  when the operands share vertices.

- **`=>` (connect)** is a _refinement_ of Mokhov's Connect, not an instance of it. Mokhov's Connect
  takes the cross product of left outputs against right inputs and unions the resulting edges.
  Wire's `=>` is **port-key-matched**: an edge is added between a left-hand boundary output and a
  right-hand boundary input only when their port keys agree on `(direction, contract, label)`. An
  absent label is itself a key, not a wildcard. The result is a deterministic cross-product with a
  filter: fewer edges than Mokhov's Connect for the same endpoints, never more.

This refinement is why `=>` lands usable edges instead of a combinatorial mesh of unchecked
connections. It also preserves the Mokhov laws where they matter: overlay's associativity and
commutativity hold on Wire values; connect remains associative under port-key matching;
`Empty <> w = w` and `Empty => w = w`. The laws that involve the cross-product shape of Connect
(full distributivity over Overlay) hold only on the port-matched projection, which is the only form
Wire ever exposes. See [`terminology.md`](../Reference/terminology.md) for the normative definitions
of port key and the composition algebra.

### DAG semantics as a Circuit-layer invariant

The pure Graph layer is acyclic-agnostic. Mokhov's algebra constructs arbitrary directed graphs, not
DAGs. Cortex does not collapse this distinction: acyclicity is a **Circuit-layer invariant**, not a
Graph-layer one. The Graph algebra stays maximally permissive so that intermediate fragments,
rewrite templates, and source-authored fragments can use the full algebraic surface. Cycles are
rejected when a graph is promoted to a Circuit — the point at which the topology becomes an
executable artifact.

This placement matters because rewrite fragments may be algebraically simpler than their insertion
target; forcing them to be acyclic in isolation would over-constrain the algebra. The Circuit
validator is also the natural place to pair acyclicity with the other executable invariants:
port-contract compatibility, runnable-wire boundary checks, and payload-kind admission. The full
list lives in [`chapter 04`](./04-graph-and-circuit.md); the formalism only requires that they
attach at the Circuit boundary.

### Rewrite algebra

A rewrite is a structural edit: a function from a Circuit to a Circuit whose effect is expressible
as a composition of Mokhov operators applied at an anchor. In Wire terms, a rewrite fragment is
itself a wire value, and admitting a rewrite is overlaying that fragment into the live topology and
re-connecting endpoints under `=>`. Because the fragment and the target belong to the same algebraic
class, admission is law-preserving by construction: the post-rewrite object satisfies exactly the
same overlay and connect laws as the pre-rewrite object.

The rewrite algebra is stated as vertex-anchored substitution: a fragment is spliced at a designated
vertex through a typed interface, preserving causal structure outside the interface. This is the
substitution semantics developed in
[`paper 3`](../Publications/Paper-3-graph-substitution-semantics/manuscript.md). The operational
side — gas, admission, materialization, replay contracts — is the subject of
[`chapter 07`](./07-rewrites-and-materialization.md). The formalism only records that rewrites are
algebraic operations over the same object class, not a separate mutation layer.

Boundary resources refine that statement without changing the algebra. A contract-preserving
substitution consumes the anchor's boundary obligation and must expose the same boundary again. An
append continuation keeps the anchor node and consumes the anchor output as the continuation input.
A conditional branch actualization consumes an owner-bound actualization capability and promotes one
guarded branch into the live linear resource context. Those are resource laws over the graph
operation; they are not new Mokhov constructors.

### Latent structural control

`select(...)` is the first accepted **latent structural control** operator. Before selection, its
branches are a sealed family of graph possibilities, not live topology and not a fifth constructor
in the graph algebra. Every branch can be checked against its variant boundary, but each
branch-local obligation is guarded and affine until the selected arm is actualized.

After selection, the chosen branch lowers to ordinary Wire graph composition and the usual overlay
and connect laws apply to the materialized result. Unselected branches do not become graph fragments
for the run. This is how Wire can represent structured runtime choice without treating conditionals
as ordinary fan-out or hiding the choice inside executor code.

## Boundaries and invariants

What this stack enforces:

- **Composition closure.** Wire graph values are closed under `<>` and `=>`. Authored topology and
  rewrites share the same object class as finished circuits.
- **Law preservation through refinement.** `<>` inherits Mokhov overlay laws. `=>` preserves those
  laws on the port-key-matched projection.
- **Layered invariants.** Acyclicity and port-contract compatibility attach at the Circuit boundary,
  not at Graph. Fragments remain algebraically first-class below that line.
- **Boundary-resource accounting.** Structural operations consume, preserve, or transform declared
  boundary obligations. Node identity, provenance envelopes, and boundary obligations are related
  but not the same resource.
- **Latent control lowers after resolution.** A latent branch family is checked before runtime, but
  only the selected branch enters the live graph and inherits the graph laws.
- **Rewrites as algebraic operations.** Structural edits are expressible in the same algebra that
  authored the topology; admission preserves the laws.

What the stack does not enforce: executor semantics, payload-kind validation, runtime scheduling,
provenance — all delegated to Circuit, Pulse, or the contract registry.

## Extensibility

The Mokhov alphabet is fixed at four constructors. Cortex does not extend it. New authoring
convenience enters Wire as derived value operators (`//`, `++`, `let`, configured executor values)
that reduce to explicit graph vertices before the expression reaches the Graph layer. New semantic
categories — payload kinds, boundary-resource modes, structural-authority classes, and latent
structural control operators — attach as registry metadata, proof obligations, or runtime admission
rules above the Circuit layer, not as new graph primitives. The algebra stays small on purpose; the
ecosystem grows by registering authority into a closed alphabet, not by mutating the alphabet.

## Related

- [`../Reference/terminology.md`](../Reference/terminology.md) — normative vocabulary.
- [`./01-overview.md`](./01-overview.md) — three-layer model and ownership.
- [`./04-graph-and-circuit.md`](./04-graph-and-circuit.md) — Graph and Circuit mechanics.
- [`./05-wire-language.md`](./05-wire-language.md) — Wire substrate; grammar at
  [`../Reference/Wire/grammar.md`](../Reference/Wire/grammar.md).
- [`./07-rewrites-and-materialization.md`](./07-rewrites-and-materialization.md) — rewrite admission
  mechanics.
- [`../ADRs/0032-wire-boundary-contract-resources.md`](../ADRs/0032-wire-boundary-contract-resources.md)
  — boundary obligations as planning resources.
- [`../ADRs/0037-wire-latent-structural-control.md`](../ADRs/0037-wire-latent-structural-control.md)
  — latent structural control operators and their graph-algebra boundary.
- [`../Publications/Paper-2-algebraic-foundations/manuscript.md`](../Publications/Paper-2-algebraic-foundations/manuscript.md)
  — algebraic foundations of staged durable execution.
- [`../Publications/Paper-3-graph-substitution-semantics/manuscript.md`](../Publications/Paper-3-graph-substitution-semantics/manuscript.md)
  — vertex-anchored substitution semantics.
- [`../Research-notes/Foundation/2026-04-11-formalism-stack-synthesis.md`](../Research-notes/Foundation/2026-04-11-formalism-stack-synthesis.md)
  — live research on topology/intent/authority split.
