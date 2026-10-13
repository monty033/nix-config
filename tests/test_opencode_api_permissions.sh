#!/usr/bin/env bash
# Mock-only tests for the permission-request commands in packages/opencode-api.sh.
#
# The API (curl) is stubbed: every request is recorded to a log and answered from
# fixture files. No request ever leaves the machine and the real OpenCode server is
# never contacted. The script under test is wrapped with the same `set -o errexit
# -o nounset -o pipefail` options that writeShellApplication prepends.
#
# Body contract verified against OpenCode v2.0.23
# packages/server/src/handlers/permission.ts, which consumes ctx.payload.decision:
#   POST /api/session/:sessionID/permission/:requestID/reply
#     body {"decision":"once"|"reject"} -> 204
#   The wire field is `decision`; internal reply/body naming is not the wire shape.
#   The wrapper no longer exposes `always`/`--persist`; both are rejected as invalid
#   without sending a POST.
#   The Permission.Request schema requires sessionID, so a re-fetched request missing
#   it fails closed (no reply POST).
#   Rejecting fails every pending permission ask in that session, so `reject` always
#   requires --reject-all-pending.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/packages/opencode-api.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/opencode-api-perm-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mockbin="$tmp/bin"; mockdir="$tmp/mock"
mkdir -p "$mockbin" "$mockdir"

CANARY='OPENCODE_SERVER_PASSWORD=CANARY-do-not-log-2c9f0a'
secret="$tmp/secret"; printf '%s\n' "$CANARY" > "$secret"

# Script under test with the same options the Nix wrapper prepends.
testscript="$tmp/opencode-api"
{ printf 'set -o errexit\nset -o nounset\nset -o pipefail\n'; cat "$SCRIPT"; } > "$testscript"

# --- stubbed curl ----------------------------------------------------------
cat > "$mockbin/curl" <<'MOCK'
#!/usr/bin/env bash
set -u
# Consume and discard the credentials config delivered on stdin.
cat >/dev/null
args=("$@")
method=GET url='' data='' hdr=''
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  a=${args[$i]}
  case "$a" in
    -X) i=$((i+1)); method=${args[$i]} ;;
    -d) i=$((i+1)); data=${args[$i]} ;;
    -K) i=$((i+1)) ;;
    -H) i=$((i+1)); hdr=${args[$i]} ;;
    -m) i=$((i+1)) ;;
    http*) url=$a ;;
    *) : ;;
  esac
  i=$((i+1))
done
{
  printf 'CALL %s %s\n' "$method" "$url"
  printf 'HDR %s\n' "$hdr"
  [ -n "$data" ] && printf 'BODY %s\n' "$data"
} >> "$MOCK_LOG"
case "$url" in
  */permission/*/reply)
    if [ "${MOCK_POST_STATUS:-204}" -ge 400 ]; then echo 'curl: (22) mock POST error' >&2; exit 22; fi
    exit 0 ;;
  */permission/*)
    if [ "${MOCK_GET_STATUS:-200}" -ge 400 ]; then echo 'curl: (22) mock GET 404' >&2; exit 22; fi
    cat "$MOCK_DIR/get.json"; exit 0 ;;
  */permission)
    if [ "${MOCK_LIST_STATUS:-200}" -ge 400 ]; then echo 'curl: (22) mock list 404' >&2; exit 22; fi
    cat "$MOCK_DIR/list.json"; exit 0 ;;
  */api/model)
    cat "$MOCK_DIR/models.json"; exit 0 ;;
  */api/session)
    if [ "$method" = POST ]; then cat "$MOCK_DIR/created.json"; else cat "$MOCK_DIR/sessions.json"; fi; exit 0 ;;
  */message*)
    cat "$MOCK_DIR/messages.json"; exit 0 ;;
  */diff)
    cat "$MOCK_DIR/diff.txt"; exit 0 ;;
  */api/session/*)
    cat "$MOCK_DIR/session.json"; exit 0 ;;
  *) echo "curl: unexpected mock url: $url" >&2; exit 22 ;;
esac
MOCK
chmod +x "$mockbin/curl"

export MOCK_DIR="$mockdir" MOCK_LOG="$tmp/curl.log" MOCKBIN="$mockbin"
: > "$MOCK_LOG"

last_rc=0
run_api() { # run_api ARGS...
  : > "$MOCK_LOG"
  set +e
  PATH="$MOCKBIN:$PATH" \
  OPENCODE_BASE='http://mock.invalid:4096' \
  OPENCODE_SECRET_FILE="$secret" \
    bash "$testscript" "$@" >"$tmp/out" 2>"$tmp/err"
  last_rc=$?
  set -e
}
post_calls() { grep -c '^CALL POST ' "$MOCK_LOG" 2>/dev/null || true; }
curl_calls() { grep -c '^CALL ' "$MOCK_LOG" 2>/dev/null || true; }

expect_rc() { [ "$last_rc" -eq "$1" ] || fail "$2: expected rc $1 got $last_rc (stderr: $(cat "$tmp/err"))"; }
expect_post0() { [ "$(post_calls)" -eq 0 ] || fail "$1: expected zero POSTs, got: $(grep '^CALL POST' "$MOCK_LOG")"; }
expect_post1() { [ "$(post_calls)" -eq 1 ] || fail "$1: expected one POST, got $(post_calls)"; }
expect_nocalls() { [ "$(curl_calls)" -eq 0 ] || fail "$1: expected no API calls, got: $(cat "$MOCK_LOG")"; }
assert_no_secret() {
  if grep -Fq "CANARY-do-not-log-2c9f0a" "$tmp/out" "$tmp/err" "$MOCK_LOG" 2>/dev/null; then
    fail "$1: credential canary leaked"
  fi
}
assert_refetch_before_post() { # assert_refetch_before_post RID DESC
  local g p
  g=$(grep -n "CALL GET .*/permission/$1\$" "$MOCK_LOG" | head -1 | cut -d: -f1)
  p=$(grep -n '^CALL POST ' "$MOCK_LOG" | head -1 | cut -d: -f1)
  [ -n "$g" ] && [ -n "$p" ] && [ "$g" -lt "$p" ] \
    || fail "$2: exact request not re-fetched before POST (get line=$g post line=$p)"
}

