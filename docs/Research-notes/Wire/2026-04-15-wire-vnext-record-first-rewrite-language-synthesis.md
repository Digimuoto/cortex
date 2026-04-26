---
title: "Research Memo: Wire vNext Record-First Rewrite Language Synthesis"
description: Synthesis of exploratory language-design discussion on static node vocabularies, concrete rewritable circuits, homogeneous edges, capability-set contracts, and gas-bounded runtime rewrites
---

# Research Memo: Wire vNext Record-First Rewrite Language Synthesis

> Terminology update: this memo was drafted while the Wire surface was
> still referred to as `.cr`. The preferred name is now **Cortex Wire** and the
> preferred file extension is `.wire`; `.cr` remains compatibility input.

**Date:** 2026-04-15
**Scope:** exploratory synthesis of the latest Wire / Cortex language-design discussion, cross-referenced against the shipped v0 Wire surface and the current Cortex formalism notes
**Artifacts examined:** discussion transcript in this thread, [wire-v0-implementation.md](../../Roadmap/Archive/wire-v0-implementation.md), [2026-04-11-formalism-stack-synthesis.md](../Foundation/2026-04-11-formalism-stack-synthesis.md), current thesis/quant workflow usage on this branch
**Method:** discussion synthesis with implementation-aware calibration
**Confidence profile:** high on the design pressures identified in the discussion; medium on the proposed surface syntax; low-to-medium on the more speculative gas-economics and realized-graph lifecycle ideas

---

## Executive Summary

The strongest new conclusion from this discussion is that Wire wants a cleaner split between **static node vocabulary** and **dynamic circuit topology**. Nodes are defined once, up front, as a closed environment of capabilities. Circuits are concrete finite graphs over that environment. Runtime rewrites do not invent new node kinds; they propose new concrete topology using the same syntax and the same static vocabulary.

The second major conclusion is that the graph algebra should stay **topological and homogeneous at the edge level**. Edges mean dependency, not operations, selectors, or typed morphisms. Types live on the endpoints: input capability sets describe valid predecessors, output capability sets describe valid successors. That keeps rewrites cheap to validate and preserves the current "graph as structure, runtime as interpreter" boundary.

The third major conclusion is that the language is converging toward a small record-first surface built from four primitives, three graph operators, and two separators. The vNext sketch is not a general-purpose host language. It is a compact notation for defining a static execution environment and authoring or rewriting concrete graph topology within that environment.

The discussion also uncovered several unresolved tensions that should stay explicit: whether node "roles" are truly semantic or collapse into a single node record; whether contracts should stay coarse or evolve toward richer capability sets and projections; and whether runtime gas is best understood as a bounded rewrite budget, a renewable temporal metabolism, or eventually an economic control surface.

---

## Key Findings

### [P1] The cleanest split is static node vocabulary plus dynamic concrete circuit
**Category:** Missed Abstraction
**Status:** Inferred
**Confidence:** High
**Primary evidence:** discussion synthesis, [Wire v0 plan](../../Roadmap/Archive/wire-v0-implementation.md), [formalism stack synthesis](../Foundation/2026-04-11-formalism-stack-synthesis.md)
**Cross-reference:** v0 currently mixes node declarations and one circuit in one file; the formalism memo already separates topology, intent, and authority

The most stable design from the discussion is a two-layer model:

- **Nodes are the alphabet.** They are defined statically before execution. They declare executors, tools, and interface capabilities. The node set is closed at runtime.
- **Circuits are sentences.** They are concrete finite graph expressions over that alphabet. They execute as real graphs, and runtime rewrites produce new concrete finite graphs using the same node vocabulary.

This is cleaner than treating rewrites as hidden runtime magic or treating the surface language as a dynamic programming language. A rewrite becomes "new graph topology over pre-validated nodes" rather than "arbitrary new code."

**Why it matters:**
This split preserves cheap runtime validation and makes LLM-proposed rewrites tractable. A rewrite proposal only needs to name existing nodes and express edges between them. The runtime does not need to validate new executors, new tools, or new contract declarations in the rewrite path.

