---
title: "ADR 0039 — Wire Boundary Polarity and Terminators"
description:
  "Wire graph values carry a typed boundary signature whose slots are open or sealed; `!` is the
  surface form of the sealing tag, not a node and not an executor."
sidebar:
  label: "0039. Boundary polarity"
  order: 39
status: proposed
date: 2026-04-30
superseded_by: null
related:
  - docs/Reference/Wire/conditionality.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/contracts-ports-and-matching.md
  - docs/Architecture/04-graph-and-circuit.md
  - docs/Architecture/05-wire-language.md
  - docs/ADRs/0005-budgeted-rewrite-admission-and-materialization.md
  - docs/ADRs/0006-compiled-workflow-artifact-boundary.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0028-wire-topology-composition-and-boundary-labels.md
  - docs/ADRs/0032-wire-boundary-contract-resources.md
  - docs/ADRs/0033-wire-select-guarded-affine-collapse.md
  - docs/ADRs/0035-wire-rewrite-algebra-forms.md
  - docs/ADRs/0036-wire-latent-branch-budget-recovery.md
  - docs/ADRs/0037-wire-latent-structural-control.md
  - docs/ADRs/0038-wire-proof-track-theorem-ledger.md
---

# ADR 0039 — Wire Boundary Polarity and Terminators

## Status

Proposed — settles the `!` terminator and boundary-openness mechanism deferred in
[`docs/Reference/Wire/conditionality.md`](../Reference/Wire/conditionality.md) §14.3, provides the
boundary mechanism that future §14.2 absorptive-arm work can use, and adds the missing axis (port
openness) to the topology composition model proposed in ADR 0028.

## Context

ADR 0028 introduces `<>` (overlay) and `=>` (connect) over Wire circuits with **exposed
boundaries**: vertices and edges from each operand are retained, and unmatched exposed ports remain
on the composed boundary. The model is otherwise minimal and uniform: every exposed port is
implicitly connectable, and connect succeeds whenever contracts and labels match.

The conditionality reference explicitly defers two related questions:

- §14.2 — whether later versions admit terminating or absorptive arms that do not expose the shared
  downstream boundary;
- §14.3 — whether a dedicated terminator such as `!` becomes the first extension after the initial
  `select(...)` design.

Those questions touch `select(...)`, but this ADR does not use boundary sealing to explain
`select(...)` itself. `select(...)` is latent structural control: before collapse, its arms are
guarded affine alternatives, not live graph values with ordinary exposed boundaries. This ADR is
narrower. It addresses ordinary graph-value boundaries after a graph exists or after a selected arm
has been promoted into live topology.

Wire today has no way to say _"this boundary slot is exposed, but it must not be connected."_ That
gap appears in ordinary composition and in future termination work:

- **Topology composition** (ADR 0028) treats every exposed boundary slot as connectable.
- **Terminating / absorptive graph values** have no surface form, leaving authors to encode closure
  as awkward continuations.
- **Structurally closed graph values** can be useful for isolation and artifact visibility, but
  closure needs to remain distinct from executor authority, CorePure authority, and runtime
  materialization.

Cortex needs one typed boundary fact for _exposed but not connectable_ graph-value slots.

## Decision

A graph-valued Wire expression carries a typed **boundary signature**. Each boundary slot is:

```text
BoundarySlot
  { direction : In | Out
  , contract  : ContractId
  , label     : Maybe Label
  , openness  : Open | Sealed
  }
```

The boundary signature is part of the graph value's type. The slot is exposed in the signature
regardless of openness; openness only governs eligibility for composition.

In this ADR, **openness** is the `Open | Sealed` field. **Polarity** is the upstream/downstream
placement of that openness fact, derived from slot direction and from whether the author writes
`a => !` or `! => a`.

The composition operators from ADR 0028 are refined:

- `<>` (overlay) preserves both operands' slot signatures by disjoint union of slots; openness is
  carried through unchanged.
- `=>` (connect) connects only `Open Out` slots to compatible `Open In` slots. A sealed slot has no
  connectable endpoint at the type level: the elaborator rejects any composition that would route an
  edge incident to a `Sealed` slot, with a diagnostic that distinguishes sealed-by-design from
  no-matching-port.

