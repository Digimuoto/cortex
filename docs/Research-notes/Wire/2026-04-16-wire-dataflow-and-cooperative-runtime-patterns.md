---
title: "Research Memo: Wire Dataflow and Cooperative Runtime Patterns"
description: How data, prompts, context, memory, provenance, and cooperation flow through a concrete Wire workflow, plus how the same runtime pattern transfers to game-NPC loops and complex coding graphs
---

# Research Memo: Wire Dataflow and Cooperative Runtime Patterns

**Date:** 2026-04-16  
**Scope:** `config/cortex/workflows/thesis-stress-test.wire`, the Deep Report runtime path, prompt builders, adaptive rewrite flow, and how the same execution model generalizes beyond document delivery  
**Artifacts examined:** `config/cortex/workflows/thesis-stress-test.wire`, `src/Portman/Task/DeepReportWorkflow.hs`, `src/Portman/Clerk/Prompts.hs`, `src/Cortex/Circuit/Lowering.hs`, `src/Cortex/Pulse/Plan.hs`, `src/Cortex/Pulse/Executor/Attempt.hs`, and adjacent research memos on Wire and bounded rewriting  
**Method:** implementation-first cross-reference synthesis  
**Confidence profile:** high on the current document-delivery path and adaptive runtime behavior; medium on the scenario transfers because they are design extrapolations rather than shipped examples

---

## Executive Summary

The simplest honest description of the current system is: **graph topology is the coordination language, and durable node outputs are the shared state**. A Wire workflow does not primarily work by keeping one giant mutable prompt in memory. It works by giving each node a bounded role, feeding it typed upstream outputs plus runtime context, and letting the graph decide what can run next.

The `thesis_stress_test` example is the best canonical case because it contains almost every important surface in one place: static ports, a conditional repair branch, an adaptive analyst node that can append more analysts, a reconverging reviewer, and a final document artifact. In that flow, prompt text, payload JSON, tool evidence, merged context, rewrite gas, and observability all move through different channels. They are related, but they are not the same thing.

The main design consequence is that "memory" in the current system is mostly **durable structured outputs plus replayable graph state**, not a shared mutable scratchpad. That is strong for provenance and recovery. It is weaker for live collaborative text editing, which is why larger adaptive graphs will eventually want a more explicit scratchpad or fragment store.

The same pattern transfers cleanly to other domains. An evolving NPC loop in a game would change the artifact type and memory substrate, but it would still use topology for decomposition and durable outputs for handoff. A complex coding workflow would do the same, except some nodes would wait on tools and CI while other branches continue through the graph.

---

## Canonical Wire

The current example wire is `config/cortex/workflows/thesis-stress-test.wire`.

Its essential shape is:

```wire
planner => gatherer;

if required_evidence_missing between gatherer analyst {
  required_evidence_repair;
};

analyst => reviewer => report_artifact;
```

And its key adaptive authority is attached to `analyst`:

```wire
features = {
  adaptationPoints = {
    analyst = {
      maxBranches = 4;
      propagateRewriteAuthority = true;
      budgetSlice = {
        nodes = 16;
        edges = 40;
        depth = 8;
        frontier = 12;
        ops = 8;
      };
    };
  };
};
```

This says:

- the static workflow is planner -> gatherer -> analyst -> reviewer -> report artifact
- there is a closed-world conditional repair branch between gatherer and analyst
- `analyst` is also an open-world adaptation point
- any materialized downstream `Analyst` nodes may themselves propose more `Analyst` nodes while rewrite gas remains

That combination makes this wire a useful miniature of the larger system.

---

## The Six Data Surfaces

The runtime becomes easier to reason about if its data surfaces are kept separate.

| Surface | What it is | Where it comes from | What it is for |
| --- | --- | --- | --- |
| Prompt | System instructions for a node | Prompt builders in `Prompts.hs` plus runtime prompt appendix | Role-shaping and behavior constraints |
| Payload | The immediate user message for a node | Stage-specific input renderers such as `plannerInput`, `gathererInput`, `renderEvidenceBundle`, and `wireAnalysisInput` | Task-local working input |
| Context | Runtime JSON attached to prompts | `buildMergedContext` and user/template/runtime state | Shared background facts and request framing |
| Memory | Durable outputs and optional memory prompt blocks | Upstream node outputs, tool call records, graph state, optional `## Research Memory` blocks | Cross-node continuity |
| Provenance | Evidence and execution trace | Tool call records, stage logs, run events, graph state, audit bundle | Auditability and replayability |
| Cooperation | How nodes divide work | Graph topology, conditions, joins, rewrites, and gas | Parallelism, decomposition, reconvergence |

