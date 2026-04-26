---
title: "Wire Syntax and Bounded Autonomous Rewriting"
description: Research synthesis on Cortex Wire syntax, homogeneous-edge typing, bounded graph rewrites, and gas-style rewrite authority
---

# Research Memo: Wire Syntax and Bounded Autonomous Rewriting

**Date:** 2026-04-15
**Scope:** Cortex Wire syntax, bounded autonomous graph rewriting, endpoint typing, and budget/gas design
**Artifacts examined:** `src/Cortex/Graph/Core.hs`, `src/Cortex/Wire/{AST,Parser,Compiler,Contracts}.hs`, `src/Cortex/Circuit/NodeKind.hs`, `src/Cortex/Circuit/Lowering.hs`, `src/Cortex/Pulse/{Plan,Rewrite,Materialization,Types}.hs`, `test/Cortex/Circuit/CompilerSpec.hs`, `docs/Roadmap/Archive/wire-v0-implementation.md`, `docs/Research-notes/Foundation/2026-04-11-formalism-stack-synthesis.md`, `docs/Research-notes/Wire/2026-04-15-wire-vnext-record-first-rewrite-language-synthesis.md`, `docs/Roadmap/Plans/rewrite-materialization-and-recovery.md`, `docs/Publications/Paper-3-graph-substitution-semantics/manuscript.md`, issues `DIG-478`, `DIG-481`, `DIG-482`, `DIG-483`, `DIG-488`, `DIG-490`, and selected external literature on algebraic graphs, selective applicatives, rewriting logic, and amortized resource analysis
**Method:** Cross-reference synthesis
**Confidence profile:** High for current implementation and local design constraints; medium for syntax recommendations; medium-to-low for long-range gas and self-evolving workflow hypotheses

---

## Executive Summary

The strongest emerging design is not "a nicer workflow DSL" but a small typed graph machine with four distinct layers: a static node vocabulary, a concrete executable circuit, bounded runtime rewrites, and realized graphs as artifacts. Cortex already contains most of the semantic kernel needed for this in its graph core, rewrite planner, durable materialization, and vector rewrite budget.

The most important design click is correct: **edges should stay homogeneous and purely topological**. Compatibility should live on node endpoints, not on wires. This is already aligned with both the current implementation and the paper direction around boundary contracts. The language should preserve that separation instead of turning edges into typed selectors, function applications, or data-routing operators.

The current rewrite budget is already richer than a scalar "gas" model. It should remain the authoritative admission kernel. If a user-facing gas abstraction is added, it should be a policy layer or normalized view over the existing vector budget, not a replacement. Refund-style gas is interesting but should be deferred; the current monotone budget is easier to reason about, safer for admission, and much friendlier to proof and recovery.

The main missing abstractions are not graph theory primitives. They are boundary abstractions: explicit separation between environment and circuit, between deterministic pruning and open rewrite authority, between compatibility labels and payload projections, and between budget kernel and human-facing gas. These are where the next round of design should focus.

---

## Key Findings

### [P1] Cortex already has the right topological kernel for a graph-first surface language
**Category:** Novel Idea
**Status:** Observed
**Confidence:** High
**Primary evidence:** `src/Cortex/Graph/Core.hs`, `src/Cortex/Wire/Compiler.hs`, `docs/Roadmap/Archive/wire-v0-implementation.md`
**Cross-reference:** graph core, Wire v0 plan, algebraic graph literature

The current graph core is already the right semantic substrate for a compact circuit language. `Graph a` is built from `Empty`, `Vertex`, `Overlay`, and `Connect`. `Semigroup` uses overlay as `(<>)`. The current `path` semantics already make the subtle but correct choice that `a -> b -> c` should mean `edge a b <> edge b c`, not nested sequential composition with hidden structure. `connect` is full cross-product over left/right vertex sets.

This matters because the proposed vNext syntax is strongest when it is an honest skin over this kernel rather than a fresh invented formalism. A surface language with:

```wire
planner -> gatherer -> reviewer,
reviewer => (publisher, workflowAudit)
```

is not speculative. It is a direct authoring view of the algebra Cortex already uses internally.

**Why it matters:**
This sharply lowers design risk. The interesting work is not inventing a graph algebra; it is choosing how much of the existing algebra to expose, and how to keep the exposed layer honest with respect to lowering and runtime admission.

