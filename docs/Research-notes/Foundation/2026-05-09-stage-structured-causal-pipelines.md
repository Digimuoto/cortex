---
title: "Research Memo: Stage-Structured Causal Pipelines"
description:
  "Synthesis note on Wire as a stage-structured causal pipeline language: from ordered vectors and
  lexical records to typed frontier graphs, with implications for examples, runtime loops, and child
  runs."
date: 2026-05-09
status: research
related:
  - docs/Publications/Paper-5-Causal-Programming/
  - docs/Publications/Paper-6-executable-diagrams/
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/Architecture/07-rewrites-and-materialization.md
  - docs/Reference/Wire/grammar.md
  - docs/ADRs/0047-wire-frontier-linearity-and-precedence.md
  - docs/ADRs/0052-wire-bounded-indexed-boundary-products.md
  - examples/wire/dashboard-request.wire
  - examples/wire/bounded-shard-analysis.wire
---

# Research Memo: Stage-Structured Causal Pipelines

**Date:** 2026-05-09 **Scope:** the current Paper 6 example, the `<>`/`=>` precedence discovery, the
vector/record/graph explanation of ordinary programs, finite-product adapters, bounded loops,
runtime-owned process loops, and aspirational child-run composition. **Branch / PR:**
`docs/executable-diagrams-submission` **Layers examined:** Wire parser and grammar, Wire/Pulse
architecture chapters, ADRs 0047 and 0052, Paper 5 and Paper 6 drafts, current Wire examples, Theory
README proof-status surface, and selected external context on graph algebra, arrows, dataflow,
traces, and durable execution. **Layers skipped:** live GitHub issues and PRs; `gh` returned 401
after token removal, so issue state was not authoritative in this pass. Downstream repositories were
skipped because the question is substrate-level. **Method:** cross-source synthesis through the
seven archetype lenses. **Confidence profile:** high on the local Wire/Pulse semantics and Paper 6
example; medium on the broader programming-language framing; speculative on new child-run syntax.

External context checked:

- Andrey Mokhov, _Algebraic Graphs with Class_: <https://eprints.ncl.ac.uk/239461>
- John Hughes / Haskell arrows overview: <https://www.haskell.org/arrows/>
- Gilles Kahn, _The Semantics of a Simple Language for Parallel Programming_:
  <https://www.cs.columbia.edu/~sedwards/papers/kahn1974semantics.pdf>
- OpenTelemetry traces: <https://opentelemetry.io/docs/concepts/signals/traces/>
- Restate durable execution: <https://docs.restate.dev/foundations/key-concepts#durable-execution>
- AWS Durable Execution SDK determinism guidance:
  <https://docs.aws.amazon.com/durable-execution/patterns/best-practices/determinism/>

## Executive Summary

The best synthesis is that Wire is not mainly a "graph DSL" and not mainly a language about `*`. It
is a **stage-structured causal pipeline** language: `<>` forms a same-stage frontier, `=>` advances
the frontier, and typed ports decide which causal observations may cross between stages. That phrase
connects Paper 6 back to Paper 5's stronger thesis: ordinary code overuses ordered vectors and
lexical call/return records for computations whose true structure is an asymmetric causal DAG.

The current dashboard example is close to canonical because `prepare_dashboard` is a causal
derivation node, not a fan adapter: it consumes `UserProfile` once and emits the distinct branch
facts required by later work. `*` remains important, but only as the finite-product boundary adapter
for product-shaped frontiers such as records and `[T; N]`. Unbounded or dynamically bounded looping
should stay outside pure Wire topology for now: the process loop belongs to Pulse, while child runs,
bounded generated families, and runtime-admitted rewrites are the controlled ways to express
repetition and hierarchy.

## Coherent Narrative

### 1. From ordered vectors to named records to causal frontier graphs

Imperative code is structurally close to an ordered vector of effects. The reader cannot interpret a
later variable use by name alone; the ordered prefix decides what the name currently denotes:

```python
x = 1
x = x + 1
y = x * 2
```

An SSA transform makes the dependency structure more record-like:

```text
x0 = 1
x1 = x0 + 1
y0 = x1 * 2
```

Functional programming moves part of that record structure into source. In a pure `let`, a binding
can be understood by recursively following names:

