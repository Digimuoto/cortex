---
title: "ADR 0040 - Logos-Owned Reasoning Surfaces"
description:
  "Moves model/provider/tool-call, structured-output policy, and report artifact IR surfaces out of
  Cortex and into Logos."
sidebar:
  label: "0040. Logos reasoning surfaces"
  order: 40
status: accepted
date: 2026-05-02
superseded_by: null
related:
  - docs/Architecture/02-ownership-and-boundaries.md
  - docs/Architecture/08-artifacts-and-provenance.md
  - docs/Consumers/Logos/reasoning-library.md
  - docs/ADRs/0001-structured-report-ir.md
  - docs/ADRs/0016-cortex-roots-and-logos-pattern-extraction.md
  - docs/ADRs/0018-canonical-haskell-module-tree.md
---

# ADR 0040 - Logos-Owned Reasoning Surfaces

## Status

Accepted. This ADR supersedes ADR 0001's implementation placement and narrows the proposed module
trees in ADR 0016 and ADR 0018.

## Context

Cortex is the durable runtime substrate. It owns Algebra, Wire, Pulse, and executor registration
mechanics. Logos is the reasoning library above the substrate. It owns model-mediated cognition,
reasoning patterns, cognitive memory, and reusable report workflows.

The current Haskell tree still carried reasoning-library surfaces in Cortex:

- model choice request/result types under `Cortex.Capability.Model.*`
- OpenRouter provider adapters under `Cortex.Capability.Provider.OpenRouter.*`
- structured-output fallback policy under `Cortex.Capability.StructuredOutput`
- tool-call request/record helpers under `Cortex.Capability.Tool.*`
- report/document artifact IR and rendering under `Cortex.Artifact.*`

Those modules are not substrate mechanics. They encode model-provider behavior, tool-loop records,
structured-output policy, or DeepReport-shaped document artifacts. Keeping them in Cortex makes the
runtime package look like an AI/provider framework and forces every substrate consumer to inherit a
reasoning-library API surface.

## Decision

Move those surfaces to Logos and remove the Cortex exports without compatibility shims.

The canonical Logos homes are:

| Former Cortex surface                                   | Logos home                                     |
| ------------------------------------------------------- | ---------------------------------------------- |
| `Cortex.Capability.Model.*`                             | `Logos.Thought.Model.*`                        |
| `Cortex.Capability.Provider.OpenRouter.*`               | `Logos.Provider.OpenRouter.*`                  |
| `Cortex.Capability.StructuredOutput`                    | `Logos.Thought.StructuredOutput`               |
| `Cortex.Capability.Tool.*`                              | `Logos.Thought.ToolCall` and thought-tool APIs |
| `Cortex.Artifact.*` report/document IR and host surface | `Logos.Patterns.DeepReport.Artifact.*`         |

`Cortex.Capability` remains, but its public role is narrower: it owns executor registration and
native pure-executor configuration surfaces. Model providers, LLM response schemas, tool-call
records, and reasoning-output retry policy are not Cortex capability APIs.

Cortex still has artifact and provenance concepts at the architecture level. Those concepts are
expressed through Wire contracts, runtime envelopes, Pulse provenance, and consumer bindings. Cortex
does not currently expose a public `Cortex.Artifact` Haskell root. A future generic artifact API can
be added by a separate ADR if a substrate-shaped need appears.

## Consequences

Positive consequences:

- The Cortex public Haskell API is visibly substrate-shaped.
- Logos becomes the single home for model/provider/tool-loop and DeepReport artifact APIs.
- Downstream consumers do not inherit OpenRouter, report IR, or structured-output policy when they
  depend only on Cortex.
- Dependency pressure moves with the owning surface: HTTP provider clients, report rendering, and
  money/markdown helpers belong to Logos, not Cortex.

Costs and obligations:

- Existing imports of the removed Cortex modules must move to Logos.
- ADR 0001 remains historical, but its `Cortex exposes ReportIR` claim is superseded.
- Proposed ADRs that listed `Cortex.Artifact` or model/provider/tool surfaces under
  `Cortex.Capability` must be read through this ADR.
- The Logos package must provide the moved APIs before Cortex deletes its copies.

## Alternatives Considered

- **Keep compatibility shims in Cortex.** Rejected. The point of the change is to make the substrate
  boundary mechanically obvious; shims would preserve the wrong public vocabulary.
- **Keep provider adapters in Cortex but move report IR to Logos.** Rejected. Provider adapters and
  model request/response types are reasoning-library concerns unless and until the substrate has a
  provider-neutral executor capability contract that needs them.
- **Keep a generic `Cortex.Artifact` root with only empty marker types.** Rejected. A root with no
  concrete substrate API invites future leakage. Generic artifact concepts remain documented until a
  real substrate API is justified.

## Related

- [Chapter 02 - Ownership and boundaries](../Architecture/02-ownership-and-boundaries.md)
- [Chapter 08 - Artifacts and provenance](../Architecture/08-artifacts-and-provenance.md)
- [Logos reasoning library](../Consumers/Logos/reasoning-library.md)
- [ADR 0001 - Structured Document IR](0001-structured-report-ir.md)
- [ADR 0016 - Cortex Roots and Logos Pattern Extraction](0016-cortex-roots-and-logos-pattern-extraction.md)
- [ADR 0018 - Canonical Haskell Module Tree](0018-canonical-haskell-module-tree.md)
