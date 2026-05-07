---
title: "Wire Frontier Binding Syntax"
description:
  Research note on node-local binding, record-to-port egress projection, and source-driven
  structural syntax after makeEach/include_dir exposed a new authoring pressure.
date: 2026-05-07
status: research
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/pure-execution.md
  - docs/ADRs/0031-wire-binding-forms-and-where-clauses.md
  - docs/ADRs/0039-wire-node-boundary-transform-normal-form.md
  - docs/ADRs/0048-wire-make-bounded-node-generation.md
  - docs/ADRs/0049-wire-fan-phantom-adapter.md
  - docs/ADRs/0050-wire-corepure-output-residue.md
  - docs/ADRs/0051-wire-source-includes-and-item-generation.md
---

# Wire Frontier Binding Syntax

**Date:** 2026-05-07 **Scope:** syntax pressure exposed by the C build example, source includes,
`makeEach`, trailing `where`, node-local CorePure residue, and egress projection. **Branch / PR:**
`wire-haskell-linearity-parity` / PR 168. **Layers examined:** implementation, Wire reference docs,
architecture chapter 05, ADRs 0031/0039/0048/0049/0050/0051, and the C build example. **Layers
skipped:** Lean theory and external literature; this memo records syntax design space before theorem
or literature alignment. **Method:** architecture classification plus research synthesis through the
seven archetype lenses, with emphasis on Poiesis.

---

## Executive Summary

The C build example exposed an authoring pressure, but the first-pass note overstated the missing
surface. ADR 0031 already rejected the pre-output `let ... in` block and chose trailing
`where <record-expr>;` for node-local authority-free scope. The honest open question is narrower:
whether trailing `where` remains ergonomic for source-driven graphs, and how to name the distinct
operation that maps local record fields into output ports.

Architecture classification: **Existing ADR Concern + Scope Too Big**. ADR 0031 constrains binding
placement; ADR 0039 supplies the node boundary normal form; ADR 0049 covers `*` as a topology
adapter; ADR 0050 covers CorePure residue; ADR 0051 covers source includes. The surviving novel
slice is **egress projection**: typed, injective field-to-port exposure inside a node, distinct from
topology fan-out.

---

## Archetype Synthesis

| Lens     | One-line read                                                                                                                                              |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Episteme | ADR 0031 already provides node-local trailing `where`; current code also supports includes, `makeEach`, and top-level plan records.                        |
| Logos    | The corrected claim is not "Wire lacks local scope"; it is "Wire lacks a named egress projection rule and may have a where-placement ergonomics question." |
| Kritikos | Reintroducing pre-output `let` would collide with ADR 0031; a spread form can also become implicit fan-out unless field use is checked injectively.        |
| Themis   | Source includes belong to source elaboration; `where` belongs to CorePure residue; executor authority remains behind `@`.                                  |
| Techne   | Smallest next artifact is an ADR for egress projection semantics, plus a reference patch for binding phases.                                               |
| Poiesis  | The useful alien framing is "frontier projection": node egress maps local data into linear output resources, not a function return.                        |
| Sophia   | Do not fight ADR 0031 until `where` has been tested on large examples; name egress projection first.                                                       |

---

## Key Findings

### [P1] Node-local planning already has a canonical surface: trailing `where`.

**Category:** ADR Constraint **Status:** Corrected **Confidence:** High **Surfaced by:** Episteme,
Themis, Sophia **Primary evidence:**
`docs/ADRs/0031-wire-binding-forms-and-where-clauses.md:293-355`,
`docs/ADRs/0039-wire-node-boundary-transform-normal-form.md:33-68`,
`docs/Reference/Wire/grammar.md:618-631` **Cross-reference:** ADR 0031 ↔ ADR 0039 ↔ grammar

The first-pass finding treated node-local planning as a missing surface and proposed a pre-output
`let` block between `<-` and `->`. ADR 0031 already considered and removed that exact placement. Its
canonical rewrite is trailing `where <record-expr>;`, with `where let ... in { ... };` for
sequential shared intermediates. ADR 0039 then assigns that local record to the node boundary normal
form rather than to graph topology.

