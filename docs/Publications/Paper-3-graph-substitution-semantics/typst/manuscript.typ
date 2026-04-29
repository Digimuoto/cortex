#import "../../_typst/cortex-paper.typ": cortex-paper

#let horizontalrule = line(length: 100%)

#show: cortex-paper

= Graph Substitution Semantics for Dynamic Durable Workflows
<graph-substitution-semantics-for-dynamic-durable-workflows>
== Abstract
<abstract>
We present a semantics for dynamic durable workflows in which workflow
meaning, durable execution, and topology evolution are separated into
explicit layers. A workflow program is first interpreted into a typed
workflow IR, then compiled into an executable graph artifact carrying
topology, node definitions, typed interfaces, and a compatibility
witness. The compiled artifact denotes the space of obligations that may
arise during a run; the materialized run state records what has actually
been reached after applying an admitted lineage of substitutions.
Execution proceeds in phases over that materialized state. Dynamic
change is modeled by #strong[graph substitution];: an admitted operation
replaces or refines a durable step by splicing in a fragment through an
explicit interface while preserving causal structure and durable
provenance.

The paper makes four claims. First, workflow semantics should not be
identified with runtime scheduling; lowering is a compilation boundary.
Second, dynamic topology change is best modeled by vertex-anchored
substitution rather than ad hoc mutation. Third, durable execution
requires a lineage-plus-materialization semantics, not merely a replay
story. Fourth, concurrency of node execution and concurrency of
substitutions are distinct questions and should be treated by different
laws.

The running examples use Cortex and downstream host applications as
motivating contexts, but the theory is stated independently of any
particular implementation.

#horizontalrule

== 1. Introduction
<1-introduction>
Durable workflows must survive crashes, suspension, operator
intervention, and long-running external work. Fixed-topology models
explain a large class of workflow engines, but they are insufficient
when execution may reveal that the remaining graph itself should change.

Typical examples include:

- a planning step that elaborates itself into a larger analysis subgraph
- a validation step that inserts remediation work before release
- a review step that appends a new branch for additional evidence
- an operator signal that unblocks or redirects part of the remaining
  workflow

The central semantic problem is therefore:

#quote(block: true)[
How can a workflow evolve after partial execution while preserving
durable replay, causal correctness, and a stable explanation of what was
executed?
]

This paper presents the implementation-independent theory of that
problem. A companion research plan, #strong[Rewrite Materialization and
Recovery for Dynamic Durable Graphs];, grounds the same ideas in the
concrete Pulse runtime and uses implementation-specific invariants to
sharpen the recovery story.

This paper answers that question by separating three levels of meaning:

+ #strong[workflow meaning];, expressed in a typed workflow language
+ #strong[compiled executable structure];, expressed as a graph artifact
+ #strong[durable operational semantics];, expressed as phase-based
  execution with graph substitution

The key terminological choice is deliberate:

- #strong[graph substitution] is the primary term of this paper
- #strong[graph rewriting] is used only as the umbrella term from the
  literature on algebraic graph transformation

The reason is precision. The runtime operation is not arbitrary graph
surgery. It substitutes a fragment into a durable graph through a
bounded, typed, interface-preserving rule.

#horizontalrule

== 2. Glossary
<2-glossary>
- #strong[workflow];: a semantic program describing obligations,
  dependencies, branching, waiting, and artifact boundaries
- #strong[workflow IR];: a canonical typed intermediate form of workflow
  meaning
- #strong[compiled workflow artifact];: the executable result of
  lowering a workflow IR into a graph package
- #strong[materialized run state];: the currently executable graph and
  node/output state obtained by applying a lineage prefix to an original
  compiled artifact
- #strong[node];: a durable execution locus with identity, status, and
  outputs
- #strong[fragment];: a graph package intended to be substituted into
  another graph
- #strong[substitution];: the operation of splicing a fragment into a
  graph through an explicit boundary contract
- #strong[graph rewriting];: the broader literature umbrella; this paper
  studies a substitution calculus within that space
- #strong[materialization];: durable installation of admitted
  substitutions into the graph state
- #strong[lineage];: append-only history of admitted substitutions
- #strong[compatibility witness];: a fingerprint or derivation witness
  tying a compiled artifact to the semantics that produced it

#horizontalrule

== 3. Layered Semantic Architecture
<3-layered-semantic-architecture>
The theory is organized around a strict stack:

```mermaid
flowchart TD
    A["Workflow semantics"] --> B["Compiled artifact"]
    B --> C["Phase-based execution"]
    C --> D["Lineage"]
    D --> E["Recovery"]
```