```haskell
let
  user = fetchUser uid
  posts = fetchPosts (userId user)
  friends = fetchFriends (userId user)
in assemble user posts friends
```

But effects pull the program back toward a linear spine unless the language or library adds a second
structure:

```haskell
do
  user <- fetchUser uid
  posts <- fetchPosts (userId user)
  friends <- fetchFriends (userId user)
  pure (assemble user posts friends)
```

Paper 5 names the general problem as temporal dishonesty: mainstream syntax presents a single-stack
or sequence-shaped story even when the real execution is partially ordered. Wire's move is to make
the partial-order frontier explicit in the source:

```wire
receive_request
  => fetch_user
  => prepare_dashboard
  => fetch_posts <> fetch_friends
  => assemble
  => respond
```

Here the graph is not a record of expressions and not an ordered vector. It is a source-level
frontier transformer. `receive_request => fetch_user` advances a causal stage;
`fetch_posts <> fetch_friends` forms a same-stage frontier; `assemble` consumes the branch facts and
makes their histories comparable again.

Useful progression:

```text
imperative: order first, names are mutable slots
functional: names first, dependency can be recovered for pure code
Wire: dependency/frontier first, execution order is derived
```

### 2. The precedence choice is semantic ergonomics, not parser trivia

ADR 0047 and the current parser deliberately bind `<>` tighter than `=>`. This is inverted from the
usual Algebra.Graph/Haskell operator convention, where connect-like composition binds tighter. For
Wire, the inversion is load-bearing:

```wire
source
  => prepare
  => left <> right
  => join
```

parses as:

```wire
source => prepare => (left <> right) => join
```

That makes the common source shape a pipeline whose stages can be whole graph frontiers. The author
does not write a parenthesized graph calculus term at every diamond. They write a causal pipeline
where overlay is same-stage formation and connect is stage advancement.

This does not weaken the algebraic story. Wire still refines Mokhov's empty/vertex/overlay/connect
skeleton. The point is that the source syntax is tuned for executable causal diagrams rather than
for a generic graph library. The authoring contribution is: _pipeline ergonomics over a typed linear
graph algebra_.

### 3. The dashboard diamond is the right example when written as causal derivation

The canonical implemented example is
[examples/wire/dashboard-request.wire](../../../examples/wire/dashboard-request.wire):

```wire
node prepare_dashboard
  <- user: UserProfile;
  -> profile: ProfileSummary;
  -> posts_req: PostsRequest;
  -> friends_req: FriendsRequest;
  = @dashboard.prepare (user);

receive_request
  => fetch_user
  => prepare_dashboard
  => fetch_posts <> fetch_friends
  => assemble
  => respond
```

The load-bearing point is not that Wire can run two HTTP calls. Many languages can do that. The
point is that the causal act is named: `prepare_dashboard` consumes the observed user exactly once
and derives three distinct facts. That derivation is what authorizes parallel branches and the later
join. A shorter graph that silently lets both branches consume the same `user` endpoint is rejected,
because it hides the event that explains why two downstream observations are legitimate.

This is also why `*` should not dominate the paper. `*` is the right mechanism when the boundary
itself is a finite product. The dashboard example is stronger because it shows the ordinary causal
case: facts are derived by a real domain node, then consumed linearly downstream.

### 4. Finite products solve bounded topology, not unbounded control

ADR 0052 makes a separate point. When the topology really is a finite product, Wire now has a
bounded indexed idiom:

```wire
let workers[] = make(4, analyze_shard);

slice_corpus
  => plan_shards
  * workers
  * reduce_findings
```

The implemented example is
[examples/wire/bounded-shard-analysis.wire](../../../examples/wire/bounded-shard-analysis.wire).
Here `plan_shards` emits `[ShardPlan; 4]`, `workers[]` denotes four generated workers, and `*`
crosses the product boundary explicitly. Each leaf remains linear after the adapter elaborates.

This answers the bounded fan question without making `=>` magical. It does not answer the unbounded
loop question, and it should not. A runtime-length list such as `[T]` must not decide graph shape.
If a value produced by a node is used to choose a loop bound, that is runtime policy or a
runtime-admitted rewrite/child-run boundary, not ordinary static Wire topology.

### 5. Process loops belong to Pulse; Wire describes one admitted causal object

The earlier observation was:

