---
title: "A Keyed Frontier Calculus for Executable Open Graphs"
description:
  Flagship draft. The Wire calculus on paper - keyed connect, carried frontiers, certified
  elaborations, and the single admitted referent - with mechanized metatheory and an executing
  compiler.
kind: publication
status: draft
authors:
  - Julius Koskela
date: 2026-06-10
updated: 2026-06-10
related:
  - docs/Publications/glossary.md
  - docs/Publications/Paper-3-graph-substitution-semantics/
  - docs/Publications/Paper-4-wire-language/
  - docs/Publications/Paper-6-executable-diagrams/
  - docs/Reference/proof-status.md
---

# A Keyed Frontier Calculus for Executable Open Graphs

> Complete draft, pre-submission. All sections are drafted; figures and the typeset export are
> pending. Verification claims are stated against the project proof-status dashboard as of
> 2026-06-10 and must be refreshed at any submission freeze.

## Abstract

We present a typed calculus of open directed graphs whose composition transforms **frontiers**: the
multisets of named, contract-typed ports a fragment exposes on its boundary. The calculus adopts the
no-implicit-copy port discipline of interaction nets and proof-net descendants — each endpoint used
exactly once, copying only through an explicit node — and contributes three things that family does
not have. First, **keyed connect**: composition is computed, not hand-wired — an edge forms only per
uniquely matched port key, and unmatched endpoints are **carried** unchanged to the composite
boundary, so source expressions compose as frontier transformers. Two consequences are the point of
the design: source-level distributivity fails — distributing duplicates an operand, and an operand
owns resources — and every fan-out is a named event. Second, richer source forms (product adapters,
bounded generation, latent branch selection) are certified **elaborations** — statically admitted
expansions into a four-form core — not new primitives, so the trusted theory never grows. Third, the
**single admitted referent**: source typing, the compiler's executable artifact, the runtime's
durable replay and provenance, and the proof-facing validation all refer to one admitted diagram,
with the correspondence compiler-enforced by a structural binding check. The linearity theorem, the
elaboration corollaries, the lowering equations relating the calculus to the algebra of graphs, and
the admission, budget, and recovery theorems for dynamic extension are mechanized in Lean 4 with no
axioms; the metatheory table states each claim's exact strength, including what remains open. The
system is demonstrated on workloads from build pipelines to a quantum-eraser experiment executed on
physical hardware, where port linearity structurally mirrors the no-cloning constraint that
qubit-carrying ports require.

## 1. Introduction

Most programming notations make time primary and structure derived. An imperative program is an
ordered vector of effects: a later read means something only because the program counter supplies an
ordered prefix. Pure functional programs recover dependencies through names; effectful programs fall
back to an ordered spine unless the author maintains parallel structure by hand. This paper develops
the next rung of that ladder: a notation in which the **causal diagram** — an open graph of typed
events — **is the primary object**, order is derived from it, and the type discipline makes the
diagram trustworthy enough to schedule, replay, and audit.

The object is an open directed graph of typed events. Each node owns named, contract-typed ports;
each composition step is read as a transformer of the **frontier**, the multiset of typed port
instances not yet consumed. Two operators suffice for composition: overlay unions independent
fragments, and connect matches compatible output-input port keys, forming one edge per uniquely
matched key and **carrying** every unmatched endpoint forward as an open obligation. The discipline
underneath is **port linearity**: every owned endpoint is consumed by exactly one internal edge or
exposed on the boundary — never both, never twice, never silently dropped. That discipline is
inherited, not invented here: interaction nets and their proof-net ancestry already connect each
typed port at most once, expose free ports as the interface, and route all copying through explicit
agents (§6). What this calculus adds on top is the composition story — connect by key, carry the
rest: there is no ambient copying, reusing a value requires a named node that consumes one endpoint
and produces fresh ones, so every fan-out in the executed topology is a causal event with a name,
and provenance questions ("why do these two observations share a source?") have answers in the
diagram rather than in reconstructed traces. The algebraic signature of this choice is that connect
does not distribute over overlay: distributing duplicates an operand, and an operand owns resources
(§3.6).

A second commitment is what makes admission decidable for programs nobody hand-wrote: **authority
stays closed while composition stays open**. The calculus composes references to _registered_
capability — executors, payload contracts, node kinds are declared outside the graph language — and
the grammar offers a small, fixed operator alphabet over those references. Programs, including
machine-generated ones, can therefore compose rich behavior without ever minting new runtime
authority, and admission can check every composition against declarations it already knows. The
derived source forms that make the language practical — product adapters for fan-shaped topologies,
bounded generation of node families, latent branch selection — obey the same rule: each is a
certified elaboration into the four-form core, so the trusted theory never grows.

The practical stakes are why precision is worth the trouble. Durable workflow systems — runtimes
that record execution so a crashed or suspended run can resume — journal and replay behavior;
distributed tracing rebuilds causal graphs from timing spans; agentic systems compose tools and
models into evolving plans. All three spend their complexity budget reconstructing, at run time and
after the fact, causal structure the source language erased. Here the admitted diagram **is** that
structure from the start — the **single admitted referent**: source typing, the compiler's
executable artifact, the runtime's replay and provenance, and the proof assistant's obligations all
refer to the same object, and a certification architecture (§5) makes those references checkable
rather than aspirational. The implemented language is called **Wire** and its durable runtime
**Pulse**; the body of the paper uses the proper names only where the implementation is concerned.

The paper makes its claims at stated strength. §2-§3 develop the calculus: definitions, a worked
example before any rule, four core typing rules, the derived forms as certified elaborations, the
linearity theorem and its elaboration corollary, the forgetful lowering that recovers the algebra of
graphs, and the two-layer (latent/actualized) reading. §4 is the metatheory table: every claim
classified as core theorem, elaboration corollary, implementation check, or open correspondence
obligation, with the mechanized declaration and the residual assumption per row. §5 presents
execution and the certifying admission boundary. §6 positions the calculus against algebraic graphs,
open-graph and string-diagram composition, linear logic, session types, graded types, certifying
compilation, and durable execution.

## 2. Definitions

Consistent with the shared publications glossary; restated here in the paper's notation.

Fix countable sets of node names, port names, contract names, and labels. A **port instance** is a
tuple $p = (n, a, c, \ell, d)$: owner node $n$, port name $a$, contract $c$, optional label
$\ell \in \mathcal{L} \cup \{\bot\}$, and direction $d \in \{{-}, {+}\}$ (input, output). The
**key** of a port instance is $\operatorname{key}(p) = (d, c, \ell)$: direction, contract, and
label; its direction-erased **match key** is $\operatorname{mkey}(p) = (c, \ell)$. Identity uses the
full key; matching uses the match key, because matching always crosses an output frontier and an
input frontier — direction is enforced by that partition, so a direction-bearing key could never
occur on both sides of a match. The owner and port name are deliberately excluded from both, and an
absent label is itself a key component, not a wildcard. Port instances may additionally carry an
exclusive-group component marking membership in an exclusive output sum; the core rules ignore it,
and E-Select (§3.4) is where it enters the discipline.

