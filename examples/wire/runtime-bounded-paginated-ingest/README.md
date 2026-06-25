# Runtime-Bounded Paginated Ingest

This example shows the current ADR 0055 split between Wire and Pulse.

Wire does **not** define recursion or a loop keyword today. The Wire file in this directory authors
one loop body as an ordinary open graph fragment:

```text
PageState -> page_kernel -> PageState | PageTerminal
```

Pulse repeats that fragment only after a host binding registers the compiled `page_kernel` template
as a runtime-bounded iteration kernel. The registered policy supplies the loop namespace root, the
frontier-shape witness, the kernel witness, and the effective per-run bound.

## Files

- `page-kernel.wire` — the Wire-authored loop body. It has no recursive syntax; it exposes the
  continuation frontier that Pulse may self-append.
- `provision-loop.sh` — a commented provisioning sketch. It runs the stock `wire build` command to
  produce a compiled kernel artifact, then writes the loop-registration metadata a downstream host
  binding must supply to Pulse.

## Run

From the repository root:

```bash
examples/wire/runtime-bounded-paginated-ingest/provision-loop.sh
```

The script writes:

- `examples/wire/runtime-bounded-paginated-ingest/build/page-kernel.compiled.json`
- `examples/wire/runtime-bounded-paginated-ingest/build/loop-registration.sketch.json`

The stock `wire` command stops at compile/local fixed-topology execution. Durable runtime looping is
not provisioned by `wire run` today. A downstream Pulse host binary or future durable submission
surface must consume the compiled artifact and install the `LoopRegistration` in the `StagePlan`.

## Runtime Shape

The seed graph contains one materialized kernel instance:

```text
ingest_loop:iter_0:page_kernel
```

When that node completes with the `terminal` output, the run stops. When it completes with the
`state` output, the registered host action proposes a `StageLoopStep`:

```text
AppendAfter ingest_loop:iter_i:page_kernel
            ingest_loop:iter_<i+1>:page_kernel
```

Pulse admits that append gas-neutral only if all guards pass:

- the producer template is registered as a loop kernel;
- the output frontier witness matches `paginated-ingest-state-v1`;
- the loop-carried continuation is the single `state` producer;
- the appended spec matches the certified `page_kernel` kernel witness;
- the namespace is flat and canonical;
- the run-local effective bound still has remaining self-appends.

That is why the loop is not visible as a recursive Wire definition. In the current design, Wire owns
the body shape and Pulse owns bounded runtime materialization.
