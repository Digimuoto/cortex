---
title: "ADR 0049 - Wire Phantom Record↔Ports Adapter for Topology Fans"
description:
  "Adds the * topology operator that elaborates to a phantom node from a parametric record↔ports
  adapter family in Wire's closed alphabet."
sidebar:
  label: "0049. Fan phantom adapter"
  order: 49
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
  - docs/ADRs/0045-wire-compile-time-node-body-kinds.md
  - docs/ADRs/0046-wire-compile-time-graph-forms.md
  - docs/ADRs/0047-wire-frontier-linearity-and-precedence.md
  - docs/ADRs/0048-wire-make-bounded-node-generation.md
---

# ADR 0049 - Wire Phantom Record↔Ports Adapter for Topology Fans

## Status

Proposed - this ADR introduces the `*` topology operator. It depends on ADR 0047 for the linear
endpoint rule, match determinism, and the precedence slot reserved for `*`. ADR 0048 supplies the
typical multi-port frontier (`make(N, K)`) that `*` consumes.

## Context

ADR 0024 forbids implicit aggregation: authored inputs are cardinality-one, and aggregation belongs
in an explicit node. ADR 0047 sharpens this with the linear endpoint rule: each output and each
input is consumed at most once during composition.

Together those rules make `make(N, K) => sink` a static error for N > 1 when several generated
children expose the same `(label, contract)` and the sink's input is cardinality one. The correct
authoring shape is an explicit adapter that converts the multi-port frontier into one
aggregate-typed port (gather) or one aggregate-typed port into a multi-port frontier (scatter).

This ADR adds that adapter and the operator that surfaces it.

## Decision

Wire adds a `*` topology operator that elaborates to a **phantom record↔ports adapter** inserted
between its two operands; ordinary `=>` does all the wiring.

The defining equivalence:

```
a * b   ≡   a => phantom => b
```

Both `=>` edges are ordinary boundary contractions under ADR 0047. The phantom node has two
boundaries:

- The **multi-side**, mirroring the multi-port frontier of whichever operand carries one. Each port
  is a regular cardinality-one port; ordinary `=>` matches them against the multi-side operand's
  ports under ADR 0047's match rule.
- The **singular side**, a single port of nominal record contract.

There is no `spoke_i` surface vocabulary at the topology layer. Pairing happens by record field and
port label inside the phantom's CorePure body.

The phantom belongs to a **parametric family of structural adapters** indexed by nominal record
shape: the closed alphabet contains the family, and `*` selects the instance whose shape matches the
call site. This is the same parametric move that makes `Option[T]` part of the language without
admitting user-defined generics.

### Record-form discriminator

The phantom's body and multi-side shape are determined by the **singular side's expected nominal
record contract**:

- When the singular side's port contract is a nominal record contract with fields
  `{label_1: T_1, ..., label_N: T_N}`, the phantom synthesizes multi-side ports `label_i: T_i` per
  field.
- The body pairs by **label**: `agg.label_i` ↔ multi-side port `label_i`.
- The multi-side operand's exposed port set must match the record's fields exactly: same labels,
  same contracts. A mismatch is a static error.
- A singular side whose contract is not a nominal record is a static error.

List-style aggregation (a homogeneous N-ary list contract) is not part of v1. Future work may
introduce a bounded list contract, repurpose integer-keyed nominal records, or stay with record-form
only; that decision is out of scope here.

### No mixed forms

There is no Wire contract that combines a nominal record with a positional list. Authors who want
partially-uniform aggregates compose multiple `*` calls or write the adapter by hand. The exclusion
of mixed forms is a corollary of the nominal-record discriminator.

### Phantom synthesis

The phantom is **always generated**, including for the degenerate cases:

- **Empty fan** (multi-side has zero ports): the phantom is generated with empty multi-side and a
  singular-side port of empty nominal record contract. The two `=>` edges connect normally; the
  empty multi-side simply contributes no edges. The elaborator emits a lint warning at synthesis:
  "`*` over an empty fan generates a degenerate phantom; consider whether the empty case was
  intended." Firing at synthesis (not parse) catches non-literal-zero N too. The always-generate
  stance keeps elaboration uniform and forward-compatible with conditional graph elaboration if that
  lands.
- **Singleton fan** (multi-side has one port): the phantom is generated. Authors who do not want the
  phantom for N=1 use `=>` directly.

### Port-clash diagnostic

A port clash on the synthesized phantom is a static error: "phantom would have two outputs of the
same (label, contract); rename or use a record contract." The diagnostic points at the `*` call site
and at the phantom's synthesized boundary. Clashes only matter once the phantom is synthesized;
multi-side operand label collisions are handled there, not at the operand site.

### Match determinism

Under phantom-insertion, all topology-level wiring is ordinary `=>` boundary contraction. Match
determinism for `*` therefore reduces to ADR 0047's rule for `=>`: every endpoint has zero or one
compatible counterpart; multiple is a static error. **No new tiebreak surface is introduced.**

### Canonical rule

Fan operators expand only to ordinary graph vertices and ordinary valid port edges. `*` inserts
exactly one phantom vertex and emits two `=>` edges (one to each operand); the phantom's body
performs the only aggregate-field projection in the entire elaboration, and that projection is
confined to CorePure. There are no hidden adapters, no implicit aggregation, no changes to `=>`
semantics, and no surface vocabulary for spokes.

### Static errors

