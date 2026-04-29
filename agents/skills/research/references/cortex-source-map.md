# Cortex Source Map for Research

Cortex-specific layer map. Use this to walk evidence in order and to catch layer-leaks.

## Layer 1 — Implementation reality

| Path                        | What lives here                                                                                          | Watch for                                                                              |
| --------------------------- | -------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `src/Cortex/Algebra/`       | Pure graph algebra surface (Mokhov-style)                                                                | Algebraic laws stated in haddock vs proven in `theory/Cortex/Graph`                    |
| `src/Cortex/Wire/`          | Wire authoring surface, parser, compiler, executor registry, pure evaluator                              | Wire-language ADRs (0010, 0017, 0020-0031); admission rules                            |
| `src/Cortex/Pulse/`         | Pulse runtime kernel, frontier, durable execution, recovery                                              | ADR 0003-0009; theory under `theory/Cortex/Pulse/`                                     |
| `src/Cortex/Capability/`    | Capability tokens and authority surface                                                                  | ADR 0010 closed-authority discipline                                                   |
| `src/Cortex/Artifact/`      | Artifact and provenance contracts                                                                        | ADRs 0006, 0009, 0013                                                                  |
| `src-platform/Platform/`    | Runtime substrate sub-library: `Platform.Observability`, `DurableTask`, `Database`, `HTTP.Retry`, `Text` | Layer-leak smell when generic Cortex semantics import Platform internals or vice versa |
| `src-logos/Logos/`          | Downstream reasoning library: LLM workflows, archetypes, cognitive memory                                | Cortex must not depend on Logos; Logos may depend on Cortex                            |
| `app/cortex-pulse/`         | Substrate shell executable                                                                               | Empty task registry by design; consumers link their own                                |
| `editors/tree-sitter-wire/` | Wire grammar                                                                                             | Must keep parity with `docs/Reference/Wire/grammar.md`                                 |
| `test/`, `test-logos/`      | hspec-discover test suites                                                                               | What is actually covered vs what the prose claims                                      |

Pitfalls:

- A function in `src/Cortex/...` that takes `IO` should be checked against ADR 0010 (closed
  authority).
- A type in `Cortex.*` referenced from `Logos.*` is fine; the reverse is a layer leak.
- Any `error`, `undefined`, `unsafeCoerce`, or partial pattern match in `src/Cortex/` is a finding
  candidate.

## Layer 2 — Formal narratives (Lean theory)

| Path                                     | Purpose                                                         |
| ---------------------------------------- | --------------------------------------------------------------- |
| `theory/Cortex/Graph/`                   | Track 1: Mokhov graph algebra, denotational laws, quotient laws |
| `theory/Cortex/Pulse/`                   | Track 2: fixed-topology Pulse kernel safety                     |
| `theory/Cortex/Wire/`                    | Track 3: rewrite soundness, registry boundary, CorePure subset  |
| `theory/Main.lean`, `theory/Cortex.lean` | Top-level imports; treat as the canonical proof surface         |
| `theory/README.md`                       | Status table; what is statement vs proved vs axiomatized        |
| `theory/lakefile.lean`                   | Build wiring; missing imports here are real findings            |

Pitfalls:

- `axiom`, `sorry`, `admit`, `partial`, `unsafe`, `set_option autoImplicit true` should not exist in
  committed theory. Their presence is a hard finding.
- A theorem whose name overstates what its body proves (e.g. `pureExpr_authorityFree` defined as
  `False`) is a tautology trap.
- A theorem whose hypotheses are richer than admission predicates discharge cannot be applied at the
  use site — flag the gap.

## Layer 3 — Canonical docs and roadmap