> Computation is a set of bounded loops inside a bigger possibly unbounded process loop. The only
> thing that really has to be unbounded in a program is the process loop itself.

The Cortex architecture already points this way. Wire composes registered authority; Circuit
validates executable topology; Pulse owns scheduling, replay, child-run lifecycle, and runtime
policy. General loops, host scripts, dynamic languages, IO, tools, and model calls belong behind
explicit executors, while Pulse owns the process loop that repeatedly claims work, advances
frontiers, persists checkpoints, resumes, and materializes admitted rewrites.

That suggests a clean rule:

```text
Wire describes a finite admitted causal object.
Pulse owns the possibly unbounded process loop.
Executors may implement bounded or host-domain loops behind typed authority.
Runtime rewrites and child runs are admitted structural extensions, not ambient recursion.
```

This keeps Wire compatible with efficient compilation. A finite admitted graph can lower to a stage
plan, bytecode, or native code without also becoming the global scheduler. The scheduler can remain
Pulse's responsibility.

### 6. Child-run composition is the promising hierarchy, but not native runtime syntax

The clean version of the nested-Pulse idea is not "Pulse executors are native to Wire." That phrase
collapses layers. The better framing is:

```text
Wire authors a parent graph where one node invokes another admitted Circuit as a durable child run.
```

Aspirational Wire-shaped sketch, not current syntax:

```wire
contract IndexPlan;
contract IndexRun;
contract IndexArtifact;
contract PublishedIndex;

node plan_index
  -> plan: IndexPlan = @search.plan_index ({});

node spawn_index_run
  <- plan: IndexPlan;
  -> run: IndexRun = @pulse.spawn_index_run (plan);

node await_index_run
  <- run: IndexRun;
  -> artifact: IndexArtifact = @pulse.await_index_run (run);

node publish_index
  <- artifact: IndexArtifact;
  -> published: PublishedIndex = @search.publish_index (artifact);

plan_index
  => spawn_index_run
  => await_index_run
  => publish_index
```

The child run is a typed executor boundary. The parent observes a run reference, result artifact,
failure state, signal, or cancellation outcome. The parent does not inspect child memory, and the
child does not make Wire itself recursive. This aligns with current Pulse docs that list child
workflows as a deferred extension and with rewrite docs that reserve hierarchical subgraphs for a
later composition slice.

### 7. A listener or web server is a runtime pattern, not a Wire `while true`

A web server should not be explained as one Wire graph that loops forever internally. A cleaner
model is: the service or Pulse process loop accepts work, and each request becomes an admitted run
of a finite causal graph.

Aspirational service shape:

```text
Pulse service loop:
  accept request
  choose admitted Circuit
  start run with request envelope
  drive frontier until terminal state
  persist trace / result / failure
```

Wire-shaped request graph:

```wire
receive_request
  => fetch_user
  => prepare_dashboard
  => fetch_posts <> fetch_friends
  => assemble
  => respond
```

This is not less expressive than async host code; it is a different assignment of responsibility.
The unbounded listener is runtime infrastructure. The per-request computation is a typed causal
artifact. Host executors may still run blocking code internally; Wire/Pulse is the durable,
observable scheduler around those authorities.

## Archetype Synthesis

| Lens     | One-line read                                                                                          |
| -------- | ------------------------------------------------------------------------------------------------------ |
| Episteme | ADR 0047, the parser, grammar docs, and examples agree: `<>` forms frontiers; `=>` advances them.      |
| Logos    | The load-bearing claim is frontier-first causality, not the existence of graph syntax or `*`.          |
| Kritikos | If the example centers `*`, the paper looks like a fan-adapter paper and loses Paper 5's stronger arc. |
| Themis   | Wire owns candidate topology; Circuit owns admission; Pulse owns loops, scheduling, and child runs.    |
| Techne   | Patch Paper 6 around stage-structured pipelines and keep `*` as a secondary finite-product section.    |
| Poiesis  | Useful phrase: "pipeline ergonomics over a typed linear graph algebra."                                |
| Sophia   | Make dashboard the canonical causal example; use bounded shard only when explaining product adapters.  |

## Key Findings

### [P1] Wire's main argument is stage-structured causal pipelines