A **diagram** is a triple $D = \langle N, E, \Phi \rangle$: a finite node set $N$, an edge set $E$
of ordered pairs of port instances (producer output, consumer input), and a **frontier** $\Phi$, a
finite multiset of port instances not consumed by $E$. We write $\Phi^{-}$ and $\Phi^{+}$ for the
input and output restrictions of $\Phi$, $\uplus$ for multiset sum, and $\setminus$ for multiset
difference. For a node $n$ declaring inputs $I$ and outputs $O$, we write
$\operatorname{OwnedPorts}(n) = I \cup O$ for the instances it owns. In every diagram produced by
the typing rules, an owned port instance occurs in $\Phi$ with multiplicity at most one — a
consequence of node-disjoint composition. The frontier is nonetheless kept a multiset rather than a
set, so that reordering ports (exchange) is definitional rather than an imposed identification.

## 3. The Calculus

### 3.1 A worked example, first

Four registered nodes; bodies elided, boundaries shown:

```wire
node source  -> src: Sources;
node config  -> cfg: BuildConfig;
node build   <- src: Sources;  <- cfg: BuildConfig;
             -> bin: Binary;   -> log: BuildLog;
node package <- bin: Binary;   -> pkg: Package;

source <> config => build => package
```

Overlay binds tighter than connect, so the expression parses as
$((\textit{source} \mathrel{<>} \textit{config}) \Rightarrow \textit{build}) \Rightarrow
\textit{package}$.
The frontier computation:

1. $\textit{source} \mathrel{<>} \textit{config}$: node sets are disjoint; the composite has no
   edges and output frontier
   $\{\mathit{src}^{+}{:}\textit{Sources},\
   \mathit{cfg}^{+}{:}\textit{BuildConfig}\}$.
2. $\Rightarrow \textit{build}$: match keys $(\textit{Sources},\bot)$ and
   $(\textit{BuildConfig},\bot)$ each match exactly one input on the right; two edges form; the
   composite frontier is
   $\{\mathit{bin}^{+}{:}\textit{Binary},\
   \mathit{log}^{+}{:}\textit{BuildLog}\}$.
3. $\Rightarrow \textit{package}$: the $\textit{Binary}$ key matches and becomes an edge;
   $\mathit{log}^{+}$ has no compatible consumer and is **carried** — it crosses the composition and
   remains on the final frontier together with $\mathit{pkg}^{+}{:}\textit{Package}$.

Carrying is the calculus doing real work: the build log is a typed resource that survives the
pipeline without flowing through `package`, and the final topology records that directly. The
rejection dual: if a second consumer of $\textit{Binary}$ were overlaid with `package`, the
$\textit{Binary}$ key would have two compatible inputs, and the composition is a static error — one
produced endpoint with two consumers has no linear reading. Reuse requires a named node that
consumes the endpoint and produces fresh ones.

### 3.2 Syntax: a four-form core, and derived forms that elaborate to it

The **core grammar** has exactly four forms:

$$
\begin{aligned}
e \ ::= \ & ()                              && \text{empty diagram} \\
   \mid\ & n                                && \text{registered node reference} \\
   \mid\ & e_1 \mathrel{<>} e_2             && \text{overlay} \\
   \mid\ & e_1 \Rightarrow e_2              && \text{connect}
\end{aligned}
$$

The surface language additionally offers four **derived source forms**:

$$
\begin{aligned}
s \ ::= \ & e_1 * e_2                        && \text{product adapter (gather/scatter)} \\
   \mid\ & \operatorname{make}(k, K)        && \text{bounded generation, static count } k \\
   \mid\ & \operatorname{makeEach}(\vec{v}, K) && \text{bounded generation over static items} \\
   \mid\ & e \ \operatorname{select}(k_1{:}\,e_1, \ldots, k_m{:}\,e_m) && \text{latent branch family}
\end{aligned}
$$

The derived forms introduce **no new primitive semantics**: each elaborates, during admission, to
core expressions over a context extended with generated node declarations (§3.4). This split is
deliberate and load-bearing — the trusted composition theory stays four rules, and everything richer
is a certified construction over them.

Node declarations live in a context $\Gamma$ mapping node names to boundary signatures
$n : \langle I; O \rangle$ (finite sets of input and output port instances owned by $n$), kind names
to boundary templates, and contract names to their registrations. $\Gamma$ is produced by
elaboration (source includes, kind expansion) and is closed: expressions may reference only
registered names.

### 3.3 Frontier typing: connect by key, carry the rest

The judgment

$$
\Gamma \vdash e \,\triangleright\, \langle N;\ E;\ \Phi^{-};\ \Phi^{+} \rangle
$$

reads: under context $\Gamma$, expression $e$ elaborates to the diagram with node set $N$, edge set
$E$, open input frontier $\Phi^{-}$, and open output frontier $\Phi^{+}$. The judgment produces the
diagram, not only its boundary; Theorem 1 quantifies over exactly this object.

$$
\frac{}{\Gamma \vdash () \,\triangleright\,
\langle \varnothing; \varnothing; \varnothing; \varnothing \rangle}
\ \textsf{(T-Empty)}
\qquad
\frac{(n : \langle I; O \rangle) \in \Gamma}
     {\Gamma \vdash n \,\triangleright\, \langle \{n\}; \varnothing; I; O \rangle}
\ \textsf{(T-Node)}
$$

$$
\frac{\Gamma \vdash e_1 \,\triangleright\, \langle N_1; E_1; \Phi^{-}_1; \Phi^{+}_1 \rangle
\quad
\Gamma \vdash e_2 \,\triangleright\, \langle N_2; E_2; \Phi^{-}_2; \Phi^{+}_2 \rangle
\quad
N_1 \cap N_2 = \varnothing}
{\Gamma \vdash e_1 \mathrel{<>} e_2 \,\triangleright\,
\langle N_1 \cup N_2;\ E_1 \cup E_2;\ \Phi^{-}_1 \uplus \Phi^{-}_2;\ \Phi^{+}_1 \uplus \Phi^{+}_2 \rangle}
\ \textsf{(T-Overlay)}
$$

