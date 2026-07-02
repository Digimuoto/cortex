---
title: "ADR 0086 — Wire Scoped Graph Construction: Rejection of the Graph-Block Bundle"
description:
  "Records the battle-tested rejection of the proposed scoped graph-block construction surface as a
  bundle: `saturate` is rejected (it names match sets ordinary Wire cannot lower, is non-confluent,
  and performs implicit topology formation canon forbids), module-as-implicit-outer-form is rejected
  (module merge is non-linear de-dup, graph activation is linear), and holes/`sorry` are rejected
  (redundant on the input side, unsound on the output side without an obligation-tracking layer the
  'unchanged rules' claim excludes). `closed` folds into ADR 0081's closure modes. Only cosmetic
  block-overlay sugar survives, under explicit conditions. Exact revival conditions are pinned so
  the constructs cannot return without meeting them."
sidebar:
  label: "0086. Scoped construction (rejected)"
  order: 86
status: proposed
date: 2026-07-02
superseded_by: null
related:
  - docs/ADRs/0046-wire-compile-time-graph-forms.md
  - docs/ADRs/0047-wire-frontier-linearity-and-precedence.md
  - docs/ADRs/0081-wire-endpoint-closure-accounting.md
  - docs/ADRs/0084-wire-tree-sitter-grammar.md
  - docs/ADRs/0085-wire-contract-schema-as-type-enforcement.md
  - docs/ADRs/0087-wire-edge-as-saturation-event.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/modules-imports-and-file-returns.md
  - docs/Reference/Wire/contracts-ports-and-matching.md
---

# ADR 0086 — Wire Scoped Graph Construction: Rejection of the Graph-Block Bundle

## Status

Proposed — a **rejection record**. It decides that the proposed "graph block" scoped-construction
bundle (`form a { b; c; d }` with `;`-overlay, a `saturate` directive, a `closed` policy,
`hole`/`sorry` obligations, and the module-as-implicit-outer-form reading) is not adopted, and pins
the exact conditions under which each rejected part could be re-proposed. The purpose is
institutional memory: the constructs were battle-tested against canon and the mechanized judgment on
2026-06-30, and without a decision record the same bundle can be re-proposed later with no trace of
why it breaks.

## Context