set_session() { jq -n --arg id "$1" --arg t "$2" '{data:{id:$id,title:$t}}' > "$MOCK_DIR/session.json"; }
set_get() { printf '%s\n' "$1" > "$MOCK_DIR/get.json"; }
set_list() { printf '%s\n' "$1" > "$MOCK_DIR/list.json"; }
set_status() { export MOCK_GET_STATUS=${1:-200} MOCK_LIST_STATUS=${2:-200} MOCK_POST_STATUS=${3:-204}; }

# Default fixture: one pending request per_1 owned by ses_1 (title bernie/demo).
setup_ok() {
  set_status 200 200 204
  set_session ses_1 bernie/demo
  set_get '{"data":{"id":"per_1","sessionID":"ses_1","action":"shell","resources":["ssh*","sudo*"],"save":["ssh*"]}}'
  set_list '{"data":[{"id":"per_1","sessionID":"ses_1","action":"shell","resources":["ssh*","sudo*"],"save":["ssh*"]}]}'
}

# --- list pending requests -------------------------------------------------
setup_ok
run_api permissions ses_1
expect_rc 0 'permissions'
grep -Fxq $'"per_1"\t"shell"\t["ssh*","sudo*"]\t["ssh*"]' "$tmp/out" \
  || fail "permissions output missing expected row: $(cat "$tmp/out")"
expect_post0 'permissions'
assert_no_secret 'permissions'

# --- permissions: ANSI/ESC in .action is JSON-escaped, never raw -----------
# @tsv does not escape ESC (0x1b), and neither .id nor .action is safe to place
# in a TSV field raw. Both are tojson'd so the row stays single-line JSON and
# stdout never carries a raw ESC byte.
raw_action=$(printf 'evil\033[31mred\033[0m')
esc_list=$(jq -cn --arg a "$raw_action" '{data:[{id:"per_1",sessionID:"ses_1",action:$a,resources:[],save:[]}]}')
set_list "$esc_list"
run_api permissions ses_1
expect_rc 0 'permissions ESC action'
expect_post0 'permissions ESC action'
esc_row=$(printf '%s' "$raw_action" | jq -Rr '[("per_1"|tojson),tojson,"[]","[]"]|join("\t")')
grep -Fxq "$esc_row" "$tmp/out" \
  || fail "ESC action not emitted as JSON-escaped TSV row: $(cat -v "$tmp/out")"
# Round-trip: the action column must decode back to the exact original bytes.
got_action=$(awk -F'\t' 'NR==1{print $2}' "$tmp/out" | jq -r '.')
[ "$got_action" = "$raw_action" ] || fail 'ESC action does not round-trip through fromjson'
grep -Fq 'u001b' "$tmp/out" || fail 'action ESC not JSON-escaped in output'
grep -q $'\x1b' "$tmp/out" && fail 'raw ESC byte emitted to stdout'

