---
title: "ADR 0011 — Compatibility Barriers and Fresh-Run Recovery"
description:
  "Incompatible checkpoints fail explicitly; recovery across version drift happens through fresh-run
  recovery rather than silent resume."
sidebar:
  label: "0011. Compatibility barriers"
  order: 11
status: accepted
date: 2026-04-23
superseded_by: null
related:
  - docs/Architecture/06-pulse-runtime.md
---

# ADR 0011 — Compatibility Barriers and Fresh-Run Recovery

## Status

Accepted — versioned checkpoint compatibility and non-silent recovery behavior are part of the
current Pulse runtime contract.

## Context

Long-lived durable runs inevitably cross code and runtime evolution. A stored checkpoint may no
longer match the current task type, task version, runtime version, or checkpoint shape after
deployment changes.

Allowing best-effort resume across such mismatches would create a dangerous ambiguity: a run might
appear resumable while actually executing against semantics it was not checkpointed under.

Pulse therefore needed an explicit law for version drift and operator recovery.

## Decision

Checkpoint compatibility failures are explicit runtime barriers.

- version and shape mismatches are classified as typed compatibility failures
- incompatible checkpoints do not resume silently
- the default operator recovery path across version drift is to create a fresh run rather than to
  force checkpoint-based continuation

Fresh-run recovery preserves operator intent and parent provenance while avoiding the fiction that
an old checkpoint is still valid under new code.

## Alternatives considered

- **Attempt best-effort resume against newer code** — rejected because it hides semantic drift
  behind optimistic control flow.
- **Treat every mismatch as generic corruption** — rejected because operators need to distinguish
  version drift from damaged state.
- **Default to checkpoint migration or copied restart state** — rejected because the current system
  has not adopted a general migration law and should not pretend one exists.

## Consequences

### Positive

- Durable recovery behavior is explicit and easier to reason about operationally.
- Operators can distinguish incompatibility from ordinary task failure.
- The runtime avoids overpromising replay guarantees it does not actually implement.

### Negative

- Version drift can force re-execution rather than seamless continuation.
- Any future checkpoint-migration story will need a deliberate new design, not an implicit extension
  of the current one.

### Obligations

- Keep compatibility failure categories explicit in runtime and operator surfaces.
- Do not add silent or best-effort resume paths around the barrier.
- Treat future migration support as a separate architectural decision, not as incidental
  implementation detail.

## Related

- [../Architecture/06-pulse-runtime.md](../Architecture/06-pulse-runtime.md)
