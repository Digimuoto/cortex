#!/usr/bin/env bash
# Parse every checked-in Wire fixture, then fail on any parse error.
# Invoked from CI or manually after grammar changes.

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
FIXTURES_DIR="$REPO/test/fixtures/wire"

cd "$HERE"

fails=0
for f in "$FIXTURES_DIR"/*.wire; do
  [ -e "$f" ] || continue
  name="${f#$REPO/}"
  if tree-sitter parse -q "$f" >/dev/null 2>&1; then
    printf 'ok   %s\n' "$name"
  else
    printf 'fail %s\n' "$name"
    tree-sitter parse "$f" 2>&1 | grep -E 'ERROR|MISSING' | head -3 | sed 's/^/     /'
    fails=$((fails + 1))
  fi
done

if [ "$fails" -gt 0 ]; then
  printf '\n%d Wire source(s) failed to parse\n' "$fails" >&2
  exit 1
fi