The biggest practical mistake is to treat all six as "context". They are not interchangeable.

---

## End-to-End Walkthrough

### 1. Planner: request shaping, not evidence gathering

The planner stage uses `buildPlannerPrompt` and a tiny user payload:

```text
Original request:
<user request>
```

The planner prompt explicitly says:

- do not call tools
- do not answer the request in full
- plan from request, memory, and context only

The planner output is a structured JSON payload, `DeepReportPlannerOutput`, carrying:

- workflow id
- strategy/portfolio ids when relevant
- planner notes

This is the first durable handoff artifact. The planner is not "thinking in hidden scratch space"; it is writing the first shared state object for the rest of the graph.

### 2. Gatherer: deterministic evidence production

The gatherer stage takes the original request plus planner notes:

```text
Original request:
<request>

Planner notes:
<notes>
```

Its prompt is tool-oriented and deterministic. It is the main stage allowed to use read tools in the canonical path. The output `DeepReportGathererOutput` contains:

- planner notes
- an evidence summary
- tool call records
- `drgoMissingRequiredTools`

This matters because evidence is split into two layers:

1. a human-readable summary for downstream LLMs
2. a provenance-bearing record of the exact tool calls that produced that summary

The summary helps reasoning. The tool call records make the reasoning inspectable.

### 3. Conditional repair: branch selection with payload forwarding

The wire includes:

```wire
if required_evidence_missing between gatherer analyst {
  required_evidence_repair;
};
```

At runtime, `bindCondition` checks whether required deterministic tools were missed. If they were, it selects the repair branch. If not, it falls through. The important detail is that the condition also forwards the gatherer output in its own JSON payload so the repair stage can recover it after the rewrite boundary.

That means the condition is not just a Boolean gate. It is also a controlled handoff point.

So even in the static part of the workflow, the dataflow model is already richer than "node A returns text, node B sees text".

### 4. Analyst: evidence-to-argument synthesis

The canonical analyst stage takes the gathered output and builds a larger user payload via `renderEvidenceBundle`:

- original request
- planner notes
- optional memory normalization block
- gatherer summary
- tool call evidence summaries

Its prompt says:

- use the structured evidence bundle
- do not call tools
- separate facts from inferences
- do not mention hidden runtime structure

The output `DeepReportAnalystOutput` carries:

- planner notes
- gathered summary
- tool call records
- freeform analysis text

That output is durable and typed even though the analysis body is text. This is the core pattern of the current system: **typed envelope, freeform interior**.

### 5. Adaptive analyst children: graph rewriting as cooperation

If the current `analyst` node has rewrite authority and enough gas, `runAnalystWithAdapt` calls `runAdaptationDecision` after producing the normal analyst output.

The adaptation model does not get tools. It gets a specialized rewrite prompt plus a payload containing:

- user request
- current rewrite anchor
- current analysis draft
- evidence summary
- current topology
- rewrite hole
- proposal scope
- rewrite gas tier
- remaining rewrite gas
- allowed templates
- registered contracts
- previous rejection details if any

The allowed template in this dogfood path is `Analyst`, and the prompt explicitly distinguishes:

- reusable template id: `Analyst`
- proposal-local node instance: `cuda_moat`, `valuation_break`, `synthesis`, and so on
- outer workflow nodes such as `analyst` and `reviewer`, which are not proposal-local references

This is the key to cooperation in the adaptive graph. The node does not "spawn a thread" in an unstructured way. It proposes a local graph fragment in Wire, and the runtime either admits or rejects it under:

- append-hole compatibility
- shape policy
- graph validity
- rewrite gas budget

If admitted, the new nodes become real runtime nodes with their own stage outputs, own provenance, and optionally their own downstream rewrite authority.

### 6. Spawned analyst nodes: context assembly instead of shared editing

The most important current behavior is in `runWireAnalysisStage`.

