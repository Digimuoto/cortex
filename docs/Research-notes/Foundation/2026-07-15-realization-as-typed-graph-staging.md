---
title: "Research Memo: Realization as Typed Graph Staging"
description:
  "Examines @realize as a typed post-admission staging boundary: fragment selection, canonical
  folding, target-language lowering, build and execution, and its relationship to CorePure and pure
  Wire fragments."
date: 2026-07-15
scope: foundation
status: active
related:
  - docs/ADRs/0021-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0050-wire-corepure-output-residue.md
  - docs/ADRs/0053-executor-catalog-manifests-and-pulse-bindings.md
  - docs/ADRs/0059-durable-external-call-frontiers-on-pulse.md
  - docs/ADRs/0078-lean-wire-elaboration-kernel.md
  - docs/ADRs/0079-wire-admission-witness-schema.md
  - docs/ADRs/0096-certified-native-pure-region-compilation.md
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/pure-execution.md
  - docs/Consumers/Quantum.md
---

# Research Memo: Realization as Typed Graph Staging

**Method:** cross-repository implementation reading and architectural synthesis **Confidence
profile:** high on the current Wire/CorePure/Circuit and CortexQC implementation; medium on the
proposed generic realization IR and quotient lowering; speculative on native-code realization,
nested realization, and the final proof architecture.

---

## Proposed implementation outcome

ADR 0096 proposes the memo's admitted-Circuit referent, strict typed boundary, normalized domain
plan, realization witness, and constructive compiler-spine recommendations for NativePure. Issue
#382 tracks the implementation: maximal eligible pure regions become witnessed quotient units, while
the broader cross-domain staging-role model, authored or nested boundaries, build/bind protocol, and
general quotient-realizer API remain research directions.

## Context

The quantum `@realize` path began as a practical answer to one backend problem: a graph of symbolic
quantum gates should become one provider request rather than one Pulse stage per gate. The current
CortexQC implementation compiles ordinary Wire, identifies the upstream data ancestry of a selected
`@quantum.realize` node, validates that region, folds it into a backend-neutral `QuantumPlan`,
lowers that plan to OpenQASM, and executes it through a Braket binding. ADR 0059 describes the
corresponding substrate design as a pure frontier contraction feeding one effectful collect stage.

That mechanism now appears to be more general than its first use. The same shape could compile a
typed service topology into systemd units, a pure Wire fragment into Rust or Haskell, a query graph
into SQL, or a hardware graph into a device program. The important object is not the target
language. It is the explicit boundary at which one admitted causal region changes semantic domain
while the surrounding Wire graph continues normally.

This memo asks five questions:

1. Is realization fundamentally a compilation phase?
2. What exact phases occur between Wire source and execution?
3. Can a realized fragment lower to a compiled language such as Rust or Haskell?
4. What should happen when the selected fragment is pure Wire/CorePure computation?
5. How can realization preserve Cortex's single-admitted-referent, closed-authority, durability, and
   proof boundaries?

The answer developed here is:

> **Realization is a typed graph-staging protocol.** It includes a compiler pass, but it is not
> merely code generation and not merely an executor call. It selects an explicitly delimited region
> of an admitted Circuit, folds that region into a canonical domain plan, optionally lowers and
> builds that plan into a target artifact, contracts the region to its realization boundary for
> runtime execution, and returns typed results to ordinary Wire.

A compact pipeline is:

```text
residualize -> select -> fold -> lower -> build -> bind -> execute -> re-enter
```

Several of these steps are deterministic compiler work. Build, binding, and execution may require
host authority. Keeping those phases distinct is the central design recommendation of this memo.

## Method

The investigation read the following implementation and design surfaces together:

- `src/Cortex/Wire/Pure.hs` and `src/Cortex/Capability/Executor/Pure.hs` — CorePure evaluation,
  static/runtime residue, and the current one-pure-node-to-one-Pulse-stage path.
- `src/Cortex/Wire/Circuit/Compiled.hs`, `src/Cortex/Wire/Circuit/Compiler.hs`, and
  `src/Cortex/Wire/Circuit/Lowering.hs` — the compiled Circuit carrier and the current
  one-node-to-one-stage lowering seam.
- `docs/ADRs/0021-wire-source-elaborates-to-circuits.md` and
  `docs/ADRs/0050-wire-corepure-output-residue.md` — maximal static reduction and the fixed
  post-elaboration topology boundary.
- `docs/ADRs/0053-executor-catalog-manifests-and-pulse-bindings.md` — build artifacts, ABIs, binding
  records, implementation identity, and why source does not name Rust- or Haskell-specific build
  authority.
- `docs/ADRs/0059-durable-external-call-frontiers-on-pulse.md` — the intended pure contraction plus
  effectful collector architecture.
- `extensions/quantum/src/Cortex/Quantum/Plan.hs` and the extracted equivalents in
  `Digimuoto/cortex-qc` — the current compiled-circuit frontier walker and `foldM` into
  `QuantumPlan`.