**Next step:**
Keep `Empty / Vertex / Overlay / Connect` as the semantic core. Treat surface syntax changes as elaboration decisions, not runtime-semantic changes.

### [P2] Homogeneous edges with endpoint compatibility are the right abstraction
**Category:** Missed Abstraction
**Status:** Observed
**Confidence:** High
**Primary evidence:** `src/Cortex/Wire/AST.hs`, `src/Cortex/Wire/Contracts.hs`, `docs/Publications/Paper-3-graph-substitution-semantics/manuscript.md`
**Cross-reference:** current ports model, boundary-contract semantics, rewrite discussion

This is the most important conceptual simplification in the recent discussion: **an edge should mean only "these nodes are connected."** It should not encode projection, selector semantics, argument position, or transformation meaning.

Current Cortex already trends in this direction. Ports declare accepted or produced contract labels. Connection validity is checked against endpoint declarations. Paper 3 explicitly distinguishes topology evolution from boundary contracts and rejects "arbitrary graph surgery without boundary contracts" as outside the theory. That is the same core idea stated more formally: topology is one layer, interface compatibility another.

The most useful vNext generalization is therefore:

- output labels say what a node can offer downstream
- input labels say what a node can accept upstream
- edge validity is computed from endpoint compatibility
- the edge itself remains semantically thin

This is superior to labeled edges such as:

```text
planner -[optionsSlice]-> optionsQuant
```

because labeled edges collapse topology, selection semantics, and transport policy into one object. That raises validation cost, complicates rewrites, and makes the graph language less honest.

**Why it matters:**
Keeping meaning on endpoints makes rewrites cheap to validate and easy for LLMs to propose. It also prevents the graph language from drifting into a general-purpose computation language.

**Next step:**
Make endpoint compatibility the explicit design center in vNext. If projections are needed later, model them as endpoint-level adapters or contract refinements, not edge annotations.

### [P3] Static node vocabulary plus concrete rewritable circuits is the right execution model
**Category:** Novel Idea
**Status:** Inferred
**Confidence:** High
**Primary evidence:** `src/Cortex/Pulse/Rewrite.hs`, `src/Cortex/Pulse/Materialization.hs`, `docs/Roadmap/Plans/rewrite-materialization-and-recovery.md`, issues `DIG-478`, `DIG-482`, `DIG-483`
**Cross-reference:** rewrite planner, materialization, runtime-gated rewrites

The deepest architectural distinction is not "nodes vs circuits" in a superficial authoring sense. It is:

1. **Static node vocabulary**
   - executors
   - prompts
   - tools
   - compatibility labels
   - runtime capabilities

2. **Concrete circuit**
   - a finite, currently executable topology over that vocabulary

3. **Rewrite proposal**
   - a local topology edit over the same vocabulary

4. **Realized graph**
   - the concrete topology that actually executed after admitted rewrites

This is better than dynamic template combinators like `each`, `gather`, or `scatter` for the current system. Cortex already has bounded, anchored, durable rewrites. A planner that needs four hypothesis lanes instead of two does not need a new language-level scatter primitive; it can propose a bigger concrete graph using the same vocabulary and stay within the rewrite budget.

**Why it matters:**
This keeps the runtime model closed and mechanically checkable. Rewrites do not invent executors, tools, or schemas; they instantiate and rewire a pre-validated vocabulary. That is a strong safety property and a major reason this design is LLM-compatible.

**Next step:**
In the spec, treat "environment" and "circuit" as different declaration spaces, even if they share one syntax family. Do not obscure this with too much structural magic.

### [P4] The current rewrite budget is already a vector resource algebra; gas should layer on top of it
**Category:** Design Tension
**Status:** Observed
**Confidence:** High
**Primary evidence:** `src/Cortex/Pulse/Rewrite.hs`, `src/Cortex/Pulse/Plan.hs`, `src/Cortex/Pulse/Types.hs`, `docs/Roadmap/Plans/rewrite-materialization-and-recovery.md`
**Cross-reference:** `RewriteBudget`, `RewriteCost`, `BudgetContext`, default budget, materialization model

The current runtime does not have a scalar gas budget. It has a **multi-dimensional structural budget**:

- added nodes
- added edges
- added depth
- frontier delta
- rewrite ops

