---
title: "Research Memo: Wire IO Types and Type Safety Sweep"
description: Research sweep on Wire input/output contracts, LLM-facing type understanding, Haskell-owned contract registries, and the type-safety boundary for autonomous rewrites
date: 2026-04-15
status: proposed
related:
  - DIG-482
  - DIG-488
  - DIG-490
  - DIG-495
  - DIG-498
  - DIG-499
  - docs/Reference/terminology.md
  - docs/Research-notes/Wire/archive/2026-04-15-wire-v1-grammar-prototype.md
  - docs/Roadmap/Plans/topology-aware-artifact-projections.md
  - docs/Research-notes/Wire/2026-04-15-wire-syntax-and-bounded-autonomous-rewriting.md
---

# Research Memo: Wire IO Types and Type Safety Sweep

**Date:** 2026-04-15  
**Scope:** Wire input/output contracts, endpoint compatibility, LLM rewrite safety, payload typing, and the boundary between Haskell-owned authority and Wire source syntax  
**Artifacts examined:** `src/Cortex/Wire/{AST,Parser,Compiler,Contracts}.hs`, `src/Portman/Workflow/WireEnv.hs`, `test/Cortex/WireSpec.hs`, `config/cortex/workflows/{deep-report,quant-spreadsheet-smoke-v1}.wire`, Wire terminology and grammar docs, topology-aware projection research doc, issues `DIG-482`, `DIG-488`, `DIG-490`, `DIG-495`, `DIG-498`, `DIG-499`  
**Method:** Cross-reference synthesis over current implementation, docs, and issue track  
**Confidence profile:** High for current implementation behavior; medium for recommended syntax refinements; medium-low for longer-range contract/projection evolution because payload typing is not implemented yet.

---

## Executive Summary

Wire is moving in the right direction. The important design decision is not the exact glyph choice; it is the split between homogeneous graph edges and endpoint-owned compatibility. Edges say "these nodes are connected." Input and output ports say whether that connection is legal.

The current implementation gives Wire a real first layer of type safety, but it is nominal topology safety, not full payload safety. A contract such as `AnalysisFragment` is currently a compatibility label. It does not by itself define a JSON schema, field projection, Haskell codec, or exact active-context shape.

The right next move is therefore not to put a full type language into `.wire`. Haskell should own contract definitions, codecs, schemas, projections, executor/tool authority, and LLM-facing documentation. Wire should reference registered contract IDs and compose registered nodes through compatible ports.

For autonomous rewriting, this is a strong model. An LLM can safely propose new topology if it can only use a closed vocabulary of nodes and registered endpoint contracts. Type bounds constrain what it may connect; gas bounds constrain how much topology it may add.

The latest clarification is that "projection" should not be an edge-level
selector. In the useful case, a planner emits a typed plan with N work items,
then proposes a bounded rewrite that instantiates N workers from registered
node shapes. Each worker gets local config and/or a work-item payload. Workers
emit homogeneous fragments and an aggregator consumes the stream. The mutable
part is the plan/config/payload. The stable type boundary is still
`WorkItem -> WorkFragment`.

This pattern generalizes beyond report sections:

| Domain | Planner output | Worker input | Worker output | Aggregator |
| --- | --- | --- | --- | --- |
| Report generation | `ReportPlan` | `SectionBrief` | `ReportFragment` | `FinalReport` writer |
| Trading | `TradePlan` | `TradeIntent` | `ApprovedTradeIntent` / `OrderDraft` | risk gate / order router |
| Coding | `WorkPlan` | `WorkItem` | `PatchFragment` / `ReviewFinding` | patch integrator |
| Incident response | `IncidentPlan` | `InvestigationTask` | `FindingFragment` | incident commander |
| Research | `ResearchPlan` | `ResearchQuestion` | `EvidenceFragment` | synthesis writer |

---

## Key Findings

### [P1] Endpoint-owned compatibility is the central design, and it is correct

