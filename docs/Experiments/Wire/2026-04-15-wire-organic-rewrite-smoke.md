---
title: "Wire Organic Rewrite Smoke"
description: Canonical dogfood prompt and inspection checklist for live LLM-generated Wire append rewrites in thesis_stress_test
date: 2026-04-15
status: accepted
related:
  - DIG-498
---

# Wire Organic Rewrite Smoke

Date: 2026-04-15

This is the canonical small dogfood case for the first live LLM-generated Wire rewrite smoke. It is intentionally smaller than the semiconductor equipment thesis so failures are easy to attribute to rewrite context, grammar, template discovery, or gas handling.

## Goal

Run `thesis_stress_test` with one obvious thesis that should cause the analyst adaptation node to add focused `Analyst` node instances.

The deterministic test suite already covers raw Wire proposal compilation, append-hole validation, Pulse admission, over-budget rejection, materialization, and successor fan-in. This smoke covers the remaining live behavior: whether the model chooses a valid rewrite from the context it receives.

## Workflow

Use workflow:

```text
thesis_stress_test
```

Relevant launch field:

```text
focus_assets = [NVDA:US AMD:US AVGO:US MSFT:US GOOG:US AMZN:US]
```

Canonical prompt:

```text
Thesis: NVIDIA will underperform AMD and Broadcom over the next 12 months because the market is overpaying for GPU scarcity while custom silicon and second-source accelerators capture incremental AI inference demand.

Stress-test this thesis. Focus on where it would break: CUDA/software moat durability, hyperscaler custom-chip substitution, supply constraints, valuation compression, and whether AMD/Broadcom can actually convert demand into earnings faster than NVIDIA. Pull current prices and recent company evidence where available. The final report should identify the most important failure conditions and give a conviction rating.
```

## Expected Rewrite Shape

A good live proposal should be raw Wire, for example:

```wire
node cuda_moat :
  <- AnalysisFragment
  -> AnalysisFragment
= @analyst {
  prompt = "Stress-test whether CUDA and NVIDIA's software ecosystem remain strong enough to prevent share shift to AMD or Broadcom.";
};

node custom_silicon :
  <- AnalysisFragment
  -> AnalysisFragment
= @analyst {
  prompt = "Stress-test whether hyperscaler custom silicon redirects AI accelerator demand away from merchant GPUs or merely changes the supply mix.";
};

node valuation_break :
  <- AnalysisFragment
  -> AnalysisFragment
= @analyst {
  prompt = "Stress-test what valuation compression or earnings revision path would make NVIDIA underperformance unlikely.";
};

(cuda_moat, custom_silicon) => valuation_break
```

The exact names do not matter. The important properties are:

- The response is raw Wire, not JSON or fenced markdown.
- Every node is introduced with an explicit V1 `node` declaration.
- The proposal references no existing nodes such as `analyst` or `reviewer`.
- The graph expression is a compact local DAG over the new analyst instances.
- Serial chains are allowed when they express a useful dependency and remain within gas.
- The node count stays within the remaining `addedNodes` gas.

In this proposal scope:

- `@analyst` is the registered executor target for these proposal-local nodes.
- `cuda_moat`, `custom_silicon`, and `valuation_break` are fresh proposal-local node instances.
- `analyst` is the append anchor and `reviewer` is the original successor. They are supplied by the runtime and should not appear in the proposal graph.
- `prompt = "..."` is ordinary executor config on the materialized node instance, for example `analyst:cuda_moat`.
- Because `thesis_stress_test` sets `propagateRewriteAuthority = true`, materialized `Analyst` nodes may also propose follow-on local fragments when remaining rewrite gas allows it.

## Context The Node Must Receive

The adaptation request should include:

- Wire proposal grammar.
- AppendAfter semantics for the current hole.
- Current topology.
- Remaining rewrite gas by dimension.
- Allowed node templates, currently `Analyst`.
- Template ports, executor, tools, and runtime defaults.
- Whether rewrite authority propagates to generated nodes.
- Registered contracts.
- Previous rejection context, if this is a retry.

## What To Inspect

In the run UI or DB-backed admin view, inspect:

- `analyst_adaptation` model output.
- `pulse.graph_rewrites.status`, expecting `admitted` for valid in-budget proposals.
- `pulse.graph_rewrites.rewrite_cost`, especially added nodes and edges.
- `pulse.graph_rewrites.budget_before` and `budget_after`.
- Materialized node IDs, expected to be namespaced under `analyst:`.
- Reviewer inputs, expected to include the rewritten stress nodes rather than only `analyst`.
- Later rewrite rows whose `source_node_id` is a generated node such as `analyst:software_moat`; these prove recursive bounded rewriting beyond the initial analyst node.

## Failure Diagnosis

If no rewrite happens:

- Check whether the model returned an empty response because the analyst draft looked complete.
- Check whether the prompt made the weak points too implicit.

If the rewrite is rejected:

- `proposal_parse_rejected` means the model did not return raw Wire.
- `wire_scope_rejected` means the proposal referenced existing workflow nodes such as `analyst` or `reviewer`; append proposals may only reference proposal-local nodes.
- `wire_shape_rejected` means the proposal shape violates the workflow's current shape policy.
- `wire_*_rejected` means the proposal parsed but failed template, port, hole, shape, or lowering validation.
- `rewrite_budget_exceeded` means the proposal was valid but too large for remaining gas.

If the rewritten nodes run but produce poor content:

- That is no longer a Wire smoke failure. It is a downstream analyst prompt/tooling issue.