Admission is fail-fast and monotone. `consumeRewriteBudget` subtracts structural cost from remaining budget and rejects if any dimension would go negative. `BudgetContext` exposes both initial and remaining budget, including per-dimension fractions.

This is already much more precise than a single scalar fuel counter. The design mistake would be to replace it too early with "gas" as one number. A scalar is good for human explanation and for soft model guidance; it is weaker as an admission authority.

The clean layering is:

- **kernel:** vector rewrite budget remains authoritative
- **policy:** optional scalar gas view derived from that vector
- **UX:** show gas to users or models as a summary, but never admit rewrites on gas alone

**Why it matters:**
This avoids collapsing several distinct control levers into one opaque number. A rewrite that adds little depth but many lateral branches is different from one that deepens the graph aggressively. The existing vector model captures that.

**Next step:**
If a gas abstraction is added, define it as a policy view over `RewriteBudget`, not as a replacement for `RewriteBudget`.

### [P5] Refundable gas is attractive but premature; monotone spend-only budgets are the correct first theorem target
**Category:** Design Tension
**Status:** Inferred
**Confidence:** Medium
**Primary evidence:** `src/Cortex/Pulse/Rewrite.hs`, `docs/Roadmap/Plans/rewrite-materialization-and-recovery.md`, external amortized resource analysis literature
**Cross-reference:** budget monotonicity, durable materialization, AARA for TRSs

The discussion's "graphs spend gas when adding structure and refill gas when pruning structure" is compelling. It makes the system feel metabolic and adaptive. But it also introduces serious complications:

- rewrite loops can become self-funding if refund rules are loose
- admission/recovery proofs become harder because remaining authority is no longer monotone
- pruning semantics and open rewrites get entangled
- users can no longer infer safe upper bounds from current remaining budget alone

The current kernel is much simpler:

- budget starts at a known vector
- every admitted rewrite decreases it
- zero budget disables rewrites

This monotonicity is valuable. It supports durable materialization, clear rejection explanations, and eventual bounded-growth claims. If refunds are added later, they should probably be a separate, explicitly minted credit system tied only to specific safe reductions such as deterministic branch pruning after materialization.

**Why it matters:**
Spend-only budgets are easier to reason about and easier to prove. Refundable gas is a policy feature, not a prerequisite for vNext.

**Next step:**
Keep spend-only vector budgets for the first full rewrite-capable release. Defer refunds until there is operational evidence that monotone budgets are too restrictive.

### [P6] Deterministic pruning and open topology expansion should not be treated as the same kind of rewrite
**Category:** Correctness Gap
**Status:** Observed
**Confidence:** High
**Primary evidence:** `src/Cortex/Circuit/Lowering.hs`, `src/Cortex/Pulse/Plan.hs`, `test/Cortex/Circuit/CompilerSpec.hs`, `docs/Roadmap/Plans/rewrite-materialization-and-recovery.md`
**Cross-reference:** latent conditions, `StageRewrite`, materialization loop

Current lowering already reveals a semantic distinction that the surface language should make clearer. A closed-world `if` branch is currently lowered as a rewrite (`AppendAfter`) even though it is semantically not the same as an open-ended structure proposal.

These are different operations:

- **prune/select within a declared closed world**
- **introduce new future topology within budget**

Both may materialize via the same runtime mechanism today, but they should not be conflated conceptually or in author-facing syntax. Pruning is much safer. It is constrained by predeclared alternatives and often does not need the full admission machinery of open-world expansion.

**Why it matters:**
If the language treats every branch choice as "just another rewrite," it obscures one of the best safety levers available: deterministic or near-deterministic graph reduction as a distinct effect.

**Next step:**
Keep or introduce separate semantics for:

- closed-world selection/pruning
- bounded open-world expansion

even if both still lower to the same materialization engine in early implementations.

### [P7] The current ports model is still coarser than the proposed capability-set story
**Category:** Evidence Gap
**Status:** Observed
**Confidence:** High
**Primary evidence:** `src/Cortex/Wire/AST.hs`, `src/Cortex/Wire/Contracts.hs`
**Cross-reference:** `WireInputPort`, `WireOutputPort`, native defaults, generic analysis ports

The recent discussion often speaks as if nodes naturally expose capability sets like:

```wire
outputs = [PlannerOutput AnalyzerInput OptionsQuantIn]
```