# --- permissions: malformed list responses fail closed ---------------------
# A missing .data used to be rendered as an empty success; it must now fail closed.
setup_ok; set_list '{"nope":[]}'
run_api permissions ses_1
expect_rc 2 'permissions missing .data'
expect_post0 'permissions missing .data'
grep -Fq 'malformed permission list response' "$tmp/err" || fail 'missing malformed-list refusal (missing .data)'

# A wrong .data type must not be treated as an empty success.
setup_ok; set_list '{"data":{"id":"per_1"}}'
run_api permissions ses_1
expect_rc 2 'permissions wrong .data type'
expect_post0 'permissions wrong .data type'
grep -Fq 'malformed permission list response' "$tmp/err" || fail 'missing malformed-list refusal (wrong .data type)'

# Non-object entries are malformed.
setup_ok; set_list '{"data":["per_1"]}'
run_api permissions ses_1
expect_rc 2 'permissions non-object entry'
expect_post0 'permissions non-object entry'

# Malformed JSON fails closed too.
setup_ok; set_list '{not json'
run_api permissions ses_1
expect_rc 2 'permissions malformed JSON'
expect_post0 'permissions malformed JSON'

# --- inspect one exact request --------------------------------------------
setup_ok
run_api permission ses_1 per_1
expect_rc 0 'permission'
grep -Fq 'id: per_1' "$tmp/out" || fail "inspect missing id: $(cat "$tmp/out")"
grep -Fq 'action: "shell"' "$tmp/out" || fail 'inspect missing action'
grep -Fq 'resources: ["ssh*","sudo*"]' "$tmp/out" || fail 'inspect missing resources (exact JSON)'
grep -Fq 'saved patterns (proposed): ["ssh*"]' "$tmp/out" || fail 'inspect missing saved patterns (exact JSON)'
expect_post0 'permission'
assert_no_secret 'permission'

# --- inspect renders exact JSON arrays, disambiguating commas --------------
setup_ok
set_get '{"data":{"id":"per_1","sessionID":"ses_1","action":"shell","resources":["a, b","c"],"save":["x,y"]}}'
run_api permission ses_1 per_1
expect_rc 0 'inspect comma resources'
grep -Fq 'resources: ["a, b","c"]' "$tmp/out" || fail "comma resources not exact JSON: $(cat "$tmp/out")"
grep -Fq 'saved patterns (proposed): ["x,y"]' "$tmp/out" || fail "comma save not exact JSON: $(cat "$tmp/out")"
expect_post0 'inspect comma resources'

# --- inspect renders .action as JSON so control characters cannot spoof ------
# A newline or other control character in .action must be escaped by tojson and
# stay on the single "action:" line, never interpreted by the terminal.
setup_ok
ctrl_action=$(printf 'evil\nline\aend')
expected_action=$(jq -rn --arg a "$ctrl_action" '"action: " + ($a|tojson)')
set_get "$(jq -cn --arg a "$ctrl_action" '{data:{id:"per_1",sessionID:"ses_1",action:$a,resources:[],save:[]}}')"
run_api permission ses_1 per_1
expect_rc 0 'inspect action control chars'
expect_post0 'inspect action control chars'
grep -Fxq "$expected_action" "$tmp/out" \
  || fail "action control chars not rendered as one escaped JSON line: $(cat -v "$tmp/out")"
[ "$(grep -c '' "$tmp/out")" -eq 4 ] \
  || fail "action control chars changed the output line count: $(cat -v "$tmp/out")"

# --- once payload ----------------------------------------------------------
setup_ok
run_api reply ses_1 per_1 once
expect_rc 0 'once'
expect_post1 'once'
grep -Fq 'CALL POST http://mock.invalid:4096/api/session/ses_1/permission/per_1/reply' "$MOCK_LOG" \
  || fail "once POST url wrong: $(cat "$MOCK_LOG")"
grep -Fq 'HDR Content-Type: application/json' "$MOCK_LOG" || fail 'once Content-Type missing'
grep -Fq 'BODY {"decision":"once"}' "$MOCK_LOG" || fail "once payload wrong: $(cat "$MOCK_LOG")"
grep -Fq '"reply"' "$MOCK_LOG" && fail 'internal reply field was sent instead of decision'
assert_refetch_before_post per_1 'once'
assert_no_secret 'once'

