---
title: "Research Memo: Linear Port Graph Layer"
description:
  "Synthesis note on the two-layer Wire topology semantics: linear port graphs above Mokhov relation
  graphs, with a forgetful lowering between them."
date: 2026-05-05
status: research
related:
  - docs/Architecture/03-formalism-stack.md
  - docs/Architecture/04-graph-and-circuit.md
  - docs/Architecture/05-wire-language.md
  - docs/ADRs/0028-wire-topology-composition-and-boundary-labels.md
  - docs/ADRs/0047-wire-frontier-linearity-and-precedence.md
  - docs/ADRs/0048-wire-make-bounded-node-generation.md
  - docs/ADRs/0049-wire-fan-phantom-adapter.md
---

# Research Memo: Linear Port Graph Layer

**Date:** 2026-05-05 **Scope:** Wire frontier linearity, Mokhov graph denotation, `make`, `*`, and
the proposed runtime projection into actualized port graphs. **Branch / PR:**
`wire-static-fanout-replicate` **Layers examined:** Haskell graph core, Lean Track 1 graph theory,
Wire ADRs 0028/0047/0048/0049, Architecture chapters 03-05, Wire reference docs, and external
port-graph / structured-cospan / string-diagram literature. **Layers skipped:** live GitHub issues
and downstream repositories; the question is semantic and not tied to one issue. **Method:**
Cross-source synthesis through the seven archetype lenses. **Confidence profile:** high on the
two-layer correction; medium on the exact categorical presentation to use in papers.

## Executive Summary

Wire's source topology is not governed directly by Mokhov's graph laws. It is a finer **linear port
graph** layer where node identity and endpoint ports are resources, so contraction and implicit
copying are illegal. Mokhov's algebra remains the right relation-level substrate after a forgetful
lowering erases port identity and boundary resources. The next proof move should be a typed
`LinearPortGraph` / `ActualizedPortGraph` layer with `PortLinear`, a forgetful map to
`Cortex.Graph.Relation`, and a Pulse-state projection that makes port linearity part of runtime
well-formedness.

The paper framing should give rhetorical weight to the upper layer: Cortex's contribution is not
"Mokhov graphs for workflows" but a port-linear admission and rewrite layer that lowers into the
Mokhov relation algebra.

## Archetype Synthesis

| Lens     | One-line read                                                                                  |
| -------- | ---------------------------------------------------------------------------------------------- |
| Episteme | Track 1 proves Mokhov relation laws; ADR 0047 asserts a stricter Wire frontier-resource model. |
| Logos    | Source Wire has linear-port laws; Mokhov laws apply only after forgetful relation lowering.    |
| Kritikos | Mokhov distributivity repeats operands and therefore violates Wire source linearity.           |
| Themis   | Port identity belongs at Wire/Circuit/Pulse safety, not in pure Graph topology.                |
| Techne   | Add `LinearPortGraph`, `forgetPorts`, `PortLinear`, and runtime projection lemmas.             |
| Poiesis  | Best external vocabulary: port graphs/open graphs; SMC/string diagrams are paper framing.      |
| Sophia   | Refine the base theory by adding a layer, not by replacing Mokhov.                             |

## Key Findings

### [P1] Wire source laws are linear-port laws, not Mokhov laws

**Category:** Correctness Gap **Status:** Observed **Confidence:** High **Surfaced by:** Logos,
Kritikos, Themis **Primary evidence:** ADR 0047 "Algebraic foundation" and "Linear endpoint rule";
`theory/Cortex/Graph/Relation.lean`; `src/Cortex/Algebra/Graph/Core.hs`; Architecture chapter 03
"Wire's `<>` and `=>` as refinements" **Cross-reference:** ADRs ↔ theory ↔ architecture.

Track 1's graph theory is correctly Mokhov-shaped: `Graph` has `empty`, `vertex`, `overlay`, and
`connect`, and the relation denotation interprets `connect` by adding every cross edge from the left
vertex set to the right vertex set. ADR 0047 now commits Wire source to a stricter frontier model:
typed endpoint ports are linear resources, repeated graph references are static errors, and `=>`
creates an edge only when each endpoint has zero or one compatible counterpart.

Those two theories cannot share all equations at the source layer. The diagnostic equation is Mokhov
distributivity:

```wire
down => some <> things
```

versus:

```wire
(down => some) <> (down => things)
```

The second expression repeats `down`, so it is invalid Wire source. Mokhov distributivity is valid
only after lowering to a relation where vertex identity is no longer a linear resource.

**Why it matters:** Without this split, documentation and proofs can accidentally claim that Wire
inherits a law that its own linearity rule rejects. That would undermine ADR 0047 and confuse the
paper story.

**Next step:** Amend Architecture chapter 03 to state two equational theories explicitly:
linear-port source laws above Mokhov relation laws, connected by forgetful lowering.

