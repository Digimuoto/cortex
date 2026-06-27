---
title: "ADR 0049 - Wire Phantom Record↔Ports Adapter for Topology Fans"
description:
  "Merged into ADR 0052: the `*` boundary adapter decision now lives there as a finite-product
  fold/unfold adapter that covers nominal records and bounded indexed products."
sidebar:
  label: "0049. Fan phantom adapter (merged)"
  order: 49
status: superseded
date: 2026-05-05
superseded_by: docs/ADRs/0052-wire-bounded-indexed-boundary-products.md
related:
  - docs/ADRs/0052-wire-bounded-indexed-boundary-products.md
---

# ADR 0049 - Wire Phantom Record↔Ports Adapter for Topology Fans

## Status

Superseded — merged into
[ADR 0052 — Wire Bounded Indexed Boundary Products](./0052-wire-bounded-indexed-boundary-products.md).

## Decision

The `*` topology operator introduced here is now defined by ADR 0052 as a finite-product boundary
adapter. ADR 0052 absorbed this ADR's mechanics — the `a * b ≡ a => phantom => b` phantom-insertion
model, the product discriminator, the empty/singleton degenerate cases, the port-clash diagnostic,
match determinism, the canonical rule, the full static-error list, the contract surface, and the
Lean correspondence — and generalized the record↔ports adapter to cover bounded indexed products as
well.

The "fan" / "record↔ports" vocabulary is retired in favor of "finite-product boundary adapter". See
ADR 0052 for the current decision; this file is retained so existing references resolve until the
track is re-enumerated.

## Related

- [ADR 0052 - Wire Bounded Indexed Boundary Products](./0052-wire-bounded-indexed-boundary-products.md)