# --- reject always requires --reject-all-pending, even for a single ask ----
setup_ok
run_api reply ses_1 per_1 reject
expect_rc 2 'reject single without flag'
expect_post0 'reject single without flag'
grep -Fq 'reject rejects every pending request' "$tmp/err" || fail 'reject-all requirement missing (single)'
grep -Fq -- '--reject-all-pending' "$tmp/err" || fail 'reject-all flag hint missing (single)'
grep -Fq '1 currently pending' "$tmp/err" || fail 'reject pending count missing (single)'

setup_ok
run_api reply ses_1 per_1 reject --reject-all-pending
expect_rc 0 'reject single with flag'
expect_post1 'reject single with flag'
grep -Fq 'BODY {"decision":"reject"}' "$MOCK_LOG" || fail "reject payload wrong: $(cat "$MOCK_LOG")"
grep -Fq 'reject: 1 pending request(s)' "$tmp/err" || fail 'reject count not reported (single)'
assert_refetch_before_post per_1 'reject single with flag'

# --- reject-all guard when more than one is pending ------------------------
MULTI='{"data":[{"id":"per_1","sessionID":"ses_1","action":"shell","resources":["ssh*"],"save":["ssh*"]},{"id":"per_2","sessionID":"ses_1","action":"edit","resources":["/etc/x"],"save":[]}]}'
setup_ok; set_list "$MULTI"
run_api reply ses_1 per_1 reject
expect_rc 2 'reject multi without flag'
expect_post0 'reject multi without flag'
grep -Fq '2 currently pending' "$tmp/err" || fail 'reject-all count missing (multi)'
grep -Fq -- '--reject-all-pending' "$tmp/err" || fail 'reject-all requirement missing (multi)'

setup_ok; set_list "$MULTI"
run_api reply ses_1 per_1 reject --reject-all-pending
expect_rc 0 'reject multi with flag'
expect_post1 'reject multi with flag'
grep -Fq 'BODY {"decision":"reject"}' "$MOCK_LOG" || fail 'reject-all payload wrong'
grep -Fq 'reject: 2 pending request(s)' "$tmp/err" || fail 'reject-all count not reported'

# --- C1 controls (U+0080-U+009F, incl. CSI U+009B) are JSON-escaped too ----
# jq's tojson leaves these raw; the wrapper must escape them so no 8-bit CSI reaches the terminal.
setup_ok
c1_action=$(printf 'x\xc2\x9b[31my\xc2\x80z\xc2\x9fw')
set_list "$(jq -cn --arg a "$c1_action" '{data:[{id:"per_1",sessionID:"ses_1",action:$a,resources:[],save:[]}]}')"
run_api permissions ses_1
expect_rc 0 'permissions C1 action'
expect_post0 'permissions C1 action'
grep -Fq '\u009b' "$tmp/out" || fail 'U+009B not JSON-escaped in list output'
grep -Fq '\u0080' "$tmp/out" || fail 'U+0080 not JSON-escaped in list output'
grep -Fq '\u009f' "$tmp/out" || fail 'U+009F not JSON-escaped in list output'
if grep -Fq "$(printf '\xc2\x9b')" "$tmp/out" || grep -Fq "$(printf '\xc2\x80')" "$tmp/out" || grep -Fq "$(printf '\xc2\x9f')" "$tmp/out"; then
  fail 'raw C1 bytes emitted to stdout (list)'
fi
got_c1=$(awk -F'\t' 'NR==1{print $2}' "$tmp/out" | jq -r '.')
[ "$got_c1" = "$c1_action" ] || fail 'C1 action does not round-trip through list output'

setup_ok
set_get "$(jq -cn --arg a "$c1_action" '{data:{id:"per_1",sessionID:"ses_1",action:$a,resources:[],save:[]}}')"
run_api permission ses_1 per_1
expect_rc 0 'inspect C1 action'
grep -Fq 'action: "x\u009b[31my\u0080z\u009fw"' "$tmp/out" || fail 'inspect did not JSON-escape C1 action'
if grep -Fq "$(printf '\xc2\x9b')" "$tmp/out"; then fail 'raw U+009B emitted to stdout (inspect)'; fi