and downstream nodes simply intersect with those sets. That is directionally right, but it is not yet the real implementation model. Today:

- input ports accept lists of nominal contract names plus cardinality/required flags
- output ports each expose one nominal contract
- stage execution still yields one opaque payload per node, not separately transported typed values

This means capability sets are, today, mostly **compatibility labels over one payload**, not true independent typed channels. That is not a flaw, but it should be stated clearly. Otherwise the language risks promising field-level or value-level routing that the runtime does not perform.

**Why it matters:**
This is the main place where vNext could accidentally over-promise. Endpoint compatibility is real. Typed projection of different subvalues over different edges is not yet.

**Next step:**
Define vNext contracts first as offer/accept labels over opaque node outputs. Defer true projection semantics or multi-channel transport until there is a concrete runtime need.

### [P8] `workflow = { graph = ... }` is elegant, but purely structural workflow detection is probably too implicit
**Category:** Design Tension
**Status:** Inferred
**Confidence:** Medium
**Primary evidence:** current parser/compiler shape, existing v0 `circuit` declaration, workflow runtime needs
**Cross-reference:** `Wire.Parser`, `Wire.Compiler`, v0 circuit plan

A record-first syntax is attractive:

```wire
thesisV1 = {
  meta = { ... };
  graph = planner -> reviewer -> writer;
};
```

But there is a real tooling question here: how does the compiler know this is a runnable workflow rather than just another record? A purely structural rule like "any record with a `graph` field is a workflow" is elegant, but not obviously the best choice for tooling, discoverability, diagnostics, or LLM rewrite validation.

A more robust choice is an explicit surface marker:

```wire
workflow thesisV1 = {
  meta = { ... };
  graph =
    planner -> reviewer,
    reviewer -> writer;
};
```

or

```wire
thesisV1 = workflow {
  ...
};
```

This retains the record-first feel while giving the compiler and tools a stable top-level discriminant.

**Why it matters:**
This is one of the places where a small amount of explicitness can pay for itself in much better tooling and simpler validation rules.

**Next step:**
Do not commit to purely structural workflow detection yet. Prototype with an explicit `workflow` marker or declaration kind.

### [P9] Comma-overlay with parenthesized groups is the most credible syntax direction so far
**Category:** Design Tension
**Status:** Inferred
**Confidence:** Medium
**Primary evidence:** graph algebra, parser constraints, recent discussion
**Cross-reference:** graph core, Wire syntax discussion, current parser

Among the explored syntax options, the strongest current candidate is:

- `()` for graph identity / empty group
- `(a, b, c)` for grouped overlay
- `->` for singleton path composition
- `=>` for group-to-group cross-connect
- top-level commas for overlay of graph fragments
- `[]` for data lists
- `{}` for records

Example:

```wire
workflow thesisV1 = {
  meta = { concurrency = 3; };
  graph =
    planner -> analyzer,
    planner -> optionsQuant,
    (analyzer, optionsQuant) => reviewer,
    reviewer -> writer;
};
```

This syntax has several virtues:

- it aligns directly with the graph core
- it makes overlay visually cheap
- it avoids a noisy leading `<>` on every line
- it preserves `->` as strictly path syntax

The most elegant rejected alternative was angle-bracket unification such as `<a b c>`. It is aesthetically tempting, but it visually collides with `->` and `=>`, makes nested expressions harder to read, and buys too little clarity relative to the existing parenthesis/comma story.

**Why it matters:**
This is the point where syntax should optimize for parseability and honesty, not for maximal cleverness.

**Next step:**
Prototype parser sugar around comma-overlay and grouped parentheses. Keep `<>` as a core/internal operator, not necessarily as required surface syntax.

### [P10] Realized graphs are not just execution state; they are candidate workflow artifacts
**Category:** Novel Idea
**Status:** Speculative
**Confidence:** Medium
**Primary evidence:** `Cortex.Pulse.Materialization`, rewrite materialization plan, rewrite discussion
**Cross-reference:** materialization watermark, admitted deltas, lineage, runtime snapshots

The runtime already materializes admitted rewrites durably. That means it is already constructing a realized concrete graph that differs from the initial Wire one. This suggests a powerful workflow lifecycle:

1. author a conservative seed graph with rewrite authority
2. let the runtime discover a better concrete topology
3. snapshot the realized graph
4. re-run it as a fixed or lower-gas workflow

This is not yet a product feature, but the underlying ingredients exist:

- named nodes
- admitted rewrite deltas
- durable materialization lineage
- topology hashes and watermarks

If this becomes a first-class artifact, Cortex moves from "workflow engine with dynamic branches" toward "adaptive graph compiler with executable discovered graphs."

**Why it matters:**
This could become one of the most valuable feedback loops in the system: discover graph structure under bounded experimentation, then operationalize it as a stable workflow.

**Next step:**
Treat realized-graph export as a future artifact type. Do not build it into the syntax yet; first prove that discovered graphs are stable and useful in real workloads.

---

## Missed Abstractions

| Missing abstraction | What exists today | Why it is insufficient | Better shape |
| --- | --- | --- | --- |
| Environment vs circuit | Flat module with node decls and one circuit decl | Understates the difference between vocabulary and topology | Separate declaration spaces, even if syntax remains similar |
| Compatibility vs payload projection | Contract labels on ports | Suggests more structure than the runtime currently transports | Explicitly define contracts as offer/accept labels over opaque payloads |
| Pruning vs open rewrite | Both lower through rewrite-capable machinery | Hides a critical safety distinction | Give closed-world selection its own semantic lane |
| Budget kernel vs gas view | Vector budget only | Hard for humans/LLMs to reason about holistically | Preserve vector kernel; optionally expose scalar summary |
| Realized graph vs seed graph | Materialization lineage and watermark | Not surfaced as a first-class reusable artifact | Snapshot/export realized topology as a workflow candidate |

## Evidence Gaps

| Claim | Source | Current Evidence | Missing Evidence | Recommended Validation |
| --- | --- | --- | --- | --- |
| Endpoint capability sets are sufficient for all future routing needs | Discussion, paper direction | Strong for coarse compatibility, weak for fine-grained slicing | No proof for strict native-schema nodes or true multi-channel outputs | Prototype one rich multi-offer node and see whether opaque-payload routing remains adequate |
| Gas refunds improve exploration quality | Discussion only | Intuitively appealing | No operational data, no recovery proof, no anti-oscillation rule | Instrument real rewrite workloads before designing refund semantics |
| Record-only workflow syntax is better than explicit workflow declarations | Discussion only | Aesthetic benefit | No tooling or DX validation | Build a small parser prototype and compare diagnostics/discoverability |
| Realized graphs are reusable and stable across runs | Materialization already exists | Technically plausible | No empirical evidence that discovered topologies generalize | Snapshot a few rewrite-heavy runs and compare replay quality with zero budget |
| Scalar gas can guide LLM rewrites effectively | Budget fractions already exist | Possible to derive a summary | No experiments on prompting or rewrite proposal quality | A/B test raw vector budget vs scalar gas hints in rewrite prompts |

## Design Tensions

### 1. Honest graph language vs universal expression language

The observation that expressions like `(1, 2, 3) => (+)` "almost make sense" is real and intellectually useful. It shows that the graph algebra is expressive enough to resemble a dataflow calculus. But following that path would be a mistake for this system.

The current strength of Wire is that it describes topology, not arbitrary computation. The moment `=>` starts to mean application rather than connectivity, edges stop being homogeneous and the language has to define evaluation semantics, positional wiring, and operation meaning. That would destroy much of what makes LLM-proposed rewrites cheap to validate.

**Verdict:** keep Wire a topology language, not a general-purpose dataflow language.

### 2. One generic node schema vs typed node constructors

There is a real tension between:

- a single record shape for every node
- distinct constructors or schemas for `await`, `emit`, or other boundary nodes

The recent discussion leaned toward collapsing everything into generic nodes plus tools. The current implementation weakens that argument. `Await` and `Emit` already correspond to structurally different IR forms and runtime behavior. Treating them as just more tool calls risks erasing valuable compile-time guarantees.

**Verdict:** keep executor-backed task nodes and boundary nodes semantically distinct until there is strong evidence they should collapse.

### 3. Scalar gas vs vector budget

Humans and LLMs want one number. The runtime wants a shape-aware bound. This is a classic control-surface tension.

**Verdict:** expose a human-friendly gas summary if useful, but keep authoritative admission vector-valued.

