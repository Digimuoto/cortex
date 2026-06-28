---
title: "ADR NNNN — {Decision title}"
description: "{One-sentence description of the decision.}"
sidebar:
  label: "NNNN. {Short label}"
  order: N
status: proposed   # proposed | accepted | superseded
date: YYYY-MM-DD
superseded_by: null   # if superseded, path to the replacing ADR
related:
  - docs/Architecture/...
---

# ADR NNNN — {Decision title}

## Status

{Proposed | Accepted | Superseded} — {one sentence with rationale for the status}.

## Context

<!--
What is the situation that forces a decision? What are the constraints,
stakeholders, existing infrastructure? State the problem, not the decision.
-->

## Decision

<!--
What was decided. One paragraph stating the decision clearly enough that a
reader can apply it without reading the rest of the ADR.
-->

## Alternatives considered

<!--
Two or three alternatives that were seriously considered and why they were
not chosen. Rejecting an alternative without engagement is worse than
not mentioning it; either engage or omit.
-->

- **Alternative A** — {brief description}. Rejected because {reason}.
- **Alternative B** — {brief description}. Rejected because {reason}.

## Consequences

<!--
What follows from this decision: the upsides (which claims does it enable),
the downsides (what does it cost), and the obligations (what future work
does it create).
-->

### Positive

- ...

### Negative

- ...

### Obligations

- ...

## Traceability

<!--
REQUIRED for feature/runtime/language/proof ADRs (per the Stage-3 category); OMIT for governance,
numbering/process, and ledger ADRs. See ADR 0063. There is NO release-note field here — release
framing lives only in docs/Reference/feature-status.md. Every feature key listed must already have a
feature-status row. Delete this whole section for a non-feature ADR.
-->

- Feature keys: `subsystem.capability_name`
- Public surface: `Cortex.<Layer>`, `docs/Reference/...`
- Implementation: `src/Cortex/...`
- Tests: `test/Cortex/...`
- Theory/proof: link to the relevant `docs/Reference/proof-status.md` row(s), or `none`

## Related

<!--
Other ADRs this decision depends on, architecture chapters that cite it,
references that codify it.
-->

## Tracking

<!--
Optional and only while status: proposed. Use for issue links, draft PRs, or unresolved checklist
state downstream of this ADR. The ADR is the design authority; issues, epics, and PRs execute it and
feed implementation specifics back while the ADR remains proposed. Delete this entire section before
changing status to accepted; accepted ADRs keep only durable canon/source/test/proof/merged-PR/commit
references, and the rest of the docs must already be reconciled to the accepted decision.
-->
