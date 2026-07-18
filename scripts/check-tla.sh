#!/usr/bin/env bash
# Model-check the Pulse signal and Wire process-host protocols with TLC.
#
# Positive specs must verify. NEGATIVE specs deliberately weaken one protocol
# rule and must reproduce the named invariant violation, proving the checks are
# not vacuous. Requires `tlc` on PATH (nixpkgs#tlaplus).
set -euo pipefail

cd "$(dirname "$0")/../formal"

run_tlc() { # $1 cfg, $2 spec -> sets TLC_OUT, returns tlc's exit code
  local meta
  meta="$(mktemp -d)"
  set +e
  TLC_OUT="$(tlc -config "$1" -metadir "$meta" -workers auto "$2" 2>&1)"
  local rc=$?
  set -e
  rm -rf "$meta"
  return "$rc"
}

fail=0

expect_pass() { # $1 cfg, $2 spec
  if run_tlc "$1" "$2"; then
    echo "ok   : $2 [$1] verified"
  else
    echo "FAIL : $2 [$1] expected to verify; TLC failed:" >&2
    printf '%s\n' "$TLC_OUT" | tail -n 20 >&2
    fail=1
  fi
}

expect_violation() { # $1 cfg, $2 spec, $3 needle
  if run_tlc "$1" "$2"; then
    echo "FAIL : $2 [$1] expected to reproduce '$3' but TLC verified clean" >&2
    fail=1
  elif printf '%s\n' "$TLC_OUT" | grep -qiF "$3"; then
    echo "ok   : $2 [$1] reproduced '$3' (documented negative check)"
  else
    echo "FAIL : $2 [$1] failed, but not with '$3':" >&2
    printf '%s\n' "$TLC_OUT" | tail -n 20 >&2
    fail=1
  fi
}

echo "TLA+ positive checks (must verify):"
expect_pass Atomic.cfg RunTerminalSignal.tla
expect_pass HostedProtocol.cfg HostedProtocol.tla

echo "TLA+ negative checks (must reproduce the documented bug):"
expect_violation Split.cfg RunTerminalSignal.tla "NoStuckWaiter is violated"
expect_violation HostedProtocolForwardAfterCancel.cfg HostedProtocol.tla "NoCompletionAfterCancellation is violated"
expect_violation HostedProtocolForwardAfterTerminal.cfg HostedProtocol.tla "NoCompletionAfterTerminal is violated"
expect_violation HostedProtocolLoseCrossingDeadline.cfg HostedProtocol.tla "CrossingCheckpointDeadlinePreserved is violated"
expect_violation HostedProtocolExtendDeadline.cfg HostedProtocol.tla "DeadlineStableUnderUnrelatedTraffic is violated"

if [ "$fail" -ne 0 ]; then
  echo "TLA+ protocol checks FAILED." >&2
  exit 1
fi
echo "All TLA+ protocol checks passed."
