---
title: "ADR 0090 — Computable Pulse Kernel and Extraction Boundary"
description:
  "Makes the fixed-topology Pulse lifecycle decisions constructive and defines a Cortex-owned,
  host-neutral kernel-library target gated on a reduced target runtime."
sidebar:
  label: "0090. Computable Pulse kernel"
  order: 90
status: proposed
date: 2026-07-17
superseded_by: null
related:
  - docs/Architecture/06-pulse-runtime.md
  - docs/ADRs/0002-cortex-downstream-ownership-boundary.md
  - docs/ADRs/0038-wire-proof-track-theorem-ledger.md
  - docs/Reference/proof-status.md
  - docs/Research-notes/Runtime/computable-pulse-kernel-and-c-extraction.md
---

# ADR 0090 — Computable Pulse Kernel and Extraction Boundary

## Status

Proposed — the constructive Track 2 kernel and generated-C evidence exist, while a reduced static
runtime and native Microkit boot remain explicit acceptance gates.

## Context

Track 2 proves Pulse frontier safety, failure closure, recovery, classification, and fixed-outcome
replay over a finite DAG. At the start of this work, nine functions on that decision path were
declared `noncomputable`, even though the runtime decisions were finite. This prevented the proven
surface from serving directly as an executable kernel and obscured which concrete graph decisions a
caller must supply.

Pulse's Haskell service correctly keeps task meaning behind a generic registry: Cortex cannot know
the semantics of every model call, tool, or host action. That service shape is not the semantic
kernel itself. A closed-vocabulary consumer such as wireOS needs the same lifecycle decisions but
must interpret frontier nodes through its own admitted effect vocabulary and authority policy, not
through Pulse's task registry. The shared layer is the payload-agnostic Track 2 state machine.

Lean 4 can emit C, but the pinned v4.29.0 host runtime links POSIX threads, libuv, GMP, mimalloc,
and glibc-facing support that a native Microkit protection domain does not provide. Microkit also
has no implicit heap: an application arena is ordinary statically provisioned system memory. Cortex
therefore needs one decision that distinguishes a Cortex-owned executable semantic kernel, its host
interpretation boundary, and a supported embedded runtime.

## Decision

Cortex keeps the named fixed-topology Pulse lifecycle decisions constructive. Direct readiness and
finite status classifiers require decidable node equality. Proof readiness, failed-ancestor closure,
recovery, and the closure-wrapping classifier additionally accept an explicit
`DecidableRel G.reaches`. Cortex will not hide a transitive-closure oracle behind classical choice;
a concrete topology representation must compute it and correspondence work must establish that it
agrees with `DAG.reaches`.

Cortex defines the long-term artifact as a Cortex-owned, host-neutral `cortex-kernel` library, not a
wireOS-private runtime and not a second copy of the Haskell Pulse task interpreter. Its semantic
boundary is pull-frontier/push-fact inversion of control:

- initialize or recover from a validated finite topology and structural state;
- expose the current ready frontier and lifecycle classification;
- accept topology-scoped opaque node facts/outcome payload handles; and
- never import or interpret a Pulse `TaskRegistry`, wireOS effect authorization, or another
  consumer's task vocabulary.

The host owns dispatch, authority checks, effect execution, payload encoding, and persistence. This
ADR fixes that abstract boundary, not a byte-level C ABI or serialization format. A future thin
`cortex` executable may wrap the library for diagnostics or a chosen transport, but the library is
primary because consumers must supply effect interpretation rather than have it compiled into one
canonical binary.

This is an executable refinement of Track 2 under ADR 0038's theorem/correspondence ledger, not a
new proof methodology. Existing safety, closure, classification, and replay theorems remain intact.
The proof/runtime frontier bridge is stored as pointwise semantic equivalence so it is independent
of a caller's decision procedure, while frontier-set equality remains a theorem whenever the
explicit instances are available.

Cortex retains `cortex-kernel-spike` as a reproducible generated-C and native-linkage experiment. It
is the precursor to the library, not a stable C ABI, a supported deployment artifact, or evidence
that stock Lean code boots on Microkit. Lean C extraction is a viable path to investigate, precisely
to the extent demonstrated: the constructive kernel generates C, compiles, links, and runs on the
pinned host toolchain; the generated C also compiles with musl. Native Microkit deployment remains
unverified until a minimal import surface and reduced single-threaded Lean runtime are rebuilt for
the target and booted.

The first extraction boundary is fixed topology. It does not include live rewrite planning,
admission, or materialization. Track 3 construction remains noncomputable where it chooses a graph
syntax representative of an unordered relation. A consumer that needs post-boot rewrites must first
raise a separate Track 3 computability and persistence decision.

The library creates an outbound consumer seam relevant to Track 5, but does not discharge Track 5 as
currently stated. Track 5's unstarted theorem is about proving that Cortex never imports a consumer;
no such import-graph proof lands here. The host-neutral callback boundary preserves that direction
and gives the future proof a concrete public seam to classify. If Track 5 is broadened to cover
executable consumer integration, that scope change needs an explicit update rather than a claim that
extraction silently proved it.

