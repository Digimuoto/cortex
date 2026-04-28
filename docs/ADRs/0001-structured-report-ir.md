---
title: "ADR 0001 - Structured Document IR"
description:
  "Cortex document artifacts use a typed intermediate representation that is validated before
  deterministic rendering."
sidebar:
  label: "0001. Structured Document IR"
  order: 1
status: accepted
date: 2026-03-07
superseded_by: null
related:
  - docs/Architecture/08-artifacts-and-provenance.md
  - docs/ADRs/0013-report-provenance-artifact-contract.md
---

# ADR 0001 - Structured Document IR

## Status

Accepted. Cortex exposes `ReportIR` as the typed document-artifact contract for workflows that need
deterministic rendering instead of raw model-authored Markdown.

## Context

LLM-generated Markdown is useful for drafts, but it is a weak final artifact contract. It makes
presentation, validation, escaping, citation placement, and tool provenance dependent on generated
prose. That is especially risky for domains where numbers, formulas, tables, and cited evidence must
survive rendering intact.

The architectural problem is generic: a host may want a Cortex workflow to produce a durable
document artifact, while the host still owns the artifact's domain meaning and publication policy.

Downstream report generation is one concrete consumer of this surface, but the decision belongs to
Cortex because the rendering and validation contract is reusable.

## Decision

Cortex document artifacts pass through a typed intermediate representation before rendering.

The model and runtime may produce structured section outputs, evidence records, and narrative
fragments, but the final renderer consumes a validated IR. The IR is the local contract between
workflow output and rendered artifact.

The IR contract has these rules:

- The artifact is structured data first, rendered text second.
- Validation happens before final rendering.
- The renderer is deterministic and local.
- Escaping, formula delimiting, table shape, heading structure, and code-fence metadata are renderer
  concerns.
- Domain-specific assembly policy remains downstream.
- Provenance references may be embedded in the IR, but provenance semantics are decided by the
  artifact-provenance contract in ADR 0013.

In the current implementation, this contract is named `ReportIR`. The name is historical; the
architectural decision is "structured document IR", not "Portman owns reports inside Cortex".

## Consequences

Positive consequences:

- Rendered artifacts no longer depend on prompt discipline for basic Markdown correctness.
- Validation failures are explicit and local.
- Hosts can keep product-specific document meaning downstream while reusing Cortex's structured
  rendering surface.
- Provenance and annotation can target stable IR nodes instead of brittle spans in generated
  Markdown.

Costs and obligations:

- Workflow outputs must be assembled into IR before final rendering.
- Schema evolution requires versioning discipline.
- Hosts must not treat the IR as a dumping ground for product policy.
- If a future artifact family is not report-shaped, Cortex should add a new IR or generalize the
  document layer deliberately rather than overloading `ReportIR`.

## Alternatives Considered

- **Render raw model-authored Markdown.** Rejected because it makes validation and presentation
  probabilistic.
- **Fix Markdown with regex post-processing.** Rejected because it patches symptoms and remains
  format-fragile.
- **Move all report semantics into Cortex.** Rejected because Cortex owns the artifact substrate;
  hosts own domain meaning and product policy.

## Related

- [Chapter 08 - Artifacts and provenance](../Architecture/08-artifacts-and-provenance.md)
- [ADR 0013 - Artifact Provenance Contract](0013-report-provenance-artifact-contract.md)