The stack matters because different correctness questions live at
different layers:

- #strong[workflow meaning] asks whether a program denotes the intended
  dependency structure
- #strong[lowering] asks whether the compiled graph preserves workflow
  meaning
- #strong[execution] asks whether the runtime reduces graph states
  soundly
- #strong[substitution] asks whether topology evolution preserves
  admissibility
- #strong[durability] asks whether crash, resume, and explanation remain
  coherent

Blurring these layers weakens the theory. A runtime graph is not the
meaning of the source workflow; it is the executable artifact produced
by a lowering.

#horizontalrule

== 4. Workflow Language and Compilation Boundary
<4-workflow-language-and-compilation-boundary>
=== 4.1 Workflow IR
<41-workflow-ir>
We assume a typed workflow language with the following representative
core constructors:

```text
W ::= step a
    | W ; W
    | parallel { W1, ..., Wn }
    | choose c { Wt, Wf }
    | await s
    | artifact k from W
```

Intuitively:

- `step a` introduces a durable step
- `;` introduces sequencing
- `parallel` introduces concurrent obligations
- `choose` introduces semantically controlled branching
- `await` introduces suspension on an external signal or fact
- `artifact` marks a durable product boundary

This IR is semantic, not directly executable. It does not say how node
identities are serialized, how retries are represented, or how
persistence occurs.

The purpose of introducing the IR in this paper is narrow: it marks the
compilation boundary between workflow meaning and graph execution. The
core formal development begins only after lowering.

=== 4.2 Compiled Workflow Artifact
<42-compiled-workflow-artifact>
Lowering produces an original compiled artifact:

$ cal(C)_0 = \( T \, D \, Gamma \, kappa \) $

where:

- $T = \( V \, E \)$ is a finite directed acyclic graph
- $D : V arrow.r upright("NodeDef")$ assigns executable node definitions
- $Gamma$ is the interface environment describing input/output
  contracts, signal contracts, and artifact contracts
- $kappa$ is a compatibility witness

For the purposes of this paper, the compatibility witness has the form:

$ kappa = \( nu \, lambda \, h \) $

where:

- $nu$ identifies the lowering family
- $lambda$ identifies the contract and interface regime used to
  interpret the lowered artifact
- $h$ is a digest of the normalized source artifact under
  $\( nu \, lambda \)$

Two compiled artifacts need not have the same digest in order to
interact, but they must agree on the lowering family and contract
interpretation regime. We write:

$ sans(C o m p a t)_kappa \( kappa \, kappa_F \) $

for the predicate that the ambient compiled artifact and a fragment were
produced under compatible lowering and contract interpretation regimes.
In the minimal version used by this paper:

$ sans(C o m p a t)_kappa \( \( nu \, lambda \, h \) \, \( nu_F \, lambda_F \, h_F \) \) arrow.l.r.double nu = nu_F and lambda = lambda_F $

The digests may differ because the ambient workflow and the fragment may
denote different source programs. Compatibility requires only that they
inhabit the same lowering family and contract regime.

This minimal definition is intentionally stricter than lowering-family
equality alone. Two fragments may be lowered by the same compiler family
while still disagreeing about the contract language attached to boundary
nodes. Equality on $\( nu \, lambda \)$ is therefore the smallest useful
semantic approximation.

The point of $kappa$ is semantic rather than operational: a materialized
graph should always be interpreted relative to the compilation law that
produced it.

=== 4.3 Example
<43-example>
The following surface syntax is only illustrative:

```text
workflow QuarterlyPortfolioRebalance {
  parallel {
    fetchPositions,
    fetchMarketData,
    fetchRiskLimits
  };
  computeTargetAllocations;
  parallel {
    sequence {
      proposeEquityTrades;
      choose complianceOk {
        signOffEquities,
        sequence {
          remediateEquities;
          signOffEquities
        }
      }
    },
    sequence {
      proposeFixedIncomeTrades;
      signOffFixedIncome
    },
    sequence {
      proposeDerivativesOverlay;
      await riskDeskApproval;
      signOffDerivatives
    }
  };
  aggregateExecutionPlan;
  artifact rebalanceReport
}
```

Its lowering may produce a graph whose nodes are durable execution loci
while preserving the workflow meaning that three acquisition steps are
initially independent, then join at `computeTargetAllocations`, then fan
out again into three asymmetric branches before joining at
`aggregateExecutionPlan`. That shape matters because the ready frontier
widens and narrows over the same DAG, and later substitutions may widen
it again.

#horizontalrule

== 5. Executable Graphs and Interface Contracts
<5-executable-graphs-and-interface-contracts>
The compiled topology alone is not enough. Dynamic substitution requires
typed fragment contracts.

