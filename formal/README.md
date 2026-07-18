# Formal protocol models (TLA+)

Model-checked specifications of Pulse runtime protocols whose correctness depends on
concurrency/interleaving — the layer the Lean proof track (value semantics) does not cover.

Run all checks: `just tla-check` (or `nix run .#_check-tla`). Requires `tlc` (nixpkgs `tlaplus`);
wired into `ci-check` and the flake apps.

## Models

### `RunTerminalSignal.tla` — the "await a run" suspend/deliver protocol

A parent run suspends on a child run's `run-terminal:<uuid>` signal. The `Atomic` constant selects
the protocol shape:

- `Atomic = TRUE` (`Atomic.cfg`) — models `settleSuspend`: the FOR-SHARE check, the wait row, and
  the park commit as **one transaction**. `NoStuckWaiter` and `EventuallyDone` hold.
- `Atomic = FALSE` (`Split.cfg`) — models the historical register-then-park split (before the
  post-park recheck). **Negative check**: TLC must report `NoStuckWaiter is violated`; the trace is
  the lost wakeup (a parked waiter on an already-delivered signal).

The negative config (`Split.cfg`) is expected to fail; `scripts/check-tla.sh` asserts it reproduces
its documented violation, so the model cannot vacuously pass.

### `HostedProtocol.tla` — the Wire process-host lifecycle

This model covers the concurrency owned by the process host rather than the engine value semantics:
atomic worker registration, checkpoint acknowledgement, direct and buffered completions, operator
and interruption-driven cancellation, independent deadline identities, completed/failed/cancelled
terminal precedence, and abnormal child exit. Lean separately proves snapshot validity and the
engine checkpoint gate.

The positive `HostedProtocol.cfg` checks the production policy. Three expected-failure configs prove
the central race checks are non-vacuous by respectively forwarding a buffered completion after
cancellation, clearing a deadline when a successor request crosses a completion, and replacing an
outstanding deadline on unrelated traffic.

## Note on multi-await lock ordering (no model required)

An earlier draft modelled `SELECT … FOR SHARE` acquisition ordering for deadlock-avoidance. That was
removed: `FOR SHARE` row locks are **shared** (compatible with other `FOR SHARE` holders), and a
settlement's only _exclusive_ writes are its own `pulse.runs` and `pulse.graph_state` rows (distinct
per run) plus its own new `pulse.signals` rows. Concurrent settlements therefore cannot form a lock
cycle on the awaited rows regardless of acquisition order, so no ordering requirement exists to
check. The awaited-row `FOR SHARE` serves serialization against the terminal writer's exclusive
`UPDATE` (the lost-wakeup prevention modelled in `RunTerminalSignal.tla`), not deadlock-avoidance.
