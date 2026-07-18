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
  - docs/ADRs/0091-lean-hosted-freestanding-wire-c-backend.md
  - docs/Reference/proof-status.md
  - "wireOS #8"
---

# Research Memo: Computable Pulse Kernel and C Extraction

**Method:** combined implementation reading, proof-preserving refactor, host and bare-aarch64
toolchain experiments, native Microkit boot, and external primary-source review **Confidence
profile:** high on the Cortex computability audit, generated-C portability, and present runtime gap;
medium on the reduced-runtime port estimate; low on the object-based kernel's native Microkit
viability until that kernel boots

---

## Updated conclusion

The runtime investigation answered the original object-extraction question, but it also exposed that
object extraction is the wrong first deployment boundary for a fixed admitted Wire program. ADR 0091
now keeps Lean on the build host: Haskell lowers `CompiledCircuit` into a normalized
`static-program/v1` artifact, Lean validates it and emits topology-specialized freestanding C, and
the platform consumer owns the adapter and final link.

This does not invalidate the findings below. They explain why the design pivot is preferable: the
constructive Track 2 semantics are reusable, while the stock Lean object runtime is not a native
Microkit runtime. The scalar Microkit boot is prior evidence that generated C can cross the target
boundary once object-runtime dependencies are absent. The new backend achieves that absence by
construction rather than by reducing and porting the object runtime.

The cross-implementation differential suite anticipated below is now realized as
`checks.cortex-wire-differential`: a shared scenario corpus (exhaustive DAGs for `n <= 3` plus named
four-node shapes, each with lifecycle and adversarial-completion cases) is replayed through the
Haskell `GraphRuntime` reference driver, a core-Lean reference interpreter, and the generated
freestanding C, and the three trace streams must match byte-for-byte. Building it surfaced and fixed
two v1 lifecycle defects in the emitted drive loop — a sibling failure could strand an undispatched
frontier member in the running state, and terminal failure neither latched nor cancelled running
siblings exactly once — which the differential now pins across all three implementations.

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
static link with the Lake link-object set and musl-targeted GMP/libuv packages.

