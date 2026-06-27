---
title: "ADR 0078 — Lean-Owned Wire Elaboration IR and Executable Certifying Admission Kernel"
description:
  "Records that Cortex maintains a Lean-owned post-parse Wire elaboration IR and an executable,
  soundness-by-construction certifying admission kernel for the primitive graph subset, without
  deciding the compiler-authority question that issue #103 keeps open."
sidebar:
  label: "0078. Lean elaboration kernel"
  order: 78
status: proposed
date: 2026-06-27
superseded_by: null
related:
  - docs/Architecture/03-formalism-stack.md
  - docs/Architecture/05-wire-language.md
  - docs/Reference/proof-status.md
  - docs/Reference/feature-status.md
  - docs/ADRs/0021-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0038-wire-proof-track-theorem-ledger.md
  - docs/ADRs/0047-wire-frontier-linearity-and-precedence.md
  - "GitHub #103"
---

# ADR 0078 — Lean-Owned Wire Elaboration IR and Executable Certifying Admission Kernel

## Status

Proposed — this ADR records a proof-track artifact that already exists for the primitive graph
subset and fixes the boundary it keeps. It is deliberately a **partial** answer to the larger
compiler-authority question: it does not decide whether the Wire compiler stays Haskell-first,
becomes a Lean-specified Haskell implementation, or moves into Lean. That decision remains open on
GitHub #103.

## Context

Two earlier decisions frame Wire elaboration but leave a gap between them.

- ADR 0021 decides that **Wire source elaborates to circuits** and that the executable elaborator is
  a Haskell compiler: it folds statically reducible CorePure during elaboration, fixes the
  post-elaboration vertex set, and routes input-dependent residue to runtime pure execution. ADR
  0021's elaborator is an implementation discipline ("maximal static reduction is a
  compiler-discipline rule … a later proof-oriented slice should state it formally"), not a
  mechanized object.
- ADR 0038 collects the Wire proof-track theorem targets and explicitly treats the elaborator as
  **future**: compiler admission gates "are not theorem-ledger rows until the parser or elaborator
  itself is mechanized," and 0038 records that it "settles what must be proved before deciding
  whether the compiler remains Haskell-first, becomes a Lean-specified Haskell implementation, or
  eventually moves into Lean," pinning that authority question to GitHub #103 as undecided.

Since 0038 was written, the elaborator stopped being only future for one subset. The theory track
now carries a **Lean-owned post-parse IR** and an **executable certifying admission kernel** over
the primitive graph-expression subset. This is the strongest gap in the proof track that has no
governing ADR: a non-trivial, soundness-bearing mechanization exists, it is consumed by `lean-check`
at build time, and yet the canon describes the elaborator as unmechanized and the authority question
as entirely open. Recording what this kernel _is_ — and, just as load-bearing, what it does **not**
decide — is overdue.

The constraint is sharp. Recording the kernel must not be read as choosing Lean as the compiler spec
or implementation. The kernel covers a subset, certifies a relation rather than producing the
runtime circuit, and is tied to the Haskell compiler only through a differential oracle, not through
extraction. Overstating it would silently resolve #103; understating it would keep an accepted,
checked proof surface invisible to the canon.

## Decision

Record that Cortex maintains, as a proof-track artifact, a **Lean-owned Wire elaboration IR** and an
**executable certifying admission kernel** over the primitive graph subset, and fix the boundary
that artifact keeps. Concretely:

- **The IR is Lean-owned and post-parse.** `Cortex.Wire.ElaborationIR`
  (`theory/Cortex/Wire/ElaborationIR.lean`) names the static objects Wire elaboration consumes
  _after_ the external front end has already run: `GraphExpr` (the post-source-include expression
  tree, with constructors `empty`, `node`, `binding`, `overlay`, `connect`, `star`, `select`,
  `make`, `makeEach`), accepted node/kind/contract declarations, output shapes, and the
  `AdmittedModuleShell` that names the legal node and binding references. By construction this IR
  "does not model the text parser, filesystem includes, runtime executors, or Pulse execution";
  those stay outside the kernel.

- **The kernel is soundness-by-construction.** `CertifiedGraph.elaborate`
  (`theory/Cortex/Wire/GraphElaborationExec.lean`) is an executable function

  ```text
  elaborate (mod : AdmittedModuleShell) :
    (expr : GraphExpr) →
      Except ElabError { graph : CertifiedGraph mod // Admits mod expr graph }
  ```

  whose success value carries the `GraphElaboration.Admits` derivation as data. There is no separate
  trust step between the executable path and the admission relation: `elaborate_sound` is the
  conventional corollary `result.property`, not a re-proof. The kernel decides disjointness
  (`disjointCheck`, certified by `disjoint_of_disjointCheck`), computes the ADR 0047-compatible
  boundary pairs and rejects non-functional matchings — the fan-in/fan-out/ambiguity rejections of
  the Haskell compiler — as `ambiguousConnect` (`matchBoundary`), and builds the certified
  `BulkContract` trace with its exact-pair-set witness (`buildBulkContract`).

