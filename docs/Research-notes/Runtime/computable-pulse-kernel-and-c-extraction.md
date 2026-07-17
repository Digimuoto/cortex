---
title: "Research Memo: Computable Pulse Kernel and C Extraction"
description:
  "Audits the fixed-topology Pulse proof kernel for executability and measures the gap between Lean
  4 generated C and a native seL4/Microkit protection domain."
date: 2026-07-17
scope: runtime
status: active
related:
  - docs/ADRs/0090-computable-pulse-kernel-and-extraction-boundary.md
  - docs/Reference/proof-status.md
  - "wireOS #8"
---

# Research Memo: Computable Pulse Kernel and C Extraction

**Method:** combined implementation reading, proof-preserving refactor, toolchain experiment, and
external primary-source review **Confidence profile:** high on the Cortex computability audit and
host linkage; medium on the reduced-runtime port estimate; low on native Microkit viability until a
target build boots

---

## Context

wireOS's residual-lifecycle roadmap exposed a more general missing Cortex artifact: a
single-threaded executor kernel that can resume an admitted circuit without importing the
PostgreSQL-backed Pulse service or its open task registry. Cortex already proves the
payload-agnostic fixed-topology lifecycle decisions in Lean. Pulse and a closed-vocabulary wireOS
runtime can therefore be peer host interpreters over the same kernel rather than one consumer being
forced through the other's effect vocabulary. At the starting revision, however, nine of the named
Track 2 decision functions were declared `noncomputable`. The question was whether those
declarations represented classical semantics, and whether Lean's generated C could plausibly become
a host-neutral Cortex kernel, including on a native Microkit protection domain.

This investigation was performed at Cortex commit `2856eebf62c18e345e11792bb1470cb3751ad029`, not at
the older wireOS-side investigation revision. The fixed-topology theorem inventory and the nine
Pulse declarations were rechecked before editing. The result separates two questions: the Pulse
decision kernel is now constructive, but the stock Lean runtime is not a freestanding Microkit
runtime.

## Method

The local audit used
`git grep -n '^noncomputable def' HEAD -- theory/Cortex/Pulse theory/Cortex/Wire`, read every match
and its dependency chain, and compared Track 2 against the Haskell decision path in
`GraphRuntime.hs`. Each tractable Pulse declaration was made computable, then the complete Lean tree
and a dedicated extraction executable were rebuilt. The experiment also inspected generated C, link
inputs, ELF dependencies, and binary sizes.

The extraction spike was built with the pinned `leanprover/lean4:v4.29.0` toolchain:

```text
nix develop -c sh -lc 'cd theory && lake build cortex-kernel-spike'
theory/.lake/build/bin/cortex-kernel-spike
ldd theory/.lake/build/bin/cortex-kernel-spike
readelf -d theory/.lake/build/bin/cortex-kernel-spike
```

It recovers a one-node state, computes the direct frontier, and classifies the recovered result. A
musl experiment compiled the generated `CortexKernelSpike.c` successfully, then attempted a fully
static link with the Lake link-object set and musl-targeted GMP/libuv packages. No Microkit boot was
attempted.

**Artifacts examined:**

- `theory/Cortex/Pulse/{DAG,State,Fact,Frontier,Closure,Validity,Recovery,Classify,RunSafety}.lean`
- `theory/Cortex/Wire/{RunTrace,BoundaryResource,Planner/Construction,Planner/Chain}.lean`
- `theory/Cortex/Graph/Relation.lean`, `theory/lakefile.lean`, and `theory/CortexKernelSpike.lean`
- `src/Cortex/Pulse/{Executor,GraphRuntime,Iteration,Rewrite,Scheduler,Health}.hs`,
  `src/Cortex/Pulse/Executor/ExternalCall*.hs`, and `src/Cortex/Pulse/Memory/`
- `docs/Publications/Paper-1-staged-reduction/lean-haskell-boundary.md`, ADRs 0002 and 0038,
  `docs/Reference/proof-status.md`, and `theory/README.md`
