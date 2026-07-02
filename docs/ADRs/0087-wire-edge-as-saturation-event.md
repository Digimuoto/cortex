---
title: "ADR 0087 — Wire Edge as Saturation Event and the Port-Role Parametrization"
description:
  "Canonizes what an edge is: at the typed layer, the saturation event of one output endpoint
  matched against one input endpoint under the linear side-conditions; at the algebra layer, a bare
  ordered pair after forgetful lowering. Consequently an 'edge kind' can only live in the port roles
  as a refinement of the match — parametrized by (multiplicity, relation family, protocol state) —
  never as a color on the relation-layer edge and never as computation on the wire. Today's Wire is
  the degenerate instance. The parameter slots and the rule are closed substrate-owned structure;
  the vocabulary within slots is open by downstream registration, like contracts. Kind projections
  are witness queries, not stored graph structure. Every non-degenerate instance is design-only."
sidebar:
  label: "0087. Edge as saturation event"
  order: 87
status: proposed
date: 2026-07-03
superseded_by: null
related:
  - docs/ADRs/0047-wire-frontier-linearity-and-precedence.md
  - docs/ADRs/0079-wire-admission-witness-schema.md
  - docs/ADRs/0081-wire-endpoint-closure-accounting.md
  - docs/ADRs/0085-wire-contract-schema-as-type-enforcement.md
  - docs/ADRs/0086-wire-scoped-graph-construction-rejection.md
  - docs/Architecture/03-formalism-stack.md
  - docs/Reference/Wire/contracts-ports-and-matching.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/terminology.md
---

# ADR 0087 — Wire Edge as Saturation Event and the Port-Role Parametrization

## Status

Proposed — a **definition record**. It fixes what the word _edge_ means at each layer of the stack,
and therefore where an "edge kind" could ever live. It adopts no feature: today's Wire is the
degenerate instance of the definition, and every non-degenerate instance remains design-only, each
requiring its own ADR. The motivating pressure is Paper 5's causal-programming claim that "edges
have kinds": without a substrate-owned definition, that claim is ambiguous between a paper proposal
and a Wire design commitment, and its natural first reading — kinds stored on edges — is
unrealizable in this stack.

## Context

The word _edge_ names two objects at two layers, and they have incompatible affordances:

- **Typed layer.** An edge is not an object; it is the **saturation event** — the proof that
  `connect` matched one output endpoint against one input endpoint under the substructural
  side-conditions `hMatchedFunctional` / `hMatchedInjective` plus frontier disjointness
  (`theory/Cortex/Wire/FrontierTyping.lean:284-301`). Every typed property of "the edge" lives in
  the two endpoints: their contracts, labels, direction, and use. The judgment has exactly five
  constructors and no rule for any surface form (`theory/Cortex/Wire/FrontierTyping.lean:244-304`).
- **Relation (algebra) layer.** Here an edge _is_ a first-class ordered pair — but only after
  admitted lowering has **forgotten** port identity, port polarity, labels, and contracts; the pair
  keeps only its source→target order. Mokhov equality and the graph laws are stated over that
  forgetful image (`docs/Architecture/03-formalism-stack.md:65-68,120`). The alphabet is fixed at
  four constructors and "Cortex does not extend it" (`docs/Architecture/03-formalism-stack.md:199`).

So the layer where edges are objects has no port information, and the layer with port information
has no edge objects. A kind stored on the relation-layer edge changes the relation carrier, its
equality, and the forgetful-lowering contract — it is exactly the detail lowering is defined to
forget. A kind as active computation on the wire contradicts the edge's own semantics: "an edge
never evaluates an expression and never changes payload shape"
(`docs/Reference/Wire/contracts-ports-and-matching.md`, Nodes/Ports/Edges). That leaves exactly one
coherent home for edge kinds: the compatibility relation between two endpoint roles.

## Decision

1. **Edge, defined (canon).** At the typed layer, an edge **is** a saturated directed port pair: the
   successful application of the saturation predicate to one output endpoint and one input endpoint.
   At the relation layer, an edge is a bare ordered vertex pair, with all endpoint detail already
   forgotten. The word is layer-relative; documentation must say which layer it means when it
   matters.

