#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/opencode-env-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Exercise the exact systemd EnvironmentFile parser, using synthetic data only.
run_guard() {
  systemd-run --user --pipe --wait --collect --same-dir \
    --property=Environment=OPENCODE_SERVER_PASSWORD= \
    --property="EnvironmentFile=$tmp/env" -- /bin/sh -c '
      if [ -z "${OPENCODE_SERVER_PASSWORD:-}" ]; then
        printf "%s\n" "OpenCode server password is required" >&2
        exit 1
      fi
      actual=$(printf "%s" "$OPENCODE_SERVER_PASSWORD" | od -An -t x1 | tr -d "[:space:]")
      test "$actual" = "6c6173745c76616c7565"
    '
}

cat > "$tmp/env" <<'ENV'
OPENCODE_SERVER_PASSWORD="quoted value"
OPENCODE_SERVER_PASSWORD="last\\value"
ENV
run_guard || fail "quoted duplicate EnvironmentFile value or escape was not accepted"

for value in missing empty; do
  if [[ $value == missing ]]; then : > "$tmp/env"; else printf 'OPENCODE_SERVER_PASSWORD=\n' > "$tmp/env"; fi
  if run_guard >"$tmp/out" 2>"$tmp/err"; then
    fail "$value password unexpectedly accepted"
  fi
  grep -Fxq 'OpenCode server password is required' "$tmp/err" || fail "$value diagnostic missing"
done
printf 'OpenCode EnvironmentFile tests passed.\n'