- Singular side's contract is not a nominal record.
- Multi-side operand's exposed port set does not exactly match the nominal record's fields (label or
  contract mismatch).
- Phantom synthesis would produce a port clash.
- Both sides flat singleton: "`*` requires a multi-element frontier on at least one side; for 1:1
  wiring use `=>`."
- Both sides multi-element: "`*` requires exactly one singular side; both operands carry
  multi-element frontiers."

## Alternatives considered

- **Separate `broadcast` and `gather` macros.** Rejected because the fan direction is unambiguously
  determined by the boundary shape; one operator with shape-driven direction is honest about what is
  happening, and it composes cleanly with the existing topology operators. Two macros would need
  their own grammar, identity rules, and diagnostics.
- **`<` and `>` as directional fan operators.** Considered briefly. Visually appealing
  (`a < (b, c) > d` reads as a funnel) but bites on overlays (`a < b <> c > d` is ill-formed because
  no operand is a tuple), and `<` shares tokens with CorePure comparison. Rejected for the simpler
  `*` with shape-driven direction.
- **`*` synthesizes adapters with no visible vertex.** Rejected because every Wire vertex is an
  ordinary `node` declaration with a CorePure or executor body; hidden adapters would violate the
  rule that the elaborated program is fully readable as Wire source.
- **List-form aggregation in v1.** Rejected. A bounded homogeneous list adapter would need `[T; N]`
  contracts and positional projection in CorePure before it can type-check. Record-form `*` is the
  smaller first slice because it pairs existing labeled ports to nominal record fields by name.
- **Unnamed ports for list-form aggregation.** Considered and rejected with list-form v1. List-form
  `*` feels like it wants nameless homogeneous multi-side ports, since they are all the same
  contract. That would introduce a second port flavor and weaken the label discipline. If bounded
  lists land later, they should still preserve explicit field/index ownership rather than discard
  authored labels silently.

## Consequences

### Positive

- Bounded aggregation and scatter become compact and readable. The aggregation hub is an explicit,
  visible node with a known body.
- The static-topology invariant is preserved: every vertex is still introduced by a source-level
  construct that the expander resolves before lowering.
- `*`'s phantom is an ordinary pure node that obeys port matching, authority, and runtime invariants
  without special-case handling.
- Match determinism for `*` is inherited from ADR 0047; no new rule surface is introduced.

### Negative

- One new built-in identifier (`*`) and a closed-alphabet adapter family enter the Wire surface.
- The closed alphabet now includes a parametric structural-adapter family (record↔ports adapters).
  This is a real extension of the alphabet; it must be documented as such, and any formal claims
  about Wire's alphabet (in the architecture chapter or papers) must reflect that the family is
  parametric over aggregate shape but otherwise fixed.

### Obligations

- Reserve `*` as a built-in topology operator under ADR 0047's reserved precedence slot.
- Reject `*` with two flat singletons (use `=>`) and `*` with two multi-element frontiers (ambiguous
  fan).
- Document the phantom-insertion equivalence in `docs/Reference/Wire/grammar.md`.
- Update the tree-sitter grammar to recognize `*` as a topology operator.
- Update the `wire-code-style` skill.
- Amend `docs/Architecture/04-graph-and-circuit.md` in the same change set as this ADR's acceptance
  to document the parametric record↔ports adapter family as part of Wire's closed alphabet.
- Add expansion tests for: record-form `*`, empty-fan `*` lint warning, port-clash diagnostic at
  phantom synthesis, record-form rejection on label-set mismatch, rejection of flat-singleton `*`
  and double-multi `*`, `make(N, K) => sink` resolution via `*`.
- Prove or document the preservation claim: after `*` expansion, the resulting Wire program admits
  unchanged under all existing graph, port, authority, and runtime invariants.

## Open questions

- **Nominal-record contract surface.** This ADR commits to "the singular side's contract is a
  nominal record." Implementation may reveal that ADR 0024's existing record contracts are not
  nominal enough for `*` to read field labels off the contract itself. If so, the implementation
  must stop and add a small contract-surface ADR before elaborating `*`.
- **Future aggregate shape.** Whether list-style aggregation ever lands is genuinely open, with
  three sub-options: a bounded list contract `[T; N]` (with positional projection `agg[i]` in
  CorePure), integer-keyed nominal records (no new contract surface, heterogeneous-record typing
  does more work), or no list-style topology aggregation at all.

## Related

- [ADR 0024 - Typed Executor Node Interface](./0024-typed-executor-node-interface.md)
- [ADR 0028 - Wire Topology Composition and Boundary Labels](./0028-wire-topology-composition-and-boundary-labels.md)
- [ADR 0045 - Wire Compile-Time Node-Body Kinds](./0045-wire-compile-time-node-body-kinds.md)
- [ADR 0046 - Wire Compile-Time Graph Forms](./0046-wire-compile-time-graph-forms.md)
- [ADR 0047 - Wire Frontier Linearity and Topology Operator Precedence](./0047-wire-frontier-linearity-and-precedence.md)
- [ADR 0048 - Wire Compile-Time Make for Bounded Node Generation](./0048-wire-make-bounded-node-generation.md)
- [Chapter 04 - Graph and Circuit](../Architecture/04-graph-and-circuit.md)
- [Chapter 05 - Wire Language](../Architecture/05-wire-language.md)
- [Wire Grammar Reference](../Reference/Wire/grammar.md)
