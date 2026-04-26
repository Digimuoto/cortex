# Writing Standards

Use this note when the review bar needs a compact reminder of what good Cortex
docs optimize for.

## Canonical Docs

Canonical docs should optimize for concept stability, not current repo shape.

- write as if Cortex already stands alone
- frame downstream products as examples, not as the system boundary
- prefer stable conceptual names over file paths and module names
- keep issue IDs, PR links, commit hashes, and repo-layout trivia out of canon
- keep prose compact and scannable

## Internal Docs

Research notes, ADRs, handoffs, experiments, and plans can be more explicit
about implementation and history.

- issue links and repo paths are allowed when they improve traceability
- keep the distinction between decision, evidence, and speculation clear
- even internal docs should stay concise and well-structured

## Figures, Math, And Code

- diagrams should communicate typed structure, not just connectivity
- notation should be named consistently and avoid throwaway variables
- code blocks should look runnable or obviously illustrative
- if examples are normative, they must obey the stated rules

## Compactness

Less is more, but only when it improves clarity.

- prefer deletion over repetition
- use short lead paragraphs
- cut historical digressions from canonical docs unless they change meaning
- move implementation detail into internal docs when possible