For connect, write $\Phi^{+}_1{\restriction}k$ and $\Phi^{-}_2{\restriction}k$ for the multisets of
left outputs and right inputs whose match key $\operatorname{mkey}(p)$ equals $k$. The side
condition is **per-key singleton matching**: for every match key $k$ present on both sides,

$$
|\Phi^{+}_1{\restriction}k| = 1
\quad\text{and}\quad
|\Phi^{-}_2{\restriction}k| = 1 .
$$

If one key matches two or more outputs, or two or more inputs, the composition is rejected: there is
no implicit copy and no implicit merge, and reuse requires an explicit node. When the side condition
holds, the match $M$ is the partial bijection pairing the unique output and input per shared match
key; we write $\operatorname{dom} M$ and $\operatorname{rng} M$ for the matched outputs and matched
inputs:

$$
\frac{\begin{array}{c}
\Gamma \vdash e_1 \,\triangleright\, \langle N_1; E_1; \Phi^{-}_1; \Phi^{+}_1 \rangle
\quad
\Gamma \vdash e_2 \,\triangleright\, \langle N_2; E_2; \Phi^{-}_2; \Phi^{+}_2 \rangle
\quad
N_1 \cap N_2 = \varnothing \\
\text{per-key singleton matching holds; } M \text{ the induced partial bijection}
\end{array}}
{\Gamma \vdash e_1 \Rightarrow e_2 \,\triangleright\,
\langle N_1 \cup N_2;\
E_1 \cup E_2 \cup M;\
\Phi^{-}_1 \uplus (\Phi^{-}_2 \setminus \operatorname{rng} M);\
(\Phi^{+}_1 \setminus \operatorname{dom} M) \uplus \Phi^{+}_2 \rangle}
\ \textsf{(T-Connect)}
$$

Matched pairs enter the edge set; unmatched frontier endpoints are **carried**. Carrying is the
open-graph identity wire: a carried endpoint crosses the composition unchanged and remains available
to a later compatible consumer. The compiler implements exactly this side condition: a candidate
multiplicity above one on either side is rejected with a source-level diagnostic (Appendix A).

### 3.4 Derived forms as certified elaborations

The four derived source forms elaborate to core expressions. We write the elaboration judgment

$$
\Gamma \vdash s \,\hookrightarrow\, \langle \Gamma';\ e^{\circ} \rangle
$$

read: under context $\Gamma$, source form $s$ elaborates to core expression $e^{\circ}$ under the
extended context $\Gamma'$ ($\Gamma$ plus the generated node declarations the elaboration
introduces). Typability of the target is part of the judgment:
$\Gamma \vdash s
\,\hookrightarrow\, \langle \Gamma'; e^{\circ} \rangle$ holds only when
$\Gamma' \vdash e^{\circ} \,\triangleright\, \langle N; E; \Phi^{-}; \Phi^{+} \rangle$ for some
composite — elaboration and core typing are one admission pass, and a failure of either is the same
static error at the source level. Each elaboration additionally carries its own admission premises.
The relation is deterministic by construction: generated names are a function of the generation site
and the child index or item label, so a source form has at most one elaboration. For the generation
forms, $\Gamma$ additionally carries **graph bindings** — names bound to core expressions — and a
bound name occurring in expression position denotes its core expression. This mirrors both the
compiler (derived forms are expanded before graph admission) and the mechanization (each form is an
admission predicate over the core algebra, accepted only with a construction witness).

#### E-Star: product adapters

For $e_1 * e_2$, exactly one operand boundary is **singular** (one port whose contract is a product
— a named record or a bounded indexed product $[T;\,k]$) and the other is **multi** (one port per
product component). Direction is determined by which side is which: multi-to-singular is a
**gather**, singular-to-multi is a **scatter**. The elaboration generates one fresh **phantom
adapter** node $\varphi$ whose boundary crosses exactly one product constructor — on the multi side,
one leaf port per record field or index, each keyed by the component contract and label; on the
singular side, the product port itself — and the form elaborates to two ordinary connects:

$$
\Gamma \vdash e_1 * e_2 \,\hookrightarrow\,
\langle \Gamma, \varphi : \langle I_{\varphi}; O_{\varphi} \rangle;\
e_1 \Rightarrow \varphi \Rightarrow e_2 \rangle
$$

where $\varphi$'s boundary is determined by the operands: in a gather, $I_{\varphi}$ is one leaf
input per product component, keyed by the component contract and label so that each matches exactly
one multi-side output, and $O_{\varphi}$ is the singular product port; in a scatter the directions
are swapped. Both connects are instances of T-Connect; the adapter introduces no copying rule — each
leaf endpoint is matched and consumed exactly once. Rejected at this elaboration: both operands
multi; both operands flat singular (ordinary connect already covers that case); a singular contract
that is neither a registered record nor a bounded indexed product; component arity or contract
mismatch between the product and the multi side; and products whose element contract is itself an
indexed product. One-component products ($[T;\,1]$, single-field records) are admitted — the
degenerate adapter is still a named constructor crossing, not a rename.

#### E-Make and E-MakeEach: bounded generation

Generated families are admitted through a **named binding whose right-hand side is the generation
form** — the grammar offers `make`/`makeEach` only in that position, at the top level or local to a
form. A kind $K$ is a node-body template with a label formal (and, for `makeEach`, an optional value
formal). For a binding $b$:

$$
\Gamma \vdash b = \operatorname{make}(k, K) \,\hookrightarrow\,
\langle \Gamma,\ n_{b,0}, \ldots, n_{b,k-1},\
b \mapsto n_{b,0} \mathrel{<>} \cdots \mathrel{<>} n_{b,k-1};\
\ n_{b,0} \mathrel{<>} \cdots \mathrel{<>} n_{b,k-1} \rangle
$$