**Next step:**
Write the vNext spec in two explicit sections: environment/vocabulary and circuit/rewrite topology.

### [P1] Edges should remain homogeneous; types belong to endpoints, not wires
**Category:** Design Tension
**Status:** Inferred
**Confidence:** High
**Primary evidence:** discussion thread on `(1, 2, 3) => (+)`, current workflow graph model, [formalism stack synthesis](../Foundation/2026-04-11-formalism-stack-synthesis.md)
**Cross-reference:** current Cortex graph core is about topology, not typed morphisms

The discussion converged on a strong boundary:

- graph edges mean **dependency / feed-forward topology**
- graph edges do **not** mean operation, application, selector, or typed morphism
- contract compatibility is checked at the **endpoints**

This matters because expressions like `(1, 2, 3) => (+)` feel meaningful only if `=>` stops meaning "connect these vertices" and starts meaning "apply these values to this operator." That would make the surface language a computation language rather than a graph description language.

The cleaner rule is:

- output capability sets describe what a node can provide
- input capability sets describe what a node can accept
- an edge is valid if the upstream and downstream sets intersect appropriately

The wire itself stays untyped.

**Why it matters:**
This keeps the graph algebra honest and the compiler/runtime simple. Once edges carry selectors or operations, rewrites become heavier, validation becomes more semantic, and the language stops being a thin structural layer over the runtime.

**Next step:**
State explicitly in the vNext spec that edges are homogeneous and that endpoint capability matching is the type discipline.

### [P1] Output types are better modeled as capability sets than singular payload types
**Category:** Novel Idea
**Status:** Inferred
**Confidence:** Medium
**Primary evidence:** discussion on planner exposing `AnalyzerInput`, `OptionsQuantIn`, `MacroHedgeIn` simultaneously
**Cross-reference:** current workflows already hint at latent capacity via node outputs being reused in different branches

One of the most generative ideas in the discussion was to treat node outputs as a **set of available capabilities**, not a single payload type:

```wire
planner = {
  executor = native "planner";
  inputs = [];
  outputs = [PlannerOutput AnalyzerInput OptionsQuantIn MacroHedgeIn];
};
```

Then the graph can choose which capabilities to tap:

```wire
planner -> analyzer

planner -> (analyzer, optionsQuant)
```

The planner node stays unchanged. The circuit merely exposes more of its latent capability.

This leads to a useful conceptual distinction:

- node definitions define the **possible wiring space**
- a concrete circuit picks one point within that space
- a rewrite moves to another point in the same space

**Why it matters:**
This is a good fit for bounded rewrites. Nodes remain reusable and static while graphs become richer over time by wiring more of what those nodes already know how to emit.

**Next step:**
Keep this as a vNext concept, but do not overcommit to exact syntax until the contract/capability model is written down more formally.

### [P1] Runtime rewrites are best understood as bounded topology edits over a closed vocabulary
**Category:** Missed Abstraction
**Status:** Inferred
**Confidence:** High
**Primary evidence:** discussion on planner proposing extra hypothesis lanes, existing bounded rewrite design in current branch docs
**Cross-reference:** [Wire v0 plan](../../Roadmap/Archive/wire-v0-implementation.md), [formalism stack synthesis](../Foundation/2026-04-11-formalism-stack-synthesis.md)

The discussion sharpened what a rewrite actually is:

- not dynamic template expansion
- not hidden scatter/gather semantics
- not introduction of new node definitions
- but a **bounded proposal to modify concrete graph topology** using existing nodes

Validation was implicitly framed as four cheap checks:

1. **Bound / gas**: within allowed structural budget
2. **Vocabulary**: uses only nodes from the existing environment
3. **Wiring**: every edge is capability-compatible
4. **Topology**: the resulting graph is valid

This is a strong design because it makes runtime rewrites feel like controlled graph surgery rather than arbitrary runtime code generation.

**Why it matters:**
This is the key to making LLM-proposed rewrites plausible. The LLM only emits topology over known nodes. The runtime does not need to trust it with environment mutation.