## Alternatives considered

- **Leave Pulse Haskell-only and reimplement the lifecycle semantics independently in Rust.** This
  keeps Lean out of the deployed artifact and fits wireOS's native language, but duplicates the
  frontier, closure, recovery, and classification semantics and creates a permanent correspondence
  obligation without reusing the proven decision code.
- **Use Lean only as an oracle or test generator for a separately written Rust kernel.** This avoids
  porting the Lean runtime and may be the better deployment choice if the reduced-runtime spike
  fails. It still requires an exhaustive shared representation and differential harness; passing
  generated cases is weaker than executing the proven definitions. Keep this as the fallback, not
  the first conclusion before the target-runtime experiment.
- **Make a canonical `cortex` executable own a generic task registry.** Rejected because task
  meaning belongs to the host interpreter. Baking Pulse's open registry into the canonical binary
  would force closed-vocabulary consumers through the wrong abstraction; baking a downstream
  vocabulary into it would reverse ADR 0002's dependency direction.
- **Ship the stock Lean v4.29.0 runtime in a Microkit protection domain.** Rejected for the current
  target: measured host linkage and runtime sources assume pthread/libuv/process/IO/GMP/libc
  facilities and stack behavior that Microkit does not supply as a POSIX guest.
- **Make Track 3 constructive in the same change.** Rejected because the first residual kernel can
  consume a pre-realized topology. Canonical graph-representative construction and durable rewrite
  recovery are a separable scope that becomes necessary only if wireOS executes rewrites after boot.

## Consequences

### Positive

- The full named Track 2 decision path is executable without classical-choice declarations.
- Concrete consumers can see the exact topology capabilities they must provide: node equality and,
  for reachability-level operations, a strict-reachability decision procedure.
- Pulse and closed-vocabulary consumers can share lifecycle code without sharing task semantics; the
  callback boundary keeps both interpreters outside the kernel.
- The generated-C path has a small reproducible semantic smoke target rather than depending on the
  diagnostic `theory/Main.lean` executable.
- Proof statements remain independent of a particular C ABI, persistence engine, or consumer.

### Negative

- Reachability-dependent API signatures now carry `DecidableRel G.reaches`, including downstream
  Wire/Pulse proof wrappers.
- The current extraction executable is very large because its import closure includes broad
  Mathlib/proof support; it is evidence, not an embedded-size baseline.
- The abstract library boundary still needs a concrete ABI and representation; a native deployment
  additionally needs a target runtime, a conservatively bounded and statically provisioned arena, an
  initialization/entry wrapper, and a persistence/effect adapter.

### Obligations

- Keep every Track 2 operational theorem axiom-free and preserve the no-`sorry` gate.
- Specify and check correspondence between any concrete reachability implementation and
  `DAG.reaches` before treating extracted decisions as authoritative.
- Keep node dispatch and effect interpretation behind the host boundary; neither Pulse's registry
  nor a downstream closed vocabulary may enter the kernel.
- Decide a versioned C representation and ownership/error contract only after the runtime-facing
  Lean import split establishes the types and memory behavior that can actually be supported.
- Split a minimal runtime-facing import surface and measure it with a single-threaded static target
  runtime before beginning consumer integration.
- Derive a fail-closed arena and stack bound from the admitted topology/state and optional rewrite
  budget, and carry those requirements through the host's static system resource plan.
- Treat a real Microkit boot with fixed in-memory topology/state as the next feasibility gate; do
  not infer it from host or musl C compilation.
- Keep persistence format, atomic commit, crash-safe recovery, effect idempotency, and topology
  compatibility in the host integration boundary.
- Raise a separate decision before making live Track 3 rewrites part of the extracted kernel.

## Traceability

- Feature keys: `pulse.computable_kernel`
- Public surface: future host-neutral `cortex-kernel` lifecycle boundary over `Cortex.Pulse.*`,
  [theory track roadmap](../../theory/README.md), and the
  [runtime research memo](../Research-notes/Runtime/computable-pulse-kernel-and-c-extraction.md)
- Implementation:
  `theory/Cortex/Pulse/{DAG,State,Frontier,Closure,Validity,Recovery,Classify,RunSafety}.lean`,
  `theory/CortexKernelSpike.lean`, and `theory/lakefile.lean`
- Tests: `lake build cortex-kernel-spike` and the `just lean-check`/`just lean-lint` gates
- Theory/proof: [Pulse executable decision kernel](../Reference/proof-status.md)

## Related

- [ADR 0002 — Cortex and Downstream Ownership Boundary](0002-cortex-downstream-ownership-boundary.md)
- [ADR 0038 — Wire Proof-Track Theorem Ledger](0038-wire-proof-track-theorem-ledger.md)
- [Chapter 06 — Pulse Runtime](../Architecture/06-pulse-runtime.md)
- [Research Memo: Computable Pulse Kernel and C Extraction](../Research-notes/Runtime/computable-pulse-kernel-and-c-extraction.md)
- [Paper 1 — Lean-Haskell Pulse Boundary](../Publications/Paper-1-staged-reduction/lean-haskell-boundary.md)