**Category:** Missed Abstraction  
**Status:** Observed  
**Confidence:** High  
**Primary evidence:** `Cortex.Wire.AST`, `Cortex.Wire.Compiler`, `Cortex.Wire.Contracts`, Wire terminology doc, `DIG-482`  
**Cross-reference:** `EndpointRef`, `WireInputPort`, `WireOutputPort`, `resolveConnectionEndpoints`, "Endpoint Compatibility" in `docs/Reference/terminology.md`

The strongest idea in the current design is that edges remain homogeneous. A graph connection does not carry an operation, selector, projection, argument position, or schema. It is just dependency topology.

Meaning lives on endpoints:

```wire
planner :
  -> PlannerOutput
= { executor = native "planner"; };

analyst :
  <- PlannerOutput
  -> AnalysisFragment
= { executor = native "analyst"; };

circuit deep_report =
  planner => analyst;
```

The compiler resolves the unqualified edge by looking for a source output contract compatible with a sink input port. This keeps the graph algebra simple and keeps rewrites mechanically checkable.

**Why it matters:**  
If edges carry selectors or operations, an LLM rewire proposal becomes semantic code generation. With endpoint-owned compatibility, an LLM proposal is just topology over a closed vocabulary. That is the right safety envelope.

**Next step:**  
Make "endpoint compatibility, not typed edges" the central contract rule in the Wire v1 docs and in the future LLM rewrite prompt/catalog.

### [P1] Current Wire types are nominal contract labels, not payload schemas

**Category:** Correctness Gap  
**Status:** Observed  
**Confidence:** High  
**Primary evidence:** `WireInputPort { wireInputPortAccepts :: [Text] }`, `WireOutputPort { wireOutputPortContract :: Text }`, `validatePorts`, `Portman.Workflow.WireEnv`  
**Cross-reference:** `DIG-488`, `DIG-490`, topology-aware artifact projections memo

The current type-safety story is real but limited. Wire checks that an upstream output contract label appears in a downstream input port's accepted label set. It does not check that the runtime payload contains particular fields or that the JSON value can decode into a Haskell data type before the run starts.

Today, a contract name answers:

```text
Can these endpoints connect?
```

With the first registry seam, a contract can now also carry documentation, example payloads, and optional schema metadata. It still does not answer:

```text
What exact payload shape flows?
Which fields enter active context?
Which Haskell codec validates this value?
Which projections are available?
```

This distinction explains the current hand-wavy feeling. We now have registry-backed type labels for topology and LLM-facing documentation, but not full payload semantics.

**Why it matters:**  
Without this distinction, Wire can sound more type-safe than it is. It prevents certain invalid graph shapes, such as feeding `ReportFragment` to a node expecting `AnalysisFragment`, but it does not yet prove payload-level correctness.

**Next step:**  
Keep `ContractId` as the first layer. Extend the registry from docs/schema metadata into Haskell codecs and projection metadata when payload-level safety becomes the next target.

### [P1] Haskell should own contracts; Wire should reference them

**Category:** Design Tension  
**Status:** Inferred  
**Confidence:** High  
**Primary evidence:** `DIG-490`, `DIG-495`, `Portman.Workflow.WireEnv`, topology-aware artifact projections memo  
**Cross-reference:** "Haskell registers authority; Wire composes authority" in `DIG-495`

The safest near-term rule is:

```text
Haskell registers authority.
Wire composes authority.
```

That should apply to:

- native executors
- LLM tools
- REST-backed tools
- launch/preflight inputs
- contract IDs
- payload codecs
- named projections
- node templates available for rewrites

Wire source should not define arbitrary new payload schemas, REST calls, executor authority, or tool authority in v1. It should reference stable IDs from registries controlled by Haskell and product/domain modules.

**Why it matters:**  
Autonomous rewrites are only safe if the LLM cannot expand the authority surface while it rewires topology. It should be able to connect registered nodes, not mint new capabilities.