=== 5.1 Graph Package
<51-graph-package>
A fragment is a graph package:

$ cal(F) = \( T_F \, D_F \, Gamma_F \, upright(I n)_F \, upright(O u t)_F \, kappa_F \) $

where:

- $T_F = \( V_F \, E_F \)$ is a finite DAG
- $D_F$ assigns node definitions
- $Gamma_F$ assigns contracts to fragment boundaries and internal nodes
- $diameter eq.not upright(I n)_F subset.eq V_F$ are entry nodes
- $diameter eq.not upright(O u t)_F subset.eq V_F$ are exit nodes
- $kappa_F$ is a compatibility witness for the fragment

The interface contract should be read semantically, not merely
topologically. A fragment boundary may constrain:

- value types or schemas
- artifact shapes
- signal names or capabilities
- side-effect classes
- retry or idempotence requirements

=== 5.2 Minimal Contract Discipline
<52-minimal-contract-discipline>
To keep the paper\'s formal core honest, we assume only a minimal
contract discipline.

Let $\( cal(K) \, subset.eq.sq \)$ be a preorder of contracts, where:

$ c_1 subset.eq.sq c_2 $

means \"a value or effect satisfying $c_1$ is acceptable wherever $c_2$
is required.\"

For each relevant boundary node $v$, the interface environment provides:

- $Gamma^(+) \( v \) in cal(K)$, the contract offered by $v$
- $Gamma^(-) \( v \) in cal(K)$, the contract required by $v$

Composition across a graph edge $\( u \, v \)$ is then defined by:

$ Gamma^(+) \( u \) subset.eq.sq Gamma^(-) \( v \) $

One concrete toy instantiation takes $cal(K)$ to be finite record
schemas ordered by width subtyping:

$ { f_1 : tau_1 \, dots.h \, f_n : tau_n \, dots.h } subset.eq.sq { f_1 : tau_1 \, dots.h \, f_n : tau_n } $

meaning that a provider may offer additional fields beyond what the
consumer requires.

Under that instantiation, semantic admissibility does real work. In the
running rebalance example, a predecessor might offer
`{positions, marketData, riskLimits}` while a candidate fragment entry
requires `{positions, custodianBalances}`. Structural rewiring could
still succeed, but semantic admissibility fails because
`custodianBalances` is absent even though the topology alone would
permit the splice.

This is intentionally minimal. A richer type-and-effect discipline could
refine it, but this preorder is enough to state semantic admissibility
in a falsifiable way without pretending to solve the entire typing
problem.

The abstraction is deliberately weak. It does not yet model named ports,
channel multiplicity, linear or affine resources, or retention
obligations for state that may no longer be present in the current
materialized graph. Those belong to richer interface calculi. The claim
here is narrower: even a simple contract preorder is enough to
distinguish structurally valid substitutions from semantically
admissible ones.

=== 5.3 Why Structural Interfaces Are Insufficient
<53-why-structural-interfaces-are-insufficient>
Entry and exit node sets alone only say where reconnection occurs. They
do not say whether the substituted fragment can actually inhabit the
obligation being refined. A durable dynamic workflow semantics therefore
needs both:

- #strong[structural fit];, meaning the splice preserves graph
  well-formedness
- #strong[semantic fit];, meaning contracts compose across the
  substitution boundary

This distinction is one of the central obligations of the theory.

#horizontalrule

== 6. Phase-Based Durable Execution
<6-phase-based-durable-execution>
Execution proceeds relative to an original compiled artifact and a
materialized run state:

$ Sigma_w = \( cal(C)_0 \, cal(C)_w \, sigma \, o \, ell \, w \, chi \) $

where:

- $cal(C)_0$ is the original compiled workflow artifact
- $cal(C)_w = sans(M a t e r i a l i z e) \( cal(C)_0 \, ell_(lt.eq w) \)$
  is the current materialized graph artifact for the admitted lineage
  prefix
- $sigma : V_w arrow.r upright("NodeStatus")$ is the total status map
  over $cal(C)_w$
- $o : V_w harpoon.rt upright("Value")$ is the partial output map over
  $cal(C)_w$
- $ell$ is the append-only substitution lineage
- $w$ is the materialization watermark
- $chi$ is a materialized-state integrity witness

The abstract status space is:

$ N o d e S t a t u s = upright("Pending") divides upright("Running") divides upright("Completed") divides upright("Failed") divides upright("Skipped") divides upright("Waiting") \( s \) divides upright("Rewritten") $