**Category:** Novel Idea **Status:** Inferred **Confidence:** High **Surfaced by:** poiesis, logos,
sophia **Primary evidence:** ADR 0047 precedence ladder; `src/Cortex/Wire/Parser.hs` comment
"Overlay binds tighter than connect/star"; Wire grammar section 7; Paper 6 dashboard example;
`EPHEMERAL_NOTES.md` stage-pipeline note **Cross-reference:** implementation <-> ADRs <->
publication draft.

The best name for the source contribution is **stage-structured causal pipeline**. `<>` forms a
same-stage frontier; `=>` advances the causal frontier; ports/contracts determine which facts may
cross the stage boundary. The unusual precedence choice makes this readable in ordinary source:

```wire
a => b => c <> d => e
```

is read as a pipeline with `c <> d` as one stage. That is not a minor syntactic preference. It is
how Wire becomes pleasant to author without giving up the algebra.

**Why it matters:** This is the paper-grade answer to "why Wire syntax?" It avoids reducing the work
to either "graph DSL" or "`*` adapter," and it ties the implementation to Paper 5's causal
programming thesis.

**Next step:** Update Paper 6's opening and example section to name stage-structured causal
pipelines directly, and add the one sentence about `<>` binding tighter than `=>`.

### [P2] The vector/record/graph ladder is the clearest explanation of what Wire improves

**Category:** Terminology Gap **Status:** Inferred **Confidence:** Medium **Surfaced by:** episteme,
poiesis **Primary evidence:** Paper 5 single-stack diagnosis and async/await critique; Paper 6
dashboard example; `EPHEMERAL_NOTES.md` vector/record/graph notes **Cross-reference:** publication
draft <-> conversation notes <-> grammar.

The strongest explanatory ladder is:

```text
imperative: order first, names are mutable slots
functional: names first, dependency can be recovered for pure code
Wire: dependency/frontier first, execution order is derived
```

The "stack program as nested record" intuition is useful but incomplete. Imperative code is more
like a nested ordered vector, because order is semantic. Functional code moves toward named records,
but effectful code regains a linear spine. Wire makes the frontier graph itself the authored object.

**Why it matters:** This gives Cortex a general explanation that is bigger than any single Wire
operator. It also makes the relationship to async, futures, traces, and durable workflows easier to
explain without sounding like a workflow-tool comparison.

**Next step:** Add a compact version of this ladder to Paper 6 or Paper 5. Keep the note short in
the paper; the research memo can carry the full explanation.

### [P3] `prepare_dashboard` is the causal derivation pattern the examples should teach

**Category:** Correctness Gap **Status:** Observed **Confidence:** High **Surfaced by:** logos,
kritikos **Primary evidence:** `examples/wire/dashboard-request.wire`; Paper 6 lines around the
dashboard example; Wire grammar linear endpoint rule; ADR 0047 multi-counterpart rejection
**Cross-reference:** examples <-> grammar <-> publication draft.

The dashboard example only lands if `prepare_dashboard` is shown as a node with multiple typed
outputs:

```wire
node prepare_dashboard
  <- user: UserProfile;
  -> profile: ProfileSummary;
  -> posts_req: PostsRequest;
  -> friends_req: FriendsRequest;
  = @dashboard.prepare (user);
```

This is not a select, not a hidden copy, and not a `*` operation. It is a domain derivation event:
one observation is consumed, and several new facts are produced for distinct downstream uses.

**Why it matters:** If the example is written as a call-site fan or implicit projection, the paper
teaches the opposite of the intended discipline. The example must show that linearity is causal
accounting, not a nuisance solved by syntax.

**Next step:** Keep the dashboard example as the first canonical example. Mention the rejected
implicit-copy graph once. Move product adapters to a later paragraph or footnote.

### [P4] Bounded indexed products are correct but should remain a secondary idiom

**Category:** Design Tension **Status:** Observed **Confidence:** High **Surfaced by:** themis,
sophia **Primary evidence:** ADR 0052; `examples/wire/bounded-shard-analysis.wire`; Wire grammar
section 7 **Cross-reference:** ADRs <-> examples <-> publication framing.

ADR 0052 resolves an important design problem: homogeneous generated frontiers need a first-class
finite product shape, not invented record labels and not implicit fan from `=>`. The result is good:
`[T; N]`, `let workers[] = make(N, kind)`, and `*` give bounded scatter/gather without weakening
endpoint linearity.

