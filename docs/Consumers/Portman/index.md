---
title: Portman × Cortex
description: Portman's Cortex binding. How the finance platform uses the substrate — Clerk assistant, deep-report workflows, provenance, durable runs.
sidebar:
  label: Portman
  order: 1
---

# Portman × Cortex

Portman is Cortex's first and currently only consumer. This directory documents Portman-specific bindings of Cortex's substrate — what Portman does with the grammar, Circuit, and Pulse.

## Contents

- **[deep-report-v2.md](deep-report-v2.md)** — Portman's `/deep-report` skill binding on top of Cortex. How Portman finance prompts, tools, and policy shape a Cortex research run.
- **[report-provenance.md](report-provenance.md)** — Portman's provenance-tracked report pipeline. Annotated HTML, workspace report artifacts, tool-call ledger integration.
- **[response-eval-run.md](response-eval-run.md)** — ResponseEvalRun on Pulse: typed outcomes, eval execution, incremental persistence.
- **[pulse-host-actions.md](pulse-host-actions.md)** — Portman's Pulse binding: host-action API, Portman task types, operator surface on top of Pulse.

## Ownership boundary

Every page here documents **Portman's use of Cortex**, not Cortex itself. Generic substrate concerns live in [../../Architecture/](../../Architecture/) and [../../Reference/](../../Reference/). If a doc starts describing how Cortex *generically* does something, it belongs upstream.

The rule of thumb: if this doc would need to be rewritten when another product (besides Portman) adopts Cortex, it belongs here. If it would stay intact, it belongs in the Cortex canon.

## Related

- [../index.md](../index.md) — consumers landing.
- [../../Architecture/](../../Architecture/) — Cortex canon.
- [../../ADRs/0001-structured-report-ir.md](../../ADRs/0001-structured-report-ir.md) — Report IR ADR (Portman-facing but generic enough for canon).