The proposal read a graph block as a scoped construction surface: a body of "activation items" that
elaborates to an ordinary graph expression and is admitted by the **unchanged** frontier rules. The
framing premise is sound and is retained: the mechanized `FrontierTyped`/`Admits` judgment has
exactly five constructors (empty, node, binding, overlay, connect) with no rule for any surface form
(`theory/Cortex/Wire/FrontierTyping.lean:244-304`), so any new surface must erase to those five
before typing (ADR 0046's erase-before-typing staging). A new surface that cannot be expressed as a
sequence of existing operators admitted by the unchanged rules is not sugar — it is a core (Axis-1)
change in disguise.

Battle-testing each part of the bundle against that boundary produced the verdicts this ADR records.
Two facts recur across the analysis:

- **Admission is two-layered, and the stronger layer is the one that matters.** The
  no-repeated-reference rule (`a <> a` is a static topology error, ADR 0047,
  `docs/ADRs/0047-wire-frontier-linearity-and-precedence.md:93-94`) is enforced by **node-domain
  disjointness** (`CertifiedGraph.Disjoint`), from which exposed-frontier disjointness is derived
  (`theory/Cortex/Wire/FrontierTyping.lean:310-328`). Arguments made from `FrontierTyped`'s
  frontier-exposure premises alone under-constrain legality.
- **Topology formation is explicit, by invariant.** "Wire has no implicit fan-out: topology is
  formed only by the graph operators and compile-time generation"
  (`docs/Reference/Wire/grammar.md:532-533`); fan-in/fan-out are authored as explicit nodes, never
  implicit aggregation (`docs/Reference/Wire/grammar.md:543-544`).

## Decision

Reject the bundle. Individually:

### 1. `saturate` — rejected

A `saturate` directive ("connect every unambiguous exact-key output/input pair across the block's
items") is rejected. It is not transparent sugar over unchanged rules; three independent breaks:

- **The 2-cycle: it names match sets ordinary Wire cannot lower.** Two items whose ports cross on
  two keys — `A` (out `o:K1`, in `i:K2`) and `B` (in `j:K1`, out `p:K2`) — give per-key-unique pairs
  `A.o => B.j` and `B.p => A.i`, each individually satisfying the `connect` premises
  (`theory/Cortex/Wire/FrontierTyping.lean:284-301`). But `connect` is strictly binary and the
  judgment has no n-ary or intra-graph connect constructor; lowering the first pair as `A => B`
  makes the back-edge require `B => A` — a repeated graph reference, a static topology error
  (`docs/ADRs/0047-wire-frontier-linearity-and-precedence.md:93-94`). The proposed match set has no
  realization under the unchanged rules.
- **Non-confluence.** For `A (out o:K); B (in j:K, out q:K); C (in k:K)`, greedy/maximal matching
  admits either the full pipeline or a topology with `B` dangling — same block, two results — and
  the proposal fixes neither the uniqueness scope (global-per-key vs. per-step) nor the operation
  order between self-pair exclusion and uniqueness counting.
- **It refuses the case that motivates it.** A homogeneous pipeline
  (`Source(out data:T); Transform(in data:T, out data:T); Sink(in data:T)`) puts two outputs and two
  inputs on one key — a multi-counterpart static error (`docs/Reference/Wire/grammar.md:497-501`;
  `hMatchedFunctional`/`hMatchedInjective`). `saturate` fires only in the degenerate
  one-output/one-input-per-key case, exactly where explicit `src => sink` is a one-liner. Where it
  fires at all, it performs the implicit topology formation the grammar invariant forbids
  (`docs/Reference/Wire/grammar.md:532-533`).

**Revival conditions.** A future `saturate` proposal must arrive as its own ADR satisfying all of:
**S1** — global per-key uniqueness after self-exclusion (≥2 cross-item outputs or inputs on a key is
a static ambiguity error), making the match set a pure function of the key-multiset; **S2** — a
fixed, stated operation order (gather pool → drop intra-item pairs → count uniqueness on survivors);
**S3** — rejection of any cyclic match set, or, alternatively, a mechanized n-ary intra-graph
connect rule in `FrontierTyping.lean` — an explicit Axis-1 change that must be argued as such, never
as sugar; **S4** — a canonical, declaration-order-independent lowering trace; **plus** an explicit
justification for carving an exception to the no-implicit-topology invariant, and an argument that
the restricted construct buys anything over explicit `=>` (under S1–S4 it is largely redundant with
it). An acceptable weaker form is a **diagnostic** that suggests explicit `=>` edges and emits no
topology itself.

### 2. Module as "implicit outer form" — rejected

Reading a `.wire` file as an implicit graph block overlaying its exports is rejected as a literal
semantics. A file is a `--return`-selectable **catalog** of heterogeneous declarations, most of
which are not graph values (`docs/Reference/Wire/grammar.md:80-81`;
`docs/Reference/Wire/modules-imports-and-file-returns.md:104-111`). The decisive break: the same
module surface reached through two import routes "merges silently; graph values still consume their
ports linearly no matter how many routes imported them"
(`docs/Reference/Wire/modules-imports-and-file-returns.md:87-89`) — whereas the outer-form reading
would activate the shared value twice and trip the canonical `a <> a` static error
(`docs/ADRs/0047-wire-frontier-linearity-and-precedence.md:93-94`). Module identity is non-linear
de-duplication; graph identity is linear. The two algebras are incompatible, and no rule may
conflate them.

**Surviving residue** (already canon, restated for clarity): each runnable graph target — the
file-return or each `--return`-selectable graph-valued `export let` — is independently
closure-checked at the existing evaluation boundary
(`docs/Reference/Wire/configured-executors-and-execution-boundary.md:77-80`;
`docs/Reference/Wire/contracts-ports-and-matching.md:91-93`). There is no implicit overlay across
exports; a declaration-only file produces no graph target.

### 3. Holes / `sorry` — rejected

Typed placeholder nodes ("holes") are rejected in both directions:

- **Input-only holes are redundant.** An open input boundary already _is_ a typed-frontier fragment
  carrying an outstanding obligation discharged at the evaluation boundary
  (`docs/Reference/Wire/grammar.md:639`;
  `docs/Reference/Wire/contracts-ports-and-matching.md:86-89`). No new construct is needed.
- **Output-producing holes are unsound under unchanged rules.** The only frontier-bearing leaf is
  `node` over an accepted declaration (`theory/Cortex/Wire/FrontierTyping.lean:244-262`), so an
  output-producing hole requires minting a placeholder node the judgment cannot distinguish from a
  real one — no constructor carries an obligation bit. Then `src; h = sorry; sink` wired
  `src.out => h.in`, `h.out => sink.in` satisfies the closed-actualized-graph check
  (`docs/Reference/Wire/contracts-ports-and-matching.md:91-93`) and looks **closed and runnable
  against a producer that does not exist**. If the obligation lives in a side channel, any link that
  drops it (let / export / import / `--return`) ships the placeholder.

**Revival conditions** — all four, atomically; partial adoption is unsound by construction: **H1** —
a hole must carry a fully concrete typed frontier (the `connect` premises cannot be discharged
against an unknown finset); **H2** — the obligation must be a **carried field** propagated
monotonically through binding, overlay, connect, let, export, and import — i.e. the mechanized rules
change, and the proposal must say so; **H3** — an asserted output with no backing producer must be
evaluated against the obligation set, never the falsely-closed residual frontier; **H4** — closure
and runnable lowering must reject while obligations ≠ ∅, with a negative test that an imported
hole-bearing binding cannot be made runnable. The construct must also be renamed: `sorry` collides
with the Lean tactic, "continuation hole" already names where the empty wire disappears
(`docs/Reference/Wire/conditionality.md:276`), and `WireAppendHole` already names a graph-edit
anchor (`src/Cortex/Wire/Proposal.hs:59-62`).

### 4. `closed` — no new construct; folds into ADR 0081

A `closed` form policy read as "elaborate, then reject residual required frontier" is not adopted:
closure is role-relative (the same value is closed as an open fragment yet open as a closed
executable, `docs/ADRs/0081-wire-endpoint-closure-accounting.md:99-127`), two-sided (an un-consumed
output carried endpoint also blocks a closed executable, `…:124-125`), and branch-sensitive under
`select` (`…:134-138`) — none of which a predicate on the bare graph value can decide. The
capability already exists as ADR 0081's closure modes over the admission witness and
`wire frontier --closure/--open` (`docs/ADRs/0081-wire-endpoint-closure-accounting.md:147-160`). If
a source-level spelling is ever wanted, it must be specified as exactly "expose ADR 0081's
closed-executable mode at the form surface," and it may not be admitted over a `select` body while
branch-local closure accounting remains deferred there.

### 5. Block-overlay — the only surviving fragment, as cosmetic sugar under conditions

`{b; c; d}` elaborating to `b <> c <> d` is coherent and admission-safe (overlay is commutative
set-union under the disjointness premises, `theory/Cortex/Wire/FrontierTyping.lean:263-273`), and a
form body is already a list of items ending in one graph expression
(`docs/Reference/Wire/grammar.md:94-98`), so this is sugar, not new semantics. It may be adopted
only under all of: **B1** — no overloading of `;` (today a terminator, not an operator); an explicit
composition glyph or a distinct visible block-overlay marker, so juxtaposition never reads as flow
while meaning "no edges"; **B2** — specification as a strict desugaring to the existing
`form_item* graph_expr` grammar with provably unchanged admission through the full
`CertifiedGraph.Disjoint` relation (node-domain disjointness, not merely frontier disjointness);
**B3** — the grammar change routes through ADR 0084's tree-sitter governance, with the existing
downstream `.wire` corpus as regression fixtures for the `;` reinterpretation risk; **B4** — the
Mokhov `+`/`*` analogy is explicitly forbidden in docs (`*` is a product adapter node, `+` is not a
graph operator; `docs/Reference/Wire/grammar.md:535-541`).

## Alternatives considered

- **Adopt the bundle as specified.** Rejected on the counterexamples above: `saturate`'s match sets
  are unlowerable (2-cycle) or non-confluent; the module reading rejects imports canon says merge
  silently; output holes defeat the closure check. Each break is a direct consequence of cited
  canon, not a taste judgment.
- **Mechanize an n-ary intra-graph connect rule to make `saturate` lowerable.** Not taken here: it
  is a genuine Axis-1 change to the five-constructor judgment and contradicts the bundle's own
  erase-before-typing thesis. It may be proposed on its own merits as a future ADR (S3 names it),
  but it cannot ride in as "transparent sugar."
- **Do nothing (no decision record).** Rejected: the ergonomic pressure behind the proposal is real
  — downstream stabilizer-check circuits are authored today as long explicit binary `=>` chains
  (e.g. `cortex-qc/experiments/qec-planar/wire/qec-planar-realize.wire`) — so the bundle would
  predictably be re-proposed, and without this record the same analysis would have to be
  reconstructed from scratch.

## Consequences

### Positive

- The no-implicit-topology invariant (`docs/Reference/Wire/grammar.md:532-533`) and the linear
  no-repeated-reference discipline (ADR 0047) survive intact, with the counterexamples that defend
  them recorded in canon.
- Revival conditions are pinned: `saturate` (S1–S4 + invariant exception + net-value argument),
  holes (H1–H4, atomic), `closed` (fold into ADR 0081), block-overlay (B1–B4). A future proposal
  that does not meet them can be closed by citation rather than re-analysis.
- The safe fragment (cosmetic block-overlay) is explicitly unblocked rather than lost with the
  bundle.

### Negative

- The real ergonomic pain that motivated the bundle — verbose explicit wiring in large homogeneous
  graphs — remains unaddressed. The honest answers today are compile-time generation
  (`make`/`makeEach`, ADR 0048/0051), `form` composition (ADR 0046), and explicit `=>`; anything
  better must clear the revival bars above.
- Rejecting module-as-form leaves "why is a file not a graph?" as a recurring reader question; the
  catalog/file-return model (`docs/Reference/Wire/modules-imports-and-file-returns.md`) is the
  answer and must stay prominent.

### Obligations

- Documentation must not describe `saturate`, graph blocks, `closed` forms, or holes as available or
  planned Wire surface; they may be referenced only as rejected-by-this-ADR (or as a future ADR
  meeting the revival conditions).
- If block-overlay sugar is ever pursued, the B1–B4 conditions above are the acceptance checklist,
  and the ADR-0084 grammar slice (grammar.md + tree-sitter corpus + parser) must land together.
- If holes are ever pursued, H1–H4 land atomically with the surface syntax, including the negative
  test that an imported hole-bearing binding cannot be made runnable.

## Traceability

- Feature keys: none (rejection record; no feature ships from this ADR)
- Public surface: none
- Implementation: none (the decision is that no implementation exists or is planned)
- Tests: none now; H4's negative test and B3's downstream regression fixtures become mandatory if
  the respective revival paths are ever taken
- Theory/proof: the load-bearing facts are already mechanized — the five-constructor
  `FrontierTyped`/`Admits` judgment (`theory/Cortex/Wire/FrontierTyping.lean:244-304`) and the
  node-domain disjointness layer (`theory/Cortex/Wire/FrontierTyping.lean:310-328`); this ADR adds
  no proof obligations

## Related

- [0046-wire-compile-time-graph-forms.md](0046-wire-compile-time-graph-forms.md) — the
  erase-before-typing form discipline the bundle claimed to extend; block-overlay, if adopted, is a
  strict desugaring into it.
- [0047-wire-frontier-linearity-and-precedence.md](0047-wire-frontier-linearity-and-precedence.md) —
  the no-repeated-reference and no-implicit-fan rules that break `saturate`'s cyclic match sets and
  the module-as-form reading.
- [0081-wire-endpoint-closure-accounting.md](0081-wire-endpoint-closure-accounting.md) — the
  closure-mode accounting `closed` folds into.
- [0084-wire-tree-sitter-grammar.md](0084-wire-tree-sitter-grammar.md) — grammar governance gating
  any block-overlay surface change.
- [0085-wire-contract-schema-as-type-enforcement.md](0085-wire-contract-schema-as-type-enforcement.md)
  — the sibling ceiling: 0085 bounds what a contract match may mean; this ADR bounds how topology
  may be formed.
- [0087-wire-edge-as-saturation-event.md](0087-wire-edge-as-saturation-event.md) — the saturation
  _relation_ (a match predicate over port roles) that the rejected `saturate` _directive_ reused the
  word for; the two must not be conflated.