`Rewritten` is terminal and dependency-satisfying. It represents a
durable step boundary that has been refined by substitution while
remaining part of the explanatory structure.

The execution discipline is phase-based:

```mermaid
flowchart TD
    A["Ready frontier"] --> B["Node execution"]
    B --> C["Accumulate facts"]
    C --> D["Close + classify"]
    D --> E{"Substitution<br/>pending?"}
    E -- Yes --> F["Admit + materialize"]
    F --> A
    E -- No --> G{"Frontier<br/>empty?"}
    G -- No --> A
    G -- Yes --> H["Terminal"]
```

This picture clarifies a subtle but important point:

- #strong[concurrent node execution] is a question about reducing facts
  over a fixed materialized graph
- #strong[concurrent substitution] is a question about changing the
  graph itself

They are not the same theorem.

The loop above is a runtime control loop, not a cycle in the workflow
topology. Each materialized artifact $cal(C)_w$ remains a DAG. The
back-edge means only that the next ready frontier is computed again,
possibly over a different materialized graph if a substitution was
admitted at the previous phase boundary.

=== 6.1 Frontier Semantics
<61-frontier-semantics>
Let $p r e d_w \( v \)$ denote the immediate predecessors of node $v$ in
the current materialized graph $cal(C)_w$.

The ready frontier is:

$ "Ready" \( Sigma_w \) = { v in V_w divides sigma \( v \) = upright(P e n d i n g) and forall u in p r e d_w \( v \) . med sigma \( u \) in { upright(C o m p l e t e d) \, upright(S k i p p e d) \, upright(R e w r i t t e n) } } $

The frontier is an antichain in the dependency order. Nodes in the
frontier may be executed concurrently because readiness is defined
relative to the same materialized topology.

=== 6.2 Base Phase Discipline
<62-base-phase-discipline>
The base calculus adopts a simple rule:

- many nodes may execute concurrently within one frontier phase
- substitution is admitted only at a phase boundary

This is not merely an implementation convenience. It is the semantic
barrier that separates reduction over facts from mutation of topology.

#horizontalrule

== 7. Graph Substitution
<7-graph-substitution>
=== 7.1 Core Primitive
<71-core-primitive>
The core primitive is:

$ sans(s u b s t i t u t e) \( a \, rho \, cal(F) \) $

where:

- $a in V$ is an anchor node
- $rho$ is a boundary policy
- $cal(F)$ is a fragment

The boundary policy determines whether the anchor is replaced or
retained as an envelope.

The literature uses #strong[graph rewriting] broadly for systems that
transform graphs by local rules. This paper uses #strong[graph
substitution] for the concrete runtime calculus because the admissible
operation is more specific: it chooses a durable anchor node, a fragment
with explicit boundary interface, and a splice discipline that preserves
the already discharged past.

=== 7.2 Replace and Envelope
<72-replace-and-envelope>
Let:

- $"Pred" \( a \) = { u divides \( u \, a \) in E }$
- $"Succ" \( a \) = { v divides \( a \, v \) in E }$

For a #strong[replace] substitution, the anchor is removed and the
fragment is spliced into its place:

$ V' = \( V \\ { a } \) union V_F $

$ E' = \( E \\ I \( a \) \) union \( "Pred" \( a \) times upright(I n)_F \) union E_F union \( upright(O u t)_F times "Succ" \( a \) \) $

where $I \( a \)$ is the set of edges incident to $a$.

The base calculus intentionally uses full bipartite reconnection from
every predecessor to every fragment entry and from every fragment exit
to every successor. Richer port-matching or channel-discipline rules are
refinements of the interface system, not part of this minimal core.
Accordingly, the base calculus proves compatibility for the induced
reconnections it defines; it does not claim that practical runtimes may
ignore routing, arity, or multiplicity constraints. Systems that require
single-input consumers, named ports, or linear channels must refine
$Gamma$ with that additional structure.

For an #strong[envelope] substitution, the anchor remains as the stable
step boundary and the fragment is inserted after the anchor\'s own
completion:

$ sigma \( a \) in { upright(C o m p l e t e d) \, upright(R e w r i t t e n) } $

and, whenever downstream obligations depend on the anchor\'s output,
$o \( a \)$ is defined.

$ V' = V union V_F $

$ E' = \( E \\ \( { a } times "Succ" \( a \) \) \) union \( { a } times upright(I n)_F \) union E_F union \( upright(O u t)_F times "Succ" \( a \) \) $

The envelope form is useful when the anchor\'s output, audit trail, or
semantic identity should remain explicit.