2. **Kinds live in port roles, never on edges.** A **port role** is the parametrization of an
   endpoint for matching purposes:

   ```
   PortRole = (polarity, contract, label, multiplicity, relation family, protocol state)
   O saturates I  ⟺  polarity(O) = output ∧ polarity(I) = input
                     ∧ contract(O) = contract(I)   (exact name — no coercion, ADR 0085)
                     ∧ label(O) = label(I)
                     ∧ family(O) = family(I)
                     ∧ multiplicity permits this use
                     ∧ protocol transition valid
   ```

   The first three conditions are today's port-key match — output-to-input by exact
   `(contract, label)` (`docs/Reference/Wire/grammar.md:494-501`); the last three are the refinement
   slots, all pinned trivial in the degenerate instance.

   An "edge kind" is a **classification of the saturation event by its roles' parameters** — a
   refinement of the match, not a new object. Today's Wire is the **degenerate instance**: family
   `= {value}`, multiplicity `= {linear}` (an affine mode exists in the mechanization for `select`
   collapse, `theory/Cortex/Wire/SelectAdmission.lean`), protocol trivial, compatibility `=` nominal
   equality on the port key (`src/Cortex/Wire/Compile.hs:1783-1787`;
   `theory/Cortex/Wire/ElaborationIR.lean:304-310`).

3. **The refinement is bounded by ADR 0085's rule.** A kind may only **partition or grade** an
   already-typed match between two ports carrying the same contract — it may reject matches that
   would otherwise succeed, never manufacture one, and never relate two different contract names. A
   "kind" that transforms, duplicates, logs, persists, authorizes, or observes a value is a node or
   a witness, not structure on the match
   (`docs/ADRs/0085-wire-contract-schema-as-type-enforcement.md`, Decision 4).

4. **Slots closed, vocabulary open.** The parameter **slots** of `PortRole` and the **form** of the
   saturation rule are substrate-owned and closed, like the graph alphabet. The **vocabulary**
   within slots grows by downstream registration, like contracts — "the ecosystem grows by
   registering authority into a closed alphabet, not by mutating the alphabet"
   (`docs/Architecture/03-formalism-stack.md:204-205`):

   | Slot                   | Open or closed                                | Why                                                                                         |
   | ---------------------- | --------------------------------------------- | ------------------------------------------------------------------------------------------- |
   | Saturation rule's form | Closed                                        | Admission semantics must not be host-extensible                                             |
   | `contract`             | Open (registered)                             | Already true today                                                                          |
   | `relation family`      | Open (registered **names**, never predicates) | A family tag both sides must share can only _reject_; registered data cannot alter the rule |
   | `multiplicity`         | Closed small set (linear / affine / graded)   | Modes change the side-conditions; each needs mechanization                                  |
   | `protocol state`       | Open via contracts                            | State-threading through nominal contracts is expressible today                              |

   Downstream host bindings supply a kind's **dynamic** semantics (what a durable commit or an
   approval means) through executors, witnesses, and manifests — the same split contracts already
   have: matching semantics substrate-side, content semantics host-side.

5. **Projections are witness queries, never stored colors.** The admission artifact already carries
   per-edge endpoint detail (closure-mode and endpoint-use witnesses, schema v4,
   `docs/ADRs/0079-wire-admission-witness-schema.md`). A projection of the graph "along a kind" is a
   **derived view** computed from that witness — filter the saturation events by their roles'
   parameters — before lowering forgets. The runtime relation-layer graph stores no kind
   information, and the Mokhov laws are untouched.

