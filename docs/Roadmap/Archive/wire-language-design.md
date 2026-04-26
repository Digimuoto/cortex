---
title: "Wire/Circuit Language Design — Cortex Wire Definition Language"
description: Historical design roadmap for the Cortex durable workflow authoring surface. Current terminology uses Wire for source files and Circuit for assembled executable topology.
date: 2026-04-13
status: design-roadmap
related:
  - DIG-482 (PoC for full dynamic graph rewriting)
  - DIG-483 (typed workflow authoring layer)
  - DIG-484 (dogfood workflow design)
  - DIG-481 (StageIntent algebra)
  - docs/Research-notes/Foundation/2026-04-11-formalism-stack-synthesis.md
---

# Wire/Circuit Language Design

> Terminology update, 2026-04-15: the preferred source-language name is
> **Cortex Wire** and the preferred file extension is `.wire`. Existing `.cr`
> files remain compatibility input. In current terminology, Graph is the pure
> algebra layer, Wire is the authoring language, Circuit is the assembled
> executable unit, and Pulse is the runtime. See
> [Cortex Wire Terminology](./2026-04-15-cortex-wire-terminology.md).

This document is a **design roadmap**, not an implementation spec. It
distinguishes what exists today (Phase 1 anchor points) from what requires
new runtime work (Phase 2+). Sections are marked with their phase.

Shipped today, the concrete authoring surface is the narrower
`Cortex.Wire` v0 Wire format. That surface supports same-file
declarative `act` / `await` / `emit` nodes plus a single authored circuit, and
it compiles directly to `CompiledCircuit`. `.wire` is preferred; `.cr` remains
compatibility input. `Decide` remains circuit-level and future-phase; authored
rewrite syntax also remains future-phase.

## 1. Vocabulary (Phase 1)

The Cortex module namespace keeps the generic graph-runtime terms explicit:

| Term | What it is | Module |
|------|-----------|--------|
| **Graph** | Pure topology algebra (vertices, edges, DAG operations) | `Cortex.Graph` |
| **Wire** | Source language and file format for wiring predeclared nodes | `Cortex.Wire` |
| **Node** | Authored leaf unit with identity, role, contract, resources | `Cortex.Wire` declarations / `Cortex.Circuit` compiled nodes |
| **Circuit** | Validated executable topology: nodes plus compatible wires | `Cortex.Circuit` |
| **Pulse** | Temporal execution substrate — scheduling, frontier, checkpointing | `Cortex.Pulse` |
| **Memory** | Retrieval and grounding | `Cortex.Memory` |
| **Plasticity** | Structural change at runtime (rewriting, collapsing) | Conceptual; implemented across Pulse.Rewrite and Circuit |
| **Edge** | Homogeneous dataflow relation between nodes | `Cortex.Graph` / `Cortex.Circuit` |

The historical `Cortex.Workflow` layer mixed source syntax, node definitions,
compiled topology, product templates, and report rendering. The implemented
split is:

```
Cortex/
  Wire.hs             -- source-language facade
  Wire/
    AST.hs
    Parser.hs
    Contracts.hs
    Compiler.hs
  Circuit/
    IR.hs             -- composition language (sequence, parallel, conditional, etc.)
    Compiled.hs       -- compiled circuit artifact + latent fragments
    Compiler.hs       -- IR -> compiled circuit
    Lowering.hs       -- compiled circuit -> Pulse stage plan
    NodeKind.hs       -- node semantic labels used by the compiled layer
Portman/
  Workflow/
    Template.hs       -- product workflow configuration
    Render.hs         -- product report assembly
    WireEnv.hs        -- Portman-specific default Wire ports
```

**Stage** is the Pulse executor's internal vocabulary for a runtime node. Authors
write nodes and wires. The compiler produces circuit nodes. Pulse fires stages.

## 2. Three Orthogonal Axes (Phase 1: role + plasticity; Phase 2: typed contracts)

Every authored node has role + contract + plasticity. Circuits additionally
introduce control constructs such as Decide that are not node roles.