But the feature is not the center of Wire's research story. It is a supporting idiom for static
product-shaped topology. The core story is still typed causal stage composition.

**Why it matters:** Over-centering `*` makes the work look like a clever fan-in/fan-out surface. The
stronger claim is that ordinary programs can be authored as typed causal diagrams, with product
adapters only when product boundaries are actually present.

**Next step:** In Paper 6, keep bounded shard as a secondary "when topology is a finite product"
example. Do not use it as the opening example.

### [P5] Runtime loops and dynamic bounds need a named boundary before syntax

**Category:** Design Tension **Status:** Inferred **Confidence:** Medium **Surfaced by:** themis,
kritikos **Primary evidence:** Architecture chapter 05 on general loops behind executors and Wire
runtime handoff; chapter 06 on Pulse as runtime; chapter 07 on bounded rewrites; ADR 0052 rejection
of unbounded `[T]` shaping topology **Cross-reference:** architecture <-> ADRs <-> examples.

Wire should not grow an unbounded `loop` just because web servers, listeners, streams, and retry
loops matter. The architecture already assigns the process loop to Pulse. Static bounded topology
belongs in Wire (`make(N, K)`, `[T; N]`, product adapters). Runtime-discovered topology belongs in
admitted rewrites or explicit executor/child-run boundaries.

The hard unresolved case is a node result used as a loop bound:

```text
count = @planner.count(...)
repeat graph count
```

That is not ordinary static Wire. It may be a runtime-admitted expansion with a budget, a child run
that owns its own finite trace, or an executor that implements the loop behind a typed contract.

**Why it matters:** This boundary determines whether Wire stays compile-friendly and proof-friendly
or becomes a general recursive host language with graph syntax.

**Next step:** Draft an ADR or issue for "runtime dynamic bounds" before adding syntax. The ADR
should classify static bounded generation, executor-local loops, runtime-admitted expansions, and
child-run loops separately.

### [P6] Child-run composition is the right hierarchy if it stays at the Circuit/Pulse boundary

**Category:** Novel Idea **Status:** Speculative **Confidence:** Medium **Surfaced by:** poiesis,
themis **Primary evidence:** Architecture chapter 06 deferred child workflows; chapter 07
hierarchical subgraphs as planned extension; `EPHEMERAL_NOTES.md` aspirational child-run note
**Cross-reference:** architecture <-> ephemeral design notes.

The promising hierarchy is not native recursive Wire execution. It is a registered executor that
spawns or observes another admitted Circuit as a durable child run. This keeps the parent graph
finite and typed while allowing a subsystem to have its own replay, checkpointing, failures,
signals, and rewrite budget.

**Why it matters:** This is how Wire can model long-lived systems without importing unbounded loops
into the language. It also gives a concrete path for complex systems: parent circuits supervise
child circuits through typed run references and artifacts.

**Next step:** Create a design note or ADR sketch for durable child-run composition. Required
questions: child identity, parent/child contract mapping, spawn replay, await semantics, failure
propagation, cancellation, nested budgets, and proof envelope composition.

### [P7] Prior art suggests the novelty is synthesis and layer assignment

**Category:** Evidence Gap **Status:** Inferred **Confidence:** Medium **Surfaced by:** episteme,
poiesis **Primary evidence:** Mokhov graph algebra, Kahn process networks, Hughes arrows,
OpenTelemetry traces, durable-execution replay docs, Paper 5 related-work section
**Cross-reference:** literature <-> Cortex architecture.

Several neighboring ideas are established:

- graph algebra gives equational graph construction;
- process networks and dataflow models expose networks of communicating computations;
- arrows model composable computations with input/output structure;
- tracing systems reconstruct request paths from spans and propagated context;
- durable execution systems use journals/checkpoints and deterministic replay constraints.

Cortex's plausible contribution is not any one ingredient. It is the layer assignment:

```text
Wire: authored typed causal frontier graph
Circuit: admitted executable artifact
Pulse: process loop, replay, scheduling, rewrite admission
Theory: closure and safety obligations over admitted objects
```

**Why it matters:** This keeps the research claim defensible. The right posture is "we synthesize
known ingredients into an executable, typed, durable, proof-facing language substrate," not "we
invented dataflow, arrows, or graph algebra."