6. **Sorting the causal-programming kind vocabulary.** Paper 5's six edge kinds are heterogeneous
   under this definition, and canon adopts the sorting:

   | Kind         | Disposition                                                                                                                                                 |
   | ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
   | value-flow   | The degenerate family in use today. Exists.                                                                                                                 |
   | resource     | A multiplicity-mode + family refinement of the match. Design-only.                                                                                          |
   | effect-order | The protocol axis; partially given today by linearity plus state-threading through contracts. A full protocol discipline is future work with its own gates. |
   | durability   | **Not an edge kind** — persistence is a node/witness concern.                                                                                               |
   | observation  | **Not an edge kind** — `T → Observation<T>` transforms, hence an observer node (the ADR 0085 rule's canonical violation).                                   |
   | policy       | **Not an edge kind** — authorization is a node/witness concern carried by capability and contract boundaries.                                               |

   The last three remain first-class citizens of the causal graph — as nodes, witnesses, and
   provenance — and their "edges" are the ordinary value-flow/order edges incident to those nodes.

7. **Everything non-degenerate is design-only.** No `EdgeKind`/`valueFlow` type or relation exists
   in `src/` or `theory/`. Each non-degenerate instance (a first registered family beyond `value`;
   an affine/graded multiplicity mode on general ports; any protocol discipline) requires its own
   ADR and a mechanization plan — the concrete first proof target being a mode-parametrized
   generalization of the `connect` side-conditions
   (`theory/Cortex/Wire/FrontierTyping.lean:284-301`).

## Alternatives considered

- **First-class colored edges.** Rejected: a retained color changes the relation carrier, its
  equality, and the forgetful-lowering contract; the Mokhov laws hold only past the forgetting
  (`docs/Architecture/03-formalism-stack.md:65-68`), and the alphabet is fixed (`…:199`). This is
  the reading the paper's phrase "edges have kinds" naively invites, and it is blocked.
- **Kinds as Axis-2 forms.** Rejected: forms erase before typing; an edge kind must be
  runtime-relevant and live inside the judgment. Opposite axes.
- **Downstream-registered match predicates.** Rejected: letting host bindings inject predicate
  _code_ into saturation makes admission semantics host-extensible and non-portable. Downstream
  registers names into partition slots; the rule stays closed.
- **Leave the definition to the paper.** Rejected: the publication would then propose an ontology
  its own substrate contradicts (colored edges), and every future edge-kind discussion re-litigates
  where kinds live. A definition record is cheap; ambiguity is not.

## Consequences

### Positive

- Paper 5 can cite a substrate definition instead of proposing its own ontology; the paradigm claim
  becomes precise and its projection claims become mechanizable (witness queries) rather than
  aspirational (stored colors).
- Kind-vocabulary growth is registration, not core change — the same extension philosophy as
  contracts, with the safety argument (reject-only tags) stated once.
- The three-way terminology hazard around "saturation" is closed: the Axis-1 **match relation**
  (this ADR), the rejected block-level `saturate` **directive** (ADR 0086), and Pulse scheduler
  **pool saturation** (ADR 0068) are three distinct things, now each with a canonical home.

### Negative

- Nothing new is buildable from this ADR alone: it constrains and defines. Anyone wanting a real
  edge kind still owes an ADR, a registry design (for families), and Lean work (for modes).
- The effect-order/protocol axis stays partially answered; a full protocol discipline (duality,
  channel identity, recursion) is explicitly out of scope here and larger than the kind machinery.

### Obligations

- Keep `docs/Reference/terminology.md` (Edge, Saturation, Port role rows) and Paper 5 §3.4 aligned
  with this definition; drift is a documentation-canon defect.
- Any first non-degenerate instance must cite this ADR and ADR 0085's refinement rule, and must
  state which slot it populates and why the slot's open/closed status is respected.

## Traceability

- Feature keys: none (definition record; no feature ships)
- Public surface: none new; the definition describes `=>`/`connect` as shipped
- Implementation: none (degenerate instance is current behavior;
  `src/Cortex/Wire/Compile.hs:1783-1787`)
- Tests: none new
- Theory/proof: the degenerate instance is what `theory/Cortex/Wire/FrontierTyping.lean:284-301`
  already mechanizes; the mode-parametrized generalization of the `connect` side-conditions is the
  named first proof target for any non-degenerate instance

## Related

- [0085-wire-contract-schema-as-type-enforcement.md](0085-wire-contract-schema-as-type-enforcement.md)
  — the no-subtyping ceiling and the partition-or-grade refinement rule this definition is bounded
  by.
- [0086-wire-scoped-graph-construction-rejection.md](0086-wire-scoped-graph-construction-rejection.md)
  — the rejected block-level `saturate` _directive_; the saturation _relation_ defined here is a
  match predicate, not a construction pass, and the two must not be conflated.
- [0047-wire-frontier-linearity-and-precedence.md](0047-wire-frontier-linearity-and-precedence.md) —
  the linear match discipline the saturation predicate generalizes.
- [0079-wire-admission-witness-schema.md](0079-wire-admission-witness-schema.md) /
  [0081-wire-endpoint-closure-accounting.md](0081-wire-endpoint-closure-accounting.md) — the
  endpoint-use witnesses that kind projections query.
- [03-formalism-stack.md](../Architecture/03-formalism-stack.md) — forgetful lowering, the fixed
  Mokhov alphabet, and the registered-authority extension philosophy.
- [Paper 5](../Publications/Paper-5-Causal-Programming/manuscript.md) — §3.4, the causal-programming
  kind vocabulary this ADR gives a substrate home.