This is a declaration elaboration: the extended context gains both the fresh node declarations
$n_{b,i}$ (each instantiating $K$'s boundary template with the generated label $i$) and the graph
binding $b$, bound to the overlay of the children; the elaborated core expression is that overlay,
and subsequent occurrences of $b$ in expression position denote it. `makeEach` is the same scheme
over a static item vector: one child per item, labelled by the item, with the item's static value
supplied to $K$'s value formal. Generated names are fresh by construction and deterministic — from
the binding name and index for `make`, from the binding name and item label for `makeEach` — so
re-elaboration is stable. A zero count is admitted: $\operatorname{make}(0, K)$ generates the empty
family and the binding denotes the empty diagram. Rejected: a count that is not compile-time
resolvable (admitted forms: integer literals and preceding closed numeric bindings); an unknown
kind; a kind whose formals do not match the generation form; items outside the static-value
sublanguage; duplicate item labels.

#### E-Select: latent branch families

Select is the richest derived form, and four concerns must be kept separate.

**Source admission** (the premises). The left operand's output frontier must be exactly one
**exclusive output sum**: two or more output ports forming a single exclusive group, with no other
exits. Arm keys resolve against the sum's variants **label-first**, falling back to a **unique
contract** match; an arm key matching several variants, or none, is rejected. Coverage is total in
both directions: every variant has exactly one arm and every arm names a variant. Each arm body is a
graph expression with no external inputs beyond its variant's payload. Finally, the arms must
**converge**: writing the boundary shape of a port as its (contract, label, exclusivity) triple, the
list of output boundary shapes of every arm — for an identity arm, the shape of its own variant —
must equal one common downstream boundary shape list. Convergence is what makes the composite
boundary independent of which arm is later selected.

**Latent bodies.** Admitted arm bodies are _not_ part of the composite's node set. They are sealed
latent objects carrying source provenance: declared and admitted now, instantiated only if their arm
is selected at run time (§3.7). This is the one place the calculus deliberately suspends the
frontier discipline — a latent body's resources do not exist yet, so they appear on no frontier.

**Elaboration target.** An admitted select elaborates to a generated **condition node** $\chi$ that
consumes the exclusive sum and exposes the common downstream boundary as ordinary output ports:

$$
\Gamma \vdash e \ \operatorname{select}(k_1{:}\,e_1, \ldots, k_m{:}\,e_m)
\,\hookrightarrow\,
\langle \Gamma, \chi : \langle I_{\chi}; O_{\chi} \rangle;\
e \Rightarrow \chi \rangle
$$

where $I_{\chi}$ is the variant sum and $O_{\chi}$ is the common boundary established by
convergence. The composite frontier is the left operand's open **input** endpoints — by the
admission premise its output frontier is exactly the sum, all of it consumed by $\chi$, so no left
output is carried — together with the condition node's bridge outputs; both facts are readable
directly off T-Connect. One reading deserves a sentence: the surface syntax reuses `()` in arm
position, but select admission normalizes an empty arm to the **identity arm** — the selected
variant passes through unchanged — before core elaboration, so the token does not carry two
denotations: in expression position `()` is T-Empty's empty diagram; in arm position it is shorthand
for identity, and an identity arm's boundary contribution is its own variant's shape, not the empty
boundary. One case the rule never produces follows: a select in which **every** arm is the identity
is rejected by convergence, because the variants of an exclusive sum carry pairwise distinct labels
— so at least one arm is always a real body, and the condition node always exists. (The
implementation contains a pass-through path for an all-identity select; it sits behind the
convergence check and is unreachable, which the test suite pins.)

**What this rule does not say.** Selection — the run-time instantiation of one latent body as a
budgeted append rewrite — and the correspondence between the condition node and the evidence the
compiler emits for it are run-time and certification concerns, deferred to §3.7 and §5. Folding them
into the admission premise would overstate what source typing decides.

### 3.5 Linearity

**Definition 1 (port linearity, node-boundary form).** For an elaborated diagram
$D = \langle N, E, \Phi \rangle$ define indicator functions on owned port instances:
$\operatorname{internal}_D(p) = 1$ iff $p$ is an endpoint of exactly one edge in $E$ (and $0$
otherwise), and $\operatorname{frontier}_D(p) = 1$ iff $p$ occurs in $\Phi$ with multiplicity
exactly one (and $0$ otherwise — both absence and any higher multiplicity). $D$ is **port-linear**
when

$$
\forall n \in N,\ \forall p \in \operatorname{OwnedPorts}(n),\quad
\operatorname{internal}_D(p) + \operatorname{frontier}_D(p) = 1 .
$$

Of the structural rules, only exchange comes for free: the frontier is a multiset, so reordering is
definitional. Weakening (discarding a resource) is not an operation at all, and contraction
(copying) is never ambient — it happens only when an explicit node consumes one endpoint and
produces fresh ones.

The definition quantifies over all of a node's owned instances, so it presupposes a totality
invariant: every owned instance of every node in the diagram is accounted for — internal or on the
frontier, never neither. The typing rules maintain this by construction: T-Node places all declared
ports on the frontier, T-Overlay touches no port accounting (node sets are disjoint), and T-Connect
moves matched instances from frontier to internal without dropping any.

**Theorem 1 (linearity preservation, core calculus).** If
$\Gamma \vdash e \,\triangleright\, \langle N; E; \Phi^{-}; \Phi^{+} \rangle$ for a **core**
expression $e$, then $\langle N, E, \Phi \rangle$ with $\Phi := \Phi^{-} \uplus \Phi^{+}$ (all
frontier instances, both directions) is port-linear.

_Proof._ By rule induction **on core expressions** — four cases. T-Empty and T-Node are immediate:
the empty diagram has no owned ports, and a node's declared ports all sit on the frontier with
multiplicity one. T-Overlay preserves the invariant because the operands' node sets are disjoint, so
each owned port's accounting is untouched by the union (mechanized as
`overlay_preserves_portLinear`, whose hypotheses are exactly the rule's premises: both operands
port-linear, domains disjoint). T-Connect moves each matched pair from frontier to internal —
indicator $0{+}1$ becomes $1{+}0$ on both endpoints — and touches nothing else; the per-key
singleton condition is what guarantees no endpoint is matched twice (mechanized per pair as
`contract_preserves_portLinear`, and for the induced sequence of contractions as
`bulkContract_preserves_portLinear`). $\square$

The mechanized statements live over an explicit carrier — a graph of port instances with membership
invariants — rather than over the typing rules' frontier computations; the correspondence between a
typing derivation and a certified carrier construction is summarized in §4, where each citation
states its actual hypothesis shape.

**Corollary 1 (linearity preservation, source forms).** If a derived source form is admitted —
$\Gamma \vdash s \,\hookrightarrow\, \langle \Gamma'; e^{\circ} \rangle$ — then the composite
diagram of $e^{\circ}$ under $\Gamma'$ is port-linear.

_Proof discharge._ The elaboration target $e^{\circ}$ is a core expression over $\Gamma'$, so
Theorem 1 applies once the generated declarations are well-formed; what each derived form adds is
the proof that its admission produces well-formed fresh declarations. These are mechanized as
acceptance theorems whose hypothesis is precisely a successful admission: when the certified
constructor for bounded generation returns a result (over an abstract injective naming policy and
caller-supplied per-child frontier instances), the constructed object is port-linear
(`Make.accept_portLinear`, `MakeEach.accept_portLinear`); the same holds for the phantom adapter's
witnessed construction (`Star.accept_portLinear`). For select, the convergence premise guarantees a
condition node always exists (§3.4), and that node is an ordinary declared node, so Theorem 1
already covers the composite; the latent arm bodies are outside the diagram and therefore outside
this statement — their discipline at instantiation time is §3.7's subject. The corollary is not
circular: typability of the target is definitional, and the substance is that each admission
produces well-formed fresh declarations, which is exactly what the acceptance theorems prove.
$\square$