**Next step:**
Document rewrite admission explicitly in vNext as "topology edit over closed vocabulary" and keep new node declaration out of runtime rewrite scope.

### [P2] The surface language is converging toward four literals, three operators, and two separators
**Category:** Novel Idea
**Status:** Inferred
**Confidence:** Medium
**Primary evidence:** late-stage syntax discussion in transcript
**Cross-reference:** v0 ``.wire` is already record-oriented; this pushes further toward a uniform literal vocabulary

The strongest compact syntax proposed in the discussion is:

```txt
()    circuit fragment / graph identity
{}    record / node definition
[]    list / capability and tool sets
""    string / prompt and text values

->    path over singleton fragments
=>    connect grouped fragments
<>    overlay

,     overlay separator in graph position
;     definition / field terminator
```

That leads to an appealing split:

- `[]` is data
- `()` is graph grouping / fragment identity
- `{}` is configuration
- `""` is text

One especially strong rule from the discussion:

- `(a, b) -> c` should be invalid
- grouped multi-source wiring uses `=>`

That keeps `->` strictly linear path syntax.

**Why it matters:**
The language gets dramatically smaller and more LLM-friendly if rewrites are just names plus three graph operators over a fixed vocabulary.

**Next step:**
Capture this syntax in a vNext design note, but treat it as exploratory rather than committed. Current v0 syntax should remain the authoritative implemented surface.

### [P2] The current "role" vocabulary is not yet semantically stable in this model
**Category:** Design Tension
**Status:** Inferred
**Confidence:** Medium
**Primary evidence:** discussion on `act`, `await`, `decide`, `emit`, and whether they survive as real node kinds
**Cross-reference:** current v0 explicitly supports `act`, `await`, and `emit`; earlier formalism notes also distinguish semantic node kinds

The discussion repeatedly collapsed the node taxonomy:

- `decide` looked like constrained rewrite/prune, not a fundamentally separate node shape
- `await` looked more like a capability or tool than a first-class node kind
- `emit` looked like a side effect that might belong to the executor/tool layer
- `act` became so generic that it risked meaning "everything that runs"

The end state of the discussion leaned toward:

- node = uniform record
- executor + tools + contracts define behavior
- prune/rewrite are runtime outcomes, not necessarily syntactic node categories

This is a meaningful divergence from the current v0 surface, which still uses explicit `role`.

**Why it matters:**
If vNext moves toward a single node record, the language gets smaller and more regular. But that also risks losing useful compile-time schemas and semantic tags that the runtime/admin surface may still need.

**Next step:**
Do not collapse roles yet. Record the question explicitly: are roles semantic kinds, executor capabilities, or just historical surface sugar?

### [P2] Gas is emerging as the real control surface for runtime rewrites
**Category:** Novel Idea
**Status:** Speculative
**Confidence:** Medium-Low
**Primary evidence:** discussion on gas as structural budget, refill on pruning, temporal budgets, P&L-linked budgets
**Cross-reference:** bounded rewrites are already part of the current direction, but the economic model is not yet formalized

The discussion moved from a simple rewrite budget to a more ambitious conservation law:

- adding structure spends gas
- pruning / simplifying structure refunds gas
- gas can be allocated per run, per time window, or even from external economics

This yields a powerful mental model:

- the graph expands when it needs to explore
- the graph contracts when it can eliminate paths
- rewrite authority becomes a bounded metabolic process rather than an on/off flag

This also leads to the "realized graph" idea:

- run a seed graph with gas
- let it rewrite itself into a useful concrete graph
- snapshot that realized graph
- rerun it later with low or zero gas as a stable workflow

**Why it matters:**
This is the most novel part of the design. If it works, Cortex becomes less like a fixed workflow engine and more like an adaptive graph machine with a reusable artifact lifecycle.

**Next step:**
Treat gas as a first-class research topic, not just an implementation detail. It needs a simple law before it becomes syntax or UX.

---

## Design Snapshot

The discussion converged on the following shape for ``.wire` vNext.

