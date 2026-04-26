---
title: "ADR 0013 - Artifact Provenance Contract"
description: "Cortex artifacts attach provenance through stable artifact-local references rather than raw rendered spans."
sidebar:
  label: "0013. Artifact provenance"
  order: 13
status: accepted
date: 2026-04-24
superseded_by: null
related:
  - docs/ADRs/0001-structured-report-ir.md
  - docs/Architecture/08-artifacts-and-provenance.md
---

# ADR 0013 - Artifact Provenance Contract

## Status

Accepted. Cortex artifact provenance is modeled as structured metadata attached
to artifact-local references.

## Context

Structured rendering solves only one side of trustworthy artifacts. A rendered
document can be syntactically valid and still fail to explain where a number,
claim, table, or derived value came from.

Raw span annotation is too fragile as the primary contract. Rendering changes,
Markdown normalization, and HTML transformations can move spans even when the
artifact's semantic nodes stay stable. Provenance needs to attach before final
presentation.

Downstream report provenance is one concrete consumer of this contract, but the
underlying rule applies to any host that turns Cortex workflow outputs into
auditable artifacts.

## Decision

Artifact provenance is represented through stable artifact-local references,
not through raw rendered-text spans.

The contract has four parts:

- **Artifact-local anchors.** Structured artifact nodes carry stable local
  identifiers that survive deterministic rendering.
- **Provenance records.** Each record names the source of a claim, value, tool
  result, computation, or model-produced section.
- **Coverage metadata.** Artifacts may summarize how much of the rendered output
  has explicit provenance.
- **Renderer projection.** Markdown and HTML renderers project the provenance
  metadata into annotations, links, or sidecar metadata without changing the
  provenance source of truth.

The host remains responsible for deciding which sources are valid in its domain
and which provenance gaps are acceptable for publication.

## Consequences

Positive consequences:

- Provenance survives formatting changes because it targets structured artifact
  nodes.
- Hosts can build domain-specific audit surfaces without changing Cortex's core
  document renderer.
- Rendered HTML annotations can be regenerated from the same artifact source.
- Provenance coverage becomes measurable instead of implicit.

Costs and obligations:

- Artifact IRs need stable local identifiers where provenance is expected.
- Renderers must preserve enough structure to expose provenance cleanly.
- Hosts must decide domain-specific trust policy downstream.
- Raw span offsets may still exist as derived display data, but they are not the
  source of truth.

## Alternatives Considered

- **Annotate rendered Markdown or HTML directly.** Rejected because it makes
  provenance dependent on formatting and renderer behavior.
- **Keep provenance only in run logs.** Rejected because artifact readers need a
  local explanation of claims and values.
- **Make Cortex own domain trust policy.** Rejected because accepted evidence is
  host-specific.

## Related

- [ADR 0001 - Structured Document IR](0001-structured-report-ir.md)
- [Chapter 08 - Artifacts and provenance](../Architecture/08-artifacts-and-provenance.md)