**Next step:**  
Make `DIG-490` and `DIG-495` the contract/capability boundary blockers before full LLM-authored rewrites. Introduce a generic Cortex registry seam, with DeepReport/Portman registering the first concrete contract family.

### [P1] The LLM needs a vocabulary catalog, not just syntax

**Category:** Correctness Gap  
**Status:** Inferred  
**Confidence:** High  
**Primary evidence:** `DIG-478`, `DIG-482`, current Wire compiler diagnostics, current `portsMetadataValue` metadata  
**Cross-reference:** LLM-proposed Wire rewires issue, Wire epic success criteria

A model cannot safely infer what `PlannerOutput`, `AnalysisFragment`, or `OptionsQuantInput` mean from names alone. The LLM needs an explicit vocabulary catalog generated from the same registries the compiler uses.

The catalog should include at least:

```json
{
  "nodes": [
    {
      "id": "quant_spreadsheet",
      "description": "Builds spreadsheet-backed quant evidence.",
      "inputs": [{"port": "in", "accepts": ["PlannerOutput"]}],
      "outputs": [{"port": "out", "contract": "AnalysisFragment"}],
      "tools": ["refreshSpreadsheetPrices", "recalculateQuantSpreadsheet"]
    }
  ],
  "contracts": [
    {
      "id": "PlannerOutput",
      "description": "Planner request decomposition and workflow setup data.",
      "examples": ["tickers, thesis text, requested stress dimensions"]
    }
  ],
  "graphSyntax": {
    "operators": [
      {
        "operator": "=>",
        "semantics": "bipartite_connect",
        "description": "Connect every exit endpoint on the left to every entry endpoint on the right. Not zip semantics."
      }
    ]
  }
}
```

For rewrites, the model should see "these are the legal nodes and contracts" and then emit only a small Wire graph fragment.

**Why it matters:**  
Compile-and-retry can fix syntax errors, but it cannot reliably fix conceptual misuse if the model lacks contract descriptions. The model needs the same boundary vocabulary humans use.

**Next step:**  
Add a `WireVocabulary` or `WireCatalog` serialization layer that is derived from the node, contract, and capability registries. Feed it to LLM rewrite nodes and use compiler errors for retry.

### [P1] Repeated anonymous `<-` clauses currently mean alternatives, not product inputs

**Category:** Correctness Gap  
**Status:** Observed  
**Confidence:** High  
**Primary evidence:** `portsFromSignature` in `Cortex.Wire.Parser`, v1 workflow files, `Portman.Workflow.WireEnv`  
**Cross-reference:** `deep-report.wire`, `analystPorts`, `genericAnalysisPorts`

The current v1 signature syntax lowers repeated input clauses into one default input port:

```wire
analyst :
  <- EvidenceBundle
  <- ConditionPassthrough
  -> AnalysisFragment
= { executor = native "analyst"; };
```

This becomes:

```text
in.accepts = [EvidenceBundle, ConditionPassthrough]
in.cardinality = many
in.required = true
```

That means "this default input port accepts either contract, and can receive many inbound edges." It does not mean "this node requires both a gatherer output and a condition passthrough."

This is useful for compatibility with current workflows, but it is semantically easy to misread. Outputs behave differently: multiple anonymous `->` clauses become multiple output capabilities.

**Why it matters:**  
The most likely future bug is an author or LLM writing multiple `<-` clauses expecting product requirements. The compiler will accept the source, but it will enforce only "at least one inbound edge to the default input port."

**Next step:**  
Document this asymmetry immediately. Then add v1.1 syntax for named/product inputs rather than overloading anonymous repeated `<-`.

### [P1] Wire needs explicit syntax for stable named channels without freezing topology