### 2.1 Role — what the node IS (Phase 1)

```haskell
data Role = Act | Await | Emit
```

- **Act** — transforms inputs into outputs. General-purpose computation.
- **Await** — suspends until an external condition is met.
- **Emit** — commits a durable outward-facing artifact to a sink.

**Decide is circuit-level, not a role:** In current Cortex, conditions are
synthetic nodes created by the compiler from `CircuitConditional`. They are
not authored as task nodes with the `decide` role. A planner node that returns
a `Plan` is `Act`. The circuit's `if $need_web { ... }` is `Decide`.

Semantically, Decide means:

- the circuit has two or more pre-authored, prevalidated continuation fragments
- the decision selects exactly one of them at runtime
- the selected fragment is stitched between fixed boundaries
- unselected fragments remain latent and are never admitted into the materialized graph

This distinction matters for contract enforcement and budgeting.

### 2.2 Contract — what the construct REQUIRES (Phase 2)

Each authored construct implies a minimum contract. This is a Phase 2 design
target — the current runtime does not enforce typed contracts.

```haskell
data NodeContract
  = ActContract ActSpec           -- minimal: just input/output
  | AwaitContract AwaitSpec       -- wake condition
  | EmitContract EmitSpec         -- sink/target for the artifact

data CircuitControlContract
  = DecideContract DecideSpec     -- selection space + decision basis
```

Contract details:

| Construct | Required contract | Phase 1 status |
|------|------------------|----------------|
| Act node | Input/output types | No type checking today — inputs are `Map NodeId Aeson.Value` |
| Decide construct | Selection space + branch basis | Binary conditional only via `CircuitCondition` |
| Await node | Wake condition | **Phase 1: `signal()` only.** `until/after/at` require new Pulse runtime support (Phase 2) |
| Emit node | Delivery target | Kind + label exist; replay/idempotency is implicit in `StageReplaySafety` (Phase 2: make explicit in authored contract) |

### 2.3 Plasticity — what structural authority the node HAS (Phase 1)

```haskell
data PlasticityMode
  = Static              -- no structural authority
  | LatentSelection     -- may select pre-validated branches (Decide)
  | RewriteEnabled      -- may propose runtime graph mutations (Adjust)
```

Plasticity is orthogonal to role. An Act node may be Static or
RewriteEnabled. A Decide construct is typically LatentSelection. The
combination of role + plasticity determines what contracts the executor
enforces.

**Adjust** is the human-readable name for open runtime rewrite authority
(`RewriteEnabled`). It is not a fifth role, and it is distinct from Decide.
Decide selects among pre-authored latent branches; Adjust proposes a new graph
fragment through the compiler at runtime.

## 3. Surface Syntax (Phase 1: core subset; Phase 2: typed binding)

### 3.1 Types (Phase 2)

Structural schema language mapping to JSON at runtime. **Not compilable
in Phase 1** — shown here as a design target for typed contracts.

```
type Position = {
  symbol: Text
  shares: Scientific
  avg_cost: Scientific
}

type PortfolioSnapshot = {
  positions: [Position]
  cash: Scientific
  as_of: Instant
}

enum ApprovalStatus = Approved | Rejected
```

Core primitives: `Text`, `Bool`, `Int`, `Scientific`, `UUID`, `Instant`, `Json`.
Composites: `T?` (optional), `[T]` (list), `Map<Text, T>`, `{ ... }` (record).

**Note:** `Scientific` is used instead of `Float` to match the Portman
codebase's financial precision requirements.

### 3.2 Node Definitions (Phase 1: structural form; Phase 2: typed signatures)

```
node <id>(<params>) -> <Type> : <role> {
  <body>
}
```

The header is the signature: name, typed parameters, output type, role.
The body is binding/config: executor, prompt, tools, contract-specific clauses.