### 4. Purely structural magic vs explicit top-level declarations

Minimal syntax is attractive, but workflows, node templates, contract declarations, and rewrite blocks are not the same kind of thing.

**Verdict:** tolerate a small amount of explicit syntax at the top level if it buys better tooling and clearer semantics.

### 5. Dynamic scatter/gather combinators vs bounded explicit rewrites

A tempting alternative is to add graph-level combinators like `each`, `gather`, or `gate`. They are elegant on paper. But Cortex already has bounded graph rewriting. Adding these combinators risks duplicating a capability the runtime already has, while also making the language more complicated.

**Verdict:** prefer rewrites over new higher-order structural combinators unless a concrete class of workloads proves rewrites are too awkward.

## Novel Ideas & Hypotheses

### 1. Type bounds and resource bounds should be treated as orthogonal authority systems

The phrase "autonomous graph rewriting under type bounds" is best understood as the intersection of several independent constraints:

- **vocabulary bound:** rewrites may only instantiate known node definitions
- **compatibility bound:** edges must respect endpoint offer/accept relations
- **topology bound:** resulting graph must remain a valid DAG with valid anchor semantics
- **resource bound:** structural cost must fit the remaining rewrite budget
- **materialization bound:** rewrite admission is phased and durable, not instantaneous graph mutation

This is a stronger and clearer model than "the graph can rewrite itself if types permit." Types are one bound, not the only one.

### 2. Gas should be modeled as a view of rewrite authority, not as energy in the semantic core

It is useful to speak about gas because:

- users can reason about it
- LLM prompts can mention it
- policy can normalize it

But semantically, the core object is still a vector rewrite budget plus a materialization loop. Gas is a coordination surface, not the underlying theory.

### 3. Realized graphs could become the bridge between exploratory and operational workflows

This is likely the most practically valuable speculative idea. Seed workflows with rewrite authority can act as topology search. Realized graphs can then be harvested into fixed or low-gas operational workflows. This creates a clean path from exploration to production without inventing a second language.

### 4. Latent capacity metrics may become a better rewrite prompt primitive than generic "you may rewrite"

If the environment can compute:

- which outputs a node offers but the current circuit does not use
- which nearby nodes are type-compatible but currently disconnected
- how much structural budget remains by dimension

then rewrite prompts can become much sharper. The runtime can tell a node not just "you have budget" but "you have two unused compatible downstream capabilities and frontier delta 1 remaining."

## Dead Ends / Rejected Directions

### 1. Typed or labeled edges

Rejected because they overload wires with semantics that belong at endpoints or in runtime adapters. This would make rewrites significantly harder to validate and the graph language significantly less honest.

### 2. Treating Wire as a computation language

Rejected because it collapses topology description and execution semantics. Expressions like `(1, 2, 3) => (+)` are useful thought experiments, not a good target surface language.

### 3. Newline-as-overlay

Rejected because multi-line graph expressions need ordinary line breaking. Bare newline as `<>` introduces avoidable ambiguity.

### 4. Angle-bracket unification (`<...>`)

Rejected for now because it collides visually with `->` and `=>`, degrades readability in nested graphs, and does not buy enough expressiveness over parentheses and commas.

### 5. Refundable gas in the first full rewrite release

Rejected for now because monotone budgets are far easier to reason about, validate, and recover from. Refunds can be researched later as a second-order optimization.

---

## Recommended Actions

### Act Now
- [ ] Write a vNext design note that explicitly separates environment, circuit, rewrite proposal, and realized graph.
- [ ] Preserve the current vector `RewriteBudget` as the authoritative admission mechanism.
- [ ] Document "endpoint compatibility, homogeneous edges" as a first-class design principle in the Wire spec.
- [ ] Introduce spec language distinguishing closed-world pruning from open-world bounded rewrites.

### Design Next
- [ ] Prototype a record-first surface syntax with explicit `workflow` declarations and comma-overlay graph blocks.
- [ ] Decide whether vNext contracts are only compatibility labels or whether any projection semantics are being promised.
- [ ] Explore a user-facing `GasView` derived from the vector budget without changing admission.
- [ ] Define how realized graphs would be serialized, diffed, and promoted into Wire workflows.