# --- every C1 code point U+0080-U+009F maps to the right \u00XX escape --------
for cp in $(seq 128 159); do
  ch=$(printf "$(printf '\\xc2\\x%02x' "$cp")")
  esc=$(printf '\\u00%02x' "$cp")
  setup_ok
  set_list "$(jq -cn --arg a "a${ch}b" '{data:[{id:"per_1",sessionID:"ses_1",action:$a,resources:[],save:[]}]}')"
  run_api permissions ses_1
  expect_rc 0 "permissions C1 U+$(printf '%04X' "$cp")"
  expect_post0 "permissions C1 U+$(printf '%04X' "$cp")"
  grep -Fq "a${esc}b" "$tmp/out" || fail "U+$(printf '%04X' "$cp") not escaped as $esc"
  grep -Fq "$ch" "$tmp/out" && fail "raw U+$(printf '%04X' "$cp") emitted to stdout"
done

# --- info output: C1 in server-controlled title is JSON-escaped (jq -a) -----
setup_ok
set_session ses_1 "bernie/x$(printf '\xc2\x9b')[31m"
run_api info ses_1
expect_rc 0 'info C1 title'
grep -Fq '\u009b' "$tmp/out" || fail 'info did not escape U+009B in title'
if grep -Fq "$(printf '\xc2\x9b')" "$tmp/out"; then fail 'raw U+009B emitted by info'; fi

# --- every output path escapes C1 controls, not only the permission paths ---
C1B=$(printf '\xc2\x9b')
setup_ok
printf '%s\n' "bernie/d${C1B}" > "$MOCK_DIR/diff.txt"
run_api diff ses_1
expect_rc 0 'diff C1'
grep -Fq '\u009b' "$tmp/out" || fail 'diff did not escape U+009B'
if grep -Fq "$C1B" "$tmp/out"; then fail 'raw U+009B emitted by diff'; fi

setup_ok
set_session ses_1 "bernie/i${C1B}"
run_api interrupt ses_1
expect_rc 0 'interrupt C1'
grep -Fq '\u009b' "$tmp/out" || fail 'interrupt did not escape U+009B'
if grep -Fq "$C1B" "$tmp/out"; then fail 'raw U+009B emitted by interrupt'; fi

setup_ok
printf '%s\n' "$(jq -cn --arg t "bernie/s${C1B}" '{data:[{id:"ses_1",agent:"build",model:{id:"m",providerID:"p"},time:{updated:1},title:$t,location:{directory:"/d"}}]}')" > "$MOCK_DIR/sessions.json"
run_api sessions
expect_rc 0 'sessions C1'
grep -Fq '\u009b' "$tmp/out" || fail 'sessions did not escape U+009B'
if grep -Fq "$C1B" "$tmp/out"; then fail 'raw U+009B emitted by sessions'; fi

setup_ok
printf '%s\n' "$(jq -cn --arg m "p${C1B}" '{data:[{providerID:$m,modelID:"x",variants:[]}]}')" > "$MOCK_DIR/models.json"
run_api models
expect_rc 0 'models C1'
grep -Fq '\u009b' "$tmp/out" || fail 'models did not escape U+009B'
if grep -Fq "$C1B" "$tmp/out"; then fail 'raw U+009B emitted by models'; fi

setup_ok
printf '%s\n' "$(jq -cn --arg t "a${C1B}b" '{data:[{type:"assistant",content:[{type:"text",text:$t}]}]}')" > "$MOCK_DIR/messages.json"
run_api last ses_1
expect_rc 0 'last C1'
grep -Fq '\u009b' "$tmp/out" || fail 'last did not escape U+009B'
if grep -Fq "$C1B" "$tmp/out"; then fail 'raw U+009B emitted by last'; fi

# --- create echoes server title/id; C1 must be escaped on both streams ----
C1B=$(printf '\xc2\x9b')
setup_ok
printf '%s\n' '{"data":[]}' > "$MOCK_DIR/sessions.json"
printf '%s\n' "$(jq -cn --arg t "bernie/c${C1B}" '{data:{id:"ses_new",title:$t}}')" > "$MOCK_DIR/created.json"
run_api create --dir /d --title c --model prov/mid --reason test
expect_rc 0 'create C1'
grep -Fq '\u009b' "$tmp/err" || fail 'create did not escape U+009B on stderr'
if grep -Fq "$C1B" "$tmp/err" "$tmp/out"; then fail 'raw U+009B emitted by create'; fi

# --- ownership refusal message escapes the server title -----------------
setup_ok
set_session ses_1 "other${C1B}"
run_api permissions ses_1
expect_rc 4 'owned_session refusal C1'
grep -Fq '\u009b' "$tmp/err" || fail 'refusal message did not escape U+009B'
if grep -Fq "$C1B" "$tmp/err"; then fail 'raw U+009B in refusal message'; fi