**Why it matters:** The C build smell is not proof that Wire lacks local scope. It is evidence that
the existing `where` position should be exercised on large examples before any supersession of ADR
0031 is justified.

**Next step:** Keep the C-build plan inside `plan_build` using trailing `where let ... in { ... };`.
Only revisit placement if large examples still read poorly after using the existing surface.

### [P2] The real binding question is placement ergonomics, not semantics.

**Category:** Existing ADR Concern **Status:** Reframed **Confidence:** High **Surfaced by:** Logos,
Kritikos, Techne **Primary evidence:**
`docs/ADRs/0031-wire-binding-forms-and-where-clauses.md:293-355`,
`docs/ADRs/0050-wire-corepure-output-residue.md:41-69`, `src/Cortex/Wire/Parser.hs:1170-1188`
**Cross-reference:** ADR 0031 ↔ ADR 0050 ↔ parser

ADR 0050 says static CorePure and delayed input-dependent CorePure are the same authority-free
language separated only by dependency timing. ADR 0031 says that node-local CorePure sharing is
expressed by a trailing where-record, not by pre-output syntax. That combination is coherent: inputs
are available to the where-expression, and its record fields are opened into the node body scope
used by output equations.

The remaining concern is ergonomic and visual. Trailing `where` puts the declarations after the
output equations that use them. That may be alien for large source-driven graphs, but it is an
accepted surface, not an absence.

**Why it matters:** A future ADR should not be "add node-local let." If the evidence eventually
warrants a change, it should be "supersede ADR 0031's placement decision while preserving its
three-surface binding model."

**Next step:** Rewritten examples should compare three forms: top-level plan record, trailing
`where`, and any proposed pre-output form. The burden is now on the proposed placement change.

### [P3] Record-to-port projection is not graph fan-out, but it needs a linear rule.

**Category:** Terminology Gap **Status:** Inferred **Confidence:** High **Surfaced by:** Themis,
Kritikos, Poiesis **Primary evidence:** `docs/Architecture/05-wire-language.md:169-187`,
`docs/ADRs/0049-wire-fan-phantom-adapter.md:34-72`,
`docs/ADRs/0051-wire-source-includes-and-item-generation.md:58-66`,
`examples/wire/c-build/c-build.wire:102-198` **Cross-reference:** architecture ↔ ADR 0049 ↔
example

Wire rejects implicit edge fan-out and ADR 0049 provides `*` for topology-level record↔ports
adapters. But inside a node, taking a local record value and assigning distinct fields to distinct
output ports is not topology fan-out. It is egress projection: the node's egress adapter maps local
values into the declared output frontier. The language lacks a name for that distinction, so the
source must currently spell every projection:

```wire
-> linkAppSpec: CommandSpec = linkAppCommandSpec;
-> smokeSpec: CommandSpec = smokeCommandSpec;
where let
  plan = { ... };
in
{ linkAppCommandSpec = plan.linkAppCommandSpec; smokeCommandSpec = plan.smokeCommandSpec; };
```

The dangerous version would be a spread form that silently maps one field to multiple outputs or
duplicates a whole value across ports. The admissible version is an injective field-to-port mapping:
each output port consumes exactly one expression, and each projected record field is used at most
once unless the expression is deliberately copied inside CorePure.

**Why it matters:** Without the term "egress projection", reviewers can misclassify useful syntax as
forbidden fan-out. With the term, the proof obligation is clear: projection preserves output port
linearity because it allocates distinct record fields to distinct output resources.

**Next step:** Add "egress projection" to the ADR draft vocabulary and require a compile-time
duplicate-field-use rejection for any spread shorthand.

### [P4] Source-generated graphs need a phase-indexed binding story, not more macros.

**Category:** Design Tension **Status:** Observed **Confidence:** High **Surfaced by:** Logos,
Themis, Techne **Primary evidence:** `src/Cortex/Wire/Include.hs:9-12`,
`src/Cortex/Wire/Parser.hs:1364-1371`,
`docs/ADRs/0051-wire-source-includes-and-item-generation.md:34-56` **Cross-reference:**
implementation ↔ ADR 0051

The current implementation has two phase facts:

- source includes expand before parsing and embed ordinary literals;
- `makeEach` only sees preceding closed static item lists during structural expansion.

Those facts are good, but the syntax can make them feel arbitrary. A future binding design should
make phase visible by placement and dependency, not by adding unrelated macros. Top-level `let`,
form-local `let`, source includes, and node-local trailing `where` should all be explainable as one
phase-indexed binding ladder.

**Why it matters:** More ad hoc macros would make the language powerful but unteachable. A phase
ladder lets authors understand why `include_dir` may shape graph topology while runtime CorePure
cannot read files.

**Next step:** Add a reference-doc section that lists binding phases explicitly: source elaboration,
graph expansion, node-frontier CorePure, executor runtime. ADRs 0031/0050/0051 already decide the
policy; the missing artifact is one consolidated explanation.

### [P5] The novelty is not syntax sugar; it is a language where frontier declaration and data construction interleave.

**Category:** Novel Idea **Status:** Speculative **Confidence:** Medium **Surfaced by:** Poiesis,
Sophia **Primary evidence:** current example and docs cited above; no external literature checked
**Cross-reference:** implementation ↔ architecture ↔ future paper framing

Most languages separate "compute a value" from "declare an interface". Wire is pushing toward a
different object: a node is a boundary transformer whose input frontier, local CorePure plan, output
frontier, and graph composition all live in one source artifact. That makes syntax unfamiliar:
ordinary block structure fights with frontier order. But the payoff is also unusual: the graph's
resource frontier can remain visible while deterministic data construction is still local enough to
read.

**Why it matters:** This is paper-worthy if handled carefully. The ergonomic contribution is not "we
added local lets"; it is "we found a syntax where boundary resources and deterministic local
construction are co-designed rather than layered after the fact."

**Next step:** Park as paper-language material. Validate first through a prototype and large example
rewrite; do not claim novelty externally until compared against dataflow DSLs, Nix-style source
elaboration, build systems, and string-diagram languages.

---

## Poiesis Option Set

| Option                                            | Sketch                                                                                             | Fit                                                                 | Risk                                                                                  | Verdict                                                                 |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| **A. Top-level plan record**                      | `let build_plan = let ... in { ... }; node n -> x = build_plan.x;`                                 | Works today; phase is explicit; no grammar change.                  | Plan is detached from the node boundary; output list is repetitive.                   | Useful fallback, but weaker than node-attached `where`.                 |
| **B. Trailing `where let`**                       | Output equations, then `where let ... in { exposed = value; } ;`                                   | Already decided by ADR 0031; keeps local data attached to the node. | Declarations appear after uses, which can feel backward in large source-driven nodes. | Canonical current surface; test it before changing syntax.              |
| **C. Pre-output frontier `let`**                  | Inputs, then `let ...`, then output equations.                                                     | Visually localizes dependencies before use.                         | Direct conflict with ADR 0031; reopens a rejected placement decision.                 | Do not pursue without a superseding ADR and strong example evidence.    |
| **D. Egress projection block**                    | `expose plan { libMetricsSpec -> lib_objects_metrics: CommandSpec; ... }`                          | Names projection as egress work rather than topology fan-out.       | Another block form; could duplicate output-equation syntax.                           | Best new semantic/vocabulary direction.                                 |
| **E. Record-spread output declaration**           | `-> ...BuildPlan = plan;` or `-> { lib_objects_metrics: CommandSpec = plan.libMetricsSpec; ... };` | Compact for large records; powerful for generated plan records.     | High risk of implicit copying unless field use is checked linearly.                   | Worth prototyping only after projection vocabulary is settled.          |
| **F. Contract-driven output derivation**          | `contract BuildPlan { ... }; node n -> BuildPlan = plan;` lowers fields to ports.                  | Strongly typed; removes repeated output contract names.             | Blurs value contract vs port frontier; may fight existing contract registry meaning.  | Parked; needs separate contract-surface ADR.                            |
| **G. Combinator helper nodes for plan expansion** | Keep syntax unchanged; generate helper pure nodes or command-spec nodes with `makeEach`.           | Uses graph itself; no new syntax.                                   | Turns local deterministic construction into graph topology noise.                     | Rejected for planning data; use graph nodes only when behavior is real. |

