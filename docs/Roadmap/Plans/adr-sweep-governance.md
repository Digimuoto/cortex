---
title: ADR Sweep Governance Closure
description:
  Current coordination ledger for ADR-sweep governance gaps that still need a deciding ADR,
  reference contract, or explicit deferral.
sidebar:
  label: ADR sweep governance
  order: 3
status: active
date: 2026-06-30
related:
  - docs/ADRs/0001-canonical-documentation-contract.md
  - docs/ADRs/0063-adr-traceability-and-feature-status-canon.md
  - docs/Reference/feature-status.md
  - docs/Roadmap/Epics/substrate-soundness-closure.md
---

# ADR Sweep Governance Closure

This page is the current coordination ledger for the ADR-sweep governance gaps. It is not a new
decision record and does not supersede the source issues. Its job is narrower: keep each remaining
gap attached to the right canonical surface, and make explicit why a source issue remains open until
that surface lands.

Issue trackers are planning state, so this page must not replace ADRs, Reference pages, or
[`feature-status.md`](../../Reference/feature-status.md). When a row below receives its governing
decision, remove the tracker-facing row and let the accepted ADR, Reference page, and feature-status
matrix carry the durable state.

## Closure Rules

- **One decision per governing artifact.** Do not fold unrelated Pulse, Wire, package, and tooling
  decisions into one catch-all ADR.
- **Reference pages can govern only when they are normative.** If the existing Reference text fully
  states the rule and no ADR is required by ADR 0063, the issue can close with a pointer to that
  Reference page.
- **Feature-status changes only when capability status changes.** This coordination pass does not
  flip ADR or implementation status merely because a gap is listed here.
- **Open issue means explicit missing decision.** Every retained row names the exact decision still
  missing, not just the historical sweep that found it.

## Current Ledger

| Source                                                 | Area                                                          | Current canon                                                                                                                                                                                                                                                                                                                                                    | Closure decision                                                                                                                                                                                                                                                                                                                                   |
| ------------------------------------------------------ | ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [#318](https://github.com/Digimuoto/cortex/issues/318) | Pulse schema migration/evolution                              | [`Pulse/schema`](../../Reference/Pulse/schema.md), [`provisionPulseSchema`](https://github.com/Digimuoto/cortex/blob/main/src/Cortex/Pulse/Database.hs), and `data/pulse-schema.sql` describe the current shape and provisioning path. ADR 0011 governs checkpoint compatibility, and ADR 0075 governs service DB configuration; neither governs DDL lifecycle.  | Keep open until a short ADR or normative Reference section decides the schema source of truth, migration runner expectation, forward-only/idempotency policy, dump regeneration rule, and compatibility promise for existing downstream DBs. #338 owns the mechanical drift guard, not the policy.                                                 |
| [#317](https://github.com/Digimuoto/cortex/issues/317) | Durable signal primitive                                      | [`Pulse/signals`](../../Reference/Pulse/signals.md) specifies signal names, pending/delivered/expired states, delivery, expiry, and lookup. ADR 0003 allocates signals to Pulse; ADR 0058 and ADR 0059 specialize settlement and external-call signal families.                                                                                                  | Keep open until the base durable signal primitive is governed by a deciding ADR or an explicitly normative Reference contract. The remaining decision is the generic signal state machine and uniqueness contract that ADR 0058/0059 build on.                                                                                                     |
| [#325](https://github.com/Digimuoto/cortex/issues/325) | Durable graph-state write seam and terminal writer set        | ADR 0064, ADR 0065, ADR 0066, ADR 0058, ADR 0059, and ADR 0067 each restate parts of the persistence seam. ADR 0058 and ADR 0068 mention terminal writer locking obligations.                                                                                                                                                                                    | Keep open until the graph-state write seam is named once as the governed mutation boundary and the run-terminal advisory-lock writer set has one extensible registry or Reference rule. The eventual work should also add a lint/test obligation for raw graph-state writes and terminalizing paths.                                               |
| [#319](https://github.com/Digimuoto/cortex/issues/319) | `tree-sitter-wire` second front-end                           | [`Wire/style`](../../Reference/Wire/style.md) documents tree-sitter usage, and ADR 0076 uses tree-sitter comparison for grammar fixtures. There is no deciding surface for maintaining `editors/tree-sitter-wire/` as a second grammar front-end.                                                                                                                | Keep open until a small ADR or normative development/reference page states authority between the Haskell parser, Wire grammar reference, and generated tree-sitter artifacts; when regeneration is required; and whether this is substrate tooling or editor-only support.                                                                         |
| [#320](https://github.com/Digimuoto/cortex/issues/320) | Wire node runtime-options boundary                            | ADR 0040 assigns model/provider/tool/reasoning policy to Logos or downstream hosts. ADR 0012 accepts topological memory as a Cortex/Pulse substrate feature. `WireNodeRuntimeOptions` still contains generic execution knobs beside names that look like model/tool/reasoning policy.                                                                            | Keep open until the runtime-options split is folded into ADR 0022, ADR 0024, or a focused amendment: Cortex-owned substrate execution metadata versus downstream/provider policy. `memory` must remain aligned with ADR 0012: substrate graph-memory strategy is Cortex/Pulse; cognitive memory presets and product ranking policy are downstream. |
| [#285](https://github.com/Digimuoto/cortex/issues/285) | ADR 0053/0054 acceptance after catalog/package implementation | ADR 0053 and ADR 0054 still have `status: proposed`, and [`feature-status`](../../Reference/feature-status.md) still records `capability.executor_catalog` and `packaging.downstream_packages` as `proposed` / `partial`. ADR 0080 confirms some binder-construction behavior but deliberately leaves general binder composition and codec/schema work deferred. | Keep open until the generalized catalog/package/binding surfaces are implemented and documented enough to accept ADR 0053/0054. Acceptance requires flipping ADR status, refreshing Architecture/Reference pages to code-backed behavior, and keeping downstream authoring guidance free of downstream product code.                               |

## Close Criteria for the Coordination Issue

The coordination issue can close once this ledger lands because every child issue now has a current
reason to remain open and a named canonical destination. Closing this coordination issue does not
close the child issues. Close each child only when its own governing ADR/reference update or
explicit supersession lands.

## Validation

Run:

```sh
just docs-check
```

If a future row changes a capability's ADR or implementation status, also update
[`feature-status.md`](../../Reference/feature-status.md) and run the full docs lint gate.
