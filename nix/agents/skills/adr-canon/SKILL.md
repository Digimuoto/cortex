---
name: adr-canon
description: >
  Write or review Cortex ADRs against the canonical ADR lifecycle: one decision, durable references,
  proposed-only tracking, accepted-ADR cleanup, and Traceability/feature-status consistency.
---

# ADR Canon

Use this skill when drafting, reviewing, accepting, or sweeping files under `docs/ADRs/`.

Canonical sources:

- `docs/ADRs/0001-canonical-documentation-contract.md`
- `docs/ADRs/0063-adr-traceability-and-feature-status-canon.md`
- `docs/Templates/adr.md`
- `docs/Reference/feature-status.md`

## Core Rules

- Keep one decision per ADR. Split when a draft combines independent decisions.
- Start substantial design work with a proposed ADR. Issues, epics, and PRs are downstream execution
  surfaces derived from the ADR.
- Iterate the proposed ADR with implementation specifics, then accept only after dependencies are
  met, evidence is current, and surrounding docs have been reconciled.
- Use durable references in frontmatter and body: ADRs, Architecture/Reference pages, source paths,
  tests, proof-status rows, merged PRs, or commit hashes when permanent provenance is necessary.
- Do not use issue numbers as accepted-ADR provenance. Issues are planning state.
- Proposed ADRs may end with `## Tracking` for issue links, draft PRs, and checklist state.
- Delete `## Tracking` and numeric issue/PR references before moving an ADR to `accepted`.
- Feature/runtime/language/proof ADRs carry `## Traceability`; governance/meta ADRs omit it.
- Feature readiness lives in `docs/Reference/feature-status.md`; active tracker IDs live only in
  proposed ADR `## Tracking` sections or the issue tracker, not in accepted ADR prose or Reference
  matrices.
- Append to accepted ADRs only for amendments or forward pointers. Do not rewrite the original
  accepted decision text except for status/supersession metadata.

## Review Checklist

1. Confirm the ADR status matches its lifecycle.
2. For accepted ADRs, reject `GitHub #N`, `issue N`, `PR #N`, bare `#N`, and `## Tracking`.
3. For proposed ADRs, keep tracker material confined to `## Tracking`.
4. Check that `related:` contains durable local canon/source references, not issue links.
5. Check that a feature ADR's `Feature keys` are present in `feature-status.md`.
6. Run `just docs-lint`, `just docs-check`, and `just fmt-check` after edits.
