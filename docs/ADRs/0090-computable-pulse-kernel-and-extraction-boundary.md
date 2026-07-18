---
title: "ADR 0090 — Computable Pulse Kernel and Extraction Boundary"
description:
  "Keeps the fixed-topology Pulse decision kernel constructive, records the object-runtime
  extraction evidence, and defers deployed object extraction in favor of ADR 0091's host compiler."
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
  - docs/ADRs/0091-lean-hosted-freestanding-wire-c-backend.md
  - docs/Reference/proof-status.md
  - docs/Research-notes/Runtime/computable-pulse-kernel-and-c-extraction.md
---

# ADR 0090 — Computable Pulse Kernel and Extraction Boundary

## Status

Proposed — the complete named Track 2 decision path is constructive and the host/musl extraction
spike is reproducible. Native object-runtime deployment remains unverified and is no longer the
wireOS path; ADR 0091 selects topology-specialized freestanding C generation instead.

## Context

Track 2 proves frontier safety, failure closure, recovery, classification, and fixed-outcome replay
over a finite DAG. Nine operational definitions were formerly declared `noncomputable`, although
their decisions range over finite topology. Making those definitions constructive clarifies which
decision procedures a concrete implementation must supply and allows Lean-hosted executable
refinements to reuse the proof-facing semantics.

The original extraction investigation also asked whether Lean-generated objects could form a
host-neutral kernel inside a native Microkit protection domain. It established useful negative
evidence. Pinned Lean v4.29.0 uses mimalloc in its ordinary build and its object runtime assumes
hosted C++, TLS, process/IO initialization, and broader runtime services. Selecting the simple
`malloc` fallback is a target-runtime build decision, not a link-time symbol substitution. A
reduced, single-threaded runtime has not linked or booted on Microkit.

That evidence remains relevant to any consumer that truly needs an object-level dynamic kernel. It
does not require wireOS to solve that problem. ADR 0091 moves Lean to the build host and emits a
topology-specialized freestanding C program instead of shipping Lean-generated objects.

## Decision

Cortex keeps the named fixed-topology Pulse lifecycle operations constructive:

- direct readiness and closed-state classification require decidable node equality;
- proof readiness, failed-ancestor closure, recovery, and closure-wrapping classification also take
  an explicit `DecidableRel G.reaches`; and
- concrete topology representations must establish that their decision procedure agrees with the
  edge-derived `DAG.reaches` relation rather than hiding classical choice.

The Track 2 semantic boundary stays payload-agnostic. It decides structural readiness, failure
closure, recovery normalization, and classification. It does not execute tasks, grant authority,
define an effect vocabulary, persist attempts, or make external calls idempotent.

`Executor.ExternalCall*` is not intrinsically AI-specific. Excluding Pulse's current external-call
implementation from a smaller runtime is justified by its database-backed provider protocol, not by
the class of effect. Any alternative adapter still needs explicit idempotency, retryability,
indeterminate-outcome, and final-outcome semantics.

### Object-extraction evidence

`cortex-kernel-spike` remains a host-side generated-C experiment for the constructive Track 2
surface. It proves that the selected definitions generate C, compile, link, and execute with the
pinned hosted toolchain; the generated C also compiles under musl. A scalar-only temporary
experiment cross-compiled and booted on Microkit after dead-code elimination removed its boxed
wrappers and runtime references. Neither experiment proves that a `lean_object` kernel boots
freestanding.

An object-runtime deployment requires a consistent Lean target-runtime rebuild, at minimum disabling
multithreading, mimalloc, and GMP while also removing TLS and unused IO, process, libuv, signal, and
initialization surfaces. It must enumerate the complete reachable symbol set, provide checked
fail-stop panic behavior, and either supply or eliminate the reachable hosted C++/libc requirements.
No such profile is supported by this ADR today.

### Deployment boundary

The wireOS deployment path is ADR 0091's Lean-hosted static C backend. It does not use the proposed
`cortex_kernel_v1` object façade, an embedded Lean runtime, or an arena sized for Lean objects.
Fixed-topology target memory is the static section footprint of generated arrays and consumer
adapter state. `RewriteBudget` does not justify that bound; post-boot rewrite materialization is a
separate Track 3 decision.

Object-level extraction is retained as research evidence and a possible future option for consumers
that need dynamic topology or a shared runtime library. Reopening it requires a new concrete
target-runtime proposal and native boot evidence rather than an amendment that treats the stock
runtime as freestanding.

## Alternatives considered

- **Leave Track 2 noncomputable.** Rejected. The decisions are finite and the explicit instances
  improve both proofs and executable refinements without weakening any theorem.
- **Continue the reduced Lean runtime as the first wireOS milestone.** Rejected by ADR 0091. It
  solves a broader runtime-port problem than a fixed admitted program requires.
- **Treat scalar generated C as proof that the object kernel works.** Rejected. The scalar boot
  exercised no allocation, reference counting, initializer, panic path, or `lean_object` ABI.
- **Use `RewriteBudget` as the fixed kernel's memory bound.** Rejected. The first profile performs
  no rewrites; its memory follows fixed topology and representation counts.

## Consequences

### Positive

- The Track 2 theorem surface remains executable and reusable by host-side target semantics.
- The runtime research has a precise conclusion instead of a vague “reduced runtime” assumption.
- The wireOS path no longer depends on unresolved allocator, TLS, hosted C++, or initializer work.
- Effect meaning and idempotency remain explicit host obligations rather than being attributed to
  the structural kernel.

### Negative

- Reachability-dependent APIs carry explicit decision-procedure parameters.
- The existing extraction executable is evidence, not an embedded size baseline.
- Cortex still has no supported freestanding Lean object-runtime profile.
- ADR 0091 initially supports a narrower fixed topology than an object-level generic kernel could.

### Obligations

- Preserve the no-`sorry` and no-new-axiom gates for Track 2 operational theorems.
- Keep concrete reachability correspondence explicit.
- Keep host effect authority, idempotency, persistence, and payload ownership outside Track 2.
- Retain the object-runtime investigation as evidence without presenting it as an accepted target.
- Raise a separate Track 3 decision before post-boot rewrites enter any freestanding profile.

## Traceability

- Feature keys: `pulse.computable_kernel`
- Public surface: constructive `Cortex.Pulse.*` decisions and the experimental `cortex-kernel-spike`
- Implementation:
  `theory/Cortex/Pulse/{DAG,State,Frontier,Closure,Validity,Recovery,Classify,RunSafety}.lean`,
  `theory/CortexKernelSpike.lean`, and `theory/lakefile.lean`
- Tests: `lake build cortex-kernel-spike`, `just lean-check`, and `just lean-lint`
- Theory/proof: [Pulse executable decision kernel](../Reference/proof-status.md)

## Related

- [ADR 0002 — Cortex and Downstream Ownership Boundary](0002-cortex-downstream-ownership-boundary.md)
- [ADR 0038 — Wire Proof-Track Theorem Ledger](0038-wire-proof-track-theorem-ledger.md)
- [ADR 0091 — Lean-Hosted Freestanding Wire C Backend](0091-lean-hosted-freestanding-wire-c-backend.md)
- [Research Memo: Computable Pulse Kernel and C Extraction](../Research-notes/Runtime/computable-pulse-kernel-and-c-extraction.md)
