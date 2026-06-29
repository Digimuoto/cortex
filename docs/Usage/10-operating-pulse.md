---
title: Operating Pulse
description: Diagnose durable runs, leases, signals, events, schema state, and retention.
sidebar:
  label: 10. Operating Pulse
  order: 10
---

# Operating Pulse

Pulse operations start from one question: what durable state does the database show for the run? The
runtime records enough state to distinguish waiting, running, failed, completed, cancelled, and
timeout outcomes.

## Run State

Use the `pulse.runs` row as the first checkpoint:

- `status` tells you whether the run is open, waiting, or terminal.
- `lease_owner` and `lease_expires_at` tell you which worker currently owns running work.
- terminal fields record completion, failure, cancellation, or timeout.

The exact schema is in [Pulse schema](../Reference/Pulse/schema.md).

## Leases And Resume

A live worker renews the lease while it owns a running run. A durable service can recover expired
runs according to the scheduler path. A managed consumer can resume a managed run by keeping the run
id returned by `runCompiledCircuitManaged` and later calling `resumeCompiledCircuitManaged` with a
compatible binder and circuit configuration.

If a resume is rejected, check whether the run is still live-running under another owner, already
terminal, waiting on a signal, or missing the task definition expected by the original run.

## Signals And Waiting Runs

Waiting is usually explicit. Check signal state before assuming a worker is stuck:

- signal wait rows identify what the run is waiting for;
- external-call wake signals are delivered through the trusted host-action path;
- waiting runs are not the same as lease-lost running runs.

Use [signals](../Reference/Pulse/signals.md) and [host actions](../Reference/Pulse/host-actions.md)
for the exact protocol.

## Events And Stage Logs

Run events and stage logs explain how the runtime moved:

- lifecycle events show run transitions;
- stage attempts show execution and retry history;
- checkpoint envelopes preserve stage state;
- graph state records completed outputs and resumable frontier state.

Use [events](../Reference/Pulse/events.md) for the event catalog.

## Schema And Retention

`provisionPulseSchema` can create a missing schema and validate required current objects, but it
does not migrate an already-deployed stale schema in place. Apply forward migrations from
`migrations/` before rolling out code that depends on new shape.

Managed runs intentionally create durable task-definition and run records. Long-lived hosts that
drive many one-off managed runs need a retention policy for task definitions, runs, graph state,
stage logs, and events.

## Related

- [Deploying Pulse](09-deploying-pulse.md)
- [Troubleshooting](11-troubleshooting.md)
- [Pulse schema](../Reference/Pulse/schema.md)
- [Pulse events](../Reference/Pulse/events.md)
- [Pulse signals](../Reference/Pulse/signals.md)