The phrase "by induction on source syntax" is deliberately avoided: Theorem 1 is a four-case core
theorem, and source forms enter only through Corollary 1's admission hypotheses.

**Definition 2 (closed diagram).** A diagram is **closed** when its frontier is empty.

Closedness is a property, not an admission requirement. Top-level admission checks acyclicity of the
node-level projection; the compiler packages every admitted diagram, closed or open, as an
executable circuit artifact, with the frontier becoming the artifact's external interface — open
inputs become entry ports the runtime feeds, open outputs become exit ports whose values leave the
diagram. (The test suite pins both directions: open-input and open-output programs compile to
circuits.) Where everything must in the end be used exactly once is the **actualized** layer of the
running circuit, developed in §3.7, where exposed outputs are consumed by terminal discharge rather
than left dangling.

### 3.6 Forgetful lowering and the algebraic delta

Define $\lfloor D \rfloor$ as the node-level relation graph obtained by erasing port identity:
vertices $N$, and one relation edge per distinct owner-node pair of an element of $E$ — parallel
port edges between the same node pair collapse to one relation edge, since the lowered object is a
relation, not a multigraph. Wire expressions erase to ordinary relation graphs, but the two
operators lower differently: **overlay lowers homomorphically**
($\lfloor D_1 \mathrel{<>} D_2 \rfloor = \lfloor D_1 \rfloor \oplus \lfloor D_2
\rfloor$, mechanized
as `forgetPorts_overlay`), while **source connect lowers to insertion of the matched endpoint
relation** — the node pairs of $M$ — **not** to Mokhov's total connect, which would add the full
cross-product of edges. Mokhov's laws, including `connect_decomposition` (proven at relation,
denotational, and quotient levels), hold of the relation algebra in which the lowered graphs live;
they are not equations on source expressions. In particular **source-level distributivity of
$\Rightarrow$ over $<>$ deliberately fails**: distributing duplicates an operand and with it a port
resource — $(d \Rightarrow a) \mathrel{<>} (d \Rightarrow b)$ is rejected where
$d \Rightarrow a \mathrel{<>} b$ is admitted.

Three lowering equations are mechanized and carry the delta precisely. Lowering commutes with
overlay: $\lfloor D_1 \mathrel{<>} D_2 \rfloor = \lfloor D_1 \rfloor \oplus \lfloor D_2 \rfloor$
(`forgetPorts_overlay`). Lowering a sequence of contractions adds exactly the lowered matched edges
and nothing else: the result has the same vertex set and the edge set extended by precisely the node
pairs of the consumed port pairs (`forgetPorts_bulkContract`) — this equation _is_ the formal
statement that source connect inserts the matched endpoint relation rather than a cross-product. And
lowered graphs are endpoint-closed: every lowered edge's endpoints are lowered vertices
(`forgetPorts_edgeEndpointsInVertices`), which is what lets the relation-algebra vocabulary (paths,
acyclicity, decomposition) apply downstream.

### 3.7 Latent and actualized layers

The calculus above types the **source** layer: declared boundaries composed by the rules of §3.3. A
running circuit lives at a second layer, and the two must not be identified. A resource is
**latent** when it is declared and admitted but not yet instantiated — a select arm body before its
arm is chosen, a generated-form template before expansion. A resource is **actualized** when it is a
port instance of the running circuit, carrying values under the runtime's schedule. The two-layer
reading is what lets one diagram serve authoring (source) and replay and provenance (actualized)
without conflating a declaration with an execution.

**The actualized discipline.** An actualized port graph assigns each output port instance its
consumers — either edges to input instances or **terminal discharges**, the runtime's named exits
for values that leave the diagram — and each input instance its producers. It is **closed
port-linear** when every output is consumed exactly once (one edge or one terminal discharge) and
every input is produced exactly once. Two differences from Definition 1 are deliberate: there is no
frontier (a running circuit is closed), and terminal discharge exists only at this layer — the
source calculus has no notion of a value leaving.

**The projection, and what is proved about it.** The proof-side actualized model expects, for each
compiled circuit, a **port-use witness**: the actualized instances together with their use
assignment. Producing that witness is the compiler's obligation and remains open correspondence work
(§4); the mechanized facts are conditional on a supplied witness. First, any well-formed witness
induces a closed port-linear actualized graph (`portUseWitness_toGraph_closedPortLinear`) —
closedness is a consequence of the witness shape, not a separate check. Second, when a witness is
**aligned** with an admitted source object, the projection is exact in both directions: an instance
is an actualized port of the witness if and only if it is the projection of a source port of the
object (`compiledPortUseWitness_exact_output`, `compiledPortUseWitness_exact_input`). Nothing
appears at run time that was not declared, and nothing declared goes missing.

**Actualization preserves both layers.** When a latent select arm is chosen, its body is
instantiated and overlaid into the running circuit. The mechanized preservation statement is
conditional and we state its hypotheses plainly: if the current actualized graph and the selected
fragment's graph are each closed port-linear, and the current graph's ports are disjoint from the
selected fragment's nodes, then the overlay is closed port-linear
(`selectActualize_preserves_closedPortLinearity`). The disjointness hypotheses are discharged in
practice by the freshness discipline of admission — selected bodies are namespaced away from the
live graph — but that discharge is part of the certification story (§5), not of this theorem.

**The trust seam, stated.** Alignment is a _compiler-supplied_ witness: the theorems above say that
aligned witnesses have exact projections and closed actualized graphs, not that the compiler always
produces aligned witnesses. Producing and checking alignment is an executable correspondence
obligation, tracked openly (§4), and it is precisely the kind of obligation the certification
architecture of §5 is designed to make testable.

## 4. Metatheory: What Is Proved, and at What Strength

Every formal claim in this paper is one of four kinds: a **core theorem** (mechanized over the core
calculus or a carrier for it), an **elaboration corollary** (mechanized acceptance of a derived
form), an **implementation check** (an executable, tested gate), or an **open correspondence
obligation** (stated, tracked, not claimed). The table gives each claim with the Lean declarations
that carry it and — just as deliberately — the column saying what remains assumed or open. All
declarations live in the project's public mechanization (Appendix A); the development has **no
axioms and no incomplete proofs**, with 28 of 28 dashboard claims mechanized and 19 of 28 carrying
executable Haskell correspondence, as of 2026-06-10.

