---
title: "Research Memo: Portman Workflow Surfaces and a Killer Rewrite-Capable Workflow"
description: Cross-source synthesis of current Portman workflows, Pulse rewrite/runtime capabilities, and a high-value durable graph application
---

# Research Memo: Portman Workflow Surfaces and a Killer Rewrite-Capable Workflow

**Date:** 2026-04-08  
**Scope:** current Portman workflows, deep-report/runtime boundaries, backtesting/toolbox surfaces, Pulse rewrite model, and adjacent durable-workflow prior art  
**Artifacts examined:** Clerk/Cortex runtime code, workflow templates, architecture docs, rewrite docs/papers, and official docs from Temporal, LangGraph, and Dagster  
**Method:** Cross-reference synthesis  
**Confidence profile:** high on current Portman behavior; medium-high on proposed workflow architecture; medium on external analogies

---

## Executive Summary

Portman already has most of the pieces for a genuinely differentiated durable
agent system: bounded deep-report phases, report artifacts with provenance, a
paper-portfolio cycle shell, backtest and spreadsheet tools, and a
rewrite-capable Pulse runtime.

The strongest practical stress workflow is not "generic agent chat", but a
**strategy distillation and paper-execution cycle** that can dynamically branch
into backtests, walk-forward checks, spreadsheet scenarios, and guardrail
reviews exactly when the evidence demands it.

The main architectural gap is not another prompt workflow. It is a missing
typed layer between Clerk workflow semantics and Pulse execution graphs.
`workflowStageGraph` is decorative today; Portman needs a **typed workflow
compiler** that turns request + strategy + template into a durable graph with
controlled rewrite rights.

---

## Key Findings

### [P1] Portman already has the primitives for a durable investment-research loop

**Category:** Missed Abstraction  
**Status:** Observed  
**Confidence:** High  
**Primary evidence:** `docs/Consumers/Portman/deep-report-v2.md:41-56`, `docs/Consumers/Portman/report-provenance.md:134-150`, `src/Portman/Task/PaperPortfolioCycle.hs:132-156`, `docs/Architecture/backtest-engine.md:16-21`, `src/Portman/Clerk/Prompts.hs:112-132`

Today these capabilities exist, but as separate seams:

- deep-report produces bounded section outputs and a durable report artifact
- the paper portfolio cycle already has a durable 12-stage shell
- backtest and spreadsheet tools already exist in the assistant surface
- report artifacts already preserve tool-call provenance and workspace persistence

**Why it matters:** the "killer app" does not require inventing a new product
from scratch. It requires composing existing Portman assets into one durable
graph.

**Next step:** prototype one end-to-end durable task that spans research,
validation, and paper execution.

### [P1] The current deep-report flow is robust, but only weakly adaptive

**Category:** Design Tension  
**Status:** Observed  
**Confidence:** High  
**Primary evidence:** `src/Cortex/Task/Report.hs:151-342`, `src/Cortex/Task/Gather.hs:75-205`, `src/Cortex/Task/ToolLoop.hs:52-108`, `src/Portman/Clerk/Runtime/ReportSections.hs:110-167`

`runReportTask` is still a fixed Planner -> Gatherer -> Analyst -> Reviewer
chain with only one required-evidence repair pass. The gather loop is
step-budgeted, and the compiler is bounded and retry-compressed. That is good
safety engineering, but dynamic branching is minimal.

**Why it matters:** the best place for graph rewrites is not prose compilation.
It is **evidence escalation**:

- missing deterministic evidence
- contradictory tool results
- unstable or regime-sensitive thesis
- guardrail-triggered reanalysis

**Next step:** keep report compilation bounded, but let
Gatherer/Analyst/Guardrails append typed subgraphs like `BranchBacktest`,
`BranchStressScenario`, or `RequireEvidenceRepair`.

### [P1] `workflowStageGraph` is not the right executable surface; the missing layer is a typed workflow compiler