- **Scope is the primitive subset.** `elaborate` certifies `empty`, `node`, `binding`, `overlay`,
  and `connect`. The derived forms `star`, `select`, `make`, and `makeEach` return a named
  `ElabError.unsupportedForm`; their certified shapes have their own acceptance surfaces and join
  the kernel later. The kernel's rejection constructors (`unknownNode`, `unknownBinding`,
  `overlayConflict`, `connectConflict`, `ambiguousConnect`, `unsupportedForm`) mirror the Haskell
  compiler's rejection surface for that subset.

- **Haskell correspondence is differential, not extraction.** The kernel is connected to the live
  Haskell compiler only through a differential oracle: `Cortex.Wire.LeanFixture`
  (`src/Cortex/Wire/LeanFixture.hs`) renders the `WireAdmissionArtifact` that a real compilation
  attaches into Lean source, and the generated modules under
  `theory/Cortex/Wire/AdmissionArtifact/Differential/` reconstruct the core expression from the
  artifact's own primitive trace, re-run `elaborate`, and `#guard` that it lands on the artifact's
  exposed boundary at every `lean-check`. The Haskell suite re-renders every fixture and fails on
  drift, so the bridge is a tested code path — but it remains a differential check over a
  representative fixture corpus, **not** a proof that the compiler is extracted from or specified by
  the kernel.

This records a proof-track representation and its boundary. It does **not** decide which layer is
the normative authority for Wire elaboration; see Boundary Rules and Obligations.

## Boundary Rules

These rules fix what the recorded artifact is allowed to claim. They are the edges a reader must not
cross when citing this ADR.

1. **Post-parse only.** The IR begins after parsing and source inclusion. Any claim about lexical
   grammar, `include_str`/`include_dir` resolution, identifier shape beyond non-emptiness, or
   generated-name freshness is out of scope and must carry its own witness. `NominalNameValid` is
   the minimal `name ≠ ""` invariant, explicitly "not pretending to mechanize the parser."

2. **Soundness, not completeness.** `elaborate` returning `ok` proves the result is admitted
   (`Admits`). The kernel does not claim that every Haskell-accepted program elaborates here, that
   `connect` matching is unique up to trace order, or that the certified graph equals the runtime
   `CompiledCircuit`. Confluence and completeness are named correspondence targets elsewhere, not
   results of this ADR.

3. **Primitive subset is the frontier.** Only `empty`/`node`/`binding`/`overlay`/`connect` are
   certified. `unsupportedForm` for the derived forms is honest scope, not a soundness gap: the
   differential corpus is core-only at the source-visible frontier, and select-internal choice exits
   stay the validator's and the select theorems' obligation.

4. **Differential is the only tie to the compiler.** Correspondence to `src/Cortex/Wire/Compile.hs`
   runs through rendered artifacts and `#guard` agreement over a fixture set. No extraction, shared
   oracle, or compiler-from-Lean is asserted. Programs outside the fixture set get the Haskell-side
   validator only.

5. **No authority claim.** The kernel being executable and Lean-owned does not make Lean the
   compiler spec or implementation. The authority model is exactly the open question on #103; this
   ADR leaves it open.

## Alternatives considered

- **Fold the kernel into ADR 0038's ledger as another theorem row.** Rejected. 0038 is the
  proof-track _ledger_ — a non-feature governance ADR that points at `proof-status.md` and carries
  no Traceability block. The executable kernel is a substrate proof _capability_ with a stable
  feature key, source/theory implementation, and a differential test surface; it needs its own
  one-decision record so its boundary and its `partial` status are explicit rather than a status
  cell in a table.

- **Wait for #103 and record the kernel only once authority is decided.** Rejected. That leaves an
  accepted, build-checked soundness surface undocumented in canon and lets readers infer either too
  much ("Lean is the compiler now") or too little ("the elaborator is still entirely future") from
  0021 and 0038. Recording the artifact and explicitly scoping out the authority question is more
  honest than silence.

- **Record the kernel as the Wire compiler's specification.** Rejected — it would presume the answer
  to #103. The kernel certifies a relation over a subset and corresponds to the compiler only
  differentially; calling it the spec would overclaim and pre-empt the binding question this ADR is
  required to leave open.

## Consequences

### Positive

- The strongest proof-track gap becomes visible: a Lean-owned elaboration IR and a
  soundness-by-construction admission kernel are now governed canon with a fixed boundary, instead
  of an undocumented surface that contradicts 0038's "elaborator is future" framing.