### [P2] The missing formal object is a linear port graph carrier

**Category:** Missed Abstraction **Status:** Inferred **Confidence:** High **Surfaced by:** Techne,
Themis **Primary evidence:** ADR 0047 typed frontier model; ADR 0049 phantom adapter; Track 2
proposal for `actualizedPortGraphOf`; theory status table in `theory/README.md` **Cross-reference:**
ADRs ↔ Lean proof track.

ADR 0047 introduces the frontier-resource vocabulary, and ADR 0049 relies on it for `*`, but the
Lean base currently has no carrier that makes this vocabulary a theorem object. The existing graph
carrier is relational; it has vertices and edges, not port instances or exposed frontiers.

The missing layer should contain:

- node identities;
- actualized input and output port instances;
- a port-edge relation from output instance to input instance;
- exposed input and output frontier sets;
- `PortLinear`;
- overlay with disjoint node identity;
- connect with deterministic one-counterpart matching;
- a forgetful map into `Cortex.Graph.Relation`.

This layer should sit above pure Graph and below runtime Pulse state.

**Why it matters:** This is what turns "no implicit fan-in/fan-out" from an ADR rule into a
mechanized invariant. It also gives `make`, `*`, select actualization, and admitted rewrite
materialization one shared target.

**Next step:** Add a proof-track ADR or research-to-ADR follow-up for `LinearPortGraph`,
`ActualizedPortGraph`, `forgetPorts`, and `PortLinear`.

### [P3] `PortLinear` should be folded into runtime safe-state through projection

**Category:** Correctness Gap **Status:** Inferred **Confidence:** High **Surfaced by:** Themis,
Techne **Primary evidence:** Track 2 proposal; `SafePulseRunState` / `wellFormedGraphState` status
in `theory/README.md`; ADR 0047 runtime-preservation obligations **Cross-reference:** Theory ↔
ADRs.

The proof track already has a closed middle around `SafePulseRunState` and finite admitted traces,
but the current safe-state envelope is graph/rewrite/pulse shaped rather than port-resource shaped.
ADR 0047 needs a bridge from runtime state to actualized port use:

```lean
actualizedPortGraphOf : PulseState ... -> ActualizedPortGraph ...
```

Then runtime safety can carry:

```lean
(actualizedPortGraphOf state).PortLinear
```

either inside `wellFormedGraphState` or as a field of `SafePulseRunState`.

**Why it matters:** Parser/compiler checks are not enough once admitted runtime rewrites exist.
Runtime materialization must preserve the same linear endpoint discipline that source Wire enforces.

**Next step:** Prefer widening the safe-state predicate after the projection exists. Avoid a
parallel sibling preservation chain; it would institutionalize drift between safety and linearity.

### [P4] `*` is not an exception to linearity; it is the explicit linear adapter

**Category:** Terminology Gap **Status:** Observed **Confidence:** High **Surfaced by:** Logos,
Kritikos **Primary evidence:** ADR 0049 "defining equivalence" and "Canonical rule"; ADR 0047 linear
endpoint rule **Cross-reference:** ADR 0047 ↔ ADR 0049.

ADR 0049's `*` operator inserts an explicit phantom record↔ports adapter:

```text
a * b ≡ a => phantom => b
```

Both edges are ordinary `=>` boundary contractions. The multi-side ports are ordinary
cardinality-one ports; the singular side is a nominal record port. Therefore `*` does not add
copying, implicit aggregation, or hypergraph-style Frobenius structure. It preserves linearity by
making the aggregation/scatter node explicit.

**Why it matters:** This is the clean explanation for why Cortex can be strict about copying while
still ergonomic. The language has no implicit contraction; it has explicit construction of fresh
nodes and explicit structural adapters.

**Next step:** In ADR 0049 and the language guide, keep saying "phantom adapter" rather than
"fan-out" when precision matters. "Fan" is acceptable as authoring vocabulary, but proof prose
should call it a record↔ports adapter.

### [P5] SMC/string diagrams are useful framing, but port graphs/open graphs are the closer source model

**Category:** Novel Idea **Status:** Inferred **Confidence:** Medium **Surfaced by:** Poiesis,
Episteme **Primary evidence:** Joyal-Street string-diagram literature; port graph rewriting and
PORGY; structured cospans for open systems **Cross-reference:** Architecture ↔ literature.

Symmetric monoidal categories and string diagrams are useful paper language for parallel and
sequential composition without copying. But Wire source has named ports, partial frontier exposure,
static rejection, and runtime admission. That makes it closer to port graphs and open graph
composition than to a plain SMC term calculus.