### Write Up
- [ ] Update the ongoing papers so Paper 3's boundary-contract story and the rewrite materialization plan's budget/materialization story are clearly reflected in the language design notes.
- [ ] Add a short "Why edges are homogeneous" section to the formalism-stack synthesis.
- [ ] Add a rewrite-authority section to the Wire vNext design doc showing the full bound lattice: vocabulary, compatibility, topology, resource, and materialization.

### Parked
- Refundable gas / budget credits — defer until rewrite-heavy workloads exist and oscillation risks can be measured.
- Fully generic node-only surface without boundary node distinctions — defer until the current `Await`/`Emit` semantics are pressure-tested.
- Higher-order combinators like `each` or `gather` — defer unless bounded rewrites prove too awkward.
- Profit- or time-backed gas for perpetual agents — interesting, but well beyond the current theorem and product boundary.

---

## Optional Additions

### Known Unknowns

- Whether native executors will eventually require stricter sub-structure contracts than opaque payload compatibility can support.
- Whether one admitted rewrite per frontier wave is sufficient for the kinds of exploratory graphs Portman will want.
- Whether realized graphs discovered in one run generalize well enough to deserve promotion into reusable workflows.
- Whether a scalar gas summary actually improves LLM rewrite quality or merely sounds intuitive to humans.

### Claim-to-Evidence Matrix

| Claim | Artifact that supports it | Artifact that weakens it | Verdict |
| --- | --- | --- | --- |
| Wire should be graph-first, not operation-first | `Graph.Core`, current compiler, recent design discussion | None substantial | Strong |
| Homogeneous edges are the right default | current ports model, Paper 3 boundary-contract framing | Rich native-schema routing may strain opaque payloads | Strong, with a future caveat |
| Gas should not replace vector budgets | `RewriteBudget`, `BudgetContext`, durable materialization | Scalar gas may still help UX/prompting | Strong |
| Closed-world conditions should be distinct from open rewrites | latent conditions already exist; current lowering conflates them operationally | shared materialization engine tempts syntactic unification | Strong |
| Pure record-structural workflow detection is enough | aesthetic simplicity only | tooling and discoverability concerns | Weak |

### Selected External Reference Points

- Andrey Mokhov et al., *Selective Applicative Functors* (2019): static declaration of effects with dynamic selection is a useful comparison point for bounded graph evolution, but Cortex goes further because topology itself can grow or shrink.
  https://eprints.ncl.ac.uk/258640
- Narciso Martí-Oliet and José Meseguer, *Rewriting logic as a logical and semantic framework*: useful for the idea that topology description and execution interpretation can remain separate layers.
  https://maude.cs.illinois.edu/papers/abstract/tcs4012.html
- Georg Moser and Manuel Schneckenreither, *Automated Amortised Resource Analysis for Term Rewrite Systems* (2018): relevant as a resource-analysis backdrop for future gas accounting, especially if Cortex ever wants proof-oriented budget claims.
  https://arxiv.org/abs/1811.09071

---

## Concrete vNext Sketch

The following is not a final proposal. It is a credible synthesis of the current direction:

```wire
PlannerOut = contract;
AnalyzerIn = contract;
OptionsIn = contract;
ReviewIn = contract;
ArtifactOut = contract;

planner = {
  executor = native "planner";
  inputs = [];
  outputs = [PlannerOut AnalyzerIn OptionsIn];
};

analyzer = {
  executor = llm "openai/gpt-5.4";
  inputs = [AnalyzerIn];
  outputs = [ReviewIn];
  tools = [searchAssets getAssetPrices];
  prompt = "Decompose the thesis into testable claims.";
};

optionsQuant = {
  executor = native "options_quant";
  inputs = [OptionsIn];
  outputs = [ReviewIn];
};

writer = {
  executor = native "report_writer";
  inputs = [ReviewIn];
  outputs = [ArtifactOut];
};

workflow thesisV1 = {
  budget = {
    addedNodes = 16;
    addedEdges = 32;
    addedDepth = 6;
    frontierDelta = 4;
    rewriteOps = 4;
  };

  graph =
    planner -> analyzer,
    planner -> optionsQuant,
    (analyzer, optionsQuant) => writer;
};
```

The key property of this sketch is not the exact punctuation. It is that it preserves:

- static vocabulary
- homogeneous edges
- endpoint compatibility
- concrete topology
- explicit bounded rewrite authority

That is the semantic center worth protecting.