### 1. Static environment

Node definitions are declared once and remain the only available runtime vocabulary:

```wire
planner = {
  executor = native "planner";
  inputs = [];
  outputs = [PlannerOutput AnalyzerInput OptionsQuantIn];
  tools = [searchAssets getAssetPrices];
};

analyzer = {
  executor = llm "deepseek/deepseek-r1";
  inputs = [AnalyzerInput];
  outputs = [AxiomSet AnalystOutput];
  tools = [searchAssets getAssetPrices];
  prompt = "Decompose the thesis into testable axioms.";
};

optionsQuant = {
  executor = native "optionsQuant";
  inputs = [OptionsQuantIn];
  outputs = [OptionsAnalysis];
};

reviewer = {
  executor = native "reviewer";
  inputs = [AxiomSet AnalystOutput OptionsAnalysis];
  outputs = [ReviewerOutput];
};
```

### 2. Concrete initial circuit

```wire
thesisV1 = {
  meta = {
    displayLabel = "Thesis Stress Test";
    gas = 50;
  };
  graph =
    planner -> analyzer,
    analyzer -> reviewer;
};
```

### 3. Runtime rewrite in the same language

If the planner discovers an options branch is needed, it can propose:

```wire
planner -> (analyzer, optionsQuant),
(analyzer, optionsQuant) => (reviewer)
```

The node set did not change. The topology did.

### 4. Realized graph as artifact

The realized graph can later be snapshotted as a new Wire workflow:

```wire
thesisV1_realized = {
  meta = {
    displayLabel = "Thesis Stress Test (Realized)";
    gas = 0;
  };
  graph =
    planner -> (analyzer, optionsQuant),
    (analyzer, optionsQuant) => (reviewer);
};
```

This is one of the most important consequences of the design: the Wire language, rewrite language, and artifact language are all the same surface.

---

## Relationship to Current V0

This discussion is **not** a description of the currently implemented `.wire` surface.

Current v0 in [wire-v0-implementation.md](../../Roadmap/Archive/wire-v0-implementation.md):

- uses `node ... { ... }` plus exactly one `circuit ... { ... }`
- uses `connect`, `path`, `fanin`, `fanout`, `between`, `clique`
- supports roles `act`, `await`, `emit`
- compiles to `CompiledCircuit`
- treats Wire rewrites as a deferred next slice

The vNext ideas here differ in several ways:

- record-first node definitions rather than the current `node` declaration form
- more uniform graph-expression syntax rather than `connect`-list sugar
- runtime rewrites expressed directly in the same graph notation
- capability-set contracts rather than simple singular port declarations
- a more explicit split between static environment and rewritable circuit

So this memo should be read as:

- a synthesis of where the design pressure is heading
- not a claim that the current parser/runtime already behaves this way

---

## Missed Abstractions

### Static vocabulary vs. runtime topology
This appears to be the most important missing abstraction. The current language surface and runtime design already hint at it, but the discussion made it explicit.

### Endpoint capability sets vs. edge typing
The discussion clarified that the useful type discipline is likely endpoint-based rather than wire-based.

### Realized graph as first-class artifact
This may be the cleanest way to unify exploration and stable replay without inventing a second language.

---

## Evidence Gaps

| Claim | Source | Current Evidence | Missing Evidence | Recommended Validation |
| --- | --- | --- | --- | --- |
| Static node vocabulary plus rewritable concrete circuit is the right split | Discussion + current rewrite direction | Strong conceptual fit with current bounded rewrite direction | No concrete vNext spec or prototype yet | Write a minimal vNext spec and prototype parser/lowering stub |
| Capability-set outputs are better than singular outputs | Discussion | Strong explanatory value | No formal contract model or compiler rules yet | Prototype one worked example with planner/analyzer/optionsQuant |
| Roles should collapse into a single node record | Discussion | Conceptually appealing | Conflicts with current v0 and existing semantic distinctions | Compare admin/runtime needs before collapsing |
| Gas should be a conservation-law control surface | Discussion | Strong intuition | No measured gas law or runtime accounting model yet | Instrument one bounded rewrite prototype and inspect realized graphs |
| Realized graphs should be saved and rerun as workflows | Discussion | Highly compelling lifecycle idea | No storage/versioning/replay design yet | Prototype export of one realized graph to Wire source |