Structured cospans supply a well-known framework for open networks with inputs and outputs.
Port-graph rewriting supplies a graph-rewriting tradition that already treats ports as explicit
connection sites. Both are closer to ADR 0047's frontier-resource model than unqualified "plain
SMC."

**Why it matters:** The literature framing determines whether reviewers see Cortex as inventing a
bespoke graph language or refining known open-network and port-graph semantics for durable execution
and admitted rewrites.

**Next step:** For Paper A, use:

```text
linear port graphs / open graphs for the source layer
Mokhov algebra for relation lowering
SMC/string diagrams for intuition and coherence framing
```

Do not lead with "Wire is a plain SMC" without the port-layer qualification.

### [P6] Chapter 03 currently risks overstating Wire's inheritance of Mokhov laws

**Category:** ADR Drift **Status:** Observed **Confidence:** High **Surfaced by:** Kritikos, Themis
**Primary evidence:** Architecture chapter 03 "Wire's `<>` and `=>` as refinements"; ADR 0047
"linear endpoint rule" **Cross-reference:** Architecture ↔ ADRs.

Chapter 03 says Wire's `<>` and `=>` correspond to Mokhov primitives and preserve laws "where they
matter." After ADR 0047, that statement needs a sharper boundary: source Wire is port-linear, and
Mokhov laws apply after admitted lowering. The architecture chapter should not suggest that Mokhov
distributivity is a source-language equivalence.

**Why it matters:** This is the exact place future contributors will read before changing the
compiler, formatter, or proof track. If it remains ambiguous, the same fan-out/fan-in confusion will
recur.

**Next step:** Completed by the follow-up architecture patch: Chapter 03 now states:

```text
Wire source equality is not Mokhov equality.
Wire source lowering preserves/forgets into Mokhov relation equality.
```

## Missed Abstractions

| Multiple sites                                   | Shared shape                         | Proposed name         | Cost of unifying                    |
| ------------------------------------------------ | ------------------------------------ | --------------------- | ----------------------------------- |
| ADR 0047 frontier, ADR 0049 phantom, Track 2 WF  | port instances plus linear use       | `LinearPortGraph`     | medium Lean slice                   |
| Runtime materialization, selected actualization  | concrete runtime port graph          | `ActualizedPortGraph` | medium-high projection proof        |
| Compiler rejection and runtime preservation      | no duplicated endpoint consumption   | `PortLinear`          | medium per-constructor preservation |
| Relation topology and port-resource source layer | erase ports and retain node relation | `forgetPorts`         | small definition, harder laws       |

## Claim-to-Evidence Matrix

| Claim                                        | Artifact that supports it                                               | Artifact that weakens it                         | Verdict                                      |
| -------------------------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------ | -------------------------------------------- |
| Graph layer is Mokhov relation algebra       | `theory/Cortex/Graph/Relation.lean`, `src/Cortex/Algebra/Graph/Core.hs` | none                                             | established                                  |
| Wire source is linear in endpoints           | ADR 0047, Wire reference cardinality text                               | older ADR 0028 wording prior to amendment        | active proposed correction                   |
| Wire directly inherits Mokhov distributivity | older Chapter 03 phrasing                                               | `down` counterexample under ADR 0047             | reject at source layer                       |
| `*` introduces a copying/fan-out primitive   | informal word "fan"                                                     | ADR 0049 phantom-insertion and ordinary `=>` use | reject; `*` is explicit adapter construction |
| Runtime states preserve port linearity       | desired Track 2 proposal                                                | no current projection theorem                    | target, not yet proved                       |

## Design Tensions

### Source ergonomics vs. linear resource discipline

Authors want compact expressions such as:

```wire
make(8, worker) * summarize
```

The system wants no implicit copying. The resolution is explicit construction: `make` creates fresh
node identities; `*` creates an explicit adapter node. Ergonomics should come from visible
constructors, not hidden graph contraction.

### Mokhov algebra elegance vs. Wire source correctness

Mokhov's laws are elegant and mechanically useful. But Wire source has more structure than a vertex
relation. Treat Mokhov as the lowered relation layer, not as the source equality theory. This keeps
both benefits: source linearity and relation-level algebraic reasoning.

### Paper simplicity vs. accurate categorical placement

"Wire is a symmetric monoidal category" is memorable but incomplete. "Wire source is a port-linear
open graph calculus that forgets to a Mokhov relation algebra" is longer but accurate. The paper can
use SMC/string-diagram language for intuition while keeping port graphs/open graphs as the formal
source model.

## Novel Ideas & Hypotheses

- **Forgetful lowering as a theorem boundary** - Treat source-to-relation lowering as a named
  forgetful map between equational theories. **Validation path:** define `forgetPorts` in Lean and
  prove that admitted overlay/connect steps commute with relation denotation.
