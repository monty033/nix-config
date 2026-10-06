#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/update-opencode-v2.sh"
TMPDIR="${TMPDIR:-/tmp}"
mkdir -p "$TMPDIR"

tmp="$(mktemp -d "$TMPDIR/opencode-update-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Usage is required for wrong arity.
if "$SCRIPT" >"$tmp/out" 2>"$tmp/err"; then fail 'usage accepted no version'; fi
grep -q 'Usage:' "$tmp/err" || fail 'usage message missing'

# Invalid semantic versions must fail before calling Nix.
cat > "$tmp/nix" <<'MOCK'
#!/usr/bin/env bash
printf called >> "$MOCK_LOG"
exit 99
MOCK
chmod +x "$tmp/nix"
export MOCK_LOG="$tmp/nix-calls"
if PATH="$tmp:$PATH" "$SCRIPT" latest >"$tmp/out" 2>"$tmp/err"; then fail 'invalid version accepted'; fi
[[ ! -e "$MOCK_LOG" ]] || fail 'Nix called for invalid version'

# Mock prefetch and assert exact diff preview plus no source mutation.
cat > "$tmp/nix" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_LOG"
printf '{"url":"%s","hash":"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}\n' "${@: -1}"
MOCK
chmod +x "$tmp/nix"
export MOCK_LOG="$tmp/nix-calls"
# The test operates on the repository package and ensures the helper leaves it unchanged.
package="$(cd "$(dirname "$SCRIPT")/.." && pwd)/packages/opencode-v2.nix"
old_version="$(grep -E '^[[:space:]]*version = "[^"]+";' "$package" | cut -d '"' -f2)"
before="$(sha256sum "$package" | cut -d' ' -f1)"
PATH="$tmp:$PATH" "$SCRIPT" 2.1.0 >"$tmp/preview"
after="$(sha256sum "$package" | cut -d' ' -f1)"
[[ "$before" == "$after" ]] || fail 'package file changed'
grep -F -- "-  version = \"$old_version\";" "$tmp/preview" >/dev/null || fail 'old version missing from diff'
grep -F -- '+  version = "2.1.0";' "$tmp/preview" >/dev/null || fail 'new version missing from diff'
grep -F -- '+    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";' "$tmp/preview" >/dev/null || fail 'new hash missing from diff'
grep -F 'https://opencode.ai/files/bin/2.1.0/opencode-linux-x64.tar.gz' "$MOCK_LOG" >/dev/null || fail 'wrong URL prefetched'

# Malformed prefetch JSON/hash must fail closed.
cat > "$tmp/nix" <<'MOCK'
#!/usr/bin/env bash
printf '{"hash":"bad"}\n'
MOCK
chmod +x "$tmp/nix"
if PATH="$tmp:$PATH" "$SCRIPT" 2.1.0 >"$tmp/out" 2>"$tmp/err"; then fail 'malformed hash accepted'; fi

printf 'All update-opencode-v2 tests passed.\n'