| Path                                                   | Purpose                                                      |
| ------------------------------------------------------ | ------------------------------------------------------------ |
| `docs/Architecture/01-overview.md`                     | Public substrate framing                                     |
| `docs/Architecture/02-ownership-and-boundaries.md`     | Cortex vs consumer ownership                                 |
| `docs/Architecture/03-formalism-stack.md`              | Algebraic and proof-layer vocabulary                         |
| `docs/Architecture/04-graph-and-circuit.md`            | Graph and Circuit boundary                                   |
| `docs/Architecture/05-wire-language.md`                | Wire language architecture                                   |
| `docs/Architecture/06-pulse-runtime.md`                | Runtime, frontier, durable execution                         |
| `docs/Architecture/07-rewrites-and-materialization.md` | Rewrite admission and materialization                        |
| `docs/Architecture/08-artifacts-and-provenance.md`     | Artifact and provenance contracts                            |
| `docs/Reference/Wire/grammar.md`                       | Wire grammar reference                                       |
| `docs/Reference/Wire/pure-execution.md`                | CorePure runtime reference                                   |
| `docs/Reference/Wire/contracts-ports-and-matching.md`  | Contract and port reference                                  |
| `docs/Consumers/Logos/`                                | Downstream consumer surface; not the frame for Cortex itself |

Pitfalls:

- Docs that paraphrase an accepted ADR but disagree with it are silently authoritative — readers
  treat docs as canonical even when ADRs are.
- Architecture chapters that mention concepts with no typed carrier in `src/Cortex/` are prose
  conventions, not invariants.

## Layer 4 — Decision history

| Path                  | Purpose                                                                          |
| --------------------- | -------------------------------------------------------------------------------- |
| `docs/ADRs/index.md`  | ADR catalog with status                                                          |
| `docs/ADRs/NNNN-*.md` | One decision per ADR. Status: `proposed`, `accepted`, `superseded`, `deprecated` |

Read `index.md` first. Then read every ADR whose status is `proposed` and that touches the scope —
`proposed` ADRs are where the active edge is.

Pitfalls:

- An ADR is `accepted` but the implementation has moved past it without supersession.
- Two `proposed` ADRs commit to incompatible decisions in interlocking parts of the same subsystem.
- An ADR's `related:` list is missing forward links from a newer ADR that depends on it.

## Layer 5 — Live tracking

| Source         | Command                                | Watch for                                              |
| -------------- | -------------------------------------- | ------------------------------------------------------ |
| GitHub Issues  | `gh issue list --search "<scope>"`     | Multiple issues that point at the same structural gap  |
| Recent PRs     | `gh pr list --state merged --limit 20` | What shipped in adjacent areas; what reverted          |
| Open PRs       | `gh pr list --state open`              | Conflict surfaces with ongoing work                    |
| Specific issue | `gh issue view <id>`                   | The owner's framing, the discussion thread, linked PRs |

Cortex tracks active work in GitHub Issues and PRs. Linear, downstream issue IDs, and downstream
trackers are not authoritative for Cortex planning — historical research notes may retain those
references, but new work is tracked in this repo.

## Layer 6 — External literature and prior art

Areas where Cortex sits close enough to published prior art that a memo benefits from cross-check:

- **Graph algebra.** Mokhov's polymorphic graph algebra (Track 1). Kleene-style closure semantics.
  Algebraic effects.
- **Durable execution.** Temporal/Cadence replay semantics; Restate; AWS Step Functions.
  Frontier/closure recovery is the same problem under different names.
- **Workflow languages.** Airflow, Prefect, Argo — for what _not_ to inherit (Wire is closed
  authority).
- **Pure expression languages.** Nix (CorePure surface). Dhall. Starlark.
- **Capability-secure design.** E, Caja, capability machines.
- **Bidirectional type-checking.** Dunfield-Krishnaswami, Pierce-Turner — relevant to typed contract
  checking.
- **Effect systems.** Koka, Eff, OCaml 5 effects.

Use literature to:

- name what Cortex already does so docs become more precise
- catch when Cortex is reinventing a poorly-documented version of an existing pattern
- propose stronger versions of internal claims when external results support them

Do not use literature to mandate vocabulary that has not earned its place in the codebase.

## Skipped layers

Always note in the memo which layers were not read. Common acceptable reasons:

- "Theory layer not reviewed because the scope is purely Wire-side parser work."
- "External literature not consulted because the scope is internal CI repair."
- "Issue tracker not consulted because the user supplied a specific paper as scope."

Silent skips are a finding-quality smell, not a research outcome.
