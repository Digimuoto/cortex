---
title: "Pulse Runtime-Bounded Iteration Evidence"
description:
  "Evidence surface for ADR 0055 runtime-bounded iteration: witnessed self-append claims, examples,
  and verification commands."
sidebar:
  label: "Runtime iteration evidence"
  order: 12
status: active
---

# Pulse Runtime-Bounded Iteration Evidence

ADR 0055 classifies runtime-bounded iteration as Pulse-admitted certified self-append. This page is
the implementation evidence surface for the v1 slice: one composite continuation-state anchor,
`StageLoopStep` as the proposer, ADR 0056 witnessed admission for the loop step, and durable replay
that revalidates the witness.

The design is considered demonstrated only when the positive examples and the fail-closed gallery
hold together. A passing happy path alone is not enough, because `StageLoopStep` carries a caller
supplied `GraphRewrite` and therefore must be guarded before any gas-neutral admission.

## Evidence Matrix

| Claim                                                  | Evidence                                                                                                                                                                            |
| ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A loop step is ordinary graph growth, not a back-edge. | DB examples materialize `loop:iter_0:k -> loop:iter_1:k -> ...` and assert the admin topology after rewrite materialization.                                                        |
| The loop step is gas-neutral only after certification. | The counter-loop example admits more self-appends than the default rewrite-op gas cap and persists every row with `admission_mode = witnessed`.                                     |
| The run-local effective bound is authoritative.        | The effective-bound example registers a lower `EffectiveBound` than the static policy cap and fails with `loop_iteration_budget_exhausted` after the permitted rows.                |
| Frontier shape is not prose.                           | Pure checks reject multi-node continuation exits and witness mismatch; DB checks reject a `StageLoopStep` whose witness differs from the registered policy.                         |
| The step is bound to the certified kernel.             | Authorization rejects a canonical next namespace whose spec differs from the policy's kernel witness; the DB example rejects the same mismatch before any witnessed row is written. |
| Wire authors the kernel, not a new loop keyword.       | `examples/wire/runtime-bounded-paginated-ingest/page-kernel.wire` compiles to the one-node open kernel that Pulse registers and self-appends under ADR 0055.                        |
| `StageLoopStep` is not a gas bypass.                   | Unregistered loop steps fall back to the gassed path, non-`AppendAfter` and malformed namespaces are rejected, and rewrite-closed kernels reject ordinary `StageRewrite`.           |
| Durable replay does not trust the row tag alone.       | Replay rechecks producer, policy version, effective bound, remaining-before/after, and step witness before reconstructing a witnessed row gas-neutral.                              |
| Existing rewrite history stays metered.                | `migrations/0001_graph_rewrites_admission_mode.sql` backfills old rows to `gassed` and adds a `gassed \| witnessed` check constraint.                                               |

## Runnable Examples

Run the pure law and authorization tests:

```console
just test-match "runtime-bounded iteration pure core"
```

Run the DB-backed runtime evidence examples:

```console
just test-db -m "'runtime-bounded iteration evidence'"
```

Run the Wire-source kernel example:

```console
just test-match "runtime-bounded iteration Wire example"
```

The Wire example is intentionally a kernel fragment rather than a loop syntax form. The current Wire
language compiles fixed topology; Pulse owns runtime self-append admission. A host binding registers
the compiled `page_kernel` template with a `LoopPolicy`, frontier witness, namespace root, and
effective bound. At runtime, non-terminal `state` output proposes the next certified self-append;
terminal output stops without appending.

The DB examples cover two positive shapes:

- **Counter loop:** a compact loop that runs past the rewrite-gas operation cap only because each
  step is certified and persisted as `witnessed`.
- **Paginated ingest simulator:** a deterministic page source whose state is one composite
  continuation value. Each non-terminal iteration appends the next `loop:iter_<i>:k` node with a
  flat namespace; the terminal iteration completes with an ordered summary.

They also cover the adversarial gallery: unauthorized loop step, bad frontier witness, bad kernel
witness, exhausted effective bound, and ordinary `StageRewrite` from a rewrite-closed loop kernel.

## Interpreting Failures

- `rewrite_budget_exceeded` in the positive counter-loop example means the step is being admitted
  gassed instead of witnessed.
- A successful row with `admission_mode = witnessed` in any negative example means the security gate
  is too weak.
- Missing `witnessed_loop_step` metadata means resume cannot revalidate policy version and run-local
  loop control.
- A nested id such as `loop:iter_0:k:iter_1:k` means the step was re-namespaced under the anchor
  instead of using the flat iteration seed.

## Related

- [Pulse types](types.md) — `StageLoopStep`, `LoopPolicy`, and stage-plan registration.
- [Pulse schema](schema.md) — `pulse.graph_rewrites.admission_mode`.
- [Rewrites reference](../rewrites.md) — gassed vs witnessed structural rewrite admission.
- [ADR 0055](../../ADRs/0055-pulse-runtime-bounded-iteration.md) — runtime-bounded iteration design.
- [ADR 0056](../../ADRs/0056-admission-modes-witnessed-and-gas.md) — witnessed admission mode.

---

_End of Pulse Runtime-Bounded Iteration Evidence._
