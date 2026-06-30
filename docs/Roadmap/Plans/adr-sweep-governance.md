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

## Resolved By ADR Governance Cleanup

The following sweep gaps now have governing ADRs, amendments, or reference updates and should be
closed once this cleanup lands:

- #317 — governed by ADR 0082 and the Pulse signals reference.
- #318 — governed by ADR 0083 and the Pulse schema/migrations references.
- #319 — governed by ADR 0084 and the tree-sitter/editor docs.
- #320 — folded into ADR 0025 and the configured-executor/runtime-options references.
- #325 — folded into ADR 0064's durable graph-state write seam and ADR 0058's run-terminal writer
  set.
- #350 — covered by the refreshed Pulse consumer/operations docs.

## Current Ledger

| Source                                                 | Area                                                          | Current canon                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | Closure decision                                                                                                                                                                                                                                                                                                     |
| ------------------------------------------------------ | ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [#285](https://github.com/Digimuoto/cortex/issues/285) | ADR 0053/0054 acceptance after catalog/package implementation | ADR 0053 and ADR 0054 still have `status: proposed`, and [`feature-status`](../../Reference/feature-status.md) still records `capability.executor_catalog` and `packaging.downstream_packages` as `proposed` / `partial`. ADR 0080 confirms some binder-construction behavior but deliberately leaves general binder composition and codec/schema work deferred. This depends on the catalog/package implementation tracks [#279](https://github.com/Digimuoto/cortex/issues/279) and [#281](https://github.com/Digimuoto/cortex/issues/281). | Keep open until the generalized catalog/package/binding surfaces are implemented and documented enough to accept ADR 0053/0054. Acceptance requires flipping ADR status, refreshing Architecture/Reference pages to code-backed behavior, and keeping downstream authoring guidance free of downstream product code. |

## Close Criteria for the Coordination Issue

The coordination issue can close once only #285 remains here and its dependency on #279/#281 is
explicit. Close #285 only when ADR 0053/0054 are honestly acceptable.

## Validation

Run:

```sh
just docs-check
```

If a future row changes a capability's ADR or implementation status, also update
[`feature-status.md`](../../Reference/feature-status.md) and run the full docs lint gate.