**Next step:** Add a related-work paragraph to the paper that compares on layer assignment, not just
topic names.

## Missed Abstractions

| Multiple sites                                       | Shared shape                                           | Proposed name                    | Cost of unifying                         |
| ---------------------------------------------------- | ------------------------------------------------------ | -------------------------------- | ---------------------------------------- |
| `<>` precedence, frontier execution, Paper 6 diamond | same-stage graph frontier inside a source pipeline     | stage-structured causal pipeline | Mostly prose and example discipline      |
| `make`, `[T; N]`, `*`, bounded shard example         | static finite product topology with linear leaves      | bounded product frontier         | Already partly implemented by ADR 0052   |
| Pulse process loop, child workflows, executor loops  | runtime-owned repetition outside static graph topology | runtime loop boundary            | Needs ADR and proof/runtime design       |
| Parent graph spawning admitted child circuit         | circuit treated as typed executor authority            | durable child-run composition    | Medium; identity/replay/budget semantics |
| Traces, replay journals, Wire source causal topology | runtime explanation graph                              | source-owned trace skeleton      | Needs observability/provenance write-up  |

## Evidence Gaps

| Claim                                                   | Current evidence                             | Missing evidence                                      | Recommended validation                         |
| ------------------------------------------------------- | -------------------------------------------- | ----------------------------------------------------- | ---------------------------------------------- |
| Stage-structured pipeline phrasing improves Paper 6     | ADR/parser/docs agree; example reads well    | Fresh-reader review after paper patch                 | Run doc-review against the revised manuscript  |
| Child-run composition preserves Wire/Pulse layering     | Architecture says child workflows deferred   | Concrete spawn/await contract and replay semantics    | ADR sketch plus one small executable prototype |
| Dynamic node-emitted bounds can stay outside pure Wire  | ADR 0052 rejects unbounded topology shaping  | Classification of all loop/bound use cases            | Design note with counterexamples               |
| Vector/record/graph ladder is academically robust       | Strong local intuition and Paper 5 alignment | Literature pass through arrows/dataflow/FRP/workflows | Focused related-work note                      |
| Source-owned trace skeleton helps observability tooling | Paper 5 and OTel context align conceptually  | Mapping from Wire node/edge IDs to emitted spans      | Prototype span exporter from admitted Circuit  |

## Design Tensions

### Ergonomics versus algebraic expectation

Wire's precedence inverts the common Algebra.Graph convention. That is surprising to graph-library
readers but makes pipeline-shaped source dramatically cleaner. The paper should name the inversion
once and then lean into it: overlay is stage formation; connect is stage advancement.

### Bounded topology versus dynamic control

Static products (`[T; N]`) and static `make(N, K)` are compatible with compile-time graph shape.
Runtime-discovered bounds are not. The design tension is not whether dynamic loops are useful; they
are. The question is which boundary owns them: executor, runtime rewrite, child run, or future
admitted dynamic expansion.

### Causal derivation versus convenient copying

Developers want to reuse values freely. Wire refuses ambient copying because reuse must be a causal
event with a name, contract, and provenance. The dashboard example is the friendly version of that
law: deriving branch facts is ordinary programming, but the derivation is explicit.

## Novel Ideas & Hypotheses

- **Source-owned trace skeleton** - A Wire graph can be understood as the trace skeleton before
  execution: runtime spans, checkpoints, and provenance events attach to source nodes and typed
  edges rather than reconstructing an unrelated graph afterward. **Validation path:** add a
  prototype exporter from compiled Circuit nodes/edges to OpenTelemetry span names/links and check
  whether the dashboard trace is readable without bespoke instrumentation.

- **Circuit-as-executor boundary** - A child Circuit can be registered as executor authority so a
  parent Wire graph can spawn, await, cancel, or observe it through ordinary typed ports.
  **Validation path:** design ADR first; then prototype one `spawn`/`await` pair without adding
  syntax.

- **Frontier transformer type** - A Wire graph expression can be explained informally as a typed
  frontier transformer rather than as a value expression or function call. `<>` combines
  transformers at one stage; `=>` composes stage transitions. **Validation path:** write a small
  formal note mapping graph expressions to input/output frontier sets and compare to the current
  compiler boundary model.