---

## Design Tensions

### Small language vs. meaningful static schemas
A single node record is elegant, but explicit node kinds may still be useful for validation, admin UI, and runtime policy.

### Coarse contracts vs. expressive data routing
The discussion deliberately kept edges homogeneous and pushed semantics to endpoints. That preserves simplicity, but eventually richer projections or artifact contracts may still be needed.

### Static topology clarity vs. runtime flexibility
The rewrite model is strongest when the initial graph stays simple and rewrites are common. But too much runtime mutation can make seed topology less meaningful to humans.

### Readability vs. syntactic purity
The final syntax sketch is pleasingly small, but some choices remain open:

- whether top-level graph overlay should be comma-separated
- whether inline `<>` remains necessary
- how far the language should unify record, list, and circuit literals

---

## Novel Ideas & Hypotheses

### 1. Graphs as adaptive artifacts
The most promising novel idea is that the system's best graph may emerge through bounded runtime rewriting, then become a new Wire workflow artifact.

### 2. Gas as topology metabolism
Gas may be the correct mental model for bounded runtime plasticity:

- expansion costs gas
- pruning refunds gas
- long-lived agents may receive gas over time

This is speculative, but it appears unusually fruitful.

### 3. Closed vocabulary as the safety boundary
The discussion strongly suggests that runtime plasticity should operate only inside a closed environment of pre-validated nodes and tools. This may be the key safety boundary that makes LLM-proposed rewrites workable.

---

## Dead Ends / Rejected Directions

### Edge-typed or operation-carrying wires
Rejected in the discussion because it makes the graph algebra heavier and conflates topology with computation semantics.

### Treating graph syntax as direct computation
Expressions like `(1, 2, 3) => (+)` are illuminating, but they point toward a general-purpose dataflow language. The discussion treated this as a valuable conceptual lens, not the right direction for `.wire`.

### Using `{}` as both record and graph identity
The discussion found tuple/group-style graph grouping and identity cleaner than record-literal overloading.

### Overextending node "roles"
The discussion ended up skeptical that `act/await/decide/emit` are the right long-term syntactic constructors if awaiting, branching, and emitting can be understood as executor capabilities or runtime outcomes.

### Angle-bracket circuit syntax
Explored for deeper syntactic unification, then implicitly rejected as less readable once nested arrows and grouped wiring are involved.

---

## Recommended Actions

### Act Now
- [ ] Write a short vNext note that explicitly separates static node vocabulary from rewritable concrete circuit topology.
- [ ] Keep current v0 docs authoritative; mark this memo exploratory.

### Design Next
- [ ] Define the minimal contract/capability model needed to express endpoint-based compatibility without edge typing.
- [ ] Decide whether vNext should preserve explicit node kinds or collapse to a single node record plus executor/tool capability.
- [ ] Sketch rewrite admission in vNext as vocabulary + wiring + topology + gas checks.

### Write Up
- [ ] Add one worked example showing an initial circuit, a runtime rewrite, and the realized graph artifact.
- [ ] Cross-link this memo from the existing Wire v0 plan and the formalism-stack memo.

### Parked
- Gas tied to time, profits, or other external economics — promising, but too speculative until the basic rewrite engine is wired.
- NPC/game-behavior analogies — useful for intuition, but not yet helpful for the first implementation spec.

---

## Known Unknowns

- Whether capability-set contracts are the right long-term abstraction or just a stepping stone toward richer typed artifact projections
- Whether the runtime really wants a single node record or still needs explicit semantic kinds for observability and policy
- Whether a realized-graph lifecycle will feel natural in the actual thesis/analysis workloads rather than only in theory
- Whether the syntax can stay this small without becoming ambiguous or misleading in more complex real examples
