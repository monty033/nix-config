# Rescue medium scripts

The host-rescue stick is a NixOS ISO from `nixosConfigurations.rescue`, flashed
onto a USB drive that lives in `stark`. These scripts are the gates around it.

| script | runs on | purpose |
|--------|---------|---------|
| `rescue-build.sh` | hermes | drop the trigger file and wait for the root build unit; prints its status JSON |
| `rescue-static-check.sh` | any checkout | assert the rescue config still has the properties the medium relies on (hostname, copytoram, sops key, tailscale ssh, root credentials) and that the flasher's write line is safe |
| `rescue-status.sh` | agent/operator | compare the medium with what the flake builds today |
| `rescue-boot-test.sh` | host with `/dev/kvm` | boot the ISO (or the medium) in QEMU with networking off; pass on `rescue login:` and zero `[FAILED]` units |
| `rescue-flash.sh` | agent/operator | guarded write to the medium by pinned device serial, then sha256 read-back over the exact ISO length |

Order: static check → status → build → boot-test the ISO → flash → boot-test the
medium → receipt. Nothing is current until the last step passes.

## Refresh runbook

```bash
# 0. what is on the stick versus what this checkout would build
scripts/rescue/rescue-static-check.sh
scripts/rescue/rescue-status.sh --hash        # exit 3 means stale

# 1. build through the root unit (no sudo needed, trigger only)
scripts/rescue/rescue-build.sh                # prints status.json on success
cat /var/lib/rescue/out/status.json           # commit, version, sha256, bytes

# 2. boot-test the image itself, on a host with KVM
scp /var/lib/rescue/out/rescue.iso root@stark:/var/tmp/rescue-under-test.iso
scp scripts/rescue/rescue-boot-test.sh root@stark:/var/tmp/rbt.sh
ssh root@stark 'chmod +x /var/tmp/rbt.sh &&
  /var/tmp/rbt.sh --iso /var/tmp/rescue-under-test.iso --timeout 420'

# 3. flash, with the receipt kept next to the previous ones
scripts/rescue/rescue-flash.sh \
  --iso /var/lib/rescue/out/rescue.iso \
  --receipt /var/lib/hermes/workspace/rescue/receipts/flash-$(date +%Y%m%d).json

# 4. boot-test the medium itself, then delete the scratch copies
ssh root@stark '/var/tmp/rbt.sh \
  --device /dev/disk/by-id/usb-Samsung_Flash_Drive_FIT_0360723110002277-0:0 --timeout 420'
ssh root@stark 'rm -f /var/tmp/rescue-under-test.iso /var/tmp/rbt.sh'
```

Exit codes: `rescue-status.sh` 0 current / 3 stale / 2 error (including `--hash`
when either side of the hash comparison is unavailable — it fails closed rather
than grading on the version string alone). `rescue-flash.sh` 0 written and
verified / 1 verification failure / 2 refused.

## Build

Only root can build the ISO (`hosts/rescue` reads `/etc/sops/age/keys.txt` at
evaluation time). `rescue-iso-build.service` on the hermes host does it:

```bash
scripts/rescue/rescue-build.sh          # prints status.json, exits 0 on success
cat /var/lib/rescue/out/status.json     # commit, version, sha256, bytes
```

The agent's only input is the trigger `/var/lib/rescue/in/request`. The unit
fetches `master` into its own root-owned mirror with the Forgejo token, with
system and global git config disabled, extracts that commit into a root-owned
temp directory, and publishes `/var/lib/rescue/out/rescue.iso` (0644) plus
`status.json`. It cannot be pointed at another commit, ref, or working tree.
The unit also refuses to start on a symlinked state root and repairs ownership
and mode of every directory it uses; nothing left under `/var/lib/rescue` by an
earlier layout is trusted, and the mirror is rebuilt from scratch each run.

## Safety

- The medium carries the SOPS age private key and root credentials. Treat a lost
  stick as a secret compromise: rotate the age key and re-encrypt.
- `rescue-flash.sh` pins the device by-id path and serial; it refuses a caller
  override, a device that is not a whole USB removable disk, an empty or
  mismatched serial, a device smaller than the image, a mounted device, and a
  device that is part of the running root filesystem. If root ancestry cannot be
  resolved it refuses rather than guessing.
- Test boots use `-net none` so they never register a tailnet node, boot the
  medium read-only with `-snapshot`, and keep every temporary file in a private
  directory the script owns.
- Keep a copy of the image that is on the stick before overwriting it. The
  previous medium lives at `/var/lib/hermes/workspace/rescue/images/`; a flash
  that fails verification leaves the stick unusable, and the copy is the only
  rollback.

## Postmortem: the write that truncated at 16 MB

The first real flash (2026-11-02) wrote 16,023,552 bytes of a 1,631,322,112-byte
image, exited 1 at the read-back, and left the stick unbootable until it was
rewritten.

Cause: the write was

```bash
ssh root@stark "dd of='$BYID' bs=4M conv=fsync iflag=count_bytes count=$ISO_BYTES" < "$ISO"
```

Reading from a pipe returns short reads (about 64 KB), and `dd` counts each of
those as one input record. With `count=` set it stopped after `count` records
rather than `count` bytes, so it stopped early and the remote `dd` exited
cleanly. The read-back was the only thing that noticed.

Fix: drop `count=`/`iflag=count_bytes` and read to EOF. The source file is
exactly the image length, and the read-back over that same length proves what
landed. `rescue-static-check.sh` now fails if a byte count reappears on the
write line, so the pattern cannot return unnoticed.

Lesson for any future change here: the write step fails silently and the loss is
only visible at verification, by which point the medium is already destroyed.
Treat every edit to the flash path as a change to the most dangerous command in
the repo.

## Automation

`Rescue USB staleness check` (Hermes cron `b154b64f921c`) runs Mondays at 08:00
and delivers to the Homelab topic. It runs
`/var/lib/hermes/.hermes/scripts/rescue/rescue-weekly-check.py`, which is silent
while the medium matches the checkout, posts the version comparison when the
medium is stale, and posts a failure notice if the check itself breaks. It never
writes to the stick — stale means "run the runbook above", not "flash
automatically".

The wrapper is Python rather than shell because the scheduler executes `.sh`
jobs with `bash` from its own `PATH` and refuses them outright when that is
missing; it shells out to `rescue-status.sh` with an explicit bash instead.
Silence is the success signal: the job only speaks when the medium is stale or
the check itself failed.