A spawned `Analyst` node receives a recomposed input bundle consisting of:

- the original user request
- the node objective prompt
- a typed summary of the Wire inputs
- planner notes
- merged evidence summary
- evidence references
- upstream analysis text

It may also gather additional evidence locally if the runtime task declares allowed gatherer tools.

So the node does not collaborate by editing a shared document. It collaborates by reading durable upstream outputs, adding local evidence if allowed, and writing another durable `DeepReportAnalystOutput`.

This is why the right mental model is:

- topology is the coordination layer
- stage outputs are the memory layer
- prompt assembly is the local working set

### 7. Reviewer: reconvergence

The reviewer stage is where the graph collapses back into one narrative. It takes either:

- combined analyst outputs, or
- compiled section outputs if the workflow already split into report sections

Its payload includes:

- original request
- rendered evidence bundle
- draft analysis

This is the reconvergence point for adaptive exploration. Everything before it may branch; everything after it is driving toward one deliverable.

### 8. Report artifact: document boundary

The report artifact stage turns the reviewed draft into the final workspace artifact.

If the reviewer did not already provide compiled chunks, the artifact stage may:

1. plan bounded sections
2. compile them sequentially
3. persist the report artifact

This is why the final node can be slow: it is not simply rephrasing the whole report once. It may be planning and compiling the final document structure as a separate bounded phase.

---

## Prompt vs Payload vs Context

The runtime is easier to debug when these three are kept conceptually separate.

### Prompt

Prompt text is mostly stable role instruction:

- `buildPlannerPrompt`
- `buildGathererPrompt`
- `buildAnalystPrompt`
- `buildReviewerPrompt`
- `wireAnalysisSystemPrompt`

Prompt text tells the node what kind of actor it is and what it must not do.

### Payload

Payload is the node-local working material:

- `plannerInput`
- `gathererInput`
- `gathererRepairInput`
- `renderEvidenceBundle`
- `reviewerInput`
- `wireAnalysisInput`
- `adaptationCircuitInput`

Payload is usually where the concrete task state lives.

### Context

Context is the runtime JSON background attached to prompts via `Context payload JSON:`. It comes from `buildMergedContext` and may include request context, workflow selection context, strategy/portfolio context, and other runtime facts.

Context is not the same as evidence. It is closer to environment state.

---

## What Counts as Memory Today

In the current canonical flow, memory is not primarily a shared mutable notebook.

Observed memory channels:

1. durable typed stage outputs
2. carried-forward tool call records
3. graph state in Pulse
4. optional prompt memory blocks such as `## Research Memory`
5. the audit bundle assembled at the end

Important caveat: the deep-report runtime currently sets `drePromptBlocks = emptyClerkPromptBlocks`, so the memory-block surface exists in the prompt builders but is mostly empty by default in this dogfood path.

So the current memory story is:

- strong on durable outputs and replayable state
- weak on shared incremental editing
- moderate on prompt-time memory injection

That is why larger adaptive graphs can work today, but also why they start to want a more explicit scratchpad or fragment layer once many nodes are contributing overlapping text work.

---

## Provenance and Observability

The current system is stronger on provenance than on collaborative text editing.

The main provenance carriers are:

- gatherer tool call records
- stage logs
- stage attempt logs
- run events
- graph state snapshots
- node outputs
- node provenance
- remaining rewrite budget
- final report artifact
- workflow audit bundle

`buildWorkflowAuditBundle` is especially important because it packages:

- run id and workflow id
- user request and launch inputs
- merged context
- workflow metadata
- final report preview
- stage timeline
- stage attempts
- run events
- graph state, including topology hash, node statuses, node outputs, node provenance, and remaining rewrite budget

So the system can answer questions like:

- what evidence fed this node?
- which tool calls actually happened?
- which rewrite was admitted or rejected?
- what topology executed?
- what gas remained at a point in time?
- what final artifact came out?

That is a more serious provenance model than a chat transcript alone.

---

## Cooperation Model

The cooperation model is not "multiple models all chat in one room". It is more disciplined than that.

### What actually coordinates the work

Observed coordination mechanisms:

1. static ports and contracts decide which payload shapes can connect
2. graph readiness decides which nodes may run now
3. conditions choose closed-world alternate paths
4. rewrites append open-world future work under gas
5. reviewer or artifact stages reconverge branches