**Category:** Missed Abstraction  
**Status:** Inferred  
**Confidence:** Medium  
**Primary evidence:** existing `WirePorts` supports named input/output maps, but v1 signature syntax only exposes anonymous contract clauses  
**Cross-reference:** `WirePorts`, `validateNodeInputPorts`, topology-aware artifact projections memo

The underlying data model supports named input ports with independent `required` and `cardinality` settings. That machinery is useful, but the source-language semantics should not make named inputs required by default. A Wire signature should describe capability first; the realized graph and runtime value stream decide how many values actually arrive.

The syntax should distinguish:

```wire
# Alternatives on one input port
<- [EvidenceBundle ConditionPassthrough]

# Stable named channels for executor roles
<- evidence: EvidenceBundle
<- repair: ConditionPassthrough

# Future binding policy, exact spelling TBD
<- required model: spreadsheet_model
<- quant?: AnalysisFragment
<- sections*: ReportFragment
```

The exact glyphs are less important than preserving the semantic distinction:

- union input: one port accepts any of several contracts
- named channel: a stable semantic slot for an executor role
- fan-in input: one port accepts many values of compatible contracts
- product/required input: a future binding policy, not the default signature meaning

**Why it matters:**  
Agent-authored topology needs unambiguous type feedback without turning node definitions into fixed graph shapes. "This node can accept many report fragments" and "this node requires a model plus prices" are different claims. If the surface syntax cannot express that, the LLM will eventually wire a graph that is topologically legal but semantically underfed or unnecessarily rigid.

**Next step:**  
Keep current anonymous `<- Contract` as capability sugar. Use named input clauses only for stable executor roles. Put hard required/product semantics behind an explicit future binding policy.

### [P2] Output capability sets are useful, but they are not yet independent typed channels

**Category:** Evidence Gap  
**Status:** Observed  
**Confidence:** Medium  
**Primary evidence:** `portsFromSignature`, `resolveSourceEndpointCandidates`, `compileNode`, stage metadata  
**Cross-reference:** Wire syntax and bounded autonomous rewriting memo

Multiple `->` clauses currently compile to multiple output ports when there is more than one output contract:

```wire
planner :
  -> AnalyzerInput
  -> OptionsQuantInput
= { executor = native "planner"; };
```

This lets an unspecified edge resolve by compatibility:

```wire
planner => (analyst, quant);
```

That is a good abstraction for rewrites: the planner has latent output capabilities, and the circuit chooses which successors to connect.

But execution still needs careful wording. In the current runtime, a node generally completes with one stage result payload and metadata, not necessarily separately transported per-port values with independent Haskell codecs. The output ports are compatibility capabilities first.

**Why it matters:**  
If we describe output capability sets as true independent channels too early, we will overpromise. The current value is in legal topology selection. True multi-channel artifact transport belongs to the typed artifact/projection work.

**Next step:**  
Document output capabilities as "contracts offered by this node" rather than "separate materialized payload channels" until the artifact store and binding/projection model exists.

### [P2] Ambiguous compatible endpoint resolution should become diagnosable, and probably rejected in strict mode

**Category:** Extension Risk  
**Status:** Observed  
**Confidence:** Medium  
**Primary evidence:** `resolveConnectionEndpoints` chooses the first compatible pair, output/input port maps are traversed by `Map.toList`  
**Cross-reference:** `WireNoCompatiblePorts`, `WirePortContractMismatch`

When an endpoint omits port names, the compiler gathers all source output candidates and all sink input candidates, then chooses the first compatible pair. This is convenient, but it can become surprising if two compatible pairs exist.

Example risk:

```wire
source :
  -> short_summary
  -> full_report
= { ... };

sink :
  <- summary: short_summary
  <- report: full_report
= { ... };

circuit x =
  source => sink;
```

If both pairs are compatible, unqualified `source => sink` may silently pick a deterministic but non-obvious edge interpretation.

**Why it matters:**  
LLM rewrites need compiler feedback that is strict enough to guide retry. "I guessed the first compatible pair" is less safe than "ambiguous edge, specify `.short_summary` or `.summary`."