Replace substitution does not require $o \( a \)$ to remain defined
because the anchor leaves the future topology. Envelope substitution may
require it because the anchor remains part of the explanatory and
dataflow structure.

=== 7.3 Example
<73-example>
Suppose the rebalancing workflow\'s `computeTargetAllocations` step
completes and discovers unexpected crypto exposure requiring an
additional execution branch before aggregation.

Materialized shape before substitution:

```mermaid
flowchart TD
    C["computeTargetAllocations"] --> EQ["Equity branch"]
    C --> FI[Fixed income branch]
    C --> DER[Derivatives branch]
    EQ --> A["aggregateExecutionPlan"]
    FI --> A
    DER --> A
```

Envelope substitution at `computeTargetAllocations`:

```mermaid
flowchart TD
    C["computeTargetAllocations"] --> EQ["Equity branch"]
    C --> FI[Fixed income branch]
    C --> DER[Derivatives branch]
    C --> CR1["proposeCryptoLiquidation"]
    CR1 --> CR2["awaitCustodianConfirmation"]
    EQ --> A["aggregateExecutionPlan"]
    FI --> A
    DER --> A
    CR2 --> A
```

This is not arbitrary mutation. The substitution widens the fan-out by
one new branch, changes the predecessor set of `aggregateExecutionPlan`,
and still remains a local refinement of a durable step boundary.

#horizontalrule

== 8. Admissibility
<8-admissibility>
A substitution is admissible only if all of the following hold.

=== 8.1 Structural Admissibility
<81-structural-admissibility>
+ the anchor exists
+ the fragment topology is finite and acyclic
+ the fragment\'s node definitions are total
+ entry and exit interfaces are well-defined and non-empty
+ the resulting topology is acyclic

=== 8.2 Semantic Admissibility
<82-semantic-admissibility>
+ for every predecessor $u$ rewired to an entry node
  $x in upright(I n)_F$,
  $Gamma^(+) \( u \) subset.eq.sq Gamma_F^(-) \( x \)$
+ for every exit node $y in upright(O u t)_F$ rewired to a successor
  $v$, $Gamma_F^(+) \( y \) subset.eq.sq Gamma^(-) \( v \)$
+ retained-anchor substitutions preserve any contract that downstream
  nodes rely on from the anchor
+ $sans(C o m p a t)_kappa \( kappa \, kappa_F \)$ holds

These clauses define only a minimal semantic admissibility notion.
Richer contract systems remain compatible with the paper\'s structure
but are not required by the core results below. In particular, they do
not yet express port-level routing, arity bounds, linear consumption, or
snapshot-retention obligations. Those are extensions of the interface
discipline, not hidden assumptions of the present calculus.

=== 8.3 Causal Admissibility
<83-causal-admissibility>
Substitution must preserve the already discharged past. The past may
justify a substitution, but substitution does not reinterpret already
completed causal history. It refines the remaining obligation.

This distinguishes substitution from process migration. Substitution is
local future refinement, not global re-interpretation of executed
history.

=== 8.4 Resource Admissibility
<84-resource-admissibility>
The runtime may also impose explicit budgets:

$ B = \( b_V \, b_E \, b_D \, b_F \, b_S \) $

bounding:

- added vertices
- added edges
- added depth
- frontier expansion
- substitution count

Let:

$ sans(C o s t) \( a \, cal(F) \, T \) = \( c_V \, c_E \, c_D \, c_F \, c_S \) $

be the structural cost of substituting fragment $cal(F)$ at anchor $a$
in topology $T$. Resource admissibility requires:

$ sans(C o s t) \( a \, cal(F) \, T \) lt.eq B $

componentwise. Materialization consumes budget monotonically:

$ B' = B - sans(C o s t) \( a \, cal(F) \, T \) $

Budgets are not the whole safety story, but they make the calculus
operational by bounding expansion.

No core result below depends on this budget discipline. It is an
operational guard layered on top of the substitution calculus rather
than a constitutive part of the paper\'s minimal proof core.

=== 8.5 Concrete Rejection Example
<85-concrete-rejection-example>
The admissibility clauses are meant to reject substitutions that are
topologically plausible but semantically wrong.

Return to the rebalance example and let `computeTargetAllocations` be
the anchor. Suppose a predecessor $u$ offers

$ Gamma^(+) \( u \) = { p o s i t i o n s \, m a r k e t D a t a \, r i s k L i m i t s } $

and a candidate fragment entry $x$ requires

$ Gamma_F^(-) \( x \) = { p o s i t i o n s \, c u s t o d i a n B a l a n c e s } . $

Suppose also that an exit node $y$ of the fragment offers