**Category:** Missed Abstraction  
**Status:** Observed  
**Confidence:** High  
**Primary evidence:** `config/cortex/workflows/deep-report.wire`, `src/Portman/Clerk/Workflow.hs`, `docs/Architecture/durable-portfolio-agent-mvp.md:358-368`

Workflow templates already encode meaningful semantics:

- model policy
- tool policy
- required evidence
- section plans
- render policy

But `workflowStageGraph` is effectively dead, and the durable portfolio doc
explicitly says not to revive it.

**Why it matters:** Portman needs a typed compiler from

`request + strategy + workflow template -> durable StagePlan/graph`

not a stringly JSON "graph" field inside Clerk config.

**Next step:** define a small typed workflow AST above Pulse and below Clerk
templates.

### [P1] The strongest stress workflow is a Strategy Distillation and Paper Portfolio Cycle

**Category:** Novel Idea  
**Status:** Inferred  
**Confidence:** High  
**Primary evidence:** `src/Portman/Task/PaperPortfolioCycle.hs:132-156`, `docs/Architecture/backtest-engine.md:120-139`, `docs/Roadmap/Epics/graph-execution-engine-v2.md:242-279`, `docs/Roadmap/Plans/rewrite-materialization-and-recovery.md:36-109`

Candidate workflow:

```text
StrategyResolution
-> Snapshot
-> Alpha-attribution / deep-report subgraph
-> if edge is unstable: append backtest + walk-forward + stress-test subgraphs
-> if evidence is missing: append deterministic evidence-repair subgraph
-> Reviewer
-> Guardrails
-> human approval signal
-> PersistDecision
-> PaperExecute
-> post-execution monitoring / replay
```

This would stress exactly the right system properties:

- dynamic fan-out and fan-in
- durable subgraphs
- long-running backtests
- spreadsheet artifact generation
- signals and approval gates
- replay and inspection
- artifact-linked provenance
- guardrail-enforced execution

**Why it matters:** this is both technically demanding and product-legible. It
is the workflow most likely to prove that Portman's graph runtime is better
than a generic agent loop.

**Next step:** prototype it first for `portfolio_alpha_attribution` or the
weekly review path, not generic chat.

### [P2] “Whole Clerk as a durable graph” is viable, but only at semantic boundaries

**Category:** Design Tension  
**Status:** Inferred  
**Confidence:** Medium-High  
**Primary evidence:** `docs/Architecture/clerk.md:35-75`, `docs/Architecture/clerk-multi-agent-skills.md:173-210`, Temporal docs, LangGraph docs, Dagster docs

Clerk already has several graph-friendly seams:

- slash-skill dispatch
- approval-gated `/plan`
- phase timeline events
- `save_failed` durable artifact semantics
- bounded report assembly

The right granularity is:

- prompt workflows as **subgraphs**
- approval or human input as **signals**
- backtests or scenario runs as **child durable analyses**
- report/save/execute as **observable boundary nodes**

Not the right granularity:

- every token stream
- every tool thought
- every transient planner note

**Why it matters:** Portman can get inspectable replay without drowning in
meaningless execution history.

**Next step:** graphify phase outputs and artifact boundaries first; keep prompt
internals as bounded subgraphs.

### [P2] Portman’s likely differentiation is graph provenance tied to domain artifacts, not durability alone

**Category:** Novel Idea  
**Status:** Speculative  
**Confidence:** Medium  
**Primary evidence:** `docs/Consumers/Portman/report-provenance.md:194-260`, `docs/Roadmap/Epics/graph-execution-engine-v2.md:429-464`

Temporal gives durable history and message passing. LangGraph gives
checkpoints, replay/fork, and subgraphs. Dagster gives runtime duplication and
fan-out. Portman's unique angle could be:

- every rewrite carries rationale
- every branch points to report, spreadsheet, or backtest artifacts
- every execution path is reviewable as an investment thesis graph
- replay shows not just "what ran", but "why this branch existed"