---

## Missed Abstractions

| Multiple sites                                                               | Shared shape                                                    | Proposed name             | Cost of unifying                                                           |
| ---------------------------------------------------------------------------- | --------------------------------------------------------------- | ------------------------- | -------------------------------------------------------------------------- |
| `build_plan` record, pure-node trailing `where`, output equations            | local CorePure values prepared for typed output boundary        | frontier binding          | documentation and example pressure; syntax change only if ADR 0031 loses   |
| `build_plan.field -> output`, `*` record↔ports adapter, pure node egress    | translating record shape to port resources                      | egress projection         | compile-time injectivity and field-coverage checks                         |
| `include_dir`, `makeEach`, `make(N, K)`, form-local static counts            | closed data deciding graph shape                                | source-elaboration values | phase-indexed docs, tests, and later proof model                           |
| top-level helpers, node-local where fields, future source-elaboration values | deterministic CorePure evaluated at different dependency phases | CorePure residue ladder   | reference docs need one unified scoping section instead of scattered rules |

---

## Evidence Gaps

| Claim                                                     | Current evidence                                        | Missing evidence                                                | Recommended validation                               |
| --------------------------------------------------------- | ------------------------------------------------------- | --------------------------------------------------------------- | ---------------------------------------------------- |
| Trailing `where` is enough for source-driven planning     | ADR 0031 and current parser already support it.         | Rewritten large examples using the canonical surface.           | Rewrite C build first; compare quantum eraser later. |
| Egress projection can preserve linear port resources      | Architecture separates egress adapter from graph edges. | Formal statement that field-to-port projection is injective.    | Add Lean/Haskell model after syntax ADR.             |
| Contract-driven output derivation is compatible with Wire | Contracts already name port payload types.              | Whether contracts should describe value records or port fronts. | Architecture pass before any implementation.         |
| The syntax is novel enough for paper framing              | Internal design synthesis only.                         | External comparison with build DSLs, Nix, dataflow DSLs.        | Later research pass with external literature.        |

---

## Recommended Actions

### Act now

- [x] Use trailing `where let ... in { ... };` for the C-build `plan_build` node so PR 168 tests ADR
      0031's current answer.

### Design next

- [ ] Draft ADR: **Wire Egress Projection**. Owner: architecture. Cost: M.
- [ ] Patch the Wire reference with a single binding-phase ladder: source elaboration, graph
      expansion, node-frontier CorePure, executor runtime. Owner: docs. Cost: S.
- [ ] Revisit `where` placement only after `where` has been tried on at least two large examples.
      Owner: architecture. Cost: M.

### Write up

- [ ] Add a paper-note paragraph: "egress projection maps deterministic local data into linear
      output resources." Owner: research / paper track. Cost: S.

### Parked

- Contract-driven output derivation. Revisit only after egress projection has a typed carrier.
- Pre-output `let` syntax. Revisit only as an explicit supersession of ADR 0031's placement
  decision.
- Record-spread output syntax. Revisit only if projection vocabulary still leaves large nodes too
  verbose after a large-example rewrite.
- External prior-art comparison. Revisit before public novelty claims.

---

## Claim-to-Evidence Matrix

| Claim                                           | Artifact that supports it                                    | Artifact that weakens it                             | Verdict                                       |
| ----------------------------------------------- | ------------------------------------------------------------ | ---------------------------------------------------- | --------------------------------------------- |
| Includes are source elaboration, not runtime IO | `Cortex.Wire.Include` docstring and ADR 0051                 | None in current branch                               | Established for this implementation slice.    |
| `makeEach` is itemized static generation        | Parser expansion and ADR 0051                                | Only direct directory traversal, no recursive model  | Established, intentionally narrow.            |
| Trailing `where` is the canonical local surface | ADR 0031 and current parser                                  | Large examples may still read backward               | Existing decision; test before superseding.   |
| Record projection is not graph fan-out          | Architecture separates egress adapter from edge composition. | No named compiler carrier for egress projection yet. | Correct framing; implementation still needed. |