# --- round 7: LF in a server title cannot forge a second output line ------
setup_ok
set_session ses_1 "other$(printf '\nopencode-api: forged')"
run_api permissions ses_1
expect_rc 4 'LF-title refusal'
lines=$(wc -l < "$tmp/err")
[ "$lines" -eq 1 ] || fail "LF in title produced $lines stderr lines (expected 1)"
grep -Fq '\u000a' "$tmp/err" || fail 'LF in title was not escaped in refusal message'

# --- round 8: NUL/DEL reach the escaper for real (JSON-decoded and raw bytes)
setup_ok
printf '%s\n' '{"data":[{"type":"assistant","content":[{"type":"text","text":"a\u0000z"}]}]}' > "$MOCK_DIR/messages.json"
run_api last ses_1
expect_rc 0 'last NUL'
grep -Fq '\u0000' "$tmp/out" || fail 'last did not escape JSON-decoded NUL'
[ "$(tr -cd '\000' < "$tmp/out" | wc -c)" -eq 0 ] || fail 'raw NUL emitted by last'

setup_ok
printf 'x\000y\177z\n' > "$MOCK_DIR/diff.txt"
run_api diff ses_1
expect_rc 0 'diff raw NUL/DEL'
grep -Fq '\u0000' "$tmp/out" || fail 'diff did not escape raw NUL'
grep -Fq '\u007f' "$tmp/out" || fail 'diff did not escape DEL'
[ "$(tr -cd '\000' < "$tmp/out" | wc -c)" -eq 0 ] || fail 'raw NUL emitted by diff'

# --- round 8: C0 sweep through esctext (last). TAB/LF are kept by design. ----
for cp in $(seq 1 31); do
  [ "$cp" -eq 9 ] && continue
  [ "$cp" -eq 10 ] && continue
  hex=$(printf '%02x' "$cp"); oct=$(printf '\\%03o' "$cp")
  setup_ok
  printf '%s\n' "{\"data\":[{\"type\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"a\\u00${hex}b\"}]}]}" > "$MOCK_DIR/messages.json"
  run_api last ses_1
  expect_rc 0 "last C0 $hex"
  grep -Fq "\\u00${hex}" "$tmp/out" || fail "last did not escape U+00$hex"
  [ "$(LC_ALL=C tr -cd "$oct" < "$tmp/out" | wc -c)" -eq 0 ] || fail "raw C0 U+00$hex emitted by last"
done

# --- round 8: DEL and C0 on the permissions path (tojson + sj range) --------
for cp in $(seq 1 31) 127; do
  [ "$cp" -eq 9 ] && continue
  [ "$cp" -eq 10 ] && continue
  hex=$(printf '%02x' "$cp"); oct=$(printf '\\%03o' "$cp")
  setup_ok
  set_list "$(jq -cn --arg a "a$(printf "$oct")b" '{data:[{id:"per_1",sessionID:"ses_1",action:$a,resources:[],save:[]}]}')"
  run_api permissions ses_1
  expect_rc 0 "permissions C0/DEL $hex"
  case $cp in
    8)  short='\b' ;;
    12) short='\f' ;;
    13) short='\r' ;;
    *)  short='' ;;
  esac
  if [ -n "$short" ]; then
    grep -Fq "$short" "$tmp/out" || grep -Fq "\\u00${hex}" "$tmp/out" || fail "permissions did not escape U+00$hex"
  else
    grep -Fq "\\u00${hex}" "$tmp/out" || fail "permissions did not escape U+00$hex"
  fi
  [ "$(LC_ALL=C tr -cd "$oct" < "$tmp/out" | wc -c)" -eq 0 ] || fail "raw U+00$hex emitted by permissions"
done

# --- round 8: permissions list refuses entries without id or with a foreign session
setup_ok; set_list '{"data":[{"sessionID":"ses_1","action":"x","resources":[],"save":[]}]}'
run_api permissions ses_1
expect_rc 2 'permissions missing id'
[ ! -s "$tmp/out" ] || fail 'rows printed for entry without id'
expect_post0 'permissions missing id'

setup_ok; set_list '{"data":[{"id":"per_1","sessionID":"ses_OTHER","action":"x","resources":[],"save":[]}]}'
run_api permissions ses_1
expect_rc 2 'permissions foreign sessionID'
[ ! -s "$tmp/out" ] || fail 'rows printed for foreign-session entry'
expect_post0 'permissions foreign sessionID'