- `docs/ADRs/0078-lean-wire-elaboration-kernel.md` and
  `docs/ADRs/0079-wire-admission-witness-schema.md` — the certifying elaboration and
  admission-artifact boundaries that realization must not bypass.
- `docs/Publications/Paper-7-frontier-calculus/manuscript.md` — the single admitted referent,
  certified elaborations, port linearity, and the distinction between source operators and lower
  graph algebras.

No external literature pass was performed. The note is intentionally a repository-grounded
architectural synthesis rather than a prior-art claim.

## Executive answer

### Yes: realization contains a compilation phase

The current quantum implementation already behaves like a compiler pass:

```text
CompiledCircuit
  -> select the typed upstream region of @realize
  -> canonical topological fold
  -> QuantumPlan
  -> OpenQASM
```

However, calling the whole mechanism "the compilation phase" hides three different compilers:

1. **Wire elaboration compiler** — source, forms, static CorePure, and graph composition become one
   admitted `CompiledCircuit`.
2. **Domain realization compiler** — one selected typed Circuit fragment becomes a domain plan and
   then target source or target IR.
3. **Target build compiler** — Rust, GHC, a QASM toolchain, Nix, or another builder turns target
   source/IR into a runnable or deployable artifact.

Those compilers have different trust, caching, compatibility, and authority requirements. The first
is part of Wire. The second belongs to a registered realizer family. The third belongs to a build
binding/toolchain. Pulse should execute the result without pretending that all three are one opaque
executor callback.

### No: realization is not only compilation

A complete realization also decides:

- which graph region is captured;
- whether that region is admissible for one realizer;
- which boundary values remain runtime parameters;
- how source nodes map to a fused runtime stage;
- which target artifact and toolchain identity are frozen into compatibility;
- which host authority may build or execute the artifact;
- how results re-enter the outer graph;
- how provenance relates the result back to every contracted source node.

Compilation is the pure center of the mechanism. Realization is the protocol around it.

## Finding 1 — `@realize` is a typed graph-staging boundary, not an ordinary leaf executor

**Status:** inferred from ADR 0059 and observed in CortexQC. **Primary evidence:**
`docs/ADRs/0059-durable-external-call-frontiers-on-pulse.md`,
`extensions/quantum/src/Cortex/Quantum/Plan.hs`, `Digimuoto/cortex-qc/src/Cortex/Quantum/Plan.hs`.

An ordinary executor consumes values presented on its input ports. A realization boundary consumes
more than those values: its meaning depends on an upstream region of topology. The region is
selected from the admitted Circuit, checked as a unit, and interpreted under a domain algebra. Only
after that interpretation does the boundary behave like a normal runtime stage.

This gives `@realize` two roles:

1. **Static role:** delimit and classify a graph fragment for a realizer.
2. **Runtime role:** consume the resulting frozen plan/artifact and produce the declared output
   contracts.

The source spelling can remain an executor-looking `@` application because the boundary names a
registered capability and eventually reaches host authority. Its semantics should nevertheless be
represented explicitly in catalog metadata and lowering rather than treated as an ordinary 1:1 task
node.

A useful classification is:

```text
ordinary node          executes directly as one stage
symbolic node          contributes semantics to a selected realization fragment
realization boundary   selects/contracts a fragment and becomes its runtime stage
```

This is a staging-role axis, not a new executor kind and not the existing side-effect axis. A
symbolic quantum gate may denote an eventual host effect while still being inert as an individual
Pulse stage. Conversely, a pure native-code realizer may stage only pure nodes while the build
process itself is host-effecting. `pure | model | host_effect | impure` cannot express that
distinction by itself.

A future admission projection could therefore carry data resembling:

```toml
[realization]
role = "symbolic"                 # direct | symbolic | boundary
family = "quantum.circuit/v1"
```

and the boundary projection:

```toml
[realization]
role = "boundary"
family = "quantum.circuit/v1"
```

The exact manifest schema is an ADR question. The architectural point is that **effect class answers
what execution may do; realization role answers whether a node executes directly or is staged into a
larger unit**.

## Finding 2 — The right phase order is residualize, select, fold, lower, build, bind, execute

**Status:** synthesis. **Primary evidence:** ADRs 0021, 0050, 0053, and 0059.

The recommended phase model is:

| Phase                    | Input                               | Output                                           | Authority                      |
| ------------------------ | ----------------------------------- | ------------------------------------------------ | ------------------------------ |
| Wire elaboration         | Wire source                         | admitted `CompiledCircuit C` + admission witness | none                           |
| CorePure residualization | CorePure equations                  | static values or delayed pure nodes in `C`       | none                           |
| Fragment selection       | `C` + realization boundary `r`      | certified fragment `H_r`                         | none                           |
| Domain fold              | `H_r`                               | canonical domain plan `P_r`                      | none                           |
| Target lowering          | `P_r`                               | target source/IR `S_r`                           | none when deterministic        |
| Build                    | `S_r` + pinned toolchain            | built artifact `A_r`                             | host build authority           |
| Binding                  | `A_r` + runtime policy/capabilities | runtime binding record                           | host authority                 |
| Quotient lowering        | `C`, `H_r`, boundary `r`            | runtime plan where `H_r` is represented by `r`   | none after binding data exists |
| Execution                | bound realization stage             | output envelopes or suspension/failure           | backend authority              |
| Re-entry                 | realization outputs                 | ordinary downstream Wire/Pulse work              | ordinary runtime rules         |

The ordering matters.

First, CorePure maximal static reduction must precede realization. Otherwise the realization
compiler could choose whether to preserve a known value as code, violating ADR 0021's rule that
static reduction is mandatory rather than optional.

Second, selection must operate on the admitted Circuit and its port evidence, not on unresolved
source syntax. That keeps realization tied to the same object used by execution, replay, provenance,
and the proof-facing admission artifact.

Third, the domain fold should precede target-language generation. `QuantumPlan`, `SystemPlan`, and a
future `NativePurePlan` are useful semantic objects independent of OpenQASM, systemd text, Rust, or
Haskell. This permits multiple target backends, a reference interpreter, plan-level validation, and
stable plan digests.

Fourth, build must be a separately identified phase. Emitting Rust source is deterministic compiler
work; invoking `rustc` or Cargo is a host action with a toolchain, filesystem, resource policy, and
supply-chain identity. The generated program may be pure even though producing its executable is not
an authority-free operation.

## Finding 3 — Runtime realization is a quotient of the admitted Circuit, not a replacement referent

**Status:** proposed architectural model. **Primary evidence:** ADR 0059's contraction model and
Paper 7's single admitted referent.

Let:

- `C` be the admitted Circuit;
- `r` be one realization boundary node;
- `H_r` be the selected set of symbolic nodes feeding `r`;
- `P_r = fold_R(H_r)` be the canonical domain plan;
- `A_r = build_T(lower_T(P_r))` be an optional target artifact.

The runtime projection contracts `H_r` into the existing boundary node `r`:

```text
q_r : C -> C / H_r
```

where `r` remains the typed replacement boundary and carries the realization artifact/binding. From
the outer graph's perspective, the many nodes in `H_r` become one causal event at `r`.

The original Circuit must remain the admitted and provenance referent. The quotient is a runtime
projection with a witness back to `C`, not a new source truth. This avoids a serious architectural
failure: if realization rewrote the only stored Circuit in place, source typing and proof admission
would refer to one graph while execution and provenance referred to another with no governed bridge.

A realization artifact should therefore record at least:

```text
schema version
source Circuit compatibility digest
source admission-artifact digest
realization boundary node ref
selected node and typed-edge set
selected external input/output boundary
realizer family and version
canonical domain-plan digest
target language / target ABI
target source or IR digest
build/toolchain identity and artifact digest, when built
runtime binding identity
quotient-stage identity
selection, boundary, and compatibility check results
```

This is a sibling contract to `WireAdmissionArtifact`, not a replacement for it. The admission
artifact says the original Wire graph is admitted. The realization artifact says a particular
certified region of that graph was transformed into a particular plan/artifact and represented by a
particular runtime stage.

## Finding 4 — Fragment selection must be port-aware and witness-producing

**Status:** observed implementation gap and proposed generalization. **Primary evidence:**
`CompiledCircuit` stores a node-level relation; the quantum walker re-derives port matches from task
metadata and predecessors; `WireAdmissionArtifact` already carries richer connection and boundary
evidence.

`CompiledCircuit.compiledCircuitTopology` is a relation over node references. Parallel typed port
connections between the same two owners collapse at that level. A generic realizer cannot safely
select or prove a fragment from the node relation alone because realization depends on:

- the exact input port that drew each producer into the region;
- contracts and labels;
- boundary inputs that remain frozen runtime parameters;
- internal outputs consumed by the boundary;
- any outputs crossing from the selected region to the rest of the Circuit;
- endpoint linearity and ownership.

CortexQC currently compensates by decoding every selected task node's port metadata and resolving
each input against predecessor outputs. That is a valid downstream prototype, but it duplicates a
graph fact the compiler already knew.

A generic API should consume port-level admission evidence and return a certified carrier:

```haskell
selectRealizationFragment
  :: WireAdmissionArtifact
  -> CompiledCircuit
  -> CircuitNodeRef
  -> Either RealizationError CertifiedRealizationFragment
```

with a shape conceptually like:

```haskell
data CertifiedRealizationFragment = CertifiedRealizationFragment
  { crfBoundaryNode      :: CircuitNodeRef
  , crfNodes             :: Set CircuitNodeRef
  , crfTypedConnections  :: Set TypedConnection
  , crfExternalInputs    :: Set PortInstance
  , crfExternalOutputs   :: Set PortInstance
  , crfRealizerFamily    :: RealizerFamily
  , crfSelectionWitness  :: SelectionWitness
  , crfAdmissionDigest   :: Digest
  }
```

