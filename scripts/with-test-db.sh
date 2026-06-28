#!/usr/bin/env bash
# Bootstrap an ephemeral PostgreSQL with the cortex-owned Pulse schema fixture,
# export PG* connection env, run the given command, then tear everything down.
#
# Requires `initdb`/`pg_ctl`/`psql` on PATH (nixpkgs#postgresql). The Pulse
# DB-backed tests skip themselves when PGHOST is unset; this provides the DB so
# they actually run. Usage: scripts/with-test-db.sh <command...>
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
schema="$root/data/pulse-schema.sql"
[ -f "$schema" ] || { echo "missing schema fixture: $schema" >&2; exit 1; }

work="$(mktemp -d)"
export PGDATA="$work/data"
sock="$work/sock"
mkdir -p "$sock"
# Randomize the port so concurrent runs (e.g. CI on a shared self-hosted runner)
# don't collide on a fixed port.
port="${PGPORT:-$((50000 + RANDOM % 10000))}"
cleanup() { pg_ctl -D "$PGDATA" stop -m immediate >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

initdb -D "$PGDATA" -U postgres --auth=trust >/dev/null
pg_ctl -D "$PGDATA" \
  -o "-p $port -c listen_addresses='127.0.0.1' -c unix_socket_directories='$sock' -c fsync=off" \
  -w start >/dev/null

psql_() { psql -h 127.0.0.1 -p "$port" -U postgres -v ON_ERROR_STOP=1 "$@"; }
psql_ -d postgres -c "CREATE DATABASE cortex_test;" >/dev/null
psql_ -d cortex_test -q -f "$schema"
psql_ -d cortex_test -q -f "$root/test/sql/test-support.sql"

export PGHOST=127.0.0.1 PGPORT="$port" PGUSER=postgres PGDATABASE=cortex_test PGPASSWORD=
echo "test DB ready on 127.0.0.1:$port/cortex_test — running: $*"
"$@"
