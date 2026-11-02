#!/usr/bin/env bash
# Write a rescue ISO to the USB medium on its host, with identity guards and a
# byte-for-byte read-back. Refuses anything that does not look like the stick.
#
# Usage:
#   rescue-flash.sh --iso /var/lib/rescue/out/rescue.iso --dry-run
#   rescue-flash.sh --iso /var/lib/rescue/out/rescue.iso
# Options:
#   --host HOST       host holding the stick (default stark)
#   --dry-run         run every check, write nothing
#   --receipt PATH    write a JSON receipt here
#
# The device identity is pinned here on purpose: the serial is the stick's
# identity, and a caller-supplied serial or path would defeat the guard.
#
# Exit: 0 written+verified, 1 verification failure, 2 refused/usage.
set -euo pipefail

HOST=stark
BYID=/dev/disk/by-id/usb-Samsung_Flash_Drive_FIT_0360723110002277-0:0
EXPECT_SERIAL=0360723110002277
ISO=""; DRY=0; RECEIPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --iso) ISO="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --receipt) RECEIPT="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$ISO" ] || { echo "need --iso" >&2; exit 2; }
[ -f "$ISO" ] || { echo "no such ISO: $ISO" >&2; exit 2; }

ISO_BYTES=$(stat -c %s "$ISO")
ISO_HASH=$(sha256sum "$ISO" | cut -d' ' -f1)
ISO_NAME=$(basename "$ISO")
echo "iso     : $ISO_NAME ($ISO_BYTES bytes)"
echo "sha256  : $ISO_HASH"