`CompiledCircuitFragment` is a useful nearby carrier: it already records entry nodes, exit nodes, a
node relation, and node definitions for latent condition branches. It is not yet a sufficient
realization carrier because it lacks a typed crossing frontier, exact port connections, a realizer
family, and a selection witness. The generic design should extend that shape rather than confuse a
node-level fragment with a certified typed fragment.

Selection should be explicit and decidable. A conservative v1 can require:

1. Every captured node declares the same realizer family expected by `r`.
2. Every path between two captured nodes remains inside the captured set; a non-family node may not
   intervene.
3. Every edge entering the set is represented as a typed external input/frozen parameter.
4. Every edge leaving the set is represented by the realization boundary's declared output, or the
   fragment is rejected.
5. The contraction preserves endpoint linearity.
6. Multiple selected fragments in one Circuit are pairwise disjoint.
7. The quotient remains acyclic.

Condition 2 is a causal-convexity requirement. Conditions 3 and 4 are boundary preservation. They
make it possible to prove that replacing `H_r` with `r` neither invents dependencies nor silently
drops facts.

Nested realization should be deferred until it has explicit innermost-first semantics. Arbitrarily
overlapping regions are not a reasonable first implementation.

## Finding 5 — `foldw` should be a fold over certified frontiers, not merely a list traversal

**Status:** inferred from the quantum implementation and Wire's frontier semantics.

CortexQC currently obtains a deterministic lexicographic Kahn topological order and applies `foldM`
over the selected nodes. This is a strong prototype: it rejects cycles, gives reproducible plans,
and threads symbolic values through port bindings.

The generic abstraction should expose the deeper structure:

```haskell
foldRealizedFragment
  :: Realizer plan
  -> CertifiedRealizationFragment
  -> Either RealizationError plan
```

Operationally, this can still use Kahn frontiers:

```text
ready frontier F0
  -> interpret all nodes in F0
  -> extend typed value/plan environment
  -> expose ready frontier F1
  -> ...
```

The fold state may contain:

- symbolic values associated with typed output ports;
- the domain plan under construction;
- target-independent resource allocation;
- source-to-plan provenance;
- canonical ordering information;
- accumulated domain validation evidence.

The mathematical distinction matters. A chosen topological order is a deterministic serialization of
a DAG; it is not by itself a proof that independent nodes commute. A realizer should do one of two
things:

1. define a frontier/product algebra in which independent interpretations commute, then prove plan
   equivalence under valid topological orders; or
2. define one canonical order as part of the target semantics and include that order in the plan
   identity.

Quantum currently chooses the second route. A future `foldw` can retain canonical ordering while
making same-frontier structure explicit, which is especially useful for systemd, build graphs, and
native-code scheduling.

There is also a representation caveat. A catamorphism over the original Wire expression tree and a
topological fold over `CompiledCircuit` are not the same operation. The compiled artifact currently
retains graph topology, not the original `<>`/`=>` syntax tree. The generic realization API should
therefore be honest: it is initially a **certified DAG/frontier fold**. Calling it a syntax
catamorphism would overstate what the carrier preserves.

## Finding 6 — Realizing to Rust or Haskell is coherent, but generated code must remain an artifact

**Status:** proposed extension compatible with ADR 0053.

ADR 0053 already supports executors implemented in Rust, Haskell, WASM, subprocesses, or other
package formats. That is the existing case:

```text
executor author writes Rust/Haskell
  -> build system produces an implementation artifact and manifest
  -> host binding registers the artifact
  -> Wire names the pre-registered executor id
```

Realizing a Wire fragment into Rust or Haskell is a different staging case:

```text
Wire fragment
  -> NativePurePlan or another domain plan
  -> generated Rust/Haskell source
  -> pinned compiler/toolchain
  -> content-addressed executable/library/module
  -> generic realization binding executes it
```

The generated artifact must not mint new ambient authority. The registered authority remains the
realizer/binding that is permitted to build or load generated artifacts. The generated program
should receive only its declared input envelopes and should produce only candidate output envelopes.
Any filesystem, network, environment, clock, randomness, FFI, or process access is an authority
increase unless the realizer explicitly declares, binds, and isolates it.

This suggests the following invariant:

> **Target generation may specialize implementation, but it may not amplify the authority admitted
> for the selected fragment.**

For a pure fragment, the target artifact should be a function of declared inputs and frozen config.
For an effectful domain, the artifact may describe or invoke effects only through the realizer's
already-registered binding policy.

### AOT should be the default

For Rust and Haskell, the default path should be ahead-of-time realization during `wire build` or an
explicit build command:

```text
static admitted fragment
  -> canonical plan digest
  -> target source digest
  -> toolchain/build digest
  -> executable artifact digest
```

Runtime input values become function arguments; they do not change program shape. This preserves the
fixed post-elaboration topology and makes build products cacheable and compatibility-checkable.

Runtime JIT is possible, but it is a materially different executor: it requires compiler authority
at run time, writable build storage, resource limits, sandboxing, cache policy, and replay rules. It
should be an explicit binding mode rather than an accidental consequence of `@realize`.

### Rust and Haskell have different useful roles

A Haskell backend is attractive as a readable reference lowering because Cortex and the CorePure
evaluator already live in Haskell. It could generate a module exposing a canonical envelope function
and serve as a golden output for plan/code inspection.

A Rust backend is attractive as an independent, portable native-code target and can demonstrate that
realization is not just evaluator self-hosting. It also forces the semantic contract to become
language-neutral.

The architecture should not commit to either language in the realization core. Both should lower
from the same target-neutral plan. A practical implementation sequence is:

1. canonical `NativePurePlan` plus a reference interpreter;
2. a source renderer useful for human inspection and golden tests;
3. one built backend, likely Rust or Rust-to-WASM for a constrained ABI;
4. a second backend as a differential test of the plan semantics.

### Emit, build, and run are distinct products

One source spelling may eventually make the common path concise, but the internal products should
stay separate:

```text
emit:   CertifiedFragment -> DomainPlan -> TargetSource
build:  TargetSource + Toolchain -> BuiltArtifact
run:    BuiltArtifact + Inputs + Binding -> Outputs
```

That separation permits source-only inspection, reproducible offline builds, deployment without
execution, target compilation caching, and provenance that identifies which phase failed.

## Finding 7 — CorePure and pure Wire are related but not identical

**Status:** observed canon plus proposed terminology.

There is no current canonical `PureWire` type. Cortex has **CorePure**, the deterministic expression
language used inside pure node output equations. The compiler evaluates statically known CorePure at
elaboration time and lowers input-dependent residue to one internal native pure task per source pure
node.

For this memo, **pure Wire fragment** is a proposed descriptive term:

> A typed Circuit fragment whose node semantics are deterministic and authority-free, whose graph
> shape is already fixed, and whose contracts and operations are supported by a selected pure
> realizer.

CorePure is node-local value computation. A pure Wire fragment is graph-level composition of one or
more pure nodes. That distinction is essential:

```text
CorePure expression       value IR inside one node
pure Wire fragment        typed causal graph of pure nodes
NativePurePlan            fused realization IR for that fragment
Rust/Haskell/WASM source  one possible lowering of NativePurePlan
```

### Realization sees residual CorePure

ADR 0021 requires maximal static reduction before runtime. Therefore a pure realizer should see:

- constants already folded into metadata or baked values;
- only input-dependent CorePure residue as executable computation;
- a fixed typed graph and boundary.

This is a clean partial-evaluation pipeline:

```text
source CorePure
  -> mandatory static reduction
  -> residual CorePure nodes
  -> cross-node graph fusion
  -> target code
```

The native pure evaluator remains the reference semantics. Realization is an optional optimized
lowering of the same residue, not a competing definition of CorePure.

### Pure nodes may be internal or frozen parameters

A domain realizer should not automatically absorb every pure ancestor. For example, a pure node
might calculate a quantum rotation angle from ordinary inputs. Two valid implementations exist:

1. execute the pure node normally and pass its result as a frozen boundary parameter to the quantum
   realization; or
2. let the quantum realizer absorb the pure node only if that realizer explicitly implements the
   relevant CorePure subset and target semantics.

The safe default is the first. ADR 0059 already permits frozen boundary inputs and does not treat
them as cross-authority violations. Absorption should be an explicit realizer capability, not a
generic "walk all ancestors" rule.

For the native pure realizer itself, CorePure nodes are the symbolic family, so it can capture and
fuse them across node boundaries.

### Semantic preservation is the central theorem

For a pure fragment `H`, target compiler `T`, and any contract-valid input environment `x`, the
desired property is approximately:

```text
decode(run(build(lower_T(fold(H))), encode(x)))
  = evaluatePureFragment(H, x)
```

The equality must account for both successful values and typed deterministic failures. Runtime
provenance/envelope metadata may differ while payload and failure semantics agree.

A real proof or differential oracle must cover details that are easy to dismiss as implementation
noise but are semantically load-bearing:

- finite `Float64` division and non-finite rejection;
- integer bounds and bounded-iteration caps;
- canonical JSON and object-key ordering;
- the fixed total order used by `sort`/`sortBy`;
- record merge behavior;
- string indexing and Unicode/code-point rules;
- typed input binding and repeated-contract label rules;
- all-or-nothing output production;
- output contract validation.

The existing evaluator should remain available even after native realization lands. It provides a
portable fallback, a small trusted semantic oracle, and differential tests against every generated
backend.