- Lean 4 v4.29.0
  [`CMakeLists.txt`](https://github.com/leanprover/lean4/blob/v4.29.0/src/CMakeLists.txt),
  [`runtime/CMakeLists.txt`](https://github.com/leanprover/lean4/blob/v4.29.0/src/runtime/CMakeLists.txt),
  [`lean.h`](https://github.com/leanprover/lean4/blob/v4.29.0/src/include/lean/lean.h),
  [`alloc.cpp`](https://github.com/leanprover/lean4/blob/v4.29.0/src/runtime/alloc.cpp),
  [`thread.cpp`](https://github.com/leanprover/lean4/blob/v4.29.0/src/runtime/thread.cpp),
  [`init_module.cpp`](https://github.com/leanprover/lean4/blob/v4.29.0/src/runtime/init_module.cpp),
  and [`libuv.cpp`](https://github.com/leanprover/lean4/blob/v4.29.0/src/runtime/libuv.cpp)
- [Microkit 2.2.0 manual](https://docs.sel4.systems/projects/microkit/manual/2.2.0/),
  [Microkit 2.2.0 release notes](https://docs.sel4.systems/releases/microkit/2.2.0.html),
  [`libmicrokit` source](https://github.com/seL4/microkit/tree/2.2.0/libmicrokit), its
  [`microkit.ld`](https://github.com/seL4/microkit/blob/2.2.0/libmicrokit/microkit.ld), and the
  [seL4 untyped-memory tutorial](https://docs.sel4.systems/Tutorials/untyped.html); wireOS ADRs
  [0001](https://github.com/Digimuoto/wireOS/blob/main/docs/ADRs/0001-scope-layer-boundaries-and-admitted-referent.md)
  and
  [0004](https://github.com/Digimuoto/wireOS/blob/main/docs/ADRs/0004-minimal-system-graph-allocation-and-authority.md),
  and wireOS issues [#8](https://github.com/Digimuoto/wireOS/issues/8),
  [#11](https://github.com/Digimuoto/wireOS/issues/11), and
  [#12](https://github.com/Digimuoto/wireOS/issues/12)

## Findings

### Finding 1 — All nine fixed-topology Pulse decision definitions were tractably computable

**Confidence:** High. **Primary evidence:** baseline declarations at
`theory/Cortex/Pulse/Frontier.lean:78,85`, `Closure.lean:54,66`, `Recovery.lean:33`,
`Classify.lean:52,107,124`, and `RunSafety.lean:100`; constructive definitions now at
`Frontier.lean:129-139`, `Closure.lean:77-99`, `Recovery.lean:33-41`, `Classify.lean:52-149`, and
`RunSafety.lean:104-112`.

The complete starting audit was:

| Definition                     | Why it was noncomputable                                                                                                                      | Constructive result                                                                                                                                      |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `readyNodes`                   | `Finset.filter Ready` obtained its predicate decision through `classical`; strict `EdgePath` reachability had no supplied decision procedure. | Computable with `[DecidableEq ν] [DecidableRel G.reaches]`; readiness is reduced to a finite topology scan by `ready_iff_on_nodes` and `readyDecidable`. |
| `directReadyNodes`             | `Finset.filter DirectReady` used `classical`, although direct edges are `Bool`-valued.                                                        | Computable with `[DecidableEq ν]`; `directReady_iff_on_nodes` and `directReadyDecidable` scan `G.nodes`.                                                 |
| `propagateStatus`              | The failed-ancestor existential and status branch used classical proposition decisions.                                                       | Computable with explicit node equality and reachability decisions; `hasFailedAncestor_iff_on_nodes` bounds the witness search.                           |
| `propagateFailure`             | Inherited `propagateStatus`'s classical decision.                                                                                             | Computable with the same explicit instances.                                                                                                             |
| `recoveredState`               | Inherited `propagateFailure`'s classical decision.                                                                                            | Computable composition of reset and closure.                                                                                                             |
| `pendingNodes`                 | Equality and `Finset.filter` decisions were synthesized classically.                                                                          | Computable from `[DecidableEq ν]` and derived `NodeStatus` equality.                                                                                     |
| `classifyClosedGraphState`     | Failure, settlement, waiting, and frontier branches used classically synthesized decisions.                                                   | Computable finite deciders for the three quantified predicates plus computable direct readiness.                                                         |
| `classifyGraphState`           | Inherited noncomputability from failure closure and the closed classifier.                                                                    | Computable with explicit node equality and reachability decisions.                                                                                       |
| `normalizedFrontierFactsState` | Inherited noncomputability from recovery.                                                                                                     | Computable with the same instances.                                                                                                                      |

No `noncomputable def` remains under `theory/Cortex/Pulse/*.lean`. The explicit
`DecidableRel G.reaches` requirement is intentional: a finite node carrier does not by itself
compute the transitive closure of an arbitrary `EdgePath` proposition. A concrete residual kernel
must supply a reachability procedure and later prove that it agrees with the DAG relation. The
direct runtime frontier does not need that oracle because it scans the `Bool` edge relation.

This required small new proofs, not just signature edits: finite-bound equivalences and decision
procedures for readiness and failed ancestry, plus finite decisions for the classifier predicates.
The operational theorems were then re-established with the explicit instances. No theorem was
weakened, and no `sorry`, `admit`, or axiom was introduced. `frontierBridge` was reformulated as the
pointwise semantic equivalence `Ready ↔ DirectReady`, independent of which decision procedure a
caller supplies; both the general `readyNodes_eq_directReadyNodes` theorem and a well-formed-state
set-equality theorem remain available in `Validity.lean:85-154`.

### Finding 2 — Track 3 is not required for the first fixed-topology residual kernel

**Confidence:** High on scope; medium on wireOS's eventual rewrite policy. **Primary evidence:**
`theory/Cortex/Graph/Relation.lean:199-202`, `theory/Cortex/Wire/Planner/Construction.lean:659-700`,
`src/Cortex/Pulse/Rewrite.hs`, Track 3 in `theory/README.md`, and wireOS ADR 0004.

The Wire audit initially found seven noncomputable definitions. `WirePulseSnapshot.recovered` was
only a wrapper around Pulse recovery and is now computable with an explicit reachability decider.
Six construction definitions remain: `constructedFinalTopology`, `constructedPlannedRewriteDelta`,
`ConstructedPlanningStep.delta`, `nextContext`, `toRewrite`, and `boundaryResourceUse`. They inherit
`graphOfRelation`, which calls `Finset.toList` without an ordering. That operation chooses a graph
syntax representative of an unordered relation; making it constructive requires a canonical
ordered/list-backed representation or an explicit order, not a missing local proposition instance.

wireOS's first residual executor can load a pre-realized, fixed topology and use Track 2 for
frontier, closure, recovery, and classification. It therefore need not construct or admit live
rewrites after boot. If wireOS retains runtime rewrite or latent-branch materialization in the
residual phase, Track 3 becomes load-bearing and these six definitions, durable rewrite lineage,
budget, and materialization witnesses must enter a separate computability slice.

### Finding 3 — Track 2 can drive lifecycle decisions, not a complete executor

**Confidence:** High. **Primary evidence:** `theory/Cortex/Pulse/Classify.lean:123-149`,
`theory/Cortex/Pulse/RunSafety.lean:47-184`, and
`src/Cortex/Pulse/GraphRuntime.hs:127-148,228-301, 542-644`.

Track 2 is sufficient to decide what a sequential fixed-topology engine does next: recover volatile
statuses, propagate failures, return a ready frontier, and distinguish failed, completed, suspended,
and structurally stuck states. Its model is already sequential; leases, workers, and frontier races
do not appear in its semantics.

It does not execute a node, persist a transition, validate payload schemas, provide a concrete
identifier/map representation, or establish that an external effect is replay-safe. A host adapter
still needs an effect vocabulary and a persistence boundary. The shared kernel boundary should
initialize or recover validated finite topology/state, expose a frontier and lifecycle
classification, and accept topology-scoped opaque node facts. The host supplies decidable node
equality and strict reachability; dispatches effects; atomically commits outcomes/checkpoints;
retains topology/bundle identity and version compatibility; and carries attempt or idempotency
identity around effects. This names the interface shape only; wireOS issue #8 owns its storage
design, while Cortex Pulse may supply a different host adapter.

### Finding 4 — Most of the service implementation is outside the residual kernel, with one effect caveat

**Confidence:** High. **Primary evidence:** `src/Cortex/Pulse/Scheduler.hs:24-46,669-751`,
`src/Cortex/Pulse/Health.hs:29-76`, `app/cortex-pulse/Main.hs:189-246`, and
`src/Cortex/Pulse/Memory/Types.hs:320-399`.

The scheduler's Hasql transactions, `Async` pool, polling, lease renewal, fairness, and cooperative
cancellation solve multi-run/multi-worker service concerns. Warp health serving, JWT/auth options,
networking, and multiwriter CAS coordination are also unnecessary when one Microkit PD is the only
writer. `Memory.*` is deterministic graph query over settled observations for stage/agent retrieval;
it is not part of lifecycle advancement and does not belong in the residual kernel.

`Executor.ExternalCall*` is not intrinsically AI-specific, so excluding it needs a narrower reason.
Its current Haskell implementation is a database-backed submit/park/resume provider protocol. A
wireOS residual kernel can omit that protocol only if it defines a smaller native device/effect
adapter. Effects still need durable idempotency and outcome semantics; Track 4's provider/spark
model remains unstarted, so the Lean kernel does not prove them.

### Finding 5 — Generated C works, but the current native artifact pulls in a stock Linux runtime

**Confidence:** High. **Primary evidence:** `theory/CortexKernelSpike.lean`, `theory/lakefile.lean`,
the generated `CortexKernelSpike.c`, ELF inspection, and Lean v4.29.0 runtime sources linked above.

The spike built and ran through Lake's generated-C path:

```text
recovered:Cortex.Pulse.NodeStatus.pending
frontier:1
classification:progressing:1
```

The generated C was 75,639 bytes and contained specialized recovery, propagation, direct-readiness,
and classification functions. The unstripped host executable was 158,640,696 bytes; stripping
reduced it to 120,294,264 bytes. The ELF size report was 118,169,342 bytes of text, 2,118,056 bytes
of data, and 828,984 bytes of BSS. Lake linked 782 transitive objects because the current proof
modules import broad Mathlib/proof support. Those figures are a dependency-closure warning, not a
credible embedded size estimate; an extraction-facing module split is required.

`ldd`/`readelf` showed glibc, `libm`, `libdl`, `libgcc_s`, `libpthread`, and the ELF loader, with a
glibc runtime path. Lean values use reference counting, not a tracing garbage collector; the runtime
has single-threaded and multi-threaded reference-count modes. Allocation has three compile-time
branches in `lean.h`: `LEAN_SMALL_ALLOCATOR`, `LEAN_MIMALLOC`, and a fallback that prefixes the size
then calls `malloc`/`free_sized`. The fallback is favorable for an arena-backed target, but it is
not the active branch in the pinned installation: its installed `lean/config.h` defines
`LEAN_MIMALLOC`, matching v4.29.0's default mimalloc configuration. Using the fallback should
require configuration and a consistent target rebuild, not a Lean source patch; merely overriding
`malloc` at the final link leaves the already-compiled mimalloc calls in place.

The installed `libleanrt.a` confirms the distinction: `object.cpp.o`, `compact.cpp.o`, IO, mutex,
process, and event-loop objects contain unresolved `mi_*` calls; several objects also call
`malloc`/`free` directly; the mimalloc object references `mmap`/`munmap` and pthread TLS/mutex
calls. The runtime archive also contains IO, process, mutex, thread, libuv/network/event-loop, and
stack-overflow support. `init_module.cpp` initializes those subsystems, `thread.cpp` uses pthreads
on Linux and assigns an 8 MiB default Lean worker stack, and `libuv.cpp` starts a global event loop
on a Lean thread.

Therefore the observed binary requires a substantial POSIX/Linux surface. Lean's generated C is not
itself tied to glibc: musl GCC with Lake-equivalent `-O3`/section/export flags produced a
67,832-byte `CortexKernelSpike.musl.o`, and a trivial static musl executable worked. The full static
link stopped because the pinned musl GMP and libuv outputs supplied shared objects but not the
required static archives, while the installed Lean runtime archives were built for glibc. A
meaningful musl result requires rebuilding a reduced Lean runtime and its remaining dependencies for
the target; substituting a compiler at the last link is not enough.

### Finding 6 — A stock Lean runtime is mismatched with a native Microkit protection domain

**Confidence:** High on the present mismatch and static memory model; medium on feasibility of a
reduced port. **Primary evidence:** Microkit 2.2.0 manual sections on protection domains, events,
linking, memory regions, and stacks; the 2.2.0 `libmicrokit` header and linker script; the seL4
untyped-memory API; Lean v4.29.0 runtime sources; and the measured linkage above.

Microkit 2.2.0 targets seL4 15.0.0 and describes a static system: resources are assigned before
boot, each protection domain has one thread and a fixed virtual address space, program images are
ordinary ELF files linked with `libmicrokit.a`, and control enters through `init` and `notified`
(with optional protected-call and fault handlers). Notifications coalesce; the API supplies no POSIX
timers or sleeping threads. `libmicrokit.a` supplies Microkit C entry/runtime glue and the Microkit
API, not a Linux/POSIX libc environment. The default PD stack is 8 KiB, configurable up to 16 MiB.

At the seL4 level there is no malloc-style kernel service: user space manages physical memory
through capabilities to untyped memory and deliberately retypes it into kernel objects. Microkit
makes the application side still more static. The 2.2.0 `microkit.ld` lays out text, initializers,
data, BSS, and the IPC buffer but declares no heap, while the public `libmicrokit` API exposes
lifecycle, notification, protected-call, fault, IRQ, and debug operations but no allocator. A PD
that needs a heap must therefore bring one as a fixed BSS arena or as an explicitly provisioned and
mapped memory region. This is the platform's normal resource model, not an exceptional accommodation
for Lean. The arena size belongs in the host's admitted resource plan, derived from bounded topology
and state (and from the rewrite budget if rewrites ever enter the residual kernel), rather than
discovered by an unbounded allocation request at runtime.

That makes allocation tractable but does not make the stock runtime compatible. The fallback Lean
allocator branch can target the fixed arena through `malloc`/`free_sized`, subject to auditing
direct large-object and runtime calls; objects above `LEAN_MAX_SMALL_OBJECT_SIZE` (4096 bytes) also
use the general allocator. The stock artifact still expects mimalloc, thread-local/runtime
initialization, pthreads, libuv and its event-loop thread, process and IO support, GMP,
math/dynamic-link services, and much larger thread-stack assumptions. Microkit's `microkit_dbg_*`
functions are sufficient for bring-up logging, but they are not a replacement for that general IO
surface. A plausible port would first isolate a pure kernel with a small import closure, enumerate
every unresolved symbol from its generated object and selected runtime objects, configure and
rebuild a single-threaded Lean runtime for the aarch64 target, supply the fixed-arena allocator and
choose or replace big integers, remove or stub unused IO/process/libuv/thread facilities without
violating runtime initialization, provide fixed memory and stack budgets, and replace `main` with
Microkit event handlers. No evidence yet shows that this reduced runtime links or boots, so native
Microkit deployment is plausible but unverified.

### Finding 7 — The reusable target is a Cortex-owned kernel library with host interpretation

**Confidence:** High. **Primary evidence:** ADR 0002, ADR 0038, Tracks 2 and 5 in
`theory/README.md`, `src/Cortex/Pulse/Executor.hs:102`,
`src/Cortex/Pulse/Executor/Frontier.hs:1-90`, wireOS ADR 0001, and ADR 0090.

Track 2 is generic at the useful seam: it owns lifecycle state and decisions but does not know what
executing a node means. The long-term target should therefore be a Cortex-owned `cortex-kernel`
library with pull-frontier/push-fact inversion of control. Pulse may interpret frontier nodes
through its registry; wireOS may interpret them through its closed effect-authorization vocabulary.
Neither interpreter belongs in the kernel. A library is the primary artifact because it can receive
host types, persistence, and effect interpretation at a defined boundary; a future thin `cortex`
executable can wrap it without becoming a canonical task registry.

This remains an executable-refinement and runtime-correspondence obligation attached to Track 2 and
ADR 0038's existing ledger classes, not a new proof methodology. It creates an outbound seam
relevant to Track 5 but does not discharge Track 5 as currently written: that unstarted track asks
for an import-graph proof that Cortex never imports consumer modules. The host-neutral seam
preserves the direction and gives such a proof a concrete boundary; no import theorem lands here.

The dedicated `cortex-kernel-spike` target should remain as reproducible evidence, not as a
supported ABI or production artifact. It catches regressions in the generated-C path while the
reduced import surface, representation, callback ABI, and target runtime are still open.

wireOS ADR 0001 is explicit that its residual Circuit currently flows to “Pulse execution” and that
Pulse owns residual execution. A peer wireOS interpreter over `cortex-kernel` contradicts that
accepted downstream decision. wireOS must amend or supersede its ADR before adopting the peer
runtime; Cortex ADR 0090 cannot silently rewrite downstream canon.

## Open questions

- Can a runtime-facing Pulse module avoid Mathlib/proof-only transitive imports after erasure, and
  what native text/data size does that produce?
- Which Lean runtime facilities remain reachable after such a split, and can v4.29.0 be configured
  and built without pthread, libuv, process, mmap, mimalloc, and GMP dependencies?
- What is the complete unresolved-symbol set for the minimal aarch64 object/runtime closure, and
  which implementations are required for allocation, memory primitives, TLS, panic/abort, and
  initialization in a Microkit 2.2.0 protection domain?
- What conservative arena and stack bounds follow from the admitted topology/state and optional
  `RewriteBudget`, and how should the host's system resource plan carry those bounds?
- Will wireOS pre-realize every residual topology, or must selected branches/live rewrites remain
  executable after boot and therefore bring Track 3 into scope?
- What concrete reachability representation will wireOS supply, and how will its computed closure be
  checked against the admitted topology?
- Which versioned C representation, ownership rules, and error surface can expose the host-neutral
  pull-frontier/push-fact boundary without baking in either consumer's payload vocabulary?
- Should cortex-pulse first use the kernel through differential tests or an FFI path once the ABI is
  stable?

## Recommendations

1. Keep the constructive Track 2 definitions and `cortex-kernel-spike` governed by proposed ADR
   0090; treat it as evidence toward a Cortex-owned host-neutral library, not a stable interface.
2. Next, split a minimal runtime-facing Pulse import surface, cross-compile its generated object for
   aarch64, and enumerate its complete unresolved-symbol and runtime-object closure. Rebuild the
   Lean runtime single-threaded with mimalloc disabled; a static musl build remains a useful
   intermediate measurement, not a substitute for the Microkit target.
3. If that reduced artifact eliminates pthread/libuv/process dependencies, provision a fixed BSS or
   mapped-memory arena and an explicit stack budget in a minimal Microkit PD, then boot only
   recovery/classification from fixed in-memory state. That target build is the blocking evidence;
   more paper investigation will not establish boot viability.
4. Specify the abstract host boundary before a byte-level ABI: validated topology/state in;
   frontier/classification out; opaque lifecycle facts back in; effect execution and persistence
   outside.
5. Keep wireOS issue #8 responsible for its persistence and supersede wireOS ADR 0001 before routing
   the residual Circuit to a wireOS interpreter rather than literal Pulse execution.
6. Open a separate Track 3 computability decision only if wireOS confirms that rewrites or latent
   materialization must execute after boot.

## Related

- [ADR 0090 — Computable Pulse Kernel and Extraction Boundary](../../ADRs/0090-computable-pulse-kernel-and-extraction-boundary.md)
- [Cortex Proof Status](../../Reference/proof-status.md)
- [Paper 1 — Lean-Haskell Pulse Boundary](../../Publications/Paper-1-staged-reduction/lean-haskell-boundary.md)
- [Theory track roadmap](../../../theory/README.md)
- [ADR 0002 — Cortex and Downstream Ownership Boundary](../../ADRs/0002-cortex-downstream-ownership-boundary.md)
- [ADR 0038 — Wire Proof-Track Theorem Ledger](../../ADRs/0038-wire-proof-track-theorem-ledger.md)
