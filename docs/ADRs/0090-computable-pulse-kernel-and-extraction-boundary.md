---
title: "ADR 0090 — Computable Circuit-Engine Decision Kernel and Extraction Boundary"
description:
  "Names the constructive fixed-topology semantics as the target-independent circuit-engine decision
  kernel, records object-runtime evidence, and selects build-host C generation."
sidebar:
  label: "0090. Circuit-engine kernel"
  order: 90
status: accepted
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

# ADR 0090 — Computable Circuit-Engine Decision Kernel and Extraction Boundary

## Status

Accepted. The complete named Track 2 decision path is constructive; `StaticC` adds the
target-independent whole-drive decision, checkpoint gate, typed snapshot validity, and import/export
round trips; and ADR 0091's generated C is checked against the Haskell and Lean models. Native Lean
object-runtime deployment remains unverified and is explicitly not the selected target path.

## Context

Track 2 proves frontier safety, failure closure, recovery, classification, and fixed-outcome replay
over a finite DAG. These definitions originated under `Cortex.Pulse` because Pulse was the first
runtime, but the computable surface contains no database, service, lease, or host authority. Calling
it the “Pulse kernel” therefore confused a target-independent decision model with one runtime host.
Nine operational definitions were formerly declared `noncomputable`, although their decisions range
over finite topology. Making them constructive clarifies which procedures a concrete engine must
supply and lets Lean-hosted executable refinements reuse the proof-facing semantics.

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

Cortex names this surface the **target-independent circuit-engine decision kernel** and keeps its
fixed-topology lifecycle operations constructive:

- direct readiness and closed-state classification require decidable node equality;
- proof readiness, failed-ancestor closure, recovery, and closure-wrapping classification also take
  an explicit `DecidableRel G.reaches`; and
- concrete topology representations must establish that their decision procedure agrees with the
  edge-derived `DAG.reaches` relation rather than hiding classical choice.

The kernel stays payload-agnostic. It decides structural readiness, failure closure, recovery
normalization, classification, whole-drive checkpoint gating, and typed structural snapshot
validity. It does not execute tasks, grant authority, define an effect vocabulary, persist attempts,
or make external calls idempotent. ADR 0092 assigns those responsibilities to runtime hosts.

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

The selected deployment path is ADR 0091's Lean-hosted static C backend. It does not use the
proposed `cortex_kernel_v1` object façade, an embedded Lean runtime, or an arena sized for Lean
objects. Fixed-topology target memory is the static section footprint of generated arrays and
consumer adapter state. `RewriteBudget` does not justify that bound; post-boot rewrite
materialization is a separate Track 3 decision.

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

- The circuit-engine theorem surface remains executable and reusable by host-side target semantics.
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

- Preserve the no-`sorry` and no-new-axiom gates for circuit-engine operational theorems.
- Keep concrete reachability correspondence explicit.
- Keep host effect authority, idempotency, persistence, and payload ownership outside Track 2.
- Retain the object-runtime investigation as evidence without presenting it as an accepted target.
- Raise a separate Track 3 decision before post-boot rewrites enter any freestanding profile.

## Traceability

- Feature keys: `wire.circuit_engine_decision_kernel`
- Public surface: constructive `Cortex.Pulse.*` decision definitions,
  `Cortex.Wire.StaticC.driveEngine`, and the experimental `cortex-kernel-spike`
- Implementation:
  `theory/Cortex/Pulse/{DAG,State,Frontier,Closure,Validity,Recovery,Classify,RunSafety}.lean`,
  `theory/CortexKernelSpike.lean`, and `theory/lakefile.lean`
- Tests: `lake build cortex-kernel-spike`, `just lean-check`, and `just lean-lint`
- Theory/proof: [Circuit-engine decision kernel](../Reference/proof-status.md)

## Related

- [ADR 0002 — Cortex and Downstream Ownership Boundary](0002-cortex-downstream-ownership-boundary.md)
- [ADR 0038 — Wire Proof-Track Theorem Ledger](0038-wire-proof-track-theorem-ledger.md)
- [ADR 0091 — Lean-Hosted Freestanding Wire C Backend](0091-lean-hosted-freestanding-wire-c-backend.md)
- [ADR 0092 — Circuit Engine and Runtime-Host Boundary](0092-circuit-engine-runtime-host-boundary.md)
- [Research Memo: Computable Pulse Kernel and C Extraction](../Research-notes/Runtime/computable-pulse-kernel-and-c-extraction.md)
