# Archetype Lenses in Research Mode

How each of the seven archetypes reads in a research synthesis pass. Keep each lens compact: the
value is the change of viewpoint, not seven mini-essays.

Load the canonical archetype profile from `agents/archetypes/<name>.md` for stance and failure
modes. This file describes how the archetype is _used_ inside a research memo specifically.

## episteme — what is established

The first lens. Walks the layered source map and records primary evidence before any interpretation.

Reads:

- current state of the implementation (not memory, not summaries)
- current state of the theory track
- current state of canonical docs and ADRs
- current state of issues and PRs
- relevant external literature

Asks:

- What does the code/theorem/doc actually say today?
- Which artifacts are stale, which are current, which are draft?
- What did I choose not to read, and why is that acceptable?

Outputs:

- evidence brief: layer-by-layer list of artifacts read, with paths and line numbers
- list of unverified assumptions surfaced during reading
- list of evidence gaps the memo will surface

Failure mode: treating a prior conversation summary as evidence. Re-read the file.

## logos — claim map

After episteme establishes what is true, logos states what is claimed. The scope of every theorem,
ADR, prose invariant, and runtime guarantee is mapped explicitly.

Reads:

- module docstrings, theorem statements, ADR Decision sections, Architecture chapter "what this
  layer owns" sentences
- export lists, type signatures, public API surface

Asks:

- What is being asserted, by which artifact, with which quantifiers?
- What is genuinely proved vs assumed vs prose-only?
- Where is the boundary between "this layer owns it" and "this layer borrows it"?

Outputs:

- claim map: a small table or list pairing each load-bearing claim with the artifact that carries it
  and what is in/out of scope

Failure mode: paraphrasing claims into vagueness. Quote precisely or cite path:line.

## kritikos — adversarial pass

Find counterexamples, broken assumptions, drift between layers, off-domain inputs, and silent
failure modes.

Reads:

- the boundaries logos identified
- error paths, partial functions, `error` calls, `unsafeCoerce`, `IO` lifts in pure contexts
- admission predicates vs theorem hypotheses
- ADR exclusion lists vs ADT shapes

Asks:

- Can an arbitrary value satisfy the formal assumptions while violating the intended runtime
  behavior?
- Where does the implementation accept inputs that the theory rejects, or vice versa?
- What is the smallest model that satisfies the current contract but breaks the intended claim?
- Where is one layer silently more permissive than another?

Outputs:

- countermodels and concrete drift cases, each tied to a layer pair

Failure mode: confusing surprise with error. A surprising design is not necessarily a wrong design;
check the ADR and module owners first.

## themis — contract audit

Audit contracts, invariants, ownership, layer placement, and ADR conformance.

Reads:

- ADR-by-ADR conformance against current code/docs/theory
- the layer map: Platform / Cortex / Logos / downstream
- implicit invariants in module docstrings and module exports
- the closed-authority and registered-authority surfaces

Asks:

- For each contract a layer claims to own, is it enforced by a typed boundary, a compiler check, a
  runtime guard, a process gate, or only prose?
- Does each concept live at the right semantic level, or has it leaked up/down?
- Are there ADRs that commit to obligations the implementation has not yet taken on?
- Are there obligations the implementation has taken on that no ADR records?

Outputs:

- contract coverage matrix: what is owed, what carries it, what is missing
- layer-leak list: concepts that are not at the layer their owners think they are

Failure mode: treating ADRs as authoritative when code has moved on, or vice versa.

## techne — repair sketches

Convert findings into concrete next steps. Each finding earns its place by being actionable.

Reads:

- the findings produced so far
- existing skills (`architecture`, `lean-theorem-attack`, `impl`, `doc-review-and-fix`, `ship`)
- ADR templates, issue templates, theorem patterns

Asks:

- What is the smallest concrete artifact that would resolve this finding — issue, ADR draft, theorem
  statement, test, prototype, migration note, doc patch?
- Which skill is the right home for the follow-up?
- What is the rough cost?

Outputs:

- per-finding "next step" line: artifact + skill + cost estimate

Failure mode: proposing big abstractions when one concrete next step is available.

## poiesis — alternative framings

Generate alternative encodings, names, decompositions, and analogies — even ones the user will not
adopt — so the memo records the design space, not just the chosen branch.

Reads:

- the current encoding and its alternatives in nearby ADRs and prior art
- adjacent literature for richer vocabulary
- analogous systems and their boundary choices

Asks:

- Could this be encoded type-level instead of predicate-level, or vice versa?
- Is there better vocabulary the system is reaching for?
- Is the current decomposition cutting at the right joint?
- What would a different layering choice cost?

Outputs:

- alternative-encodings list: short notes describing each alternative, with one line on cost vs
  benefit

Failure mode: aestheticism. An "elegant" alternative that blocks the next ADR is not better.

## sophia — synthesis and priority

The final lens. Decide what matters most now, and what should be deferred.

Reads:

- every finding from the previous lenses
- the project's near-term roadmap and active priorities

Asks:

- What is the highest-risk unresolved issue?
- Which findings block the next slice, the next PR, or the next ADR?
- Which can be accepted as explicit debt with a tracked owner?
- What is the one thing the user should pick up first if they read no further?
- What single trade-off best characterizes the current state?

Outputs:

- decision summary: top priorities, residual risks, and the single next move
- bucket assignment for each finding: Act now / Design next / Write up / Parked

Failure mode: averaging incompatible findings into a bland recommendation.

## How the lenses compose

The seven lenses are not independent reports. They run in order:

1. `episteme` produces the evidence base.
2. `logos` extracts the claim structure from that base.
3. `kritikos` attacks the claim structure.
4. `themis` checks the contracts the claim structure is supposed to carry.
5. `techne` turns the survivors into concrete next steps.
6. `poiesis` records the design space around them.
7. `sophia` ranks and decides.

A finding becomes load-bearing when it survives at least one cross-lens check. A finding that only
appears under one lens is usually still genuine, but earns more confidence when a second lens
agrees.

Compress the archetype synthesis in the memo into one line per lens. Long archetype reports are an
anti-pattern in research mode.