### What each node knows

A node usually knows:

- the user request
- its own role prompt
- selected upstream outputs
- runtime context
- possibly the current graph topology or rewrite hole if it is an adaptive node

It does not automatically know:

- every intermediate thought from every other node
- an editable shared live document
- every raw tool result unless those results are intentionally passed through

That boundedness is a feature. It prevents the graph from collapsing into one giant undifferentiated prompt.

### What "parallel work" means here

Parallel work means:

- independent ready nodes execute concurrently
- each writes a durable output
- downstream joins or reviewers consume the merged result

This is much closer to a dataflow system than a group chat.

---

## Canonical Example Summary Table

| Stage | Prompt role | Main payload in | Main payload out | Cooperation role |
| --- | --- | --- | --- | --- |
| Planner | understand request, no tools | original request | planner notes | establish execution intent |
| Gatherer | deterministic evidence, tools allowed | request + planner notes | evidence bundle + tool records | produce inspectable factual substrate |
| Required Evidence Repair | call missing required tools | request + notes + gathered summary + missing tools | repaired evidence bundle | repair deterministic evidence gaps |
| Analyst | synthesize argument, no tools | rendered evidence bundle | analysis fragment | produce first interpretation |
| Analyst Adaptation | propose raw Wire | analysis draft + topology + gas + contracts | append proposal or empty | decompose work structurally |
| Spawned Analyst | focused local analysis | node objective + typed inputs + evidence + upstream analysis | analysis fragment | branch-specific progress |
| Reviewer | evidence-first synthesis | evidence bundle + combined analysis | review bundle | reconverge branches |
| Report Artifact | compile deliverable | reviewer output | report artifact ref | externalize final product |

---

## How This Transfers Beyond Documents

The document-delivery case is canonical, but not unique. The deeper pattern is reusable.

### Scenario A: Evolving NPC loop in a game

An NPC graph could look like:

```wire
perceive => interpret => intent;
intent => act;
act => reflect;
```

And the adaptive authority could sit on `intent` or `reflect`.

What changes:

- the final artifact is not a markdown report but a world-state mutation, action queue entry, or behavior package
- memory is likely a mix of durable graph outputs and explicit simulation state such as inventory, quest state, faction state, and episodic memory
- provenance shifts from tool calls toward simulation events, state diffs, and action traces

What stays the same:

- topology still coordinates decomposition
- durable outputs still hand off work
- an adaptive node can still decide that a situation needs extra sub-analysis before acting

Example adaptive use:

- `intent` detects conflicting motivations and spawns:
  - threat appraisal
  - social consequence check
  - resource feasibility check

Those branches can run in parallel, then reconverge into action selection.

The important requirement in a game setting is stronger real-time budget discipline. The graph model still fits, but latency budgets become much tighter and rewrite gas would likely need to couple to frame or tick budgets.

### Scenario B: Complex coding task with tools and CI

A coding workflow could look like:

```wire
spec_reader => planner;
planner => code_search;
planner => change_design;
code_search => implementation;
change_design => implementation;
implementation => tests;
implementation => reviewer;
tests => integrator;
reviewer => integrator;
integrator => patch_artifact;
```

Adaptive authority could sit on:

- `planner`, to split the task into subsystems
- `implementation`, to break large work into independent patches
- `integrator`, to request a repair branch after CI failures

What changes:

- some nodes are tool-heavy and can block on shell commands, builds, or CI
- the artifact is a patch set, commit, PR description, or release artifact
- provenance includes command logs, diffs, test results, and CI events

What stays the same:

- ready branches can progress while another branch waits on CI
- graph joins are the coordination point between implementation, review, and test evidence
- adaptive rewrites can add repair or specialization branches without losing replayability

This is where the current design is already promising. A CI-bound node can wait while other branches continue. The graph does not need to reduce the whole workflow to one blocking stage counter.

The main thing that becomes more important in coding workflows is an explicit shared artifact layer. Durable text outputs are useful, but coding tasks usually also need structured references to:

- files
- patches
- failing tests
- ownership boundaries
- command outputs

So the memory substrate should become richer than prose summaries.

---

## What Changes Across Domains, What Does Not

### Stable invariants

These seem like the runtime's real cross-domain invariants:

1. topology is the coordination language
2. node outputs are the durable shared state
3. contracts bound what can connect
4. rewrites are local, anchored, and gas-limited
5. artifacts externalize completed work
6. provenance is a first-class runtime concern, not an afterthought

### Domain-specific swaps

These are the parts that should change per use case:

- node kinds and prompt roles
- tool authorities
- contract vocabulary
- artifact kind
- latency budget
- memory substrate
- reviewer or reconvergence policy

That is the right separation. The runtime should stay generic while those surfaces vary.

---

## Current Limits Exposed by This Analysis

### [P1] The system's real shared memory is durable outputs, not a collaborative scratchpad
**Category:** Missed Abstraction  
**Status:** Observed  
**Confidence:** High  
**Primary evidence:** `src/Portman/Task/DeepReportWorkflow.hs`, `src/Portman/Clerk/Prompts.hs`  
**Cross-reference:** `runAnalystStageWithOverride`, `runWireAnalysisStage`, `renderEvidenceBundle`, `wireAnalysisInput`

The current design is strong when each node can read a bounded upstream bundle and produce a fresh durable output. It is weaker when many nodes need to cooperatively build one evolving shared document or state structure in place.

**Why it matters:**  
This is likely to become the next bottleneck as adaptive graphs grow more ambitious.

**Next step:**  
Introduce an explicit fragment or scratchpad layer rather than overloading prompt context with ever-larger prose.

### [P2] Provenance is already richer than the memory layer
**Category:** Novel Idea  
**Status:** Observed  
**Confidence:** High  
**Primary evidence:** `buildWorkflowAuditBundle`, tool call records, graph state snapshot assembly  
**Cross-reference:** workflow audit path, Pulse graph-state persistence

The system can already explain what happened better than it can let nodes co-edit a shared intermediate artifact.

**Why it matters:**  
That is a good asymmetry for correctness and audit, but it means collaboration quality will lag unless a stronger working-memory substrate is added.

**Next step:**  
Treat provenance and shared-memory design as separate tracks. Do not assume one automatically solves the other.

### [P3] The runtime pattern generalizes cleanly, but the memory substrate should vary by domain
**Category:** Design Tension  
**Status:** Inferred  
**Confidence:** Medium  
**Primary evidence:** canonical document flow plus the shape of `runWireAnalysisStage` and artifact boundaries  
**Cross-reference:** Wire runtime tasks, artifact stages, adaptation flow

The same graph/runtime core can support documents, NPC behavior, and coding tasks, but each domain wants a different working-state representation.

**Why it matters:**  
A single generic "text context" abstraction will eventually become the wrong common denominator.

**Next step:**  
Keep the generic graph/runtime layer stable, but let domain packages choose richer per-domain artifact and memory types.

---

## Recommended Actions

### Act Now

- [ ] Keep using `thesis_stress_test.wire` as the canonical explanation example in docs and demos because it exercises static flow, conditions, rewrites, reconvergence, and artifacts in one workflow.
- [ ] When describing the system externally, distinguish prompt, payload, context, memory, and provenance explicitly instead of calling all of them "context".

### Design Next

- [ ] Add a structured fragment or scratchpad surface for multi-node collaborative work.
- [ ] Define domain-specific artifact and memory patterns for at least two non-report workloads: game agents and coding workflows.
- [ ] Decide which runtime facts belong in prompt-time context versus typed input bundles versus durable shared artifacts.

### Write Up

- [ ] Add a companion memo on "artifact-first memory" for adaptive graphs.
- [ ] Add one concrete hypothetical Wire example for a coding workflow and one for an NPC loop.

### Parked

- Per-edge payload projection as a general mechanism — defer until there is a real need beyond today's contract labels and typed envelopes.

---

## Closing Model

The most compact correct model is:

1. Wire declares the possible cooperation structure.
2. Pulse materializes and advances the current graph.
3. Each node receives a role prompt plus a bounded working payload.
4. Each node emits a durable typed output.
5. Rewrites add more future work under local authority and gas.
6. Review or artifact nodes reconverge the branches into a deliverable.

That is already enough to build serious cooperative systems. The main next abstraction is not "more prompt magic". It is a better shared working-memory substrate for graphs whose branches genuinely co-author something together.