$ Gamma_F^(+) \( y \) = { c r y p t o L i q u i d a t i o n P l a n } $

while a downstream successor $v$ requires

$ Gamma^(-) \( v \) = { e x e c u t i o n P l a n } . $

The splice may still satisfy structural admissibility: the anchor
exists, the fragment is finite and acyclic, and the resulting graph
remains a DAG. But semantic admissibility fails twice:

+ $Gamma^(+) \( u \) subset.eq.sq.not Gamma_F^(-) \( x \)$ because the
  predecessor does not provide `custodianBalances`
+ $Gamma_F^(+) \( y \) subset.eq.sq.not Gamma^(-) \( v \)$ because a
  `cryptoLiquidationPlan` is not an `executionPlan`

The candidate substitution is therefore rejected before materialization,
even though bare graph surgery would permit the splice.

Envelope substitution adds one more check. If the anchor $a$ is retained
as a durable boundary but the substitution would stop exposing an anchor
contract that downstream obligations still rely on, clause 8.2(3)
rejects it. The point is that retained history remains semantically
live, not merely visually present.

#horizontalrule

== 9. Durability, Lineage, and Materialization
<9-durability-lineage-and-materialization>
Substitution is durable only if admission and materialization are
modeled explicitly.

=== 9.1 Lineage and Watermark
<91-lineage-and-watermark>
Let:

- $ell = \[ s_1 \, dots.h \, s_n \]$ be the totally ordered, append-only
  lineage of admitted substitutions
- $w lt.eq n$ be the watermark such that the materialized graph state
  reflects exactly the prefix $ell_(lt.eq w)$

This yields a precise semantics:

$ cal(C)_w = sans(M a t e r i a l i z e) \( cal(C)_0 \, ell_(lt.eq w) \) $

The original compiled artifact $cal(C)_0$ defines the space of durable
obligations. The materialized artifact $cal(C)_w$ defines the current
execution surface after the admitted lineage prefix has been installed.

=== 9.2 Integrity Witness
<92-integrity-witness>
The watermark alone states prefix application. It does not by itself
certify that the materialized graph package, node state, and provenance
all agree.

For that reason the durable state should also carry an integrity witness
$chi$, such as:

- a topology hash
- a normalized graph-package hash
- a stronger derivation witness tying materialized state to the expected
  compiled artifact

The paper treats this as part of the semantics rather than optional
operator metadata.

Each successful materialization step computes a fresh integrity witness:

$ chi' = sans(W i t n e s s) \( cal(C)' \, sigma' \, o' \, w' \) $

and subsequent execution or recovery is defined only from states
satisfying:

$ sans(V e r i f y) \( chi \, cal(C) \, sigma \, o \, w \) $

The paper assumes only the following minimal axioms:

- #strong[soundness:]
  $sans(V e r i f y) \( sans(W i t n e s s) \( cal(C) \, sigma \, o \, w \) \, cal(C) \, sigma \, o \, w \)$
- #strong[determinism:] if
  $\( cal(C) \, sigma \, o \, w \) = \( cal(C)' \, sigma' \, o' \, w' \)$
  then
  $sans(W i t n e s s) \( cal(C) \, sigma \, o \, w \) = sans(W i t n e s s) \( cal(C)' \, sigma' \, o' \, w' \)$

Stronger collision-resistance or proof-carrying interpretations are
valuable, but they are not required by the paper\'s minimal recovery
claim.

=== 9.3 Recovery Law
<93-recovery-law>
Recovery should reconstruct execution from:

$ \( cal(C)_0 \, ell_(lt.eq w) \, sigma \, o \, chi \) $

subject to:

- compatibility checks for every admitted fragment in $ell_(lt.eq w)$
  derived from the compiled artifact witness $kappa$
- integrity verification of $chi$

The aim is not merely to restart execution, but to resume from a state
whose interpretation is stable.

A #strong[canonical schedulable state] is the unique normalized state
obtained by:

+ deterministically materializing
  $cal(C)_w = sans(M a t e r i a l i z e) \( cal(C)_0 \, ell_(lt.eq w) \)$
+ verifying $chi$ against $\( cal(C)_w \, sigma \, o \, w \)$
+ normalizing transient runtime state and recomputing the ready frontier
  over $cal(C)_w$

Recovery is correct only if it produces that same $cal(C)_w$ and the
same normalized ready frontier from the same persisted inputs.

#horizontalrule

== 10. Concurrency and Independence
<10-concurrency-and-independence>
The base calculus allows concurrent node execution but treats
substitution as a phase-boundary act. This should be understood as a
semantic discipline. The base machine therefore separates two semantic
phases:

- a #strong[reduction phase] that accumulates node-local facts over a
  fixed materialized topology
- a #strong[substitution phase] that may change that topology before the
  next ready frontier is computed

This separation is not cosmetic. It isolates the order-insensitive fact
fragment from the topology-changing fragment whose admissibility depends
on the ambient graph, the candidate fragment, and the remaining budget.

=== 10.1 Reduction Phase
<101-reduction-phase>
Within a fixed materialized topology, the execution kernel from the
previous paper applies unchanged. Frontier nodes run concurrently from
the same materialized graph, emit node-local facts, and those facts are
accumulated, closed, and classified without changing the topology to
which readiness is defined.

That is the coordination-friendly fragment of the machine. The important
point is not that every operational detail is monotone, but that within
one fixed topology the reduction kernel only accumulates information
needed to move from pending work toward a more settled state. Later
execution in the same phase does not reinterpret the meaning of an
earlier frontier fact by changing the graph beneath it.

=== 10.2 Coordinated Substitution Phase
<102-coordinated-substitution-phase>
Substitution is different because admissibility is
proposal-set-sensitive. Whether a candidate fragment may be installed
can depend on:

- compatibility at the anchor boundary
- the resulting topology
- the remaining structural budget
- other proposals that may consume that same budget or overlap in effect

For that reason substitution is isolated at a phase boundary. The
barrier is the natural coordination boundary induced by the current
semantics: the runtime finishes reduction on the current materialized
graph, then admits and materializes any accepted substitutions before
defining the next ready frontier.

=== 10.3 Why This Restriction Is Natural
<103-why-this-restriction-is-natural>
Ordinary node execution accumulates facts about an already materialized
graph. Substitution changes the graph to which readiness and downstream
obligations are defined. Mixing these two levels without a barrier
complicates:

- replay
- provenance
- admissibility
- termination reasoning

This restriction is conservative and not free. In a wide frontier, a
single admitted substitution may delay further reduction until the next
materialization boundary, sacrificing some throughput and liveness for a
simpler replay story, a single lineage order, and a cleaner proof
boundary. The claim is not that the barrier is always optimal, only that
it is an explicit baseline whose relaxation requires additional laws
rather than informal scheduling intuition.

=== 10.4 Independent Substitutions
<104-independent-substitutions>
A richer calculus may admit more than one substitution in a logical
phase, but that requires an explicit independence relation. At minimum,
one would want conditions such as:

- disjoint anchor regions
- no interface overlap
- a formal commutation relation over interface effects
- a stable explanation of lineage order

Those conditions define a stronger machine. They should not be smuggled
into the base semantics by informal analogy.

#horizontalrule

== 11. Edge-Oriented Forms as Derived Notation
<11-edge-oriented-forms-as-derived-notation>
Edge-oriented refinement is still useful to describe insertion between
two durable steps. For example:

```text
insertBetween(gather, review, validateEvidence)
```

is often easier to read than a node-centered substitution formula. But
the semantic core should remain node-centered.

The reason is not only implicit joining. It is that a durable node
carries the execution meaning:

- it owns status transitions
- it may carry outputs
- it may wait or fail
- it anchors provenance

An edge denotes a dependency relation. A node denotes a durable step
boundary. Since dynamic durable workflows evolve by refining obligations
embodied by durable steps, vertex-anchored substitution is the better
core object.

Accordingly, edge-oriented forms are best treated as derived notation or
a surface language convenience that lowers into the node-centered
calculus.

#horizontalrule

== 12. Core Results and Extension Program
<12-core-results-and-extension-program>
=== 12.1 Core Results
<121-core-results>
The paper\'s core formal obligations are the following.

==== Substitution Safety
<substitution-safety>
Admissible substitution preserves graph well-formedness, causal
structure, and interface compatibility.

==== Phase Determinism
<phase-determinism>
Within a fixed materialized topology, reducing a frontier phase is
order-insensitive with respect to the accumulation order of independent
node facts, provided that frontier execution emits node-local facts
keyed by the executing node or else emits into a deterministic reducer.
The intended proof strategy is:

+ each node $v$ in the current frontier contributes facts affecting only
  the loci owned by $v$, such as $sigma \( v \)$ and $o \( v \)$
+ for distinct frontier nodes $u eq.not v$, those node-local updates
  commute
+ closure and classification are deterministic functions of the
  resulting normalized materialized state

This excludes the obvious counterexample in which concurrent frontier
nodes perform uncontrolled writes to the same shared artifact key. Such
effects must either be represented as node-local outputs or mediated by
a deterministic reduction step before the theorem applies.

