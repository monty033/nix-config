#!/usr/bin/env bash
# Boot-test a NixOS rescue ISO (file or block device) in QEMU.
#
# Proves the artifact reaches multi-user and serves a rescue login prompt on
# the serial console, without touching the network (so a test boot never
# registers a tailnet node) and without writing to the medium.
#
# Usage:
#   rescue-boot-test.sh --device /dev/disk/by-id/usb-...
#   rescue-boot-test.sh --iso /var/lib/rescue/out/rescue.iso
# Options:
#   --mem MB      guest RAM (default 5120; copytoram needs room for the squashfs)
#   --timeout S   seconds to wait for the login prompt (default 420)
#   --tcg         force TCG (no /dev/kvm)
#
# Exit: 0 boot verified, 1 boot failed/timeout/failed units, 2 usage/setup.
set -euo pipefail

DEVICE=""; ISO=""; MEM=5120; TIMEOUT=420; FORCE_TCG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --iso)    ISO="$2"; shift 2 ;;
    --mem)    MEM="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --tcg)    FORCE_TCG=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$DEVICE$ISO" ] || { echo "need --device or --iso" >&2; exit 2; }
[ -z "$DEVICE" ] || [ -b "$DEVICE" ] || { echo "not a block device: $DEVICE" >&2; exit 2; }
[ -z "$ISO" ] || [ -f "$ISO" ] || { echo "no such ISO: $ISO" >&2; exit 2; }

command -v qemu-system-x86_64 >/dev/null || { echo "qemu-system-x86_64 not found" >&2; exit 2; }

# Everything this script creates lives in a private, script-owned directory, so
# no caller-supplied path is ever handed to a root shell.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/rescue-boot.XXXXXX")
MNT=$WORK/mnt
LOG=$WORK/serial.log
mkdir -p "$MNT"
QPID=""
cleanup() {
  if [ -n "$QPID" ]; then kill "$QPID" 2>/dev/null || true; wait "$QPID" 2>/dev/null || true; fi
  mountpoint -q "$MNT" && umount "$MNT" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# Mount only an ISO9660 filesystem, read-only, from the raw device or a file.
if [ -n "$DEVICE" ]; then
  mount -t iso9660 -o ro "${DEVICE}1" "$MNT" 2>/dev/null || mount -t iso9660 -o ro "$DEVICE" "$MNT"
  QDEV=(-drive "file=$DEVICE,format=raw,media=cdrom,readonly=on")
else
  mount -t iso9660 -o loop,ro "$ISO" "$MNT"
  QDEV=(-drive "file=$ISO,format=raw,media=cdrom,readonly=on")
fi

# The ISO's own GRUB menu carries the exact stage-2 init path; reuse it so the
# test boots the same system the medium would boot.
KERNEL=$(ls "$MNT"/boot/nix/store/*-linux-*/bzImage 2>/dev/null | head -1 || true)
INITRD=$(ls "$MNT"/boot/nix/store/*-initrd-linux-*/initrd 2>/dev/null | head -1 || true)
INITSYS=$(grep -m1 -o 'init=/nix/store/[^ ]*' "$MNT"/EFI/BOOT/grub.cfg 2>/dev/null || true)
if [ -z "$KERNEL" ] || [ -z "$INITRD" ] || [ -z "$INITSYS" ]; then
  echo "FAIL: could not locate kernel/initrd/init inside the image" >&2
  exit 2
fi

VERSION=$(cat "$MNT"/version.txt 2>/dev/null || echo unknown)
ACCEL=(-machine q35)
if [ "$FORCE_TCG" -eq 0 ] && [ -r /dev/kvm ]; then
  ACCEL=(-enable-kvm -machine q35)
fi

echo "image:   ${DEVICE:-$ISO}"
echo "version: $VERSION"
echo "kernel:  ${KERNEL#$MNT}"
echo "log:     $LOG (removed with the temp dir on exit)"

qemu-system-x86_64 "${ACCEL[@]}" -m "$MEM" -smp 2 -snapshot \
  -kernel "$KERNEL" -initrd "$INITRD" \
  -append "$INITSYS copytoram nohibernate root=fstab loglevel=4 console=ttyS0,115200 console=tty0" \
  "${QDEV[@]}" -net none -display none -no-reboot \
  -serial "file:$LOG" >/dev/null 2>&1 &
QPID=$!

RESULT=timeout
DEADLINE=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  sleep 3
  if grep -qE '^rescue login:|Reached target Multi-User System' "$LOG" 2>/dev/null; then
    RESULT=ok; break
  fi
  if grep -qiE 'Welcome to emergency mode|You are in emergency mode|Kernel panic' "$LOG" 2>/dev/null; then
    RESULT=emergency; break
  fi
  if ! kill -0 "$QPID" 2>/dev/null; then RESULT=died; break; fi
done

kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
QPID=""

FAILED_UNITS=$(grep -cE '\[FAILED\]' "$LOG" 2>/dev/null || true)
echo "--- serial tail ---"
tail -12 "$LOG" 2>/dev/null || true
echo "-------------------"

if [ "$RESULT" = ok ] && [ "$FAILED_UNITS" -eq 0 ]; then
  echo "PASS: booted to multi-user (version $VERSION, failed units 0)"
  exit 0
fi
if [ "$RESULT" = ok ]; then
  echo "FAIL: booted, but $FAILED_UNITS unit(s) reported [FAILED]"
  exit 1
fi
echo "FAIL: $RESULT after ${TIMEOUT}s"
exit 1