## Finding 8 — Realizing into Wire is possible, but it creates a second admission boundary

**Status:** inferred from graph-form, rewrite, and admission canon.

A realizer may produce another Wire fragment. This is attractive for system deployment:

```text
symbolic service topology
  -> fold to SystemPlan
  -> lower to a Wire deployment program
  -> write units <> validate units
  -> reload
  -> start
  -> inspect
```

There are two semantically different cases.

### Pre-admission generated Wire

If all inputs are source-static, a derived form may elaborate to ordinary Wire before admission.
That is the graph-form model: generated topology erases to the existing core and then passes through
normal admission. It is not runtime realization and should not need `@realize`.

### Post-admission realization to Wire

If an admitted realization fragment produces new Wire based on the selected Circuit or runtime
parameters, the output must be compiled and admitted as a **new Circuit**. It cannot be silently
spliced into the original admitted graph. The runtime choices are:

- invoke the newly admitted Circuit as a typed child run;
- admit it through the existing rewrite/materialization boundary;
- return it merely as an artifact for later review/deployment.

In every case the generated Wire goes through ordinary elaboration, closure checks, an admission
artifact, and compatibility binding. A realizer is not a back door around the five-constructor core
or the rewrite budget.

This produces a useful hierarchy:

```text
parent admitted Circuit
  -> realize symbolic region to Wire source/IR
  -> compile and admit child Circuit
  -> run child through typed child-run or rewrite authority
  -> return child result to parent
```

## Finding 9 — The current implementation is a valid prototype, but the generic seam belongs before 1:1 Pulse binding

**Status:** observed.

`lowerCompiledCircuitInternal` currently traverses every `CompiledCircuitNode`, binds each one to a
`StageDefinition`, and carries the same node-level topology into the `StagePlan`. That is the
natural seam for generic realization:

```text
CompiledCircuit
  -> realize/contract selected fragments
  -> bind remaining direct nodes and realization boundaries
  -> StagePlan
```

CortexQC currently runs its fragment selection and fold in downstream runner code before driving the
generic external-call lowering. That was the right way to prove the extension model without teaching
Cortex quantum semantics. The general machinery that has emerged from it is substrate-neutral:

- explicit realization-boundary discovery;
- port-aware fragment selection;
- selection witnesses;
- canonical frontier folding;
- quotient topology production;
- realization artifact binding.

Those pieces can move into a generic Cortex library while `QuantumPlan`, gate semantics, OpenQASM,
Braket authority, and QEC remain entirely downstream.

The migration should preserve the current runnable path until the generic artifact and quotient
checks are equally strong. This memo does not recommend moving quantum semantics upstream.

## Formal model

A minimal formalization can separate selection, interpretation, target lowering, and contraction.

Let an admitted typed Circuit be:

```text
C = (N, E, Phi, W)
```

where `N` is the node set, `E` the typed port-edge set, `Phi` the external frontier, and `W` the
admission/compatibility witness material.

For a realization boundary `r`, selection produces:

```text
select(C, r) = H_r
```

where `H_r` is a typed subgraph with an explicit crossing boundary. A realizer family `R` defines:

```text
fold_R : CertifiedFragment_R -> Plan_R
```

and target backend `T` defines:

```text
lower_T : Plan_R -> TargetIR_T
build_T : TargetIR_T -> Artifact_T
```

The runtime contraction is:

```text
contract_r(C, H_r, Artifact_T) = C / H_r
```

with `r` as the replacement node.

The primary obligations are:

### Selection soundness

Every selected node and edge exists in the admitted Circuit, has the required realizer role/family,
and is included according to the explicit port-ancestry rule.

### Boundary preservation

All crossing inputs are retained as declared frozen inputs, and all crossing outputs are represented
by the realization boundary's output ports. No typed obligation is invented, duplicated, or dropped.

### Port-linearity preservation

Contracting the selected internal endpoints and re-exposing the declared realization outputs
preserves endpoint accounting. This is the generic counterpart of ADR 0059's
`external_call_collect_preserves_portLinear` obligation.

### Quotient acyclicity

If `C` is acyclic and `H_r` satisfies the convexity/boundary conditions, `C / H_r` is acyclic.

### External causal preservation

For nodes outside `H_r`, reachability through the selected region is represented by reachability
through `r`. No new ordering relation appears between unrelated external nodes, and no existing
external causal path disappears.

### Fold canonicality

The same admitted fragment, realizer version, and frozen static inputs produce the same canonical
plan and digest. If the fold permits multiple ready-frontier orders, either their results are proven
equivalent or one canonical order is part of the semantics.

### Target semantic preservation

Executing the built target artifact agrees with the domain-plan reference semantics at the typed
boundary. For pure Wire this is evaluator equivalence; for quantum it is plan-to-OpenQASM
correctness plus result decoding; for systemw it is a refinement/conformance relation between the
intended service plan and the realized unit graph.