# --- round 7: create fails closed when the server returns no session id ----
setup_ok
printf '%s\n' '{"data":[]}' > "$MOCK_DIR/sessions.json"
printf '%s\n' '{"data":{}}' > "$MOCK_DIR/created.json"
run_api create --dir /d --title c --model prov/mid --reason test
expect_rc 2 'create missing id must fail closed'
if grep -Fq 'null' "$tmp/out"; then fail 'create printed null as a session id'; fi

# --- round 8: create refuses empty or non-string ids -----------------------
for bad in '{"data":{"id":""}}' '{"data":{"id":123}}'; do
  setup_ok
  printf '%s\n' '{"data":[]}' > "$MOCK_DIR/sessions.json"
  printf '%s\n' "$bad" > "$MOCK_DIR/created.json"
  run_api create --dir /d --title c --model prov/mid --reason test
  expect_rc 2 "create bad id $bad"
  [ ! -s "$tmp/out" ] || fail "create printed output for bad id $bad"
done

# --- always / --persist are no longer exposed ------------------------------
# Only `once` and `reject` are accepted; `always` and `--persist` are invalid and
# must fail closed without sending a POST.
setup_ok
run_api reply ses_1 per_1 always
expect_rc 2 'always choice rejected'
expect_post0 'always choice rejected'
grep -Fq 'choice must be once or reject' "$tmp/err" || fail 'always rejection message missing'

setup_ok
run_api reply ses_1 per_1 always --persist
expect_rc 2 'always with persist rejected'
expect_post0 'always with persist rejected'

setup_ok
run_api reply ses_1 per_1 once --persist
expect_rc 2 'persist flag rejected'
expect_post0 'persist flag rejected'
grep -Fq 'unknown flag --persist' "$tmp/err" || fail 'persist flag rejection message missing'

# The help text must no longer advertise the removed choice or option.
run_api --help
expect_rc 0 'help'
expect_nocalls 'help'
grep -Fq 'always' "$tmp/out" && fail 'help still advertises always'
grep -Fq -- '--persist' "$tmp/out" && fail 'help still advertises --persist'

# --- stale / not-found request refuses without POST ------------------------
setup_ok; export MOCK_GET_STATUS=404
run_api reply ses_1 per_stale once
expect_rc 2 'stale request'
expect_post0 'stale request'
grep -Fq 'not found' "$tmp/err" || fail 'stale refusal message missing'
export MOCK_GET_STATUS=200

# --- wrong session / request ID refuses without POST -----------------------
setup_ok
set_get '{"data":{"id":"per_1","sessionID":"ses_OTHER","action":"shell","resources":["ssh*"],"save":["ssh*"]}}'
run_api reply ses_1 per_1 once
expect_rc 2 'wrong session reply'
expect_post0 'wrong session reply'
grep -Fq 'does not belong to session ses_1' "$tmp/err" || fail 'wrong session refusal missing'

run_api permission ses_1 per_1
expect_rc 2 'wrong session inspect'
expect_post0 'wrong session inspect'
grep -Fq 'does not belong to session ses_1' "$tmp/err" || fail 'wrong session inspect refusal missing'

# --- request endpoint returns a different .data.id than REQUESTID ----------
# The exact request re-fetch must fail closed (no POST) for both inspect and reply.
setup_ok
set_get '{"data":{"id":"per_OTHER","sessionID":"ses_1","action":"shell","resources":["ssh*"],"save":["ssh*"]}}'
run_api permission ses_1 per_1
expect_rc 2 'inspect id mismatch'
expect_post0 'inspect id mismatch'
grep -Fq 'does not belong to session ses_1' "$tmp/err" || fail 'inspect id mismatch refusal missing'

setup_ok
set_get '{"data":{"id":"per_OTHER","sessionID":"ses_1","action":"shell","resources":["ssh*"],"save":["ssh*"]}}'
run_api reply ses_1 per_1 once
expect_rc 2 'reply id mismatch'
expect_post0 'reply id mismatch'
grep -Fq 'does not belong to session ses_1' "$tmp/err" || fail 'reply id mismatch refusal missing'

# --- sessionID is required by the Permission.Request schema -----------------
# Upstream V2 requires sessionID, so a request missing it must fail closed (no POST)
# for both inspect and reply, even though the nested endpoint scope matches.
setup_ok
set_get '{"data":{"id":"per_1","action":"shell","resources":["ssh*"],"save":["ssh*"]}}'
run_api reply ses_1 per_1 once
expect_rc 2 'reply missing sessionID'
expect_post0 'reply missing sessionID'
grep -Fq 'does not belong to session ses_1' "$tmp/err" || fail 'reply missing sessionID refusal missing'