- Soundness has no separate trust step for the primitive subset — `ok` carries its own `Admits`
  proof — and that property is stated where future proof PRs can cite it.
- The differential boundary between Lean and Haskell is written down, so later work cannot quietly
  upgrade a `#guard` corpus into a claimed extraction or compiler-spec without amending this ADR.

### Negative

- One more proof-track ADR to keep current as the kernel grows. When derived forms (`star`,
  `select`, `make`, `makeEach`) leave `unsupportedForm`, the scope statement here goes stale and
  must be updated.
- The recorded capability is genuinely partial: a reader wanting end-to-end "the compiler is
  correct" gets a subset relation plus a fixture differential, and the gap to that stronger claim is
  real.

### Obligations

- **Keep #103 open in canon.** Until GitHub #103 decides the compiler-authority model
  (Haskell-first, Lean-specified Haskell, or Lean implementation), this ADR must not be read as
  choosing one. If #103 resolves, update or supersede this ADR — and ADR 0038 — to reflect the
  chosen authority model.
- Keep the IR post-parse: do not add parser, filesystem, or runtime modelling to
  `Cortex.Wire.ElaborationIR` without a separate decision.
- When a derived form joins the certifying kernel, update the primitive-subset scope statement and
  the `proof.elaboration_kernel` feature-status evidence rather than silently widening the claim.
- Keep the Haskell↔Lean tie differential: the renderer in `src/Cortex/Wire/LeanFixture.hs` and the
  drift gate in `test/Cortex/Wire/CompileSpec.hs` are the sanctioned correspondence; promoting them
  to extraction or a shared oracle is a new decision.

## Open questions

- **Compiler authority (#103).** This ADR records the Lean-owned elaboration IR and the executable
  certifying kernel but does **not** decide the normative authority for Wire elaboration. The open
  trichotomy is exactly GitHub #103: whether the Wire compiler (a) stays **Haskell-first** with Lean
  as a differential check, (b) becomes a **Lean-specified Haskell implementation**, or (c) **moves
  into Lean**. Recording the kernel is at most a partial input to that decision and must not be read
  as selecting any branch. If #103 resolves, this ADR and ADR 0038 are updated or superseded to
  reflect the chosen model.

## Traceability

- Feature keys: `proof.elaboration_kernel`
- Public surface: `Cortex.Wire` (Haskell elaboration root),
  [`docs/Reference/proof-status.md`](../Reference/proof-status.md)
- Implementation: `theory/Cortex/Wire/GraphElaborationExec.lean` (`CertifiedGraph.elaborate`,
  `disjointCheck`, `matchBoundary`, `buildBulkContract`, `elaborate_sound`),
  `theory/Cortex/Wire/ElaborationIR.lean` (the Lean-owned `GraphExpr` / `AdmittedModuleShell` IR),
  `theory/Cortex/Wire/GraphElaboration.lean` (the `Admits` / `CertifiedGraph` carrier),
  `src/Cortex/Wire/Compile.hs` (the Haskell elaborator), `src/Cortex/Wire/LeanFixture.hs` and
  `src/Cortex/Wire/AdmissionArtifact.hs` (the differential bridge and witness schema)
- Tests: `test/Cortex/Wire/CompileSpec.hs` (admission-artifact validation and the
  emitted/differential Lean-fixture drift gate); the proof-side `#guard` corpus lives under
  `theory/Cortex/Wire/AdmissionArtifact/Differential/` and runs at `lean-check`
- Theory/proof: [the "Executable admission kernel" row](../Reference/proof-status.md#matrix) and
  [The Emission-Soundness Target](../Reference/proof-status.md#the-emission-soundness-target) clause
  4 (the per-fixture kernel differential)
- Tracking: GitHub #103

## Related

- [Chapter 03 — Formalism stack](../Architecture/03-formalism-stack.md)
- [Chapter 05 — Wire language](../Architecture/05-wire-language.md)
- [ADR 0021 — Wire Source Elaborates to Circuits](./0021-wire-source-elaborates-to-circuits.md) —
  the Haskell elaborator this kernel mechanizes a subset of.
- [ADR 0038 — Wire Proof-Track Theorem Ledger](./0038-wire-proof-track-theorem-ledger.md) — frames
  the elaborator as future and pins the compiler-authority question to GitHub #103.
- [ADR 0047 — Wire Frontier Linearity and Precedence](./0047-wire-frontier-linearity-and-precedence.md)
  — the boundary-matching policy the kernel's `connect` matcher computes.
- [Cortex Proof Status](../Reference/proof-status.md) — the proof-claim dashboard the `Theory` cell
  links to.
- [Cortex Feature Status](../Reference/feature-status.md) — the `proof.elaboration_kernel`
  capability row.
- GitHub #103