### Authority non-amplification

Selection, fold, and deterministic target emission introduce no authority. Build and execution use
only the explicitly selected toolchain and binding authorities. Generated target code cannot
exercise capabilities absent from those bindings.

### Compatibility and replay stability

The realization plan, target artifact, toolchain, binding policy, and source Circuit identity are
included in compatibility. Resume never silently rebuilds or selects a different artifact unless a
recorded policy explicitly permits it.

### Provenance completeness

Every realization result identifies the selected source nodes, domain plan, target artifact,
realizer/backend versions, binding authority fingerprints, and runtime attempt. Contracted nodes do
not disappear from explanation merely because they are no longer individual stages.

## Proposed internal surface

The smallest useful generic surface is not a universal code generator. It is a certified fragment
and a realizer protocol:

```haskell
newtype RealizerFamily = RealizerFamily Text
newtype RealizerVersion = RealizerVersion Text

data RealizationRole
  = DirectNode
  | SymbolicNode RealizerFamily
  | RealizationBoundary RealizerFamily

data Realizer plan target = Realizer
  { realizerFamily       :: RealizerFamily
  , realizerVersion      :: RealizerVersion
  , foldFragment         :: CertifiedRealizationFragment -> Either RealizationError plan
  , canonicalPlan        :: plan -> CanonicalBytes
  , lowerTarget          :: plan -> Either RealizationError target
  }

data RealizedCircuit = RealizedCircuit
  { rcSourceCircuit         :: CompiledCircuit
  , rcRuntimeTopology       :: Relation CircuitNodeRef
  , rcRealizationArtifacts  :: Map CircuitNodeRef RealizationArtifact
  }
```

The real implementation will need existential packaging for heterogeneous plan/target types,
registry lookups, target-independent canonical envelopes, and binding integration. The important
division is:

- Cortex owns selection, certification, contraction, artifact identity, and runtime mapping.
- The downstream realizer owns domain node semantics and the domain plan.
- The target backend owns plan-to-target lowering.
- The build binding owns toolchain invocation and artifact production.
- The runtime binding owns execution authority and output decoding.

## Open questions

### Is the realization boundary included in the selected fragment?

The current quantum walker selects upstream nodes and excludes the `@realize` node; the boundary
then becomes the runtime collector. That is the clean default. A formal carrier should still include
the boundary signature and its incoming typed edges in the selection witness.

### What is the exact selection rule?

"All ancestors" is too broad. Selection should follow only input-port producers whose nodes declare
the required realizer family, stopping at legitimate frozen inputs. The admission projection needs
enough staging metadata for this to be decidable without backend-specific name matching.

### Can one realization consume several disconnected components?

Quantum `@realize` may collect several qubit chains that meet only at the collector. This should be
allowed when the selected region is one typed forest/frontier under the same realizer and the fold
provides a coherent plan. Connectedness is therefore less important than common boundary, family,
and domain admissibility.

### How are nested realizations ordered?

A plausible rule is innermost first: an inner realization becomes an opaque typed node/artifact
before an outer selection runs. This needs explicit compatibility and provenance composition. V1
should reject overlap and nesting rather than infer an order.

### Where does build occur?

Build-time AOT is the recommended default. Some deployments may build on a remote builder or target
host; the realization artifact must then record builder identity and output digest. Runtime JIT
needs a separate authority/policy decision.

### Does a built pure fragment become an executor manifest?

Probably not one manifest per generated fragment. The fragment should be a content-addressed
artifact owned by a pre-registered generic native-realization binding. Minting a fresh catalog
executor id for every realization would conflate program identity with authority identity and cause
catalog churn.

### Which target should the first pure prototype use?

Haskell minimizes semantic distance and is useful as a reference renderer. Rust demonstrates a truly
language-neutral plan and gives a practical portable artifact. WASM may provide a cleaner
constrained runtime ABI. The decision should follow a small spike after `NativePurePlan` exists
rather than shape the plan around one language prematurely.

### How does target compilation interact with Lean?

Near term, keep the existing CorePure evaluator as the semantic oracle and use differential tests
over generated target programs. Longer term, formalize `NativePurePlan` and prove the
CorePure-to-plan lowering, then verify or validate target-specific compilation separately. An
end-to-end verified Rust or Haskell compiler is not required to make the realization boundary
proof-bearing, but the exact strength of every claim must remain explicit.

### Is `@realize` the right generic source name?

The name fits the semantic phase change unusually well. The generic mechanism should nevertheless be
identified by catalog metadata rather than a hard-coded executor id. Domains may export
`@quantum.realize`, `@systemw.realize`, or a more specific alias while sharing the same substrate
protocol.

## Recommendations

### 1. Record a dedicated ADR for typed realization fragments and quotient lowering

The ADR should decide one thing: an explicitly marked realization boundary may select a certified
same-family typed fragment, fold it through a registered downstream realizer, and contract it to the
boundary for runtime lowering while preserving the original Circuit as the admitted referent.

