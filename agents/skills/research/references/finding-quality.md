# Finding Quality Bar

Use this file when deciding whether a research finding belongs in the memo and how it should be
labeled.

## Evidence discipline

Classify every nontrivial claim as one of:

- `Observed` — directly supported by code, theorems, docs, ADRs, tests, commits, issues, or
  literature. The reader can re-derive the claim from the cited artifact.
- `Inferred` — not explicit in any single artifact, but strongly supported by multiple observations
  across layers.
- `Speculative` — plausible and useful, but not yet validated. Every Speculative finding must attach
  a concrete validation path.

Do not present speculation as fact. Do not suppress useful speculation either — label it and give it
a path.

## Confidence levels

- `High` — direct evidence or multiple independent artifacts agree.
- `Medium` — evidence is strong but partial; one good counterexample would shift the conclusion.
- `Low` — plausible but under-validated; the finding is in the memo because the idea is worth
  recording, not because it is settled.

## Finding quality requirements

A finding belongs in the memo only if every line is true:

1. It is grounded in at least one concrete artifact (file path, theorem, ADR id, issue, commit,
   literature reference).
2. It matters for correctness, extensibility, performance, clarity, or scientific contribution.
3. It can be stated precisely. If the title needs to hedge, the finding is not ready.
4. It is stronger than a single observation; it is a pattern, a gap, or a claim.
5. It has a plausible next step that someone could pick up.

If a candidate point fails any of these, move it to Known Unknowns, Evidence Gaps, or leave it out.

## Finding categories

| Category             | Use when                                                                              |
| -------------------- | ------------------------------------------------------------------------------------- |
| `Correctness Gap`    | A claimed or expected property is not enforced, tested, proved, or true.              |
| `Missed Abstraction` | Several ad hoc mechanisms want one principled interface, algebra, or capability.      |
| `Layer Leak`         | A concept lives at the wrong semantic level (Platform / Cortex / Logos / downstream). |
| `ADR Drift`          | An ADR's accepted decision and current code/docs/theory have diverged.                |
| `Novel Idea`         | A new conceptual connection or research angle the synthesis surfaces.                 |
| `Design Tension`     | Two legitimate goals pull the design in conflicting directions.                       |
| `Evidence Gap`       | A claim may be true, but the current evidence is weak, partial, or stale.             |
| `Extension Risk`     | A plausible next ADR or roadmap step will break a current invariant or assumption.    |
| `Dead End`           | A promising direction looks attractive but does not survive closer analysis.          |
| `Terminology Gap`    | The system lacks the right names for concepts it already relies on.                   |

## Traceability

Every major finding traces to concrete artifacts when possible:

- code path with line number (`src/Cortex/Wire/Pure.hs:1391-1422`)
- theorem name and file (`whereStaticFields_sound` at `theory/Cortex/Wire/Pure.lean:672`)
- ADR id and section
  (`ADR 0031 §"Invariant: where-records have a statically determinable field set"`)
- issue or PR (`#107`, `gh pr view 111`)
- architecture chapter (`docs/Architecture/05-wire-language.md:#binding-surfaces`)
- commit hash (`48663c5`)
- external source (paper title, section, year; or URL if a public writeup)

The memo should let the reader verify the claim without repeating the whole investigation.

## Speculation budget

- Default to 5-8 major findings.
- No more than 20-30% of findings should be Speculative or Low confidence.
- A Novel Idea is fine as Speculative if it has a validation path attached.
- If half the memo is Speculative, the synthesis is not ready; widen the evidence layer first.

## Helpful checks

Before finalizing a finding, answer:

- What did I observe directly?
- What do I infer from that?
- How sure am I, and why?
- Why does it matter — for correctness, for the next slice, for scientific contribution?
- How would I validate it cheaply — a test, a small theorem, a literature check, a prototype?

If you cannot answer those five questions, the finding is not ready for the main list.

## Cortex-specific signals

Beyond the general bar, treat these as elevated signals when ranking:

- A Lean theorem and a Haskell function disagree on shape, semantics, or ordering.
- An accepted ADR and the implementation disagree about an admission rule.
- Two `proposed` ADRs commit to incompatible decisions in interlocking parts of the same subsystem.
- A concept named in `docs/Architecture/` has no typed carrier in code.
- A typed carrier in code has no description in `docs/Architecture/` or in any ADR.
- A theorem's hypotheses are richer than what admission discharges (the use site cannot apply the
  theorem).
- A `runtimeOnly` policy is enforced by prose convention rather than by a compiler check, runtime
  guard, or process gate.
