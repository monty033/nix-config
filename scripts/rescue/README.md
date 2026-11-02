# Rescue medium scripts

The host-rescue stick is a NixOS ISO from `nixosConfigurations.rescue`, flashed
onto a USB drive that lives in `stark`. These scripts are the gates around it.

| script | runs on | purpose |
|--------|---------|---------|
| `rescue-build.sh` | hermes | drop the trigger file and wait for the root build unit; prints its status JSON |
| `rescue-static-check.sh` | any checkout | assert the rescue config still has the properties the medium relies on (hostname, copytoram, sops key, tailscale ssh, root credentials) |
| `rescue-status.sh` | agent/operator | compare the medium's `version.txt` with what the flake builds today |
| `rescue-boot-test.sh` | host with `/dev/kvm` | boot the ISO (or the medium) in QEMU with networking off; pass on `rescue login:` and zero `[FAILED]` units |
| `rescue-flash.sh` | agent/operator | guarded write to the medium by pinned device serial, then sha256 read-back over the exact ISO length |

Order: static check → status → build → boot-test the ISO → flash → boot-test the
medium → receipt.

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
