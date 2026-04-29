#import "../../_typst/cortex-paper.typ": cortex-paper

#let horizontalrule = line(length: 100%)

#show: cortex-paper

= Algebraic Foundations of Staged Durable Execution
<algebraic-foundations-of-staged-durable-execution>
== Abstract
<abstract>
We develop an algebraic account of durable workflow execution organized
as a staged reduction: commutative fact accumulation, idempotent failure
closure, and deterministic state classification. The core object is not
a workflow program trace but a topology-indexed graph state together
with a validity predicate for normalized, closed states. We separate
three layers of obligation: algebraic facts about accumulation, closure,
and classification; structural recovery theorems for fixed-topology
execution; and external assumptions about worker I/O reproducibility.
The result is a sharper statement of what the runtime proves, what it
merely assumes, and what is deferred to mechanization. We also
characterize the extension boundary: which changes preserve the staged
reduction and which require a different machine. Topology-changing graph
rewriting is treated as one such boundary and is excluded from the core
theory of this paper.

#horizontalrule

== 1. Core Model
<1-core-model>
=== 1.1 Graphs, States, and Validity
<11-graphs-states-and-validity>
Let $G = \( V \, E \)$ be a finite DAG. A graph state consists of:

- a total status map $s t a t u s : V arrow.r N o d e S t a t u s$
- a partial output map $o u t p u t : V harpoon.rt V a l u e$

For the fixed-topology core:

$ N o d e S t a t u s = upright("Pending") divides upright("Running") divides upright("Completed") divides upright("Failed") divides upright("Skipped") divides upright("Waiting") \( s i g n a l \) $

We distinguish three kinds of states:

- #strong[mid-accumulation states];, which may still contain
  $upright("Running")$
- #strong[normalized states];, after `resetRunningToPending`
- #strong[closed states];, after `propagateFailure`

The main validity predicate is defined only on normalized, closed
states.

#strong[Definition 1 (`wellFormedGraphState`).]
$"wellFormedGraphState" \( G \, s \)$ holds iff:

+ $"dom" \( s t a t u s \) = V$
+ $"dom" \( o u t p u t \) subset.eq V$
+ outputs appear exactly on statuses that semantically carry outputs
+ no node is $upright("Running")$ or $upright("Interrupted")$
+ every $upright("Pending")$ or $upright("Waiting")$ descendant of a
  $upright("Failed")$ node is itself $upright("Failed")$
+ $"readyNodes" \( G \, s \)$ is extensionally equal to the readiness
  predicate: nodes that are $upright("Pending")$ and whose predecessors
  are all $upright("Completed")$, $upright("Skipped")$, or
  $upright("Rewritten")$

This definition is intentionally relative to fixed topology. Once
topology changes, the validity contract must be enriched with
materialization and identity invariants.

=== 1.2 The Staged Machine
<12-the-staged-machine>
The fixed-topology runtime factors as:

$ "reduce" \( G \, R \, s \) = "classify" \( G \, "close" \( G \, "accumulate" \( R \, s \) \) \) $

Where:

- `accumulate = foldl (flip applyNodeFact)`
- `close = propagateFailure`
- `classify = classifyGraphState`

The execution model uses barriered frontier waves, but the algebraic
core only sees a set of node-local facts and a topology-indexed state.

#horizontalrule

== 2. Algebraic Structure
<2-algebraic-structure>
=== 2.1 Accumulation as a Commutative Action
<21-accumulation-as-a-commutative-action>
Let `F` be the free commutative monoid of `NodeResult` values with
distinct `NodeId`s. Distinctness is justified by the frontier antichain
property.

`applyNodeFact` induces a monoid action:

$ "act" : F times G r a p h S t a t e arrow.r G r a p h S t a t e $

$ "act" \( S \, s \) = "foldl" \( "flip" med a p p l y N o d e F a c t \, med s \, med S \) $

The load-bearing property is not a deep join law on shared state. It is
the more modest disjoint-key commutativity of point updates.

#strong[Lemma 1 (disjoint-key commutativity).] If
$r_1 . n i d eq.not r_2 . n i d$, then:

= \$\$ applyNodeFact\\ r\_1\\ (applyNodeFact\\ r\_2\\ s)
<-applynodefact-r_1-applynodefact-r_2-s>
applyNodeFact\\ r\_2\\ (applyNodeFact\\ r\_1\\ s) \$\$

This is the precise theorem. References to LVars, CRDTs, and related
work should be read as analogies in design style, not as direct reuse of
their stronger shared-key commutativity results.

=== 2.2 Failure Closure
<22-failure-closure>
`propagateFailure` is treated as a closure operator on the preorder
\"has at least as many failed consequences as\":

- extensive
- monotone
- idempotent

These laws are what make partial persistence structurally safe. In this
draft they are stated as semantic obligations of the implementation and
deferred to the Lean mechanization plan.

