---
title: Clerk Report Provenance
description: Design spec for provenance-tracked Clerk reports, annotated HTML, and workspace report artifacts
---

# Clerk Report Provenance

Status: **Accepted**

Last updated: **March 19, 2026**.

This design is implemented in the shipped report-mode artifact pipeline. The
future multi-agent runtime will reuse the same artifact/provenance contract
rather than replacing it.

Portman's Clerk skill runtime produces provenance-aware reports downstream of
Cortex. This page stays focused on the report artifact, annotated HTML, and
provenance inspection surfaces.

## Problem

When a Clerk report shows `€63,258.76`, a user should be able to ask: *where
did this number come from?* Currently the typed IR (`Currency Scientific
CurrencyCode`) carries the value and its display format, but not its origin.
There is no way to trace a compiled markdown value back to the tool call, API
response field, and timestamp that produced it.

This matters for:

1. **Trust**: users need to know if a number came from a live API or was
   hallucinated by the LLM.
2. **Audit**: compliance and debugging require a chain from rendered value to
   IR node to tool response to upstream API.
3. **Staleness**: knowing when data was fetched lets the UI show freshness
   indicators.
4. **Reproducibility**: re-running a report should be able to diff against
   prior snapshots.

## Current State

The report pipeline is:

```
Prompt -> Planner/Gatherer/Analyst/Reviewer -> section compiler outputs -> local ReportIR assembly -> compileToMarkdown -> output
```

The IR types (from `Cortex.Document.IR`):

| Level | Types |
|-------|-------|
| Top | `ReportIR { version, blocks }` |
| Block | `Heading`, `Paragraph`, `Table`, `BulletList`, `OrderedList`, `Code`, `Math`, `HorizontalRule` |
| Inline | `PlainText`, `BoldText`, `ItalicText`, `InlineCode`, `InlineMath`, `Currency`, decimal-fraction `Pct`, legacy `Ref`, `Link`, `Embed` |

Observations from testing:

- IR compilation is reliable (4/4 success, 0ms compile time, zero validation errors)
- Currency/pct formatting is correct and deterministic
- The LLM sometimes injects content outside IR control (emojis, footnote styles)
- No embed tools exist yet (chart/price), so embed rendering is untested
- Benchmark/index data tools are missing (degraded gracefully to qualitative)

## Design Goals

1. **Minimal IR extension**: provenance is metadata on existing nodes, not a
   separate block-level system.
2. **Optional**: provenance annotations are not required for IR validity. A
   report without provenance compiles identically.
3. **Serialisable**: provenance round-trips through JSON (LLM writes it,
   server stores it, UI reads it).
4. **Tool-call granularity**: the primary provenance anchor is a tool call ID
   plus response field path.
5. **Composable**: an inline value may derive from multiple sources (for
   example a computed ratio from two tool calls).

## Proposed Design

### 1. Source Reference

`Source` is defined in
[Structured Document IR](/docs/ADRs/0001-structured-report-ir/) and identifies the tool
call plus result field path referenced by a provenance entry.

Freshness remains runtime-owned in v1. `Source` does not carry
`sourceFetchedAt`; the UI derives freshness from the matching
`ToolCallRecord.tcrTimestamp`.

### 2. Provenance Annotation

`Provenance` is defined in
[Structured Document IR](/docs/ADRs/0001-structured-report-ir/) as either `Direct
Source` or `Computed [Source] Text`.

`Authored` is deferred. In v1, the absence of a `Sourced` wrapper is the signal
that a span is normal narrative text rather than tool-traced data.

### 3. IR Extension

The IR types including `ReportIR.reportProvenance`, `Sourced Int Inline`,
`Source`, and `Provenance` are defined in
[Structured Document IR](/docs/ADRs/0001-structured-report-ir/).

This document assumes the report-local integer provenance ID model from that
spec:

- `Sourced` uses positive integer IDs local to one report artifact.
- `data-prov-id="3"` resolves against provenance entry `3` in the report IR.
- Reports without provenance still compile identically.
- Provenance stays invisible in markdown and only becomes visible in annotated
  HTML / UI inspection flows.

### 4. Tool Call Registry

The runtime already measures tool-call completion time during report runs. V1
formalises this into a registry carried on the report artifact:

```haskell
data ToolCallRecord = ToolCallRecord
  { tcrId        :: Text
  , tcrToolName  :: Text
  , tcrArgs      :: Aeson.Value
  , tcrResult    :: Aeson.Value   -- truncated result payload, not full raw JSON
  , tcrTimestamp :: UTCTime       -- tool completion timestamp
  , tcrDuration  :: Int
  }
```

`tcrResult` is intentionally truncated for storage safety. V1 should use a less
aggressive truncation than timeline previews so field-path-based hover and
drilldown still have the referenced subtrees available. A suggested baseline is
`truncateJsonValue 20 50 100`.

### 5. Assistant Report Artifact

The canonical artifact is stored once in assistant message metadata and exposed
to the UI via the poll response:

```haskell
data AssistantReportArtifact = AssistantReportArtifact
  { araCompiledMarkdown   :: Text
  , araAnnotatedHtml      :: Maybe Text
  , araIr                 :: ReportIR
  , araToolCalls          :: [ToolCallRecord]
  , araProvenanceCoverage :: Maybe Double  -- 0.87 = 87%
  , araComposeReportCallCount :: Maybe Int
  , araAcceptedComposeReportCallIndex :: Maybe Int
  , araWorkspaceItemId    :: Maybe UUID
  }
```

Example:

```json
{
  "compiledMarkdown": "## Portfolio Overview ...",
  "annotatedHtml": null,
  "ir": {
    "version": 1,
    "blocks": [...],
    "provenance": {
      "3": {
        "kind": "direct",
        "source": { "toolCallId": "call_abc123", "fieldPath": "$.totalValue" }
      }
    }
  },
  "toolCalls": [
    {
      "id": "call_abc123",
      "tool": "getPortfolioPositions",
      "args": { "...": "..." },
      "result": { "...": "..." },
      "timestamp": "2026-03-09T09:14:02Z",
      "durationMs": 515
    }
  ],
  "provenanceCoverage": 0.87,
  "workspaceItemId": null
}
```

`provenanceCoverage` is a best-effort trust metric computed after successful
report compilation:

```text
coverage = sourced eligible data leaves / total eligible data leaves
```

To avoid penalising normal prose, the denominator counts leaf nodes in
`Currency`, `Pct`, `Ref`, `Link`, and `Embed`, plus `PlainText`,
`InlineCode`, and `InlineMath` only when they appear inside `Sourced`.

### 6. Artifact Delivery and Storage

Artifact flow is:

```text
AssistantRunState -> poll response -> assistant message metadata + workspace item metadata
```

Implementation contract:

- `AssistantRunState` gains `runStateReportArtifact :: Maybe AssistantReportArtifact`.
- A successful local report assembly and compilation pass populates that field.
- `AssistantChatPollResponse` gains optional `reportArtifact`, emitted on the
  terminal poll for report-mode runs.
- The frontend persists `reportArtifact` into assistant message metadata using
  the existing backend round-trip path.
- Deep-report runs create a markdown workspace item placeholder before expensive
  execution begins so the workspace document exists as a live canvas from the
  start of the run.
- The workspace item title comes from the first `HeadingBlock`; fallback is
  `Report <timestamp>`.
- The workspace item is placed alongside the session's chat workspace item when
  that exists; otherwise deep reports default to `Inbox/Deep Reports` instead of
  the workspace root.
- Workspace metadata stores the full artifact under `assistantReport` together
  with `source = "assistant-report"`, `mode = "report"`, `runId`, and optional
  `chatSessionId`.
- `workspaceItemId` is patched onto the artifact before the terminal poll
  returns, so both the chat message metadata and workspace item metadata carry
  the same saved artifact.
- Workspace metadata also mirrors persistence lifecycle:
  `queued|running|completed|failed|save_failed|canceled`.
- If final workspace save fails after compilation, the artifact transitions to
  `save_failed` and remains durably retryable without rerunning the report.
- Clarification-only turns and report runs that never produce valid IR create
  no workspace item.

V1 storage rule:

- The full artifact lives in assistant message metadata.
- The same artifact is duplicated into workspace item metadata so workspace
  report rendering works without a second fetch path.

### 7. UI Rendering

The web UI can use provenance for:

- **Annotated report rendering**: chat messages and saved workspace markdown
  items tagged as assistant reports render `annotatedHtml` when present.
- **Compiled markdown fallback**: if `annotatedHtml` is `null`, the UI renders
  `compiledMarkdown` instead so pre-DIG-243 artifacts remain valid.
- **Hover tooltips** on `[data-prov-id]` spans: the UI resolves the integer ID
  against `artifact.ir.provenance`, then resolves each `Source` against
  `toolCalls`.
- **Freshness indicators**: use `ToolCallRecord.tcrTimestamp` as the
  authoritative fetch/completion time.
- **Deep-link to tool call**: click to expand the truncated tool result and the
  source field path.
- **Coverage badge**: render `provenanceCoverage` as a user-facing trust
  indicator.
- **Open in workspace**: report chat messages can link to `workspaceItemId`
  when the report has been auto-saved successfully.

`compileToAnnotatedHtml` may emit `data-prov-kind="direct|computed"` for
styling, but `data-prov-id` is the primary lookup attribute.

Frontend sanitisation must preserve provenance attributes. The existing
DOMPurify allowlist should explicitly include:

```ts
'data-prov-id', 'data-prov-kind'
```

### 8. Validation Extensions

Validation rules for `Sourced`, provenance ID resolution, and `Source`
integrity are defined in
[Structured Document IR](/docs/ADRs/0001-structured-report-ir/).

### 9. Compilation

Markdown compilation semantics for provenance-aware IR are defined in
[Structured Document IR](/docs/ADRs/0001-structured-report-ir/).

`compileToAnnotatedHtml` (DIG-243) wraps sourced leaf nodes in stable
provenance spans:

```html
<span data-prov-id="3" data-prov-kind="direct">€63,258.76</span>
```

The DOM only carries compact report-local IDs. Full provenance and tool-call
details stay in the artifact, not duplicated into HTML attributes.

## Implementation Phases (DIG-239)

1. **Phase 1 - IR extension** (DIG-240): add report-root `provenance`,
   `Sourced Int`, `Source`, `Provenance`, JSON codecs, and validation rules.
2. **Phase 2 - Tool call registry** (DIG-241, parallel with Phase 1): capture
   tool-call args, truncated results, completion timestamps, and durations
   during report runs.
3. **Phase 3 - Report artifact + poll response** (DIG-242): define
   `AssistantReportArtifact`, add `runStateReportArtifact`, compute
   `provenanceCoverage`, and attach optional `reportArtifact` to the terminal
   poll response.
4. **Phase 4** (parallel):
   - **Annotated HTML** (DIG-243): populate `annotatedHtml` using integer
     `data-prov-id` spans and optional `data-prov-kind`.
   - **Workspace persistence** (DIG-244): auto-create workspace markdown items
     from `compiledMarkdown`, store `assistantReport` metadata, and patch
     `workspaceItemId` back onto the artifact before the terminal poll returns.
   - **System prompts** (DIG-245): teach the LLM about `provenance` maps,
     `sourced` wrappers, and best-effort provenance behavior.
5. **Phase 5 - UI integration** (DIG-246): render `annotatedHtml` when
   available, fall back to `compiledMarkdown` when it is `null`, bind
   provenance inspection to `data-prov-id` spans, surface
   `provenanceCoverage`, preserve provenance attributes in DOMPurify, render
   workspace report items, and add an "Open in workspace" action.

Deferred:

- CLI `--provenance` flag
- snapshot diff UI
- server-side provenance inference
- generated reports API integration

## Resolved Decisions

The following v1 decisions are fixed by this spec:

1. **Report-local provenance IDs**
   `data-prov-id` uses positive integer IDs scoped to one report artifact.
2. **Runtime-owned freshness**
   timestamps come from `ToolCallRecord.tcrTimestamp`, not the LLM.
3. **Best-effort provenance**
   partial provenance is valid and surfaced via `provenanceCoverage`.
4. **Automatic workspace persistence**
   deep-report runs create workspace markdown items up front; successful runs
   finalize them in place, `save_failed` runs keep a retryable durable artifact,
   and clarification-only turns / failed pre-IR runs create none.
5. **Intentional artifact duplication**
   the full artifact lives in both assistant message metadata and workspace
   item metadata in v1.