```
node planner(input: Request) -> Plan : act {
  label = "Planner"
  executor = llm("claude-sonnet-4.6")
  prompt = """
    You are a planner. Produce a plan for gathering and analysis.
  """
}

node gatherer(input: Plan) -> Evidence : act {
  label = "Gatherer"
  executor = native("portman.gather")
  tools = [Market.Search, Memory.Lookup, Finance.Prices]
}

node approval_gate(input: OrderPlan) -> Approval : await {
  on = signal("operator_approval")
}

node report_artifact(input: ReportDraft) -> ReportRef : emit {
  kind = "report"
  to = workspace.reports["deep-report"]
}
```

Role-specific enforcement:

- `act` — no special clauses required
- `await` — **Phase 1:** must specify `on = signal(...)`. **Phase 2:** additional `until`, `after`, `at` clauses for time-based awaits
- `emit` — must specify `kind` and `to` (delivery target). **Phase 2:** explicit `replay` policy

### 3.3 Circuit Definitions (Phase 1: structural topology)

```
circuit <id>(<params>) -> <Type> {
  <topology>
}
```

Topology operators:

| Operator | Meaning | Phase 1 compilable? |
|----------|---------|-------------------|
| `A -> B -> C` | Sequential | Yes |
| `[ x: A, y: B ]` | Parallel with labeled outputs | Yes (labels are Phase 2 binding) |
| `if cond between A B { ... } else { ... }` | Conditional branch (Decide) selecting one latent continuation between fixed boundaries | Yes (condition ref only; field access is Phase 2) |
| `rewrite "intent" { ... }` | Plasticity scope | Yes |

### 3.3.1 Writing Decide

Write Decide as a circuit-level conditional, not as `role = decide` on a node.
The currently implemented basic form is explicit about the anchor boundaries.

Implemented basic binary Decide:

```txt
if required_evidence_missing between gatherer analyst {
  required_evidence_repair;
};
```

Meaning:

- `gatherer` and `analyst` are the fixed boundaries
- the `if` owns pre-authored continuation fragments between them
- when the condition resolves true, `required_evidence_repair` is stitched in
- when it resolves false, the empty continuation is selected and execution continues to `analyst`
- the condition name is a plain condition reference, not a dereference, so no `$` marker is needed

If both continuations are explicit:

```txt
if needs_web between analyst reviewer {
  path [web_search, synthesize];
} else {
  memory_lookup;
};
```

Potential future sugar:

```txt
gatherer -> if required_evidence_missing { required_evidence_repair } -> analyst
```

but that is not the shipped v0 syntax.

Future n-way selection should stay circuit-level too, likely as `match` or
`choose`, for example:

```txt
analyst
  -> match $next_step {
       stress    => { stress_dimension }
       summarize => { summary_section }
       escalate  => { human_escalation }
     }
  -> reviewer
```

The important invariant is that all branches are authored and validated ahead
of time. Runtime Decide only selects which latent continuation to admit.

### 3.4 Complete Example — Deep Report

This example shows the target surface form. **Phase 1 compilation** would
support the topology (`->`, `[]`, `if`, `rewrite`) and node structural forms.
**Phase 2** adds typed signatures, field access in conditions, and labeled
fan-in binding.