**Next step:**  
Add a strict-mode diagnostic for multiple compatible endpoint pairs. Consider making ambiguity an error for LLM-authored rewrites while allowing legacy source to keep current permissive behavior.

### [P2] `JsonField` belongs in the binding/projection layer, not in the core edge type

**Category:** Design Tension  
**Status:** Inferred  
**Confidence:** High  
**Primary evidence:** topology-aware artifact projections memo, Wire terminology doc, current homogeneous-edge compiler  
**Cross-reference:** `DIG-488`, `DIG-490`

Field-level data such as `.valuation.forwardPe` or `metrics.return12m` is real and important, but it should not become an edge annotation in core Wire topology.

Bad direction:

```wire
planner.optionsJsonField => options_analyst;
```

Better direction:

```wire
options_analyst :
  <- options_section
  -> AnalysisFragment
= {
  executor = llm "model";
  bindings = {
    main = from planner.out use options_section;
  };
};
```

The edge remains "planner feeds options_analyst." The binding/projection layer determines which part of the persisted planner artifact becomes active context.

**Why it matters:**  
This preserves the homogeneous-edge invariant while still allowing precise data shaping. It also keeps selector semantics deterministic and Haskell-validated instead of letting the LLM invent field paths as topology.

**Next step:**  
Keep `JsonField` or JSON Pointer concepts out of the v1 graph grammar. Introduce named projections and small deterministic bindings as a later artifact-context slice.

### [P2] Type bounds and gas bounds are orthogonal and should stay orthogonal

**Category:** Novel Idea  
**Status:** Inferred  
**Confidence:** High  
**Primary evidence:** `DIG-482`, `DIG-499`, current Wire compiler checks, rewrite gas issue  
**Cross-reference:** Wire syntax and bounded autonomous rewriting memo

There are two different constraints on autonomous rewrites:

```text
Type bounds: what may connect?
Gas bounds: how much topology may change?
```

Type bounds are endpoint-contract checks. They reject semantically invalid edges even if the proposed graph is small.

Gas bounds are resource checks. They reject expensive or too-large topology edits even if every edge is type-compatible.

These should remain separate in implementation and diagnostics:

```text
Rejected: quant_spreadsheet => report_artifact
Reason: no compatible endpoint contracts.

Rejected: planner => (a, b, c, d, e, f, g)
Reason: fan-out width exceeds remaining gas.
```

**Why it matters:**  
Clear separation helps both humans and LLM retries. A type error should not be framed as budget exhaustion, and a budget rejection should not look like a contract mismatch.

**Next step:**  
When `DIG-499` defines gas diagnostics, include type/gas rejection categories explicitly in the LLM retry context.

---

## Current Safety Layers

| Layer | What it protects | Current status | Gap |
| --- | --- | --- | --- |
| Syntax safety | Source parses into Wire AST | Implemented in `Cortex.Wire.Parser` | Diagnostics can still improve for LLM retry |
| Vocabulary safety | Node refs must exist and be used | Implemented for declared nodes | Runtime rewire vocabulary admission still pending |
| Topology safety | DAG, connectedness, fragment lowering | Implemented in `Cortex.Wire.Compiler` | Rewire delta validation still pending |
| Port compatibility | Output contract must be accepted by input port | Implemented nominally with ambiguous endpoint rejection | Diagnostics can still improve for LLM retry |
| Cardinality/binding safety | Whether a runtime node got enough values for its executor role | Internal port model has required/cardinality fields | Source-level semantics should remain capability-first until binding policy is explicit |
| Contract registry safety | Contract IDs have payload kinds, docs/schema metadata/examples | Implemented via `WireContractRegistry` on `WireCompileEnv` | Codecs/projections still pending |
| Payload safety | Actual runtime payload decodes and validates | `WireValue` envelope type exists; Portman Wire binders wrap/unwrap envelopes at the StageAction boundary | Payload-kind validators and codecs still pending |
| Projection/binding safety | Downstream gets precise context slices | `WireInputBundle` groups envelopes by contract and producer; generic Wire analysis prompts include typed-input summaries | Deterministic projection codecs still pending |