`!` is **surface syntax for sealing**, not a node, not an executor, and not a wildcard. Two
placements are admissible:

```wire
a => !          -- seal the matching downstream boundary slot(s) of a
! => a          -- seal the matching upstream boundary slot(s) of a
```

The placement is read as an openness tag attached to a boundary slot of the bound graph value. The
_node_ port declaration is unchanged: a node still declares what it can produce or accept locally.
The boundary signature describes which of the graph-value's exposed slots are eligible for external
grafting.

Bare `!` is admissible only when the boundary slot it seals is uniquely inferred in context. When
ambiguous, authors write the explicit shape:

```wire
a => !(result: ResearchPlan)
a => !{ result: ResearchPlan, error: ExecutorError }
```

The short shape `!(result)` or `!{ result, error }` is valid only when labels uniquely identify
slots in the relevant direction. If a label is ambiguous, the explicit `label: Contract` form is
required. There is no bare seal-all form. This preserves the no-wildcard rule from ADR 0028.

`()` and `!` remain semantically distinct:

- `()` is the empty wire and identity under composition (`a => () = a`); it exposes the current
  boundary unchanged. (See conditionality.md §6.)
- `!` is boundary closure; it removes the targeted slot from the open interface while leaving it
  visible in the signature as a sealed fact.

Sealing prevents external grafting. It does **not**:

- satisfy required inputs (a sealed `In` slot still needs its node-local input from elsewhere in the
  graph for the circuit to be runnable);
- erase the node's runtime behaviour (the node behind `a => !` still executes; its output may be
  materialized for provenance, but no successor may consume it through the sealed slot);
- decide `select(...)` branch materialization (ADR 0033 and ADR 0037 still own the latent-to-live
  transition).

A graph value whose entire boundary is sealed is **closed**. A closed graph is _runnable_ iff every
required `In` slot is satisfied by internal structure; closed-but-not-runnable is a typing error
caught by the elaborator, not a runtime failure.

For the current cardinality-one input surface, `! => a` is therefore only useful when the targeted
upstream obligation is already internally satisfied by the graph value, or when a future optional
input mode explicitly admits unsatisfied closure. Sealing an ordinary required input that still has
no internal source is rejected as closed-but-not-runnable.

## Non-goals

These are explicit non-goals so this ADR does not overclaim:

- **Does not explain `select(...)` non-grafting.** ADR 0033 and ADR 0037 own that through latent
  structural control: branch arms are guarded affine alternatives before selection, not live graph
  values with exposed connectable boundaries. The selected arm becomes an ordinary live graph
  fragment after actualization. `!` applies only if that selected graph explicitly seals one of its
  own boundary slots.
- **Does not replace CorePure authority closure.** ADR 0010 closes authority syntactically and
  through the builtin environment. Boundary openness may be useful for graph values that should not
  accept additional authority-bearing connections, but it is not the proof that CorePure is
  authority-free.
- **Does not assign runtime semantics to sealing.** Sealing is a compile-time boundary fact. The
  Pulse runtime sees no `Sealed` flag at execution time.
- **Does not change `()`.** Empty wire keeps its identity behaviour from conditionality.md §6.
- **Does not introduce a wildcard.** ADR 0028's no-wildcard discipline holds for `!` placement.

## Adversarial cases addressed

The kritikos lens identifies six cases the surface must answer before it can be accepted. Each is
resolved here so future implementation work has a single reference.

### A1 — Bare `!` on a multi-boundary graph

If a graph value exposes more than one open boundary slot in the relevant direction, bare `!` is
ambiguous and rejected. Authors must write the explicit shape:

```wire
review_report => !(reviewed: ReviewedReport)        -- seal one slot, leave others open
review_report => !{ reviewed, issue }               -- seal both named slots
```

The elaborator infers the slot only when the inference is unique; the rule mirrors the existing
no-wildcard discipline for labels in ADR 0028.

### A2 — Closed vs runnable

A graph with every output slot sealed and every input slot internally satisfied is **closed and
runnable**. A graph with sealed input slots whose underlying node-local input obligations remain
unsatisfied is **closed but not runnable**, and the elaborator rejects it with a diagnostic that
names the unsatisfied node-local input. Sealing is a boundary fact; runnability is a node-input
fact; both must be checked.