```
type ResearchRequest = { prompt: Text, portfolio_id?: UUID }
type Plan = { required_evidence: [Text] }
type Evidence = { facts: [Text], missing_required: [Text] }
type Analysis = { thesis: Text }
type SectionDraft = { title: Text, body: Text }
type ReviewInput = {
  summary: SectionDraft
  risks: SectionDraft
  catalysts: SectionDraft
}
type ReportDraft = { title: Text, markdown: Text }
type ReportRef = { id: UUID, path: Text }

node planner(input: ResearchRequest) -> Plan : act {
  executor = llm("claude-sonnet-4.6")
  prompt = "You are a planner."
}

node gatherer(input: Plan) -> Evidence : act {
  executor = native("portman.gather")
  tools = [Market.Search, Filing.Search, Memory.Lookup]
}

node required_evidence_repair(input: Evidence) -> Evidence : act {
  executor = native("portman.required_evidence_repair")
}

node analyst(input: Evidence) -> Analysis : act {
  executor = llm("claude-sonnet-4.6")
  prompt = "Analyze the evidence."
}

node summary_section(input: Analysis) -> SectionDraft : act {
  executor = llm("claude-sonnet-4.6")
  prompt = "Write the summary section."
}

node risks_section(input: Analysis) -> SectionDraft : act {
  executor = llm("claude-sonnet-4.6")
  prompt = "Write the risks section."
}

node catalysts_section(input: Analysis) -> SectionDraft : act {
  executor = llm("claude-sonnet-4.6")
  prompt = "Write the catalysts section."
}

node reviewer(input: ReviewInput) -> ReportDraft : act {
  executor = llm("claude-sonnet-4.6")
  prompt = "Review and merge sections into a final report."
}

node report_artifact(input: ReportDraft) -> ReportRef : emit {
  kind = "report"
  to = workspace.reports["deep-report"]
}

circuit deep_report(input: ResearchRequest) -> ReportRef {
  planner -> gatherer

  if required_evidence_missing between gatherer analyst {
    required_evidence_repair;
  };

  analyst -> [
    summary: summary_section,
    risks: risks_section,
    catalysts: catalysts_section
  ] -> reviewer -> report_artifact
}
```

## 4. Initial Compilation Anchors (Phase 1)

The Phase 1 subset of the surface syntax maps to existing Cortex IR
constructors. This is not a complete 1:1 mapping — typed binding,
field-access conditions, and labeled fan-in require Phase 2 work.

**What compiles today (structural topology):**

| Surface form | Current IR anchor |
|-------------|------------------|
| `node x : act` | `CircuitTask CircuitTaskNode` |
| `node x : await` with `signal()` | `CircuitAwaitSignal CircuitSignalBoundary` |
| `node x : emit` | `CircuitArtifact CircuitArtifactBoundary` |
| `if $condition_ref { ... }` | `CircuitConditional` (condition ref only) |
| `rewrite "intent" { ... }` | `CircuitRewriteScope + CircuitRewriteBoundary` |
| `A -> B -> C` | `CircuitSequence` |
| `[ ... ]` | `CircuitParallel` |

**What requires Phase 2 runtime/compiler work:**

| Surface form | Blocker |
|-------------|---------|
| `if gatherer.field != []` | Field-access conditions need typed binding |
| `[ label: node, ... ] -> join_node` | Labeled fan-in needs typed merge |
| `node x : await` with `until/after/at` | Pulse only knows `StageSuspend SignalName` today |
| Typed input/output signatures | Runtime is `Map NodeId Aeson.Value`; no schema validation |

## 5. Budget Split: Decide vs Adjust (Phase 2 — requires Pulse changes)

> **This section describes target semantics, not current behavior.**
> Today, both Decide (conditional branch selection) and Adjust (open
> rewrite proposals) go through the same `StageRewrite` + `admitRewriteDelta`
> path in Pulse. Implementing the split requires either a distinct
> continuation-selection result type or explicit executor special-casing.

Decide and Adjust both affect future topology, but they are fundamentally
different operations and should not share a budget:

| | Decide | Adjust |
|---|--------|--------|
| What it does | Select one pre-authored branch fragment | Propose a new graph fragment |
| Branches known at | Compile time | Runtime |
| Validated at | Compile time | Runtime (admission) |
| Cost known at | Compile time | Runtime |
| Budget consumed | Continuation budget (pre-computed) | Rewrite budget (open) |
| Re-execution on rejection | N/A | Yes |
| Degradation policy | N/A | Fail or Degrade |

Target implementation: branch costs pre-computed by the compiler, stored on
the compiled condition node. The executor distinguishes continuation
materialization for Decide from open rewrite admission for Adjust.

## 6. Contract Enforcement (Phase 2 — requires lowering changes)

> **This section describes target semantics, not current behavior.**
> The current lowering binder does not enforce role-specific result
> constraints. Structural enforcement is incidental (e.g., condition
> nodes can only produce `StageRewrite` or `StageComplete` because of
> how the closure is constructed).