- **Pipeline ergonomics as a research contribution** - The authoring surface is not just notation;
  it changes which causal structures are natural to write. **Validation path:** collect three
  examples that are awkward in async/await but direct in Wire: dashboard diamond, bounded shard
  scatter/gather, and runtime cache insertion.

## Dead Ends / Rejected Directions

- **Make `=>` infer bounded fan from adjacent topology** - Rejected by ADR 0052. It makes edge
  semantics nonlocal and order-sensitive. Product unfolding must be visible through `*` or an
  explicit adapter node.

- **Treat nested Pulse as native Wire recursion** - Too early and layer-confusing. The child-run
  idea should go through Circuit/Pulse executor authority, not through unbounded Wire syntax.

- **Lead the paper with `*`** - It is accurate for finite products but too narrow. It makes the
  paper look like it is about fan adapters rather than executable causal diagrams.

## Recommended Actions

### Act now

- [ ] Patch Paper 6 to say "stage-structured causal pipeline" and explicitly state that `<>` binds
      tighter than `=>`. Owner: doc-review-and-fix; cost: S.
- [ ] Keep the dashboard diamond as the first example and ensure `prepare_dashboard` remains a
      multi-output causal derivation node. Owner: doc-review; cost: S.
- [ ] Demote `*` to a finite-product-adapter paragraph backed by the bounded shard example. Owner:
      doc-review-and-fix; cost: S.

### Design next

- [ ] Draft a runtime-loop-boundary ADR that separates static bounded generation, executor-local
      loops, runtime-admitted dynamic expansion, and child-run loops. Owner: architecture; cost: M.
- [ ] Draft a durable child-run composition note with spawn/await replay semantics, failure
      propagation, and nested budget questions. Owner: architecture; cost: M.
- [ ] Prototype source-owned trace skeleton export from admitted Circuit to spans/links. Owner:
      implementation; cost: M.

### Write up

- [ ] Turn the vector/record/graph ladder into a compact explanatory sidebar for Paper 5 or Paper 6.
- [ ] Add a related-work paragraph that compares layer assignments across graph algebra, arrows,
      dataflow, tracing, and durable workflows.
- [ ] Preserve "pipeline ergonomics over a typed linear graph algebra" as the paper-grade phrasing.

### Parked

- Native unbounded loops in Wire - deferred until runtime dynamic bounds and child-run semantics are
  classified.
- Recursive nested Pulse syntax - deferred; use child-run executor framing first.
- Dependent/generic child-run contracts - deferred until ordinary typed child run references exist.
- Automatic recursive flattening of nested products - rejected for now by ADR 0052's shallow-product
  decision.

## Known Unknowns

- The issue tracker was not available in this pass because GitHub authentication returned 401. The
  memo relies on canonical docs, ADRs, examples, and local proof-status notes rather than live issue
  state.
- The external literature pass was selective. A dedicated related-work pass should still check
  synchronous dataflow, FRP, workflow calculi, build systems, and open-graph semantics before the
  larger causal-programming paper makes broad novelty claims.
- The child-run example is intentionally aspirational. It should not be copied into reference docs
  until the executor boundary and replay semantics are designed.

## Claim-to-Evidence Matrix

| Claim                                     | Artifact that supports it                             | Artifact that weakens it               | Verdict                 |
| ----------------------------------------- | ----------------------------------------------------- | -------------------------------------- | ----------------------- |
| Wire source is stage-structured           | ADR 0047, parser precedence, grammar section 7        | Reader expectation from Algebra.Graph  | Strong, needs prose     |
| Dashboard is a canonical causal example   | `examples/wire/dashboard-request.wire`, Paper 6 draft | Initial drafts overemphasized `*`      | Strong                  |
| `*` is secondary                          | ADR 0052, bounded shard example                       | Product adapter is recently prominent  | Strong for Paper 6      |
| Process loop belongs to Pulse             | Architecture chapters 05 and 06                       | Need for servers/listeners/streams     | Strong layer decision   |
| Child runs are the right hierarchy        | Architecture 06/07 deferred-extension notes           | No concrete syntax or theorem yet      | Plausible, speculative  |
| Vector/record/graph ladder is paper-grade | Paper 5 diagnosis and Wire example                    | Literature comparison still incomplete | Promising, needs review |