---

## Recommended Contract Model

Wire should treat "type" as a layered concept rather than one overloaded thing.

| Name | Owner | Purpose |
| --- | --- | --- |
| `ContractId` | Cortex registry, populated by domain libraries | Nominal endpoint compatibility key |
| `ContractDoc` | Registry | LLM/human-facing explanation and examples |
| `ArtifactType` | Haskell/domain library | Full persisted producer payload type |
| `InputType` | Haskell/domain library | Semantic active-context shape for a consumer |
| `ContractCodec` | Haskell/domain library | Encoder/decoder/validator for runtime payloads |
| `Projection` | Haskell/domain library | Named mapping from artifact type to input type |
| `BindingPolicy` | Registry or registered template metadata | Deterministic selection/cardinality rules for projected source data |

The near-term rule should be:

```text
Wire signatures reference ContractIds.
Haskell registries define what those ContractIds mean.
Payload typing and projection typing are registry features, not arbitrary source syntax.
```

---

## LLM Rewrite Model

The strongest safe path for autonomous rewrites is:

1. Runtime serializes a Wire catalog from registries.
2. LLM sees available node instances or templates, their ports, contract docs, and remaining gas.
3. LLM emits a Wire graph fragment, not new Haskell authority.
4. Parser checks syntax.
5. Compiler checks node references, topology, endpoint compatibility, cardinality, and required ports.
6. Rewire admission checks gas/budget and convergence policy.
7. Runtime admits or rejects with structured feedback.

For v1, the LLM should be allowed to:

- connect existing nodes
- duplicate or instantiate from approved templates only if the template already declares fixed ports/tools/executor policy
- select among registered output/input ports by name

For v1, the LLM should not be allowed to:

- invent new contract IDs
- invent new payload schemas
- define new tools or REST calls
- grant a node new tools
- introduce unregistered executors
- attach arbitrary JSON selectors to edges

---

## Surface Syntax Notes

The current v1 syntax is good enough to implement and dogfood, but the type story wants one more syntax layer.

### Current v1

```wire
node_name :
  <- InputContract
  -> OutputContract
= {
  executor = native "executor";
};
```

Current anonymous input meaning:

```wire
<- A
<- B
```

means:

```text
default input port accepts A or B, cardinality many, required false
```

Current output meaning:

```wire
-> A
-> B
```

means:

```text
output capability A and output capability B
```

This asymmetry is acceptable as a transition, but it must be documented.

### Stable named channels

```wire
# One default input accepts alternatives
<- [EvidenceBundle ConditionPassthrough]

# Stable named executor channels, optional by default in signature syntax
<- evidence: EvidenceBundle
<- audit: AnalysisFragment

# Output capabilities, optionally named
-> PlannerOutput
-> quant: options_quant_input
```

This lets us explain the rules cleanly:

- brackets mean a value-level set of alternatives
- repeated named input clauses mean separate input ports
- repeated output clauses mean offered output capabilities
- graph `=>` connects fragments and resolves compatible endpoints
- explicit record-style ports are used when a named input slot must be required

---

## Evidence Gaps

| Claim | Current evidence | Missing evidence | Recommended validation |
| --- | --- | --- | --- |
| LLMs can reliably use nominal contracts if given a catalog | Strong design fit, `DIG-478` plan | No end-to-end compile-and-retry loop yet | Build a 2-3 node LLM rewire POC with structured compiler feedback |
| Contract registry can stay Haskell-owned without slowing authoring | `DIG-490`, `DIG-495`, existing `WireCompileEnv` | No generic registry abstraction yet | Extract DeepReport contract defaults behind a Cortex registry seam |
| Named/product input syntax is enough for complex nodes | Named signature syntax and explicit required-port tests exist | Runtime binding policy not implemented | Prototype binder behavior for required A+B vs A-or-B |
| Output capability sets are sufficient for first rewrites | `v1CapabilitySetSourceText` test | Runtime per-port artifact behavior not formalized | Keep first rewrite examples at compatibility-label level |
| Projections should not live on edges | Topology-aware projection memo | No projection implementation yet | Implement named projections as bindings before considering edge selectors |