**Why it matters:** that is a product users can inspect, trust, and audit.

**Next step:** add branch-level provenance: rewrite reason, triggering evidence
refs, emitted artifacts, and disposition.

---

## Missed Abstractions

| Abstraction | Current split | Needed |
|-------------|---------------|--------|
| Workflow semantics vs execution | Clerk templates vs Pulse runtime | typed workflow compiler |
| Report provenance vs graph provenance | artifact/tool-call provenance only | branch/rewrite provenance |
| Tool call vs durable analysis unit | backtests and context tasks are tools | child subgraph contract |

---

## Evidence Gaps

| Claim | Current Evidence | Missing Evidence |
|-------|------------------|------------------|
| Deep-report can become graph-native cleanly | fixed phases + strong artifacts | typed workflow compiler and first real task |
| Backtest branches can stress Pulse meaningfully | tools and draft engine exist | walk-forward / scenario fan-out implementation |
| Whole Clerk loop is replay-worthy | timeline, `save_failed`, approval gate exist | graph inspector and branch provenance UI |

---

## Design Tensions

- Portman's current runtime is intentionally bounded and deterministic-first;
  graph rewrites add power, but also widen the policy surface.
- Generic `GraphRewrite` is the right substrate, but product safety likely
  requires finance-specific rewrite intents on top.
- Rich replay is valuable, but replaying too fine a grain will make the system
  harder to inspect rather than easier.

---

## Dead Ends / Rejected Directions

- Reviving `workflowStageGraph` as the durable execution contract
- Making every Clerk turn fully graph-native before the finance cycle proves value
- Letting prompt code or closures be the durable rewrite payload instead of structure + template identity

---

## Recommended Actions

### Act Now

- Prototype a single durable `StrategyDistillationCycle` on top of Pulse
- Add finance-specific rewrite intents above generic graph rewrites: backtest,
  walk-forward, stress scenario, evidence repair, approval gate
- Persist branch rationale and artifact links with rewrite provenance

### Design Next

- Define a typed workflow compiler from Clerk template + strategy + request to
  Pulse graph
- Promote backtests and spreadsheet scenarios from "just tools" to optional
  durable child subgraphs
- Decide the first graph inspector surface: node lineage, artifacts, signals,
  replay points

### Write Up

- Frame the system as "planner over graph with artifact-linked provenance", not
  just "multi-agent workflow"
- Treat prompt workflows as bounded subgraphs inside a larger durable financial
  process

---

## Suggested Tracker Routing

- **Create new feature issue:** typed workflow compiler from Clerk workflow
  semantics to Pulse graph
- **Create new feature issue:** first `StrategyDistillationCycle` as a
  rewrite-capable durable financial workflow
- **Create new feature issue:** durable child-analysis subgraphs for backtests
  and spreadsheet scenarios
- **Route existing provenance and inspection scope:** `DIG-419`, `DIG-420`
- **Route broader planner-over-graph integration:** `DIG-422`
- **Route domain portfolio-agent productization:** `DIG-82`

---

## External References

- Temporal Workflow Execution: https://docs.temporal.io/workflow-execution
- Temporal Event History: https://docs.temporal.io/encyclopedia/event-history
- Temporal Workflow Message Passing: https://docs.temporal.io/encyclopedia/workflow-message-passing
- Temporal Child Workflows: https://docs.temporal.io/child-workflows
- LangGraph Durable Execution: https://docs.langchain.com/oss/python/langgraph/durable-execution
- LangGraph Time Travel: https://docs.langchain.com/oss/python/langgraph/use-time-travel
- LangGraph Streaming/Subgraphs: https://docs.langchain.com/langsmith/streaming
- Dagster Dynamic Graphs: https://legacy-versioned-docs.dagster.dagster-docs.io/concepts/ops-jobs-graphs/dynamic-graphs