| Claim (this paper's notation)                                                                                 | Mechanized as                                                                                                                                                                           | What remains assumed or open                                                                                                                                               |
| ------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Theorem 1: core composition preserves port linearity                                                          | `overlay_preserves_portLinear`, `contract_preserves_portLinear`, `bulkContract_preserves_portLinear` over the source linear-port carrier                                                | The interpretation of typing derivations as certified carrier constructions is stated on paper (§3.5); the interpretation itself is not a Lean theorem                     |
| Corollary 1: admitted source forms preserve port linearity                                                    | `Make.accept_portLinear`, `MakeEach.accept_portLinear`, `Star.accept_portLinear`                                                                                                        | Acceptance quantifies over an abstract injective naming policy and caller-supplied per-child frontiers; the compiler's concrete instantiation is tested, not proved        |
| Lowering equations: overlay homomorphic; connect inserts the matched relation; lowered graphs endpoint-closed | `forgetPorts_overlay`, `forgetPorts_bulkContract`, `forgetPorts_edgeEndpointsInVertices`; relation algebra incl. `connect_decomposition` at relation, denotational, and quotient levels | Nothing open at this layer (proof-only facts; no runtime analog claimed)                                                                                                   |
| E-Select source admission: key coverage and provenance                                                        | `admitClause_entries_keys_eq_shape` (admitted entries' keys are exactly the sum's arm keys), `admitClause_fromClause` (each entry ties to its source arm)                               | The exclusive-sum shape itself is supplied by the compiler's boundary resolution — tested correspondence, not a derived object                                             |
| Select actualization: lowering, exclusion, preservation, recovery                                             | `selectActualize_lowers_to_appendAfter`, `selectActualize_unselected_not_in_selectedFragment`, `selectActualize_preserves_closedPortLinearity`, `selectedBranch_recovery_deterministic` | Preservation's disjointness hypotheses are discharged by namespace freshness in practice — that discharge is a correspondence obligation; durable lineage decoding is open |
| Two-layer projection exactness (§3.7)                                                                         | `compiledPortUseWitness_exact_output`, `compiledPortUseWitness_exact_input`, `portUseWitness_toGraph_closedPortLinear`                                                                  | `AlignedWith` is a compiler-supplied witness; producing and independently checking alignment is open executable correspondence                                             |
| Boundary resources: one-slot epochs, law families                                                             | `rewriteSlot_spent_at_most_once` with the proof-relevant `SlotUniqueTrace`; `substitution_preserves_boundary`, `appendContinuation_preserves_boundary` per rewrite family               | The three law families are mechanized per rewrite kind; a unified boundary-law algebra is not; executable epoch production is open                                         |
| Graded budgets: five-dimensional cost, fit, chain monotonicity                                                | `consume_le`, `ConstructedPlanningChain.finalBudget_le_initial`, `selectActualize_consumes_selected_cost`                                                                               | No completeness claim for the five dimensions; runtime budget accounting is tested, not proved                                                                             |
| Rewrite admission soundness (planner checks imply abstract admissibility)                                     | `planGraphRewriteChecks_admissible`, `runtimePlannerConstruction_admissible`                                                                                                            | Field-by-field runtime witness production is open                                                                                                                          |

Two absences are stated rather than implied. There is **no unified dynamics theorem**: nothing
mechanized says "every admitted run step preserves Theorem 1's invariant at both layers" — the
closest results are the per-step preservation theorems above, and unifying them is named future
work, not background assumption. And the **compiler is engineered, not extracted**: the Lean proves
models and contracts; the Haskell is held to them by the tested and gated correspondence machinery
of §5, which reduces — but does not eliminate — trust in the compiler.

## 5. Executing Admitted Diagrams

This section is deliberately outside the core calculus: the calculus is the contribution, and the
runtime story is evidence that the typed object is executable, durable, and certifiable.

### 5.1 Dynamics, imported

Execution over an admitted diagram — its open frontier, if any, supplied at entry ports and
discharged at exit ports by the runtime — is a two-level operational story, and both levels are
developed and mechanized in companion work; this paper imports them by citation rather than
re-proving. Within fixed topology, the runtime is a staged pure reduction — commutative accumulation
of node-local facts, idempotent failure closure, deterministic lifecycle classification — whose
structural recovery safety and replay determinism are mechanized in the staged-reduction paper. At
admitted boundaries, topology evolves by budgeted, vertex-anchored substitution and by
selected-branch actualization, with the admission, budget, exclusion, and recovery theorems of §4.
The two levels alternate: reduce within a topology, substitute at its admitted boundaries, reduce
again. What does not yet exist is the single theorem composing the two levels with linearity — the
open obligation named in §4 — and until it does, the dynamics remain an application of the calculus
rather than part of its metatheory.

### 5.2 The certifying admission boundary

The compiler does not merely emit circuits; it emits a proof-shaped **admission artifact** alongside
every circuit compiled on the Wire source path, and the architecture makes that artifact trustworthy
in three independently checkable steps.

First, **artifact-internal validity** is decided by mirrored executable contracts: a validator in
the compiler's language and an independent checker in the proof assistant (`validatorReadyCheck`),
with a soundness theorem (`validatorReadyCheck_soundness`) packaging acceptance into the
proof-facing contract from which reconstruction theorems recover the witnesses the metatheory
consumes — replay frames for primitive composition, provenance for generated forms, latent-admission
shape for selects, bulk-replay evidence for adapters.

Concretely, the artifact is pure data with no proof terms: a summary of the admitted diagram (its
node rows, raw connections, and open boundary) together with a replay trace of the composition steps
that built it, plus one evidence row per derived-form instance — which children a generation
produced and from which static items, which leaf endpoints an adapter crossed, which arms a select
admitted under which resolution. Internal validity means the summary and the trace agree: the
checker replays the recorded steps and requires the result to match the summary exactly, so an
artifact cannot claim a diagram its own history does not rebuild.

Second, **artifact-to-circuit correspondence is compiler-enforced by a structural binding check**: a
compilation on this path cannot succeed unless the artifact it attaches describes exactly the
circuit it travels with — schema, node set, the node-level projection of its connections rebuilding
the circuit topology, the derived entry/exit boundary, exact metadata embedding, and the select rows
replaying the condition-node tree. Mutation tests cover every error constructor — fourteen in all —
on both the artifact and the circuit side: mutate a valid artifact against its unchanged circuit, or
the circuit against its unchanged artifact, and compilation is refused.

Third, **what remains trusted is stated**. The binding check ties values, not provenance: it does
not prove the compiler emitted the artifact it validated, and circuits constructed outside this
compile path are not gated. Nor does the proof-assistant checker yet run on compiler output as part
of the build — its first emitted-artifact fixture is hand-transcribed, and automating that
transcription is tracked, open work. This architecture sits strictly between proof-carrying code and
translation validation: no proof terms travel with the artifact, and no recompilation or semantic
re-execution occurs — the compiler emits structured evidence, mirrored contracts validate it, and a
structural check binds it to the executable object. Each of the three steps is independently
testable, which is the practical point: drift between proofs, compiler, and runtime becomes a
failing check rather than a latent divergence.

### 5.3 Implementation surface

The calculus is implemented end to end. Wire's compiler carries the admission and binding machinery
above; a command-line interface compiles, checks, and formats programs; and Pulse, the durable
runtime, journals execution and replays runs against the admitted diagram, so provenance queries
resolve to named nodes and typed edges. An example corpus exercises the calculus across data
pipelines, build systems, planners, and dashboards (Appendix A).

The corpus's quantum examples deserve their own sentence, because they are evidence for the calculus
rather than decoration. A delayed-choice quantum-eraser experiment is authored in the same language
with no quantum-specific rules and was executed on physical quantum hardware. Qubit-carrying ports
are linear resources, so the fan-out rejection of §3.3 is exactly the static error that copying a
qubit-typed port would require, and gate application order is enforced by the same typed frontiers
that order workflow effects. This is a structural correspondence with the no-cloning discipline, not
a quantum-semantics theorem — no formal semantics of gates is claimed — but it is a striking one: a
single port-linear language spans durable workflows and quantum circuit description because both are
causal diagrams over unforgeable resources.

## 6. Related Work

**Interaction nets and port-graph formalisms — the nearest neighbors, addressed first.** The
port-linearity discipline itself is inherited lineage. Interaction nets [\[18\]](#ref-18), arising
from proof-net reduction [\[19\]](#ref-19), already give agents with typed ports, each port incident
to at most one edge, free ports forming the open interface, and copying and erasing routed through
explicit agents — precisely the no-implicit-copy, named-fan-out discipline this calculus enforces,
and we claim none of it as new. The deltas are elsewhere. Interaction nets are a reduction system:
their content is the rewrite relation on active pairs, and their edges are drawn by the author. Here
there is no reduction at the source layer — composition is admission of a static object — and edges
are not drawn but **computed**: keyed connect induces them from typed port keys, with unmatched
endpoints carried as live boundary resources, so that source expressions compose as frontier
transformers. And no formalism in this family has the calculus's third leg, the single admitted
referent with its certifying boundary (§5.2). Bigraphs [\[20\]](#ref-20) are the adjacent account of
graph-based reactive systems with typed interfaces and composition; they carry reaction rules and a
nesting structure this calculus lacks, and lack its linearity invariant and admission/replay
correspondence. Wiring diagrams and their operads [\[21\]](#ref-21) compose boxes with typed ports
along wiring patterns — the purest prior account of typed-port composition — but a wire there may
split; the prohibition of splitting, and partial carrying composition computed per key, are exactly
this calculus's departures.

**Algebraic graphs.** Mokhov's algebra of graphs [\[2\]](#ref-2), and its application to build
systems [\[3\]](#ref-3), supplies the four-constructor skeleton this calculus inherits — empty,
vertex, overlay, connect. The delta is precise and theorem-shaped. Vertices carry named, typed
ports, and connect changes meaning: Mokhov's connect adds the full cross-product of edges between
operands, while $\Rightarrow$ adds one edge per uniquely matched port key and carries the rest. Two
algebraic consequences follow. Multiple compatible counterparts for one key are a static error
rather than a fan-out, and source-level distributivity of connect over overlay deliberately fails,
because distributing duplicates an operand and with it a port resource. Mokhov's laws are recovered
after admission by the forgetful lowering of §3.6 — overlay lowers homomorphically, connect lowers
to insertion of the matched endpoint relation — so the laws hold of the relation algebra in which
lowered graphs live, not of source expressions.

**Open graphs, cospans, and string diagrams.** Decorated cospans [\[4\]](#ref-4), graphical
languages for monoidal categories [\[5\]](#ref-5), and open-graph reasoning [\[6\]](#ref-6) give
composition-by-boundary its categorical home, and the frontier of §2 is recognizably such a
boundary. The differences are where the calculus earns its keep: the boundary is a multiset of
contract-and-label-keyed ports with admission obligations attached; composition is partial,
key-directed, and carrying rather than total gluing along a chosen interface; and the composite is
not only a categorical object but the executable artifact a durable runtime schedules and replays,
with linearity discharged by a mechanized check rather than by construction in a chosen category.
The sharpest contrast is with string-diagram rewrite theory over hypergraph categories
[\[22\]](#ref-22): there, copying and sharing are obtained through Frobenius structure. This
calculus deliberately omits ambient copy and delete at the source level — copying must be
represented by a named node — so a categorical semantics would have to model key-directed partial
composition **without** the comonoid structure the calculus rejects. That, precisely, is the open
semantic question, and it is sharper than a generic appeal to future work.

**Linear logic and linear types.** The structural-rule vocabulary is inherited from linear logic and
proof nets [\[7\]](#ref-7), [\[8\]](#ref-8) and from linear type systems [\[9\]](#ref-9), but the
calculus uses a deliberately restricted fragment: exchange holds definitionally (the frontier is a
multiset; source order survives only in diagnostics), weakening is absent (no operation discards a
resource), and contraction is never ambient — it requires an explicit node consuming one endpoint
and producing fresh ones, which is what turns the type discipline into a provenance semantics. There
is no exponential modality and no cut-elimination claim; linearity here governs diagram admission,
not proof reduction.

**Session types.** Latent branch families are the nearest relative of labeled choice in session
types [\[10\]](#ref-10), [\[11\]](#ref-11): an exclusive output sum offers variants, exactly one of
which is taken. The deltas are durability and the rewrite reading. Selection is not a step of a
process protocol but a budgeted append rewrite into a durable graph, with mechanized exclusion of
unselected bodies and recovery determinism — the same selection replays from persisted admission.
There is no duality story and no channel discipline; arms converge to a common downstream boundary
instead of continuing a dialogue.

**Graded and quantitative types.** The five-dimensional rewrite budget of §4 — added nodes, edges,
depth, frontier width, rewrite operations — is a coeffect-like grading [\[12\]](#ref-12) on
structural change rather than on variable use: each dimension names a distinct scarcity, and the
mechanized facts are per-step fit and chain-level monotonicity. We make no claim that the five
dimensions are complete, and no cross-dimension trade theory is developed.

**Certifying compilation.** The admission boundary of §5.2 sits between proof-carrying code
[\[13\]](#ref-13) and translation validation [\[14\]](#ref-14). PCC ships proof terms with the code;
here no proof terms travel — the artifact is structured evidence, and proof obligations are
reconstructed from accepted artifacts on the proof-assistant side. Translation validation re-checks
each compilation semantically; here nothing is re-executed — mirrored executable contracts validate
the artifact, and a structural binding check ties it to the emitted object, with the residual trust
stated (values, not provenance). The architecture trades the strength of those guarantees for
independent testability of each step.

**Durable execution.** Temporal [\[15\]](#ref-15), Azure Durable Functions [\[16\]](#ref-16), and
Restate [\[17\]](#ref-17) journal and replay workflow execution, recovering effective topology from
runtime behavior; tracing standards reconstruct causal DAGs from spans after the fact. The
relationship here is inverted: topology is authored, admitted, and typed before execution, and
replay and provenance refer to the admitted diagram. Lamport's partial-order view of distributed
execution [\[1\]](#ref-1) is the common ancestor; this calculus turns it into an authoring
discipline with a linearity theorem.

## 7. Conclusion

The paper's object is small: four typing rules over typed port frontiers, one linearity invariant,
and a forgetful lowering into the algebra of graphs. Everything else is discipline about how to grow
from that object without diluting it — derived forms as certified elaborations so the core never
grows; a metatheory table that grades every claim as core theorem, elaboration corollary,
implementation check, or open obligation; an execution and certification story that makes the gap
between proofs and compiler testable instead of rhetorical. The deliberate law failure — no source
distributivity — and the deliberate absence — no ambient contraction — are the contributions as much
as the theorems are: they are what make the admitted diagram a causal explanation rather than a
drawing. Open problems are stated where they live: a unified dynamics theorem composing reduction
and admitted substitution with linearity (§4), compiler-produced alignment witnesses for the
two-layer projection (§3.7), and a categorical statement of key-directed partial composition (§6).
The artifact — mechanization, compiler, runtime, and example corpus through to quantum hardware — is
public (Appendix A).

## References

1. <a id="ref-1"></a>Leslie Lamport. _Time, Clocks, and the Ordering of Events in a Distributed
   System_. Communications of the ACM 21(7), 1978.
2. <a id="ref-2"></a>Andrey Mokhov. _Algebraic Graphs with Class (Functional Pearl)_. Haskell
   Symposium, 2017.
3. <a id="ref-3"></a>Andrey Mokhov, Neil Mitchell, Simon Peyton Jones. _Build Systems à la Carte_.
   ICFP 2018.
4. <a id="ref-4"></a>Brendan Fong. _Decorated Cospans_. Theory and Applications of Categories
   30(33), 2015.
5. <a id="ref-5"></a>Peter Selinger. _A Survey of Graphical Languages for Monoidal Categories_.
   Lecture Notes in Physics 813, 2011.
6. <a id="ref-6"></a>Lucas Dixon, Ross Duncan, Aleks Kissinger. _Open Graphs and Computational
   Reasoning_. EPTCS 26, 2010.
7. <a id="ref-7"></a>Jean-Yves Girard. _Linear Logic_. Theoretical Computer Science 50(1), 1987.
8. <a id="ref-8"></a>Vincent Danos, Laurent Regnier. _The Structure of Multiplicatives_. Archive for
   Mathematical Logic 28(3), 1989.
9. <a id="ref-9"></a>Philip Wadler. _Linear Types Can Change the World!_ Programming Concepts and
   Methods, 1990.
10. <a id="ref-10"></a>Kohei Honda, Vasco T. Vasconcelos, Makoto Kubo. _Language Primitives and Type
    Discipline for Structured Communication-Based Programming_. ESOP 1998.
11. <a id="ref-11"></a>Kohei Honda, Nobuko Yoshida, Marco Carbone. _Multiparty Asynchronous Session
    Types_. POPL 2008.
12. <a id="ref-12"></a>Tomas Petricek, Dominic Orchard, Alan Mycroft. _Coeffects: A Calculus of
    Context-Dependent Computation_. ICFP 2014.
13. <a id="ref-13"></a>George C. Necula. _Proof-Carrying Code_. POPL 1997.
14. <a id="ref-14"></a>Amir Pnueli, Michael Siegel, Eli Singerman. _Translation Validation_.
    TACAS 1998.
15. <a id="ref-15"></a>Temporal Technologies. _Temporal_. <https://temporal.io>
16. <a id="ref-16"></a>Microsoft. _Azure Durable Functions_.
    <https://learn.microsoft.com/en-us/azure/azure-functions/durable/>
17. <a id="ref-17"></a>Restate. _Restate_. <https://restate.dev>
18. <a id="ref-18"></a>Yves Lafont. _Interaction Nets_. POPL 1990.
19. <a id="ref-19"></a>Yves Lafont. _From Proof Nets to Interaction Nets_. In Advances in Linear
    Logic, Cambridge University Press, 1995.
20. <a id="ref-20"></a>Robin Milner. _Bigraphical Reactive Systems: Basic Theory_. Technical Report
    UCAM-CL-TR-523, University of Cambridge, 2001.
21. <a id="ref-21"></a>Dmitry Vagner, David I. Spivak, Eugene Lerman. _Algebras of Open Dynamical
    Systems on the Operad of Wiring Diagrams_. Theory and Applications of Categories 30(51), 2015.
22. <a id="ref-22"></a>Filippo Bonchi, Fabio Gadducci, Aleks Kissinger, Paweł Sobociński, Fabio
    Zanasi. _String Diagram Rewrite Theory III: Confluence with and without Frobenius_. Mathematical
    Structures in Computer Science, 2022.

## Appendix A: Artifact

The implementation and mechanization are public in the Cortex repository
(<https://github.com/Digimuoto/cortex>). The Lean development lives under `theory/Cortex/` (graph
algebra, port linearity and the actualized bridge, generated forms and phantom adapters, select
admission and recovery, boundary resources and budgets, admission artifacts); the declaration names
cited in §3-§4 resolve there, and the generated documentation and the proof-status dashboard — the
per-claim grading this paper's counts are drawn from, as of 2026-06-10 — are published from the same
sources. The compiler and runtime live under `src/` (the binding check of §5.2 is
`Cortex.Wire.AdmissionBinding`, enforced in the compile path), with the Wire command-line interface
under `app/wire/`. The example corpus referenced in §5.3 lives under `examples/wire/`, including the
dashboard pipeline, the build-system examples, and the quantum experiments; the quantum-eraser run
on IBM hardware is reported, with its job identifier and reproduction notes, in the companion
causal-programming paper.
