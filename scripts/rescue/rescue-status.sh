#!/usr/bin/env bash
# Report the state of the host-rescue USB medium versus what nix-config would
# build today. Read-only: mounts the medium read-only and unmounts it.
#
# Usage: rescue-status.sh [--host stark] [--repo PATH] [--hash]
# Exit: 0 current, 3 stale, 2 error.
#
# The device identity is pinned here for the same reason as in rescue-flash.sh:
# a caller-supplied path reaches a remote shell, so it is not a parameter.
set -euo pipefail

HOST=stark
DEVICE=/dev/disk/by-id/usb-Samsung_Flash_Drive_FIT_0360723110002277-0:0
REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
DO_HASH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --hash) DO_HASH=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$HOST" in
  *[!A-Za-z0-9._-]*) echo "invalid host: $HOST" >&2; exit 2 ;;
esac

EXPECTED=$(cd "$REPO" && nix eval --impure --no-write-lock-file --raw \
  '.#nixosConfigurations.rescue.config.system.nixos.version' 2>/dev/null) || {
  echo "cannot evaluate rescue system version from $REPO" >&2; exit 2; }

REMOTE=$(ssh -o BatchMode=yes "root@$HOST" bash -s -- "$DEVICE" "$DO_HASH" <<'EOS'
set -euo pipefail
DEV=$1; DO_HASH=$2
[ -b "$DEV" ] || { echo "ERR device missing: $DEV" >&2; exit 2; }
BASE=$(readlink -f "$DEV")
TRAN=$(lsblk -dno TRAN "$BASE" | tr -d ' ')
RM=$(lsblk -dno RM "$BASE" | tr -d ' ')
SIZE=$(lsblk -dno SIZE "$BASE" | tr -d ' ')
SERIAL=$(lsblk -dno SERIAL "$BASE" | tr -d ' ')
if findmnt -rn -S "${BASE}1" >/dev/null 2>&1 || findmnt -rn -S "$BASE" >/dev/null 2>&1; then
  echo "ERR device is mounted: $BASE" >&2; exit 2
fi
MNT=$(mktemp -d /tmp/rescue-status.XXXXXX)
trap 'mountpoint -q "$MNT" && umount "$MNT"; rmdir "$MNT" 2>/dev/null || true' EXIT
mount -t iso9660 -o ro "${BASE}1" "$MNT" 2>/dev/null || mount -t iso9660 -o ro "$BASE" "$MNT"
VER=$(cat "$MNT/version.txt" 2>/dev/null || echo unknown)
ISO_BYTES=$(isosize "${BASE}1" 2>/dev/null || isosize "$BASE" 2>/dev/null || echo 0)
HASH=""
if [ "$DO_HASH" = 1 ] && [ "$ISO_BYTES" -gt 0 ]; then
  HASH=$(head -c "$ISO_BYTES" "$BASE" | sha256sum | cut -d' ' -f1)
fi
printf 'device=%s\ntran=%s\nremovable=%s\nsize=%s\nserial=%s\nversion=%s\niso_bytes=%s\nsha256=%s\n' \
  "$BASE" "$TRAN" "$RM" "$SIZE" "$SERIAL" "$VER" "$ISO_BYTES" "$HASH"
EOS
)

echo "$REMOTE" | grep -q '^version=' || { echo "$REMOTE" >&2; exit 2; }
get() { echo "$REMOTE" | sed -n "s/^$1=//p"; }

ACTUAL=$(get version)
# A version.txt match is weak: a config-only change keeps system.nixos.version
# identical. When the root build unit has published an image, its sha256 is the
# authoritative identity, so hash the medium too (--hash) and compare.
EXPECTED_HASH=""
if [ -r /var/lib/rescue/out/status.json ]; then
  EXPECTED_HASH=$(sed -n 's/.*"sha256":"\([0-9a-f]\{64\}\)".*/\1/p' /var/lib/rescue/out/status.json)
fi
ACTUAL_HASH=$(get sha256)
# --hash means "compare the image itself". If either side is unavailable the
# check cannot be made, so fail closed rather than quietly grading on version.
if [ "$DO_HASH" -eq 1 ] && { [ -z "$ACTUAL_HASH" ] || [ -z "$EXPECTED_HASH" ]; }; then
  echo "hash comparison requested but unavailable (medium='${ACTUAL_HASH:-none}' built='${EXPECTED_HASH:-none}')" >&2
  exit 2
fi
echo "medium : $(get device)  $(get size)  serial $(get serial)  removable=$(get removable) tran=$(get tran)"
echo "on disk: $ACTUAL"
echo "nix-config would build: $EXPECTED"
if [ -n "$ACTUAL_HASH" ]; then echo "medium sha256 : $ACTUAL_HASH"; fi
if [ -n "$EXPECTED_HASH" ]; then echo "built  sha256 : $EXPECTED_HASH"; fi

STATUS=0
[ "$ACTUAL" = "$EXPECTED" ] || STATUS=3
if [ -n "$ACTUAL_HASH" ] && [ -n "$EXPECTED_HASH" ] && [ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]; then
  STATUS=3
fi
if [ "$DO_HASH" -eq 0 ]; then
  echo "note   : version-only comparison; pass --hash to compare the image bytes"
fi
if [ "$STATUS" -eq 0 ]; then
  echo "STATUS: current"
  exit 0
fi
echo "STATUS: stale (medium is behind nix-config; rebuild + reflash + boot-test)"
exit 3
