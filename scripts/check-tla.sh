#!/usr/bin/env bash
# Model-check the Pulse run-terminal signal protocol with TLC.
#
# Positive specs must verify. The two NEGATIVE specs must reproduce the bug they
# document (lost wakeup / deadlock) -- proving the models actually catch the bug
# class rather than vacuously passing. Requires `tlc` on PATH (nixpkgs#tlaplus).
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

echo "TLA+ negative checks (must reproduce the documented bug):"
expect_violation Split.cfg RunTerminalSignal.tla "NoStuckWaiter is violated"

if [ "$fail" -ne 0 ]; then
  echo "TLA+ protocol checks FAILED." >&2
  exit 1
fi
echo "All TLA+ protocol checks passed."
