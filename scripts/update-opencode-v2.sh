#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s VERSION (stable v2 semantic version, e.g. 2.0.23)\n' "${0##*/}" >&2
}

fail() {
  printf 'update-opencode-v2: %s\n' "$1" >&2
  exit 1
}

[[ $# -eq 1 ]] || { usage; exit 2; }
version=$1
[[ "$version" =~ ^2\.[0-9]+\.[0-9]+$ ]] || fail 'version must be a stable v2 semantic version (2.MINOR.PATCH)'

command -v nix >/dev/null 2>&1 || fail 'required command nix is missing'
command -v jq >/dev/null 2>&1 || fail 'required command jq is missing'
command -v diff >/dev/null 2>&1 || fail 'required command diff is missing'

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package="$root/packages/opencode-v2.nix"
[[ -f "$package" ]] || fail 'package file not found'

# Require exactly one literal version and SRI hash assignment, so an upstream
# package shape change cannot silently produce an incomplete preview.
version_count=$(grep -Ec '^[[:space:]]*version = "[^"]+";' "$package" || true)
hash_count=$(grep -Ec '^[[:space:]]*hash = "[^"]+";' "$package" || true)
[[ "$version_count" -eq 1 ]] || fail 'expected exactly one version assignment in package'
[[ "$hash_count" -eq 1 ]] || fail 'expected exactly one hash assignment in package'
old_version=$(grep -E '^[[:space:]]*version = "[^"]+";' "$package" | sed -E 's/^[[:space:]]*version = "([^"]+)";.*/\1/')
old_hash=$(grep -E '^[[:space:]]*hash = "[^"]+";' "$package" | sed -E 's/^[[:space:]]*hash = "([^"]+)";.*/\1/')

url="https://opencode.ai/files/bin/${version}/opencode-linux-x64.tar.gz"
if ! prefetch=$(nix store prefetch-file --json --hash-type sha256 "$url" 2>&1); then
  fail "Nix prefetch failed: $prefetch"
fi
hash=$(printf '%s' "$prefetch" | jq -er '.hash | select(type == "string")' 2>/dev/null) || fail 'Nix prefetch returned malformed JSON or missing hash'
[[ "$hash" =~ ^sha256-[A-Za-z0-9+/]{43}=$ ]] || fail 'Nix prefetch returned malformed SRI SHA-256 hash'

scratch="${TMPDIR:-/tmp}"
mkdir -p "$scratch" || fail 'cannot create scratch directory'
tmp=$(mktemp -d "$scratch/opencode-update-preview.XXXXXX") || fail 'cannot create temporary preview files'
trap 'rm -rf "$tmp"' EXIT
sed -E \
  -e "s|^([[:space:]]*version = )\"${old_version//./\.}\";|\\1\"$version\";|" \
  -e "s|^([[:space:]]*hash = )\"${old_hash//+/\\+}\";|\\1\"$hash\";|" \
  "$package" > "$tmp/proposed"
diff -u --label a/packages/opencode-v2.nix --label b/packages/opencode-v2.nix "$package" "$tmp/proposed" || [[ $? -eq 1 ]]