A second experiment used wireOS's pinned Microkit 2.2.0 SDK, clang 18 `-target aarch64-none-elf`,
and QEMU `qemu_virt_aarch64` profile. A two-function Lean module with fixed-width scalar exports was
compiled to C. Function/data sections and linker garbage collection removed its boxed wrappers,
module initializer, and all Lean runtime references. The resulting ELF linked only with
`libmicrokit.a`; the generated Microkit image booted and printed `lean-generated-c:ok`. The actual
Cortex `Recovery`, `Frontier`, and `Classify` generated C modules were then cross-compiled with a
no-mimalloc target header to enumerate their direct unresolved symbols. Finally, the same bare
target attempted to compile Lean's core `runtime/object.cpp` first without and then with pinned
libc++ headers. This was a target-boundary experiment, not a reduced runtime implementation; all
temporary artifacts remained outside the repository.

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
  [`object.cpp`](https://github.com/leanprover/lean4/blob/v4.29.0/src/runtime/object.cpp),
  [`thread.h`](https://github.com/leanprover/lean4/blob/v4.29.0/src/runtime/thread.h),
  [`thread.cpp`](https://github.com/leanprover/lean4/blob/v4.29.0/src/runtime/thread.cpp),
  [`init_module.cpp`](https://github.com/leanprover/lean4/blob/v4.29.0/src/runtime/init_module.cpp),
  [`initialize/init.cpp`](https://github.com/leanprover/lean4/blob/v4.29.0/src/initialize/init.cpp),
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
- The WebAssembly C API's
  [black-box/manual-ownership goals](https://github.com/WebAssembly/wasm-c-api) and SQLite's
  [opaque handles](https://www.sqlite.org/c3ref/sqlite3.html) and
  [append-only versioned VFS shape](https://www.sqlite.org/c3ref/vfs.html) as primary-source C ABI
  precedents

## Findings

### Finding 1 — All nine fixed-topology Pulse decision definitions were tractably computable

**Evidence class:** Observed. **Category:** Correctness Gap. **Confidence:** High. **Primary
evidence:** baseline declarations at `theory/Cortex/Pulse/Frontier.lean:78,85`,
`Closure.lean:54,66`, `Recovery.lean:33`, `Classify.lean:52,107,124`, and `RunSafety.lean:100`;
constructive definitions now at `Frontier.lean:129-139`, `Closure.lean:77-99`,
`Recovery.lean:33-41`, `Classify.lean:52-149`, and `RunSafety.lean:104-112`.

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
compute the transitive closure of an arbitrary `EdgePath` proposition. A concrete residual
implementation must compute reachability and later prove that it agrees with the DAG relation. The
direct runtime frontier does not need that oracle because it scans the `Bool` edge relation.

This required small new proofs, not just signature edits: finite-bound equivalences and decision
procedures for readiness and failed ancestry, plus finite decisions for the classifier predicates.
The operational theorems were then re-established with the explicit instances. No theorem was
weakened, and no `sorry`, `admit`, or axiom was introduced. `frontierBridge` was reformulated as the
pointwise semantic equivalence `Ready ↔ DirectReady`, independent of which decision procedure a
caller supplies; both the general `readyNodes_eq_directReadyNodes` theorem and a well-formed-state
set-equality theorem remain available in `Validity.lean:85-154`.

### Finding 2 — Track 3 is not required for the first fixed-topology residual kernel

**Evidence class:** Observed. **Category:** Extension Risk. **Confidence:** High on scope; medium on
wireOS's eventual rewrite policy. **Primary evidence:** `theory/Cortex/Graph/Relation.lean:199-202`,
`theory/Cortex/Wire/Planner/Construction.lean:659-700`, `src/Cortex/Pulse/Rewrite.hs`, Track 3 in
`theory/README.md`, and wireOS ADR 0004.

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

**Evidence class:** Observed. **Category:** Missed Abstraction. **Confidence:** High. **Primary
evidence:** `theory/Cortex/Pulse/Classify.lean:123-149`,
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
classification, and accept topology-scoped opaque node facts. The executable refinement supplies
dense node equality and strict reachability; the host dispatches effects, atomically commits
outcomes/checkpoints, retains topology/bundle identity and version compatibility, and carries
attempt or idempotency identity around effects. This names the interface shape only; wireOS issue #8
owns its storage design, while Cortex Pulse may supply a different host adapter.

### Finding 4 — Most of the service implementation is outside the residual kernel, with one effect caveat

**Evidence class:** Observed. **Category:** Layer Leak. **Confidence:** High. **Primary evidence:**
`src/Cortex/Pulse/Scheduler.hs:24-46,669-751`, `src/Cortex/Pulse/Health.hs:29-76`,
`app/cortex-pulse/Main.hs:189-246`, and `src/Cortex/Pulse/Memory/Types.hs:320-399`.

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

### Finding 5 — Lean-generated scalar C boots on Microkit; the object kernel still needs a runtime

**Evidence class:** Observed. **Category:** Evidence Gap. **Confidence:** High. **Primary
evidence:** `theory/CortexKernelSpike.lean`, the generated `CortexKernelSpike.c`, wireOS
`nix/qemu-baseline.nix:10-105`, the pinned Microkit SDK's `libmicrokit.a`/`microkit.ld`, QEMU boot
output, and the generated-object symbol audits described in Method.

The existing spike still gives the same host result:

```text
recovered:Cortex.Pulse.NodeStatus.pending
frontier:1
classification:progressing:1
```

Its generated C contains specialized recovery, propagation, direct-readiness, and classification
functions, but the unstripped host executable is 158,640,696 bytes and links 782 transitive objects.
The ELF carries 118,169,342 bytes of text, 2,118,056 bytes of data, and 828,984 bytes of BSS because
the runtime surface imports broad Mathlib/proof and executable support. This remains a
dependency-closure warning, not an embedded-size estimate.

The new bare-target experiment separates C generation from object-runtime portability. A temporary
Lean module exported `UInt32 -> UInt32` and `Bool -> Bool -> UInt8` functions. Clang 18 compiled the
generated C for `aarch64-none-elf`; `-ffunction-sections`, `-fdata-sections`, and `--gc-sections`
discarded boxed wrappers and module initialization. The remaining scalar export had no unresolved
Lean symbols. It linked with only Microkit 2.2.0's `libmicrokit.a`, produced a normal protection-
domain ELF with no TLS sections, and booted under wireOS's pinned QEMU profile:

```text
MON|INFO: Microkit Monitor started!
lean-generated-c:ok
```

This proves that Lean's C emitter, the aarch64 compiler, the Microkit ELF/linker path, and Microkit
entry model are not themselves the blocker. It does not exercise a `lean_object`, allocator, module
initializer, reference-count decrement, or panic path, so it does not prove the Cortex kernel.

The actual generated `Recovery`, `Frontier`, and `Classify` modules also cross-compile for bare
aarch64 when the target header removes `LEAN_MIMALLOC`. Their direct runtime surface is now
enumerated: `malloc`; reference-count cold paths; heartbeat and panic/assert hooks; object/closure
allocation and apply helpers; module initializers; selected big-natural helpers; and the imported
Mathlib multiset/finset routines. `CortexKernelSpike.c` adds executable-only IO, argument, task-
manager, and print symbols. The complete transitive closure is still intentionally unknown because
the extraction-facing representation and embedded-profile runtime archive do not exist yet;
presenting the stock archive's whole symbol set as that closure would be false precision.

### Finding 6 — Lean's supported switches do not define a freestanding runtime profile

**Evidence class:** Observed. **Category:** Design Tension. **Confidence:** High on the present gap;
medium on the cost of closing it. **Primary evidence:** Lean v4.29.0
`src/CMakeLists.txt:74-105,119-125,197-202,272-285`, `src/runtime/CMakeLists.txt:1-65`,
`src/runtime/thread.h:21-229`, `src/runtime/alloc.cpp:456-500`,
`src/runtime/object.cpp:7-18,69-100,2740-2756`, and `src/runtime/init_module.cpp:7-42`; Microkit
2.2.0 `microkit.ld` and `libmicrokit.a`; and the bare-target compiler failures described in Method.

Three upstream switches are useful and must be used together: `MULTI_THREAD=OFF`,
`USE_MIMALLOC=OFF`, and `USE_GMP=OFF`. They replace pthread-backed synchronization with immediate
single-threaded types, select the `malloc`/`free_sized` allocation branch, and select Lean's
internal big-natural implementation. They do not create a minimal archive: `runtime/CMakeLists.txt`
still builds IO, process, mutex, libuv/network/event-loop, signal, stack-overflow, exception,
compacting, and debug sources into `leanrt`.

More importantly, `MULTI_THREAD=OFF` is not `TLS=OFF`. `LEAN_THREAD_PTR` and `LEAN_THREAD_VALUE`
expand to `__thread` outside the multi-thread conditional, and the ordinary non-small allocator
keeps its heartbeat in such a variable. `MK_THREAD_LOCAL_GET` additionally allocates with `new` and
registers finalizers. The static runtime is explicitly compiled with the `local-exec` TLS model.
Microkit's linker script has no `.tdata`/`.tbss` layout or thread-pointer initialization, and the
pinned `libmicrokit.a` exports only startup/event-loop, debug, and seL4-facing operations—not libc,
libc++, TLS, pthread, allocation, or process services.

The core object runtime also remains hosted C++ even in single-threaded mode. `object.cpp` includes
`string`, `vector`, `deque`, and `cmath`; its initializer captures `stderr`, allocates a vector and
mutex with `new`, and constructs a persistent Lean array. Panic paths use `getenv`, `fprintf`,
`abort`, and `exit`. Compiling it with wireOS's exact bare-aarch64 invocation fails first because
`<string>` is absent. Adding pinned libc++ headers does not close the gap: libc++ rejects the target
with `No thread API` and then reports missing libc definitions including `ldiv_t`, `mbstate_t`,
wide-character, memory, and floating-point classification functions. This is concrete evidence that
the remaining work is not an allocator-symbol swap.

Finally, the stock initializers are too broad. `lean_initialize_runtime_module()` unconditionally
initializes allocation, debug, object, IO, thread, mutex, process, stack-overflow, and libuv. The
larger `lean_initialize()` also initializes `Init`, `Std`, `Lean`, kernel, library, printing, and
construction support, and the C emitter chooses it when an executable imports `Lean`. There is no
upstream v4.29.0 switch for no TLS, an embedded panic hook, a source-subset runtime, or an embedded
initializer.

The target therefore needs an explicit Cortex Lean embedded profile, not the phrase “reduced Lean
runtime.” That profile must pin the three supported switches and additionally remove TLS for the
single PD, select only the object/apply/numeric primitives reachable from the extraction module,
replace the monolithic initializer, supply fixed-arena allocation and checked memory primitives, and
make OOM/internal panic fail-stop through a host hook. The first implementation experiment must
choose between (a) providing a measured freestanding libc++/libc/TLS support layer or (b) splitting
and adapting the reachable Lean runtime sources to avoid them. Current evidence favors (b), but only
the import-closure measurement can make that choice authoritative. Until that profile links and the
object-based recovery/frontier/classifier boots, native feasibility remains unverified.

### Finding 7 — The reusable target is a Cortex-owned kernel library with peer host interpreters

**Evidence class:** Inferred. **Category:** Missed Abstraction. **Confidence:** High. **Primary
evidence:** ADR 0002, ADR 0038, Tracks 2 and 5 in `theory/README.md`,
`src/Cortex/Pulse/Executor.hs:102`, `src/Cortex/Pulse/Executor/Frontier.hs:1-90`, wireOS ADR 0005,
and ADR 0090.

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

The dedicated `cortex-kernel-spike` target should remain reproducible evidence, not a supported ABI
or production artifact. It catches regressions in generated C while the extraction representation
and target runtime are built.

The same boundary must remain usable from `cortex-pulse`, but production FFI adoption is not a v1
acceptance gate. The Haskell service already has a richer operational implementation and
observability surface; forcing it through an immature ABI would couple two migrations and weaken
failure containment. Its first use should be a differential consumer: run common fixed-topology
fixtures through Haskell `GraphRuntime` and the C kernel, then compare normalized state, frontier,
and classification. A later ADR may choose production FFI if the stable boundary and measurements
justify it. This preserves one semantic API without pretending every host must use the same
implementation immediately.

### Finding 8 — A v1 C façade can be fixed without exposing Lean's generated ABI

**Evidence class:** Inferred. **Category:** Missed Abstraction. **Confidence:** Medium until a
header and conformance harness exist. **Primary evidence:** generated `Recovery.c`, `Frontier.c`,
`Classify.c`, and `CortexKernelSpike.c`; `theory/Cortex/Pulse/{State,Fact,Classify}.lean`; the
WebAssembly C API's black-box/manual-ownership design goals; SQLite's opaque handles and append-only
versioned VFS; and Findings 5-7.

Lean's emitted functions are not the public ABI. They expose `lean_object *`, generated symbol
names, boxed helper variants, and module initializers. Cortex should put a hand-written C façade in
front of them with these v1 rules:

- exported symbols carry a `_v1` suffix; every public aggregate starts with `abi_version` and
  `struct_size`, uses fixed-width integer tags and reserved fields, and publishes feature bits;
- nodes are dense `uint32_t` kernel identifiers; hosts retain external durable identifiers and a
  topology digest binds every imported/exported state to the admitted graph;
- the kernel is an opaque `cortex_kernel_v1 *`, single-threaded and non-reentrant; no callback is
  used for frontier or fact flow;
- the caller supplies one aligned arena. A no-allocation preflight computes checked required bytes
  from node/edge/state/scratch limits; initialization either copies borrowed topology/state into the
  arena or returns the required size without partial state;
- direct edges are the topology input. The kernel owns a deterministic finite reachability index in
  its arena rather than accepting an arbitrary host callback; a correspondence theorem must connect
  that index to `DAG.reaches`;
- frontier, classification, and state export write to caller-owned spans and report required counts.
  No `lean_object *`, pointer to arena internals, C++ exception, or allocator-owned string crosses
  the boundary;
- payloads are opaque `uint64_t` handles copied by value. The kernel neither dereferences nor frees
  host payloads, and persistence serialization remains a host contract rather than an ABI memory
  layout;
- an applied fact batch contains pairwise-distinct nodes and only final Track 2 outcomes for nodes
  that are directly ready in the pre-state. Retryable and indeterminate effect states remain in the
  host adapter; duplicate or stale submissions are rejected rather than silently re-applied. The v1
  fixed-topology feature set rejects `rewritten` facts;
- ordinary failures return a fixed status code plus a caller-owned diagnostic record: ABI mismatch,
  invalid argument, insufficient buffer/arena, invalid topology/state, duplicate batch node, and
  stale/not-ready fact. Runtime OOM, failed assertions, and internal panic are fail-stop through a
  host-supplied noreturn panic hook; they must not unwind across C or masquerade as recoverable
  errors.

The initial operations are therefore bounded and direct: memory preflight, initialize/recover,
frontier, classify, apply-final-facts, export-state, and invalidate. This is a concrete
representation and ownership/error envelope, not yet a shipped header. Numeric tag assignments,
exact struct layouts, ABI static assertions, golden C/Rust/Haskell fixtures, and symbol-version
checks must land together before ADR 0090 can be accepted.

## Seven-lens synthesis

- **Episteme:** Track 2 is constructive, generated scalar C boots on the pinned target, and the
  object runtime demonstrably does not yet compile against the Microkit SDK.
- **Logos:** the proved claim is fixed-topology lifecycle classification; effect replay, concrete
  reachability, ABI safety, runtime initialization, and persistence remain separate obligations.
- **Kritikos:** `MULTI_THREAD=OFF` still emits TLS, no-mimalloc still needs hosted C++, and exposing
  generated Lean symbols would make memory ownership and versioning accidental.
- **Themis:** Cortex owns the semantic kernel, concrete reachability, ABI, and runtime profile;
  hosts own identifiers, effects, idempotency, payloads, and persistence.
- **Techne:** the smallest resolving artifacts are an extraction-facing representation, a checked
  `cortex_kernel_v1.h`, a symbol-manifest gate, and one object-based Microkit boot fixture.
- **Poiesis:** a scalar/bitset refinement could avoid most of Lean's runtime, while a Haskell or
  Rust reimplementation checked by differential tests remains the fallback if the object runtime
  port is disproportionate.
- **Sophia:** act now on the import/representation split and ABI header; design the runtime source
  subset next; park production `cortex-pulse` FFI and Track 3 until the first target boot.

## Open questions

- Can an extraction-facing dense topology/state representation avoid the present Mathlib/proof
  closure while retaining short correspondence proofs to Track 2?
- What is the complete unresolved-symbol and maximum-stack set after that split, and does it favor a
  freestanding libc++ support layer or a smaller adapted Lean runtime source subset?
- What conservative arena and stack bounds follow from the admitted fixed topology, state, payload-
  handle count, reachability index, and measured runtime scratch space?
- Will wireOS pre-realize every residual topology, or must selected branches/live rewrites remain
  executable after boot and therefore bring Track 3 into scope?
- Which concrete bitset or index algorithm should implement strict reachability, and what theorem
  establishes its equality with `DAG.reaches` for admitted topologies?
- What exact numeric tags, struct layouts, feature bits, panic callback, and compatibility policy
  should the first `cortex_kernel_v1.h` freeze?
- Which attempt/idempotency record lets each host suppress duplicates and resolve indeterminate
  effects before submitting a final kernel fact?
- After differential correspondence is green, does production `cortex-pulse` gain enough from FFI
  reuse to justify the operational and failure-containment cost?

## Recommendations

1. Keep the constructive Track 2 definitions and `cortex-kernel-spike` governed by proposed ADR
   0090; add an extraction-facing dense topology/state refinement and prove its frontier, recovery,
   and classification results correspond to Track 2.
2. Draft `cortex_kernel_v1.h` from Finding 8 together with C/Rust/Haskell layout fixtures, invalid-
   input tests, and an exported-symbol allowlist. Do not expose generated Lean declarations.
3. Cross-compile that representation with `MULTI_THREAD=OFF`, `USE_MIMALLOC=OFF`, and `USE_GMP=OFF`;
   generate a complete object/symbol/stack manifest and choose explicitly between a freestanding C++
   support layer and an adapted runtime source subset. Remove TLS and replace the monolithic
   initializer either way.
4. Provision the measured arena and stack in one Microkit PD and boot object-based recovery,
   frontier, classification, and one final-fact transition. That is the blocking feasibility gate;
   the scalar boot is only a code-generation control experiment.
5. Add a differential suite between Haskell `GraphRuntime`, the host Lean spike, and the v1 C API
   before considering production `cortex-pulse` FFI. Keep that adoption a later decision.
6. Keep wireOS issue #8 responsible for persistence and its ADR 0005 responsible for effect
   idempotency. Open a separate Track 3 decision only if rewrites or latent materialization must run
   after boot.

## Related

- [ADR 0090 — Computable Circuit-Engine Decision Kernel and Extraction Boundary](../../ADRs/0090-computable-pulse-kernel-and-extraction-boundary.md)
- [Cortex Proof Status](../../Reference/proof-status.md)
- [Paper 1 — Lean-Haskell Pulse Boundary](../../Publications/Paper-1-staged-reduction/lean-haskell-boundary.md)
- [Theory track roadmap](../../../theory/README.md)
- [ADR 0002 — Cortex and Downstream Ownership Boundary](../../ADRs/0002-cortex-downstream-ownership-boundary.md)
- [ADR 0038 — Wire Proof-Track Theorem Ledger](../../ADRs/0038-wire-proof-track-theorem-ledger.md)
