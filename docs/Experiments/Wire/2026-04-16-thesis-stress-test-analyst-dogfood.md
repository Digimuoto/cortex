---
title: "Thesis Stress Test Analyst Dogfood"
description: Prompt and inspection checklist for the Analyst node-kind adaptive rewrite dogfood run
date: 2026-04-16
status: accepted
related: []
---

# Thesis Stress Test Analyst Dogfood

## Setup

Use workflow:

```text
thesis_stress_test
```

Set launch field:

```text
focus_assets = [NVDA:US AMD:US AVGO:US MSFT:US GOOG:US AMZN:US]
```

## Prompt

```text
Thesis: NVIDIA will underperform AMD and Broadcom over the next 12 months because the market is overpaying for GPU scarcity while custom silicon and second-source accelerators capture incremental AI inference demand.

Stress-test this thesis. Focus on where it would break: CUDA/software moat durability, hyperscaler custom-chip substitution, supply constraints, valuation compression, and whether AMD/Broadcom can actually convert demand into earnings faster than NVIDIA. Pull current prices and recent company evidence where available. The final report should identify the most important failure conditions and give a conviction rating.
```

## Expected Rewrite

`analyst_adaptation` should return raw Wire that declares focused `@analyst` nodes. It should not
use `@stress_dimension`, and it should not reference outer workflow node instances such as `analyst`
or `reviewer`.

Example shape:

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

## Inspect

- `analyst_adaptation` model output declares explicit V1 `node` forms.
- `pulse.graph_rewrites.status` is `admitted`.
- Materialized node ids include names like `analyst:cuda_moat`.
- Reviewer inputs include spawned analyst nodes, not only the original `analyst`.
- Generated analyst nodes can propose follow-on rewrites if gas remains. The stress-test workflow
  currently allows up to 16 added nodes, 40 added edges, depth 8, frontier delta 12, and 8 rewrite
  ops so the run can expose a dozen-ish materialized analysts without unbounded growth.
- Console `Feed`, `Model`, `Tools`, and `Thoughts` tabs filter correctly when clicking each node.