---

## Design Tensions

### Nominal contracts vs structural schemas

Nominal contract IDs are simple and LLM-friendly. Structural schemas are stronger but heavier. The right near-term split is nominal IDs in Wire, structural/schema information in Haskell-owned registries.

### Coarse graph safety vs precise active context

The graph compiler should answer "is this topology legal?" The artifact/binding layer should answer "what does the downstream node actually see?" Combining those into edge syntax would make the core language too heavy.

### LLM flexibility vs authority control

The LLM should have freedom to rewire topology. It should not have freedom to define executors, tools, contracts, or REST calls. The closed vocabulary is the authority boundary.

### Capability signatures vs required product bindings

Anonymous `<- Contract` should mean "can receive values of this contract." Named ports should mean stable executor roles. Required product bindings need explicit policy. If signatures imply required topology by default, rewrites become unnecessarily rigid.

---

## Recommended Actions

### Act Now

- [x] Update Wire grammar docs to state that anonymous repeated `<-` clauses mean accepted alternatives on one default input port.
- [x] Add a note that current Wire contracts are nominal compatibility labels, not full payload schemas.
- [x] Add tests or docs for the asymmetry between repeated input clauses and repeated output clauses.
- [x] Align shorthand signature inputs with capability semantics by making them optional streams.
- [x] Add a node-local `config` hook for configured worker instances.

### Design Next

- [x] Define a `ContractId`/contract registry model owned by Cortex and populated by domain libraries.
- [x] Design initial named-channel input syntax for stable executor roles.
- [ ] Design explicit required/product binding policy syntax after runtime value binding exists.
- [x] Decide whether ambiguous compatible endpoint pairs should be an error in strict/LLM mode.
- [x] Specify the first LLM-facing Wire catalog generated from registered nodes and contracts.
- [x] Feed rewrite prompts with current topology, allowed templates, contracts, graph syntax, and remaining gas for the first append-style proposal path.

### Implement Next

- [x] Extract Portman/DeepReport concrete contract defaults behind the registry seam from `DIG-490`.
- [x] Add registry validation so Wire can reject unknown contract IDs when compiling in a registered environment.
- [x] Add payload kinds to contract specs and introduce typed `WireValue` envelopes.
- [x] Add binder-layer envelope wrapping for Portman Wire task and artifact nodes while keeping Pulse generic.
- [x] Add `WireInputBundle` grouping by contract/provenance and expose summaries to generic Wire analysis prompts.
- [x] Add structured rejection categories intended for LLM compile-and-retry.
- [ ] Keep `JsonField`/selector work in the projection/binding track, not core graph syntax.

### Parked

- Full user-defined type declarations in `.wire` - defer until Haskell-owned registries prove insufficient.
- Edge-level selectors or typed edges - keep rejected unless a concrete runtime transport need appears.
- Refundable gas - useful later, but should not block the contract/type safety track.

---

## Bottom Line

The language is leading in the correct direction if we keep one discipline:

```text
Wire is topology over registered authority.
Ports expose nominal compatibility contracts.
Haskell owns what those contracts mean.
LLMs receive a catalog and propose topology only.
Payload fields and projections live in a later binding layer, not on edges.
```

That gives us a credible type-safety story without turning Wire into a general-purpose type language too early. The immediate risk is not the graph syntax. The immediate risk is letting `ContractId` names carry more semantic weight than the compiler and runtime currently enforce.