setup_ok
set_get '{"data":{"id":"per_1","action":"shell","resources":["ssh*"],"save":["ssh*"]}}'
run_api permission ses_1 per_1
expect_rc 2 'inspect missing sessionID'
expect_post0 'inspect missing sessionID'
grep -Fq 'does not belong to session ses_1' "$tmp/err" || fail 'inspect missing sessionID refusal missing'

# --- bernie/* ownership guard ---------------------------------------------
setup_ok; set_session ses_1 other/thing
run_api reply ses_1 per_1 once
expect_rc 4 'reply ownership guard'
expect_post0 'reply ownership guard'
grep -Fq 'refusing session ses_1' "$tmp/err" || fail 'reply ownership refusal missing'

run_api permissions ses_1
expect_rc 4 'list ownership guard'
expect_post0 'list ownership guard'

run_api permission ses_1 per_1
expect_rc 4 'inspect ownership guard'
expect_post0 'inspect ownership guard'

setup_ok; set_session ses_1 other/thing
run_api reply ses_1 per_1 once --force
expect_rc 0 'reply --force bypass'
expect_post1 'reply --force bypass'

# --- URL / path safety -----------------------------------------------------
setup_ok
run_api reply 'ses/../evil' per_1 once
expect_rc 2 'unsafe session id'
expect_nocalls 'unsafe session id'

run_api reply ses_1 'per/../1' once
expect_rc 2 'unsafe request id'
expect_nocalls 'unsafe request id'

run_api permissions 'ses 1'
expect_rc 2 'session id with space'
expect_nocalls 'session id with space'

# Bare dot path segments must be rejected before any API call.
run_api permissions .
expect_rc 2 'session id dot'
expect_nocalls 'session id dot'

run_api permissions ..
expect_rc 2 'session id dotdot'
expect_nocalls 'session id dotdot'

run_api permission ses_1 .
expect_rc 2 'request id dot'
expect_nocalls 'request id dot'

run_api reply ses_1 .. once
expect_rc 2 'reply request id dotdot'
expect_nocalls 'reply request id dotdot'

# A valid id using the full allowed alphabet is used verbatim in the path.
setup_ok
set_session 'ses-1_2.3' bernie/demo
set_get '{"data":{"id":"per-1_2.3","sessionID":"ses-1_2.3","action":"shell","resources":[],"save":[]}}'
run_api reply 'ses-1_2.3' 'per-1_2.3' once
expect_rc 0 'valid id passthrough'
expect_post1 'valid id passthrough'
grep -Fq 'CALL POST http://mock.invalid:4096/api/session/ses-1_2.3/permission/per-1_2.3/reply' "$MOCK_LOG" \
  || fail "safe id URL wrong: $(cat "$MOCK_LOG")"

# --- malformed args and unknown choices fail before any API call -----------
setup_ok
run_api reply ses_1 per_1 maybe
expect_rc 2 'unknown choice'
expect_nocalls 'unknown choice'

run_api reply ses_1 per_1
expect_rc 2 'missing choice'
expect_nocalls 'missing choice'

run_api reply ses_1 per_1 once --bogus
expect_rc 2 'unknown flag'
expect_nocalls 'unknown flag'

run_api reply ses_1 per_1 reject --persist
expect_rc 2 'persist flag with reject'
expect_nocalls 'persist flag with reject'

run_api reply ses_1 per_1 once --reject-all-pending
expect_rc 2 'reject-all with once'
expect_nocalls 'reject-all with once'

run_api info ses_1 --force
expect_rc 2 'force rejected for info'
expect_nocalls 'force rejected for info'

# --- credential handling ---------------------------------------------------
setup_ok
run_api reply ses_1 per_1 once
expect_rc 0 'secret run'
assert_no_secret 'secret run'

: > "$MOCK_LOG"
set +e
PATH="$MOCKBIN:$PATH" OPENCODE_BASE='http://mock.invalid:4096' OPENCODE_SECRET_FILE="$secret" \
  bash -x "$testscript" reply ses_1 per_1 once >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "xtrace reply failed rc=$rc"
if grep -Fq 'CANARY-do-not-log-2c9f0a' "$tmp/out" "$tmp/err" "$MOCK_LOG" 2>/dev/null; then
  fail 'credential canary leaked under bash -x'
fi

printf 'All opencode-api permission tests passed.\n'
