#!/usr/bin/env bash
# Assert the rescue configuration still has the properties the medium relies on.
# Pure evaluation from the flake: no build, no secrets, no root.
#
# Usage: rescue-static-check.sh [--repo PATH]
# Exit: 0 all assertions pass, 1 failure, 2 evaluation error.
set -euo pipefail

REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
if [ "${1:-}" = "--repo" ]; then REPO=${2:?}; fi

evalc() { (cd "$REPO" && nix eval --impure --no-write-lock-file --json ".#nixosConfigurations.rescue.config.$1" 2>/dev/null) || true; }

HOST=$(evalc networking.hostName) || { echo "FAIL: cannot evaluate rescue config" >&2; exit 2; }
PARAMS=$(evalc boot.kernelParams)
AUTOLOGIN=$(evalc services.getty.autologinUser)
ROOT_KEYS=$(evalc users.users.root.openssh.authorizedKeys.keys)
ROOT_HASH=$(evalc users.users.root.hashedPassword)
PW_AUTH=$(evalc services.openssh.settings.PasswordAuthentication)
TS_FLAGS=$(evalc services.tailscale.extraUpFlags)
TS_ENABLE=$(evalc extra-services.tailscale.enable)
ETC_KEY=$( (cd "$REPO" && nix eval --impure --no-write-lock-file --json '.#nixosConfigurations.rescue.config.environment.etc' --apply 'x: builtins.hasAttr "sops/age/keys.txt" x' 2>/dev/null) || true )

fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then printf 'ok   %-42s %s\n' "$1" "$3"
  else printf 'FAIL %-42s expected %s, got %s\n' "$1" "$2" "$3"; fail=1; fi
}

check "hostname" '"rescue"' "$HOST"
check "console autologin disabled" 'null' "$AUTOLOGIN"
check "copytoram in kernel parameters" 'true' \
  "$(echo "$PARAMS" | grep -q '"copytoram"' && echo true || echo false)"
check "sops age key staged into image" 'true' "$ETC_KEY"
check "tailscale enabled" 'true' "$TS_ENABLE"
check "tailscale ssh enabled" 'true' \
  "$(echo "$TS_FLAGS" | grep -q -- '--ssh' && echo true || echo false)"
check "root has an ssh key" 'true' \
  "$([ "$ROOT_KEYS" != "[]" ] && echo true || echo false)"
check "root has a password hash" 'true' \
  "$([ "$ROOT_HASH" != "null" ] && echo true || echo false)"
check "ssh password auth" 'true' "$PW_AUTH"

# The flasher streams the ISO into `dd` on stdin. A `count=`/`iflag=count_bytes`
# combination there counts short pipe reads as blocks and silently truncates the
# write, so the write path must run to EOF and let the read-back prove the size.
WRITE_LINE=$(grep -h '^  "dd of=' "$REPO/scripts/rescue/rescue-flash.sh" || true)
check "flash write has no byte count" 'true' \
  "$([ -n "$WRITE_LINE" ] && ! echo "$WRITE_LINE" | grep -q 'count' && echo true || echo false)"

# The checks above describe intent; print the effective values that matter for
# a rescue session so a reviewer can see them without another eval.
echo
echo "tailscale flags: $TS_FLAGS"
echo "root keys      : $(echo "$ROOT_KEYS" | tr ',' '\n' | wc -l) key(s)"
[ "$fail" -eq 0 ] && echo "RESULT: pass" || echo "RESULT: fail"
exit "$fail"