Target: the lowering binder wraps each `StageAction` with a contract checker:

| Construct | Allowed StageResult |
|------|-------------------|
| Act node | `StageComplete` only |
| Decide construct | `StageComplete` or `StageRewrite` (pre-validated branch materialization) |
| Await node | `StageSuspend` only |
| Emit node | `StageComplete` only |

Any node or construct with `RewriteEnabled` plasticity additionally allows
`StageRewrite` with open (budget-bounded) proposals.

**Phase 2 addition for Emit:** explicit replay/idempotency policy in the
authored contract (`replay = safe | irreversible`), not just the implicit
`StageReplaySafety` on `StageDefinition`.

## 7. Module Rename Map (Phase 1)

| Current | Proposed |
|---------|----------|
| `Cortex.Workflow.Wire` | `Cortex.Wire` |
| `Cortex.Workflow.StageIntent` | `Cortex.Circuit.NodeKind` |
| `WorkflowNodeRef`, `WorkflowTaskNode`, boundary types | `Cortex.Circuit.IR` |
| `WorkflowIR`, `WorkflowExpr`, `WorkflowCondition` | `Cortex.Circuit.IR` |
| `Cortex.Workflow.Compiled` | `Cortex.Circuit.Compiled` |
| `Cortex.Workflow.Compiler` | `Cortex.Circuit.Compiler` |
| `Cortex.Workflow.Lowering` | `Cortex.Circuit.Lowering` |
| `Cortex.Workflow.Template` | `Portman.Workflow.Template` |
| `Cortex.Workflow.Render` | `Portman.Workflow.Render` |
| `Cortex.Workflow` | Removed; generic source/topology now lives in `Wire` + `Circuit` |

**Migration safety**: Do NOT rename internal synthetic IDs
(`__cortex_workflow__/...`) or the compatibility family
(`cortex.workflow/v1`) in the same pass. Those are durable identity
strings stored in the database. Rename the module structure first, then
decide whether to bump the compatibility family later.

## 8. Phase Summary

### Phase 1: Vocabulary + Module Split + Structural Authoring

- Wire/Circuit module split with Portman workflow wrappers outside Cortex
- `Role = Act | Await | Emit` on node definitions (Decide is circuit-level)
- `PlasticityMode` as orthogonal axis
- Surface syntax for topology (`->`, `[]`, `if $ref`, `rewrite`)
- `await` supports `signal()` only
- No typed I/O schemas, no field-access conditions
- Compilation target: current `Cortex.Circuit.IR` constructors

### Phase 2: Typed Contracts + Richer Semantics + Runtime Changes

- Typed I/O schema language (`Scientific`, records, enums)
- Field-access conditions (`if gatherer.missing != []`)
- Labeled parallel fan-in/fan-out with typed merge
- `await` gains `until`, `after`, `at` clauses (requires Pulse runtime)
- Budget split: continuation budget (Decide) vs rewrite budget (Adjust)
- Contract enforcement at lowering (role-based `StageResult` wrapper)
- Emit gains explicit `replay` policy in authored contract
- Prompt template variables with compile-time validation

## 9. Open Questions

**Q1: Should the parser be a separate tool or embedded in Haskell?**
Options: standalone parser binary, Template Haskell quasi-quoter, or runtime
text parser. Runtime parser is simplest for LLM-generated fragments.

**Q2: How do prompt template variables bind to predecessor outputs?**
The current system uses `Map NodeId Aeson.Value` with manual extraction.
The typed schema language could validate variable references at compile time.
(Phase 2)

**Q3: Where does the executor model (`llm(...)` / `native(...)`) resolve?**
Currently resolved by the template's `stageModelPolicy` + user settings +
template model overrides. The node syntax makes this explicit but the
resolution chain stays the same.

**Q4: How does collapse interact with this design?**
See DIG-485. Collapse is the dual of rewrite — absorbing successor nodes.
The language doesn't need collapse syntax (it's a runtime optimization),
but the compiler's expand/collapse decisions should respect role boundaries.
(Phase 2+)