### A3 — Sealing is value-preserving, not control-terminating

`a => !` does not skip `a`. The node behind `a` executes normally; its output may be materialized
and provenanced according to existing rules; only the downstream graft path is removed. This keeps
sealing aligned with Pulse's settled-state and provenance model and avoids inventing a "discard
node" semantics.

### A4 — Interaction with `select(...)` arms

`select(...)` creates guarded affine branches from the perspective of the outside graph. Each branch
may be used zero or one times: the selected branch is promoted into live topology, and unselected
branches are never promoted. That affine latent-control rule, not boundary sealing, is why
unselected arms cannot graft into live topology.

After a branch is selected, its materialized graph may contain `!` like any other graph value. The
future "absorptive arm" (conditionality.md §14.2) can therefore use `!` to close the selected
branch's downstream boundary after actualization, but relaxing the current productive-arm
convergence rule remains a future `select(...)` decision, not this ADR.

### A5 — Budget interaction

A sealed downstream slot does not produce future frontier obligation through that slot. This is an
open-frontier fact, not a replacement for rewrite budget policy in ADR 0005 or selected-branch
budget policy in ADR 0036. Concretely: any frontier-breadth or open-interface accounting should
count open-out slots, not sealed-out slots. The proof-side ledger row in ADR 0038 should record this
as part of boundary-openness preservation.

### A6 — Tooling visibility

Sealed slots are visible to operator surfaces, the editor, the LSP, and serialized boundary
signatures in compiled artifacts. Hidden sealedness would be worse than explicit sealedness because
sealing is intentional architecture. The artifact contract from ADR 0006 should expose sealed slots
alongside open ones.

## Alternatives considered

- **Polarity tag on node port declaration.** Rejected because the same node referenced from
  different expression contexts would appear to have different ports. The boundary is a property of
  the graph value, not of the node; openness must live on the graph-value's exposed boundary
  signature, not on the node's local port declaration.

- **`!` as a pseudo-node (terminator node with no executor).** Rejected because it would require the
  executor catalog to admit a node with no semantics, would push sealing into runtime
  representation, and would obscure that sealing is a compile-time type fact.

- **Bare `!` as wildcard seal-all.** Rejected because ADR 0028 forbids wildcards in port matching;
  permitting one for sealing would introduce hidden bulk operations exactly where Wire avoids them.

- **Encode sealed slots as boundary entries that simply do not appear in the cospan gluing leg.**
  Rejected for the surface model because removing sealed entries from the signature loses the
  ability to report them to authors as deliberate sealed obligations. The implementation may still
  use that representation internally, but the surface signature distinguishes open from sealed
  slots.

- **Use boundary sealing to explain `select(...)` non-grafting.** Rejected because `select(...)`
  lives in the latent structural-control layer. Before selection, branch arms are guarded
  alternatives rather than live graph values with sealed boundary slots. Boundary sealing applies to
  ordinary graph values before or after selection, not to the latent family semantics itself.

- **Reduce ADR 0010 (CorePure authority) entirely to boundary openness.** Rejected because ADR 0010
  owns syntactic and environmental authority closure. Boundary openness can prevent extra
  graph-level connections to a graph value; it cannot prove that the CorePure expression language
  contains no authority-bearing constructors.

- **Defer `!` to a later "terminator ADR" and only add openness internally.** Rejected because the
  internal openness type and the surface form `!` are tightly coupled: settling one without the
  other forces a second ADR immediately and risks the surface drifting from the type.

## Consequences

### Positive

- Settles the `!` boundary-closure mechanism and gives future absorptive-arm work a boundary shape
  to cite.
- Gives `()` and `!` clean, separate semantics: identity vs closure.
- Provides one boundary-signature shape that ordinary graph composition, future absorptive-arm work,
  and structural isolation examples can each refer to without inventing fresh sealing prose.
- Improves elaborator diagnostics: "cannot connect to sealed slot" is more informative than "no
  matching input boundary."
- Keeps the proof model honest: rewrite preservation now has a typed object (the boundary signature)
  to be preserved, instead of a prose invariant.

### Negative

- Wire grammar gains the `!` production and the explicit-shape form `!(...)` / `!{...}`.
- The bound-value type grows a boundary signature with openness; the elaborator gains an openness
  check on every `=>`.