=== 2.3 Classification
<23-classification>
`classifyGraphState` is a deterministic decision procedure on
normalized, closed states:

- `Progressing` if some node is ready
- `Settled` if all nodes are terminal
- `Suspended` if some node is waiting and no node is ready
- `Stuck` otherwise

The case split is by construction once readiness, terminality, and
waiting are fixed.

=== 2.4 Determinism of the Staged Reduction
<24-determinism-of-the-staged-reduction>
#strong[Theorem 2 (staged reduction determinism).] For any permutation
$pi$ of a frontier result set:

$ "reduce" \( G \, pi \( r e s u l t s \) \, s \) = "reduce" \( G \, r e s u l t s \, s \) $

The theorem is conditional on the identity of `NodeResult` values. It is
a theorem about reduction order, not about worker I/O behavior.

#horizontalrule

== 3. Structural Recovery Safety
<3-structural-recovery-safety>
=== 3.1 Theorem Statement
<31-theorem-statement>
Let $S = S_1 union S_2$ be a frontier result set, where $S_1$ is the
subset whose local facts were durably persisted before a crash and $S_2$
is the subset that must be replayed. Define:

$ s_(p e r s i s t e d) = "accumulate" \( S_1 \, s_0 \) $

$ s_(r e c o v e r e d) = "close" \( G \, "resetRunningToPending" \( s_(p e r s i s t e d) \) \) $

#strong[Theorem 3 (structural recovery safety).] $s_(r e c o v e r e d)$
satisfies $"wellFormedGraphState" \( G \, s_(r e c o v e r e d) \)$.

Moreover:

- $"readyNodes" \( G \, s_(r e c o v e r e d) \)$ is a correct resume
  frontier
- re-closing after replayed facts are accumulated preserves already
  derived failures

=== 3.2 What the Theorem Does and Does Not Say
<32-what-the-theorem-does-and-does-not-say>
The theorem guarantees:

- topology-indexed domain consistency
- removal of transient `Running`
- closure completeness
- frontier correctness
- schedulable recovery from any persisted accumulation prefix

The theorem does #strong[not] guarantee:

- identical business outputs after replay
- identical worker exceptions or timing
- end-to-end correctness of the whole workflow system

Those stronger properties require assumptions or proof obligations
outside the staged reduction itself.

=== 3.3 Dependency Structure
<33-dependency-structure>
The theorem depends on four obligations:

+ `applyNodeFact` preserves topology-indexed domains
+ `resetRunningToPending` preserves domains and removes all `Running`
+ `propagateFailure` is a closure operator and preserves domain
  consistency
+ `readyNodes` is sound and complete for the readiness predicate

Only after these are stated explicitly does the recovery theorem stop
being circular.

=== 3.4 Proof Status
<34-proof-status>
#figure(
  align(center)[#table(
    columns: 3,
    align: (auto,auto,auto,),
    table.header([Claim], [Status in this draft], [Intended home],),
    table.hline(),
    [Frontier antichain], [sketchable from DAG readiness], [Paper 1 +
    Paper 2],
    [Disjoint-key commutativity], [direct proof], [Paper 1 + Paper 2],
    [Closure extensiveness / monotonicity / idempotence], [stated as
    obligations, not fully proved here], [Lean mechanization plan],
    [Structural recovery safety], [stated sharply, proof outline
    only], [Lean mechanization plan + Paper 2],
    [Outcome reproducibility under replay], [external
    assumption], [outside the algebra],
  )]
  , kind: table
  )

The point of the table is discipline: this paper should never silently
upgrade \"tested in implementation\" into \"proved in theory.\"

#horizontalrule

== 4. The Forward Fragment and the Reset Boundary
<4-the-forward-fragment-and-the-reset-boundary>
=== 4.1 Forward Fragment
<41-forward-fragment>
The forward statuses form the local monotone fragment:

$ upright("Pending") & lt.eq upright("Running") lt.eq upright("Completed")\
upright("Pending") & lt.eq upright("Running") lt.eq upright("Failed")\
upright("Pending") & lt.eq upright("Running") lt.eq upright("Skipped")\
upright("Pending") & lt.eq upright("Running") lt.eq upright("Waiting") \( s i g n a l \) $

Forward outcomes move upward in this partial order. This fragment
supports the cleanest algebraic reading.

=== 4.2 Reset Boundary
<42-reset-boundary>
Cancellation, shutdown, and crash normalization are explicitly
non-monotone. They do not invalidate the staged reduction, but they do
invalidate any claim that the runtime is globally monotone.

This separation should remain explicit:

- the forward fragment supports the order-theoretic story
- reset behavior is handled constitutionally by keeping resets
  node-local and coordinator-controlled

#horizontalrule

== 5. Extension Boundary
<5-extension-boundary>
The staged reduction has three load-bearing invariants:

- #strong[I.] accumulation commutativity for frontier facts
- #strong[II.] closure idempotence
- #strong[III.] frontier antichain / readiness soundness

=== 5.1 Extensions That Preserve the Core
<51-extensions-that-preserve-the-core>
#figure(
  align(center)[#table(
    columns: 5,
    align: (auto,auto,auto,auto,auto,),
    table.header([Extension], [I], [II], [III], [Reason],),
    table.hline(),
    [new node-local forward outcome], [yes], [yes], [yes], [still a
    point update],
    [richer classification output], [yes], [yes], [yes], [classification
    is observational],
    [additional closure commuting with failure
    closure], [yes], [conditionally], [yes], [composition of commuting
    closures],
    [edge annotations preserving DAG readiness
    semantics], [yes], [yes], [conditionally], [if readiness stays
    predecessor-based],
  )]
  , kind: table
  )

=== 5.2 Extensions That Cross the Boundary
<52-extensions-that-cross-the-boundary>
#figure(
  align(center)[#table(
    columns: 3,
    align: (auto,auto,auto,),
    table.header([Extension], [Broken invariant], [Why],),
    table.hline(),
    [inter-node mutation in accumulation], [I], [facts no longer commute
    by disjoint key],
    [compensating or oscillating propagation], [II], [closure may stop
    being idempotent],
    [topology mutation during accumulation], [III], [frontier and
    closure are computed over moving topology],
    [shared-key accumulation without a merge algebra], [I], [update
    order becomes observable],
  )]
  , kind: table
  )

Topology-changing execution is therefore not \"just another extension.\"
It requires a different machine and a different safety theorem.

#horizontalrule

== 6. Relation to Other Models
<6-relation-to-other-models>
=== 6.1 CALM
<61-calm>
The CALM theorem remains a useful interpretation:

- accumulation is coordination-free
- classification is a threshold observation
- frontier barriers are the coordination boundary

This is an architectural reading, not a formal reduction of the runtime
to CALM.

=== 6.2 CKA and BSP
<62-cka-and-bsp>
The runtime resembles a BSP-style fragment of concurrent Kleene algebra:

$ \( upright("wave")_1 med upright("workers") \) ; upright("close") ; upright("classify") ; \( upright("wave")_2 med upright("workers") \) ; upright("close") ; upright("classify") ; dots.h.c $

This is useful for intuition about barriered parallel composition, but
we do not claim a full CKA embedding here.

=== 6.3 Actor Confluence Work
<63-actor-confluence-work>
Henrio et al.\'s layered confluence results for actors are relevant
because our system is also a worker-coordinator architecture. The key
difference is that our workers are constitutionally restricted to
node-local facts, which gives a narrower and stronger commutativity
condition than arbitrary actor messaging.

#horizontalrule

== 7. Open Problems
<7-open-problems>
+ #strong[Mechanize the closure laws.] This is the main proof debt and
  the central purpose of the Lean mechanization plan.
+ #strong[Characterize the closed-state subspace.] The closure operator
  suggests a useful sub-poset of normalized states, but its exact
  algebraic structure is still only partly understood.
+ #strong[Weaken replay assumptions.] Structural safety needs less than
  outcome identity. The weakest useful replay-compatibility condition is
  still open.
+ #strong[Separate theory for topology-changing execution.]
  Rewrite-capable execution requires a materialization boundary, durable
  identity scheme, and different recovery theorem. That is the subject
  of the rewrite materialization and recovery plan.

#horizontalrule

== 8. Takeaway
<8-takeaway>
The point of the algebraic foundations paper is not to inflate an
implementation sketch into a fake theorem. It is to isolate the exact
mathematical kernel of the fixed-topology runtime:

- node-local facts commute by disjoint key
- failure closure is the load-bearing closure operator
- classification is a deterministic read on normalized, closed states
- structural recovery safety follows only after validity is defined
  explicitly

Everything stronger must either be proved elsewhere, or named honestly
as an assumption.

== References
<references>
+ Kuper, L., Newton, R. (2013). #emph[LVars: Lattice-based Data
  Structures for Deterministic Parallelism];. FHPC 2013.
+ Shapiro, M. et al. (2011). #emph[Conflict-free Replicated Data Types];.
  SSS 2011.
+ Conway, N. et al. (2012). #emph[Logic and Lattices for Distributed
  Programming];. SoCC 2012.
+ Hoare, C. A. R., Möller, B., Struth, G., Wehrman, I. (2009).
  #emph[Foundations of Concurrent Kleene Algebra];. RelMiCS 2009.
+ Valiant, L. G. (1990). #emph[A Bridging Model for Parallel
  Computation];. Communications of the ACM 33(8):103--111.
+ Henrio, L. et al. (2026). #emph[Layers of Confluence for Actors];. CPP
  2026.
