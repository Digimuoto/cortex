---
title: "Wire Reference — Executor Arguments and Execution Boundary"
description:
  The one-record executor argument ABI, node metadata, registry projections, and host invocation
  boundary.
sidebar:
  label: Executor boundary
  order: 4
status: draft
date: 2026-07-18
related:
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/Architecture/05-wire-language.md
  - docs/ADRs/0095-wire-single-record-executor-boundary.md
---

# Wire Reference — Executor Arguments and Execution Boundary

Executor authority is a bare registry reference. It carries identity and the registry-owned
projection, but no embedded configuration:

```wire
let analyst = @review.analyst;
```

An authority becomes executable only in an explicit node body. Calls take zero or one bare CorePure
argument:

```wire
node gather -> evidence: EvidenceSet = @review.gather;
node analyze <- evidence: EvidenceSet -> analysis: AnalysisRecord = @analyst evidence;
node tuned
  <- evidence: EvidenceSet
  -> analysis: AnalysisRecord
  = @analyst { payload = evidence; cfg = { temperature = 0.2; }; };
```

The boundary normalizes calls to one record: no argument becomes `{}`, a scalar becomes
`{ payload = scalar; }`, and an explicit record is unchanged. `payload` is reserved for automatic
wrapping. `cfg` is only a conventional place for executor-specific settings.

## Registry and runtime rules

- A node supplies graph identity and a concrete typed port boundary.
- Strict registry projections prove the exact accepted input labels/contracts and returned output
  labels/contracts. Permissive compilation supplies no such proof.
- Projections and package manifests declare `argument_shape`, not `config_shape`.
- After ingress/CorePure evaluation, the runtime validates the normalized record against
  `argument_shape` before invoking the host binding.
- The validated `Aeson.Value` reaches the native binding unchanged.
- Executor authorities cannot be used as graph nodes or captured by CorePure equations.

## Node metadata

Compiler-owned controls belong to a statically evaluable `with` record after the node name:

```wire
node persist_report with {
  artifactKind = "report";
  to = artifacts.reports;
  timeout = 30;
}
  <- report: ReportArtifact
  = @artifact.store report;
```

Accepted fields are the compiler's documented controls: labels/instructions, tools and memory,
timeout/retry/budget controls, `on`, `artifactKind`, and `to`. Unknown or dynamically evaluated
metadata is rejected. Executor-specific data remains ordinary argument data, normally under `cfg`.

Wire may admit an open graph, but runtime preparation still requires all required inputs and a host
binding for every executor authority. Provider failures, invalid outputs, timeouts, cancellation,
and host errors are runtime failures of already-admitted authority.