- **Runtime actualization as port-graph projection** - Make `actualizedPortGraphOf` the bridge from
  Pulse state to the source-layer invariant. **Validation path:** start with fixed topology, then
  extend to constructed rewrites and selected actualization.
- **Paper contribution statement** - Frame Cortex as "linear port-graph admission with durable
  rewrite preservation, lowering to Mokhov relation topology." **Validation path:** draft Paper A
  section and compare reviewer-legibility against port-graph / open-systems literature.

## Dead Ends / Rejected Directions

- **Replace Mokhov with plain SMC.** Rejected. It loses the existing relation-level theorem base and
  does not account for named frontiers, partial exposure, static rejection, or runtime projection.
- **Let Mokhov distributivity be a Wire source rewrite.** Rejected. It duplicates operands and
  violates ADR 0047 linearity.
- **Model `*` as hidden fan-out.** Rejected. ADR 0049 deliberately inserts a visible adapter node;
  hidden copying would undermine the whole frontier-resource story.

## Recommended Actions

### Act now

- [x] Patch Chapter 03 to state the two-layer theory explicitly. Owner: architecture/docs. Cost: S.
- [x] Adjust ADR 0047 wording that says Mokhov distributivity "does the rest"; precedence parses the
      expression, endpoint linearity admits or rejects it. Owner: architecture/docs. Cost: S.

### Design next

- [ ] Draft the proof/runtime ADR for `LinearPortGraph`, `ActualizedPortGraph`, `PortLinear`,
      `forgetPorts`, and `actualizedPortGraphOf`. Owner: architecture + lean-theorem-attack. Cost:
      M.
- [ ] Plan the Lean slice that first defines the carrier and forgetful map, before widening
      `SafePulseRunState`. Owner: lean-code-style / theorem track. Cost: M.

### Write up

- [ ] Add a Paper A subsection: "Two Equational Theories: Linear Port Graphs and Relation Graphs."
- [ ] Cite port-graph rewriting / PORGY for port-based graph rewriting, structured cospans for open
      networks, Joyal-Street for string-diagram intuition, and Mokhov for relation-level algebra.

### Parked

- Bounded homogeneous list contracts for `*`. Defer until record-form adapter proves insufficient.
- Full categorical completeness theorem. Defer until the Lean port-graph layer exists.

## Known Unknowns

| Unknown                                                            | Why it matters                                         | Validation path                                     |
| ------------------------------------------------------------------ | ------------------------------------------------------ | --------------------------------------------------- |
| Whether existing record contracts are nominal enough for ADR 0049  | `*` depends on field labels from nominal record shapes | implement small contract-surface prototype          |
| Whether runtime exposes total executor-port projection             | `actualizedPortGraphOf` needs port instances per node  | inspect compiler/runtime projection data structures |
| Whether `PortLinear` belongs in `wellFormedGraphState` or wrapper  | affects proof churn and paper alignment                | draft both theorem signatures before implementation |
| How much structured-cospan machinery is worth importing into prose | avoids overclaiming categorical novelty                | focused literature pass before Paper A              |

## External Anchors

- Andrey Mokhov, [_Algebraic Graphs with Class_](https://eprints.ncl.ac.uk/239461), Haskell
  Symposium 2017. Algebraic graph construction and equational reasoning over relation-like
  denotations.
- PORGY, [_Strategic Port Graph Rewriting_](https://porgy.labri.fr/), and related work by Fernández,
  Kirchner, Pinaud, Andrei, and collaborators. Explicit ports and rewriting strategies over graph
  states.
- John C. Baez and Kenny Courser, [_Structured Cospans_](https://arxiv.org/abs/1911.04630), Theory
  and Applications of Categories 2020. Open systems with input/output boundaries and symmetric
  monoidal structure.
- André Joyal and Ross Street,
  [_The Geometry of Tensor Calculus, I_](https://researchers.mq.edu.au/en/publications/the-geometry-of-tensor-calculus-i/),
  Advances in Mathematics 1991. String diagrams and monoidal-categorical graphical reasoning.

## Related

- [Formalism stack synthesis](2026-04-11-formalism-stack-synthesis.md)
- [../../Architecture/03-formalism-stack.md](../../Architecture/03-formalism-stack.md)
- [../../Architecture/04-graph-and-circuit.md](../../Architecture/04-graph-and-circuit.md)
- [../../Architecture/05-wire-language.md](../../Architecture/05-wire-language.md)
- [../../ADRs/0047-wire-frontier-linearity-and-precedence.md](../../ADRs/0047-wire-frontier-linearity-and-precedence.md)
- [../../ADRs/0048-wire-make-bounded-node-generation.md](../../ADRs/0048-wire-make-bounded-node-generation.md)
- [../../ADRs/0049-wire-fan-phantom-adapter.md](../../ADRs/0049-wire-fan-phantom-adapter.md)