==== Recovery Correctness
<recovery-correctness>
Resume from materialized lineage prefix, compatibility witness, and
integrity witness reconstructs the canonical schedulable state defined
in §9.3.

=== 12.2 Extension Program
<122-extension-program>
The following are intentionally outside the paper\'s core formal
development but define its natural continuation.

==== Lowering Soundness
<lowering-soundness>
One would like a theorem of the form:

$ bracket.l.double W bracket.r.double_(upright(w f)) equiv bracket.l.double upright(c o m p i l e) \( W \) bracket.r.double_(upright(g r a p h)) $

for an appropriate denotational semantics of workflows, graphs, and
their equivalence. This is a research program for the workflow/lowering
boundary, not part of the minimal substitution calculus proved here.

==== Routed Interfaces and Resource-Aware Contracts
<routed-interfaces-and-resource-aware-contracts>
The minimal preorder on $cal(K)$ intentionally leaves out named ports,
arity constraints, linear or affine resources, and retention obligations
for values that later substitutions may still depend on. A stronger
interface calculus would enrich $Gamma$ with those structures so that
executable routing policies and resource-sensitive admissibility can be
stated directly.

==== Concurrent Substitution Commutation
<concurrent-substitution-commutation>
For a richer extension, independent substitutions may admit a
commutation law. That requires an explicit independence relation and
belongs to a stronger calculus than the base one defined here.

==== Budget-Bounded Growth
<budget-bounded-growth>
If substitution cost is tracked and budget decreases monotonically, one
would like a bounded-growth result limiting the number or size of
admitted substitutions in a run. That is an operational extension, not
part of the minimal semantic core established here.

#horizontalrule

== 13. Related Work
<13-related-work>
Algebraic graph transformation studies local graph change through
rule-based systems such as DPO and SPO rewriting. This paper does not
claim novelty over graph transformation as such. Its contribution is to
specialize that space to a durable workflow setting with named step
boundaries, lineage, materialization, and recovery.

Process calculi and workflow encodings provide rich accounts of
concurrency, communication, and mobility. Their center of gravity is
usually process interaction rather than durable materialized execution
over named workflow steps. The contribution here is the layering between
workflow meaning, compiled graph artifact, substitution, and recovery.

Durable execution systems such as Temporal and Restate provide strong
replay and suspension semantics. The present contribution is orthogonal:
it asks how durable execution should behave when the future topology
itself changes through admitted local substitution.

Accordingly, the claim is not that vertex-anchored substitution is the
only possible graph evolution formalism, but that it is the right
semantic center for durable step refinement in this layered setting.

#horizontalrule

== 14. Boundary of the Theory
<14-boundary-of-the-theory>
This paper gives a theory of #strong[dynamic durable execution by local
substitution];. It does not claim to solve all process evolution
problems.

In particular, the theory should be distinguished from:

- global workflow migration
- reinterpretation of already executed history
- arbitrary graph surgery without boundary contracts
- semantic equivalence of unrelated lowered artifacts

Those are valid research directions, but they are not the same object as
local durable graph substitution.

#horizontalrule

== 15. Conclusion
<15-conclusion>
The conceptual payoff of graph substitution is that it gives dynamic
durable workflows a stable semantic center.

- workflow meaning lives in a typed language and IR
- executable structure lives in a compiled graph artifact
- durable execution lives in a phase-based runtime
- topology evolution lives in a substitution calculus
- recovery and explanation live in lineage, materialization, and
  integrity

This layering makes the design space easier to reason about. It explains
why vertex-anchored substitution is the right core abstraction, why
concurrency of execution and concurrency of substitution are different
problems, and why durability requires more than replay alone.

For motivating contexts such as Cortex and its downstream host
applications, this theory offers a principled route to dynamic workflow
execution without collapsing workflow semantics, runtime execution, and
graph evolution into a single informal notion.

== References
<references>
+ Ehrig, H., Ehrig, K., Prange, U., Taentzer, G. (2006).
  #emph[Fundamentals of Algebraic Graph Transformation];. Springer.
  #link("https://link.springer.com/book/10.1007/3-540-31188-2")
+ Milner, R. (1999). #emph[Communicating and Mobile Systems: The
  Pi-Calculus];. Cambridge University Press.
+ van der Aalst, W. M. P. (1998). #emph[The Application of Petri Nets to
  Workflow Management];. Journal of Circuits, Systems and Computers
  8(1):21--66.
+ Temporal Technologies. #emph[Temporal];. #link("https://temporal.io")
+ Restate. #emph[Workflows];.
  #link("https://docs.restate.dev/tour/workflows")