- Tooling, artifacts, and serialized graph values must surface sealed slots alongside open ones.
- A second proof obligation (rewrite forms preserve boundary openness) joins the existing
  rewrite-chain preservation theorems.
- Existing examples that informally used `!` in commentary or comments must be revised to either
  match the new surface or remove the informal usage.

### Obligations

- **Grammar.** `docs/Reference/Wire/grammar.md` adds `!`, `!(slot)`, and `!{slots}` productions with
  placement on either side of `=>`. The empty-wire `()` rules from conditionality.md §6 are
  unchanged.
- **Elaborator.** Boundary signature with openness becomes part of the graph-value type. `=>`
  rejects edges incident to sealed slots with a sealed-slot diagnostic. Bare `!` requires unique
  inference; ambiguous bare `!` is a static error.
- **Diagnostics.** Two new diagnostic kinds: _sealed slot not connectable_ and _bare `!` is
  ambiguous; specify the slot_.
- **Reference docs.** `docs/Reference/Wire/contracts-ports-and-matching.md` adds an openness column
  to the boundary slot description. `docs/Reference/Wire/conditionality.md` §14.2 and §14.3 are
  updated to point to this ADR; a new section in the conditionality reference describes the
  separation of `()` and `!`.
- **Architecture.** `docs/Architecture/05-wire-language.md` adds a one-paragraph note that boundary
  openness is a Wire-level type fact, not a runtime fact.
- **Proof ledger.** ADR 0038 receives a new ledger row:
  - _Boundary openness preservation_: composition (overlay, connect) and every rewrite form produce
    no edge incident to a sealed slot; one preservation lemma per rewrite form in
    `theory/Cortex/Wire/`.
- **Forward pointers.** `select(...)` docs should not adopt boundary openness as the explanation for
  unselected-branch non-grafting. A future absorptive-arm ADR may cite this ADR as the boundary
  closure mechanism for selected materialized graph values. ADR 0010 receives no edit; this ADR's
  non-goal note is the canonical reference for the layering.
- **Tests.** Parser tests for `!` placement on either side of `=>`, for `!(...)` and `!{...}` shape,
  and for the ambiguous-bare-`!` diagnostic. Elaborator tests for sealed-vs-open composition,
  closed-runnable vs closed-not-runnable, and the no-wildcard rule. Topology tests that sealed slots
  are visible in artifact serialization.
- **Migration.** A short migration note: existing informal `!` mentions in comments or examples
  should be brought in line with the new surface or removed.

## Related

- [Reference: Conditionality](../Reference/Wire/conditionality.md)
- [Reference: Wire grammar](../Reference/Wire/grammar.md)
- [Reference: Contracts, ports, and matching](../Reference/Wire/contracts-ports-and-matching.md)
- [Chapter 04 — Graph and Circuit](../Architecture/04-graph-and-circuit.md)
- [Chapter 05 — Wire language](../Architecture/05-wire-language.md)
- [ADR 0005 — Budgeted Rewrite Admission and Materialization](./0005-budgeted-rewrite-admission-and-materialization.md)
- [ADR 0006 — Compiled Workflow Artifact Boundary](./0006-compiled-workflow-artifact-boundary.md)
- [ADR 0010 — Wire as Closed-Authority Language over the Graph/Circuit/Wire Stack](./0010-wire-closed-authority-and-three-layer-stack.md)
- [ADR 0028 — Wire Topology Composition and Boundary Labels](./0028-wire-topology-composition-and-boundary-labels.md)
- [ADR 0032 — Wire Boundary Contracts as Planning Resources](./0032-wire-boundary-contract-resources.md)
- [ADR 0033 — Wire Select as Guarded Affine Collapse](./0033-wire-select-guarded-affine-collapse.md)
- [ADR 0035 — Wire Rewrite Algebra Forms](./0035-wire-rewrite-algebra-forms.md)
- [ADR 0036 — Latent Branch Budget and Recovery Policy](./0036-wire-latent-branch-budget-recovery.md)
- [ADR 0037 — Wire Latent Structural Control Operators](./0037-wire-latent-structural-control.md)
- [ADR 0038 — Wire Proof-Track Theorem Ledger](./0038-wire-proof-track-theorem-ledger.md)