It should govern selection, port boundary, disjointness, artifact identity, quotient checks, and the
new staging-role metadata axis. It should not standardize quantum, systemd, Rust, or Haskell
semantics.

### 2. Extract a generic port-aware selector from the CortexQC prototype

Start from the proven behavior in `Cortex.Quantum.Plan`, but make the selector consume admission
connection evidence rather than re-derive typed edges from node metadata. Keep the quantum fold in
CortexQC.

A first test corpus should include:

- one linear symbolic chain;
- several independent chains collected by one boundary;
- frozen input parameters;
- a non-family node intervening inside the would-be region;
- an escaping output not represented by the boundary;
- mixed realizer families;
- two disjoint realization boundaries;
- overlapping/nested boundaries rejected;
- a contraction that would create a quotient cycle rejected or proven impossible by the premises.

### 3. Introduce realization role/family as metadata separate from effect class

Do not infer symbolic nodes from executor-name prefixes. Do not add a third node executor kind. The
admission projection should explicitly say whether a node is direct, symbolic, or a realization
boundary and which realizer family owns it.

### 4. Define and version `RealizationArtifact`

Bind it to both the admission artifact and the compiled Circuit. Include selected typed connections,
boundary, plan digest, target/build identity, quotient mapping, and runtime binding identity. Add a
structural binding check analogous to `admissionArtifactBindsCompiledCircuit`.

### 5. Insert realization before ordinary 1:1 Circuit-to-Pulse binding

The lowering flow should become:

```text
CompiledCircuit
  -> discover/select/fold realization fragments
  -> produce witnessed quotient runtime topology
  -> bind direct nodes and realization boundaries
  -> StagePlan
```

Pulse remains unaware of domain semantics. It receives ordinary bound stages plus richer provenance
mapping.

### 6. Build a `NativePurePlan` reference implementation

Use the currently supported CorePure AST and exact evaluator semantics. Initially support a strict,
explicit subset and reject anything outside it. Interpret the plan in-process first. Then add one
source backend and one built backend.

Keep the existing native pure evaluator as fallback and oracle. Differential tests should compare:

- payload outputs;
- typed failure class and details;
- contract validation behavior;
- deterministic plan and artifact digests.

### 7. Treat generated Rust/Haskell as content-addressed implementation artifacts

Do not mint source-level authority or a fresh executor id per fragment. Build through pinned
tooling, record source/toolchain/output digests, and bind the result through one registered
realization capability. Default to AOT. Make runtime compilation an explicit future binding mode.

### 8. Preserve phase separation even if the CLI offers one command

A command may eventually run:

```sh
wire build --realize native-rust program.wire
wire pulse run program.wire
```

or combine them ergonomically, but the data model should always retain the domain plan, target
source, build artifact, binding, and runtime attempt as separate identities.

## Research conclusion

`@realize` is deeper than a quantum collection trick because it supplies the missing boundary
between a typed causal graph and a domain compiler.

Wire already provides the necessary ingredients:

- a finite, admitted, endpoint-typed graph;
- maximal static CorePure reduction and explicit runtime residue;
- closed executor authority;
- a versioned admission witness;
- durable runtime binding and replay;
- explicit graph contraction/rewrite laws;
- downstream packages that own domain semantics.

Realization composes those ingredients into a general staging architecture:

```text
Wire source
  -> admitted Circuit
  -> certified realized fragment
  -> canonical domain plan
  -> target source / IR
  -> optional built artifact
  -> witnessed quotient stage
  -> durable execution
  -> typed re-entry into Wire
```

For quantum, the target is OpenQASM and a Braket task. For systemw, it may be systemd units or a
Wire deployment Circuit. For a pure Wire fragment, it may be a generated Rust, Haskell, or WASM
function. The target changes; the realization protocol does not.

The strongest formulation is therefore:

> **Realization is a typed, witnessed phase change of an admitted graph region.** The region remains
> explainable as source topology, becomes optimizable as a domain plan, becomes executable as a
> target artifact, and returns to the surrounding graph through one declared contract boundary.

That is compiler architecture, graph contraction, capability binding, and durable execution meeting
at one explicit node.

## Related

- `docs/ADRs/0021-wire-source-elaborates-to-circuits.md`
- `docs/ADRs/0050-wire-corepure-output-residue.md`
- `docs/ADRs/0053-executor-catalog-manifests-and-pulse-bindings.md`
- `docs/ADRs/0059-durable-external-call-frontiers-on-pulse.md`
- `docs/ADRs/0078-lean-wire-elaboration-kernel.md`
- `docs/ADRs/0079-wire-admission-witness-schema.md`
- `docs/Architecture/05-wire-language.md`
- `docs/Reference/Wire/pure-execution.md`
- `docs/Publications/Paper-7-frontier-calculus/manuscript.md`
- `docs/Consumers/Quantum.md`