# --- target-side identity check (positional args, no shell interpolation) ---
check_target() {
  ssh -o BatchMode=yes "root@$HOST" bash -s -- "$BYID" "$EXPECT_SERIAL" "$ISO_BYTES" <<'EOS'
set -euo pipefail
DEV=$1; EXPECT_SERIAL=$2; NEED_BYTES=$3
refuse() { echo "REFUSED $*"; exit 3; }
[ -e "$DEV" ] || refuse "missing device $DEV"
BASE=$(readlink -f "$DEV")
[ -b "$BASE" ] || refuse "not a block device: $BASE"
TYPE=$(lsblk -dno TYPE "$BASE" | tr -d ' ')
TRAN=$(lsblk -dno TRAN "$BASE" | tr -d ' ')
RM=$(lsblk -dno RM "$BASE" | tr -d ' ')
SERIAL=$(lsblk -dno SERIAL "$BASE" | tr -d ' ')
BYTES=$(blockdev --getsize64 "$BASE")
[ "$TYPE" = disk ] || refuse "$BASE is not a whole disk (type=$TYPE)"
[ "$TRAN" = usb ] || refuse "$BASE is not USB (tran=$TRAN)"
[ "$RM" = 1 ] || refuse "$BASE is not removable (rm=$RM)"
[ -n "$SERIAL" ] || refuse "$BASE reports no serial"
[ "$SERIAL" = "$EXPECT_SERIAL" ] || refuse "serial mismatch: got $SERIAL want $EXPECT_SERIAL"
[ "$BYTES" -ge "$NEED_BYTES" ] || refuse "device smaller than image ($BYTES < $NEED_BYTES)"
if [ -n "$(lsblk -rno MOUNTPOINT "$BASE" | tr -d '\n')" ]; then
  refuse "a partition of $BASE is mounted"
fi
# Root-filesystem ancestry: resolve / down to its backing disks. ZFS and other
# non-block roots are resolved through their pool; anything unresolved refuses.
ROOTSRC=$(findmnt -no SOURCE / 2>/dev/null || true)
[ -n "$ROOTSRC" ] || refuse "cannot resolve the running root filesystem"
ROOTDEVS=""
case "$ROOTSRC" in
  /dev/*)
    # -r keeps the output free of tree glyphs (lsblk prints `└─sda1` otherwise,
    # which no amount of stripping spaces removes).
    ROOTDEVS=$(lsblk -r -s -n -o NAME "$ROOTSRC" 2>/dev/null || true)
    ;;
  *)
    POOL=${ROOTSRC%%/*}
    if command -v zpool >/dev/null 2>&1 && zpool list -H -o name "$POOL" >/dev/null 2>&1; then
      for DEVPATH in $(zpool status -P "$POOL" 2>/dev/null | awk '$1 ~ /^\/dev\// {print $1}'); do
        RESOLVED=$(readlink -f "$DEVPATH" 2>/dev/null) || continue
        ROOTDEVS="$ROOTDEVS $(basename "$RESOLVED") $(lsblk -r -n -o PKNAME "$RESOLVED" 2>/dev/null | head -1)"
      done
    fi
    ;;
esac
[ -n "${ROOTDEVS// /}" ] || refuse "cannot resolve block devices backing / ($ROOTSRC)"
KNAME=$(basename "$BASE")
PKNAME=$(lsblk -r -n -o PKNAME "$BASE" 2>/dev/null | head -1)
for DEV in $ROOTDEVS; do
  if [ "$DEV" = "$KNAME" ] || { [ -n "$PKNAME" ] && [ "$DEV" = "$PKNAME" ]; }; then
    refuse "$BASE is part of the running root filesystem"
  fi
done
printf 'TARGET=%s\nTYPE=%s\nTRAN=%s\nRM=%s\nSERIAL=%s\nBYTES=%s\n' \
  "$BASE" "$TYPE" "$TRAN" "$RM" "$SERIAL" "$BYTES"
EOS
}

TARGET=$(check_target) || { echo "$TARGET"; echo "target checks failed, nothing written"; exit 2; }
echo "$TARGET" | sed 's/^/target  : /'

if [ "$DRY" -eq 1 ]; then
  echo "DRY RUN: checks passed; would write $ISO_BYTES bytes to $HOST:$BYID"
  exit 0
fi

# --- write ----------------------------------------------------------------
# Re-check identity immediately before the write; the medium is the identity.
check_target >/dev/null || { echo "REFUSED: identity changed before write"; exit 2; }
echo "writing ..."
ssh -o BatchMode=yes "root@$HOST" \
  "dd of='$BYID' bs=4M conv=fsync iflag=count_bytes count=$ISO_BYTES status=progress" < "$ISO"
ssh -o BatchMode=yes "root@$HOST" \
  "sync; blockdev --flushbufs '$BYID'; (partprobe '$BYID' 2>/dev/null || true); udevadm settle"

# The source must not have changed size while it was being read.
[ "$(stat -c %s "$ISO")" = "$ISO_BYTES" ] || { echo "FAIL: source ISO changed during the write"; exit 1; }

# --- read-back ------------------------------------------------------------
check_target >/dev/null || { echo "FAIL: identity changed before read-back"; exit 1; }
echo "verifying read-back ..."
READ_HASH=$(ssh -o BatchMode=yes "root@$HOST" "head -c $ISO_BYTES '$BYID' | sha256sum" | cut -d' ' -f1)
READ_VER=$(ssh -o BatchMode=yes "root@$HOST" bash -s -- "$BYID" <<'EOS'
set -euo pipefail
DEV=$1
MNT=$(mktemp -d /tmp/rescue-verify.XXXXXX)
trap 'mountpoint -q "$MNT" && umount "$MNT"; rmdir "$MNT" 2>/dev/null || true' EXIT
mount -t iso9660 -o ro "${DEV}1" "$MNT" 2>/dev/null || mount -t iso9660 -o ro "$DEV" "$MNT"
cat "$MNT/version.txt" 2>/dev/null || echo unknown
EOS
)

echo "readback: $READ_HASH"
echo "version : $READ_VER"
if [ "$READ_HASH" != "$ISO_HASH" ]; then
  echo "FAIL: read-back hash does not match the source ISO"
  exit 1
fi

if [ -n "$RECEIPT" ]; then
  mkdir -p "$(dirname "$RECEIPT")"
  cat > "$RECEIPT" <<JSON
{
  "iso": "$ISO_NAME",
  "iso_bytes": $ISO_BYTES,
  "sha256": "$ISO_HASH",
  "host": "$HOST",
  "device": "$BYID",
  "serial": "$EXPECT_SERIAL",
  "version": "$READ_VER",
  "flashed_at": "$(date -Iseconds)",
  "verified": true
}
JSON
  echo "receipt : $RECEIPT"
fi
echo "PASS: medium is byte-identical to $ISO_NAME"
