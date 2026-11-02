#!/usr/bin/env bash
# Ask the root-owned rescue-iso-build unit for a fresh ISO and wait for it.
#
# The trigger carries no content: the unit fetches master itself and builds
# that, so this script cannot influence what gets built.
#
# Usage: rescue-build.sh [--timeout SECONDS]
# Exit: 0 built, 1 build failed/timed out, 2 not available on this host.
set -euo pipefail

IN=/var/lib/rescue/in
OUT=/var/lib/rescue/out
TIMEOUT=3600
if [ "${1:-}" = "--timeout" ]; then TIMEOUT=${2:?}; fi

for p in "$IN" "$OUT"; do
  if [ -L "$p" ] || { [ -e "$p" ] && [ ! -d "$p" ]; }; then
    echo "refusing: $p is not a plain directory" >&2; exit 2
  fi
done
[ -d "$IN" ] || { echo "this host does not run rescue-iso-build ($IN missing)" >&2; exit 2; }
[ -d "$OUT" ] || { echo "this host does not run rescue-iso-build ($OUT missing)" >&2; exit 2; }
if [ -L "$OUT/status.json" ]; then
  echo "refusing: $OUT/status.json is a symlink" >&2; exit 2
fi

# Freshness is judged on the nanosecond mtime, not the whole second: a request
# issued in the same second as an earlier build must not accept its status.
before=$(stat -c %y "$OUT/status.json" 2>/dev/null || echo none)
start=$(date +%s)
# The trigger directory is agent-writable, so `request` may already be a
# symlink: remove the entry and create the file with O_EXCL, never follow it.
rm -rf -- "$IN/request" 2>/dev/null || true
( set -o noclobber; : > "$IN/request" ) 2>/dev/null ||
  { echo "cannot create $IN/request" >&2; exit 2; }
deadline=$(( start + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ ! -L "$OUT/status.json" ] && [ -s "$OUT/status.json" ]; then
    now=$(stat -c %y "$OUT/status.json" 2>/dev/null || echo none)
    if [ "$now" != "$before" ]; then
      cat "$OUT/status.json"
      echo
      grep -q '"ok":true' "$OUT/status.json" && exit 0
      exit 1
    fi
  fi
  sleep 2
done
echo "timed out after ${TIMEOUT}s waiting for $OUT/status.json" >&2
exit 1
