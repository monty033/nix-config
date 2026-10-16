# opencode-api body (wrapped by packages/opencode-api.nix via writeShellApplication)
# opencode-api: thin, guardrailed helper for the OpenCode v2 server on Hermes.
# Password is read from the sops-rendered file and never printed or sourced.

BASE="${OPENCODE_BASE:-http://100.81.254.49:4096}"
SECRET_FILE="${OPENCODE_SECRET_FILE:-/run/secrets/opencode-server-env}"

# Credentials go to curl through a config on stdin, so the
# password never appears in any process argv.
auth_cfg() {
  if ! grep -q '^OPENCODE_SERVER_PASSWORD=.' "$SECRET_FILE"; then
    echo "opencode-api: no OPENCODE_SERVER_PASSWORD in $SECRET_FILE" >&2; return 1
  fi
  sed -n 's/^OPENCODE_SERVER_PASSWORD=\(.*\)$/user = "opencode:\1"/p' "$SECRET_FILE"
}
api() { # api METHOD PATH [JSON]
  local m=$1 p=$2 d=${3:-}
  if [ -n "$d" ]; then
    auth_cfg | curl -fsS -m 30 -K - -H 'Content-Type: application/json' -X "$m" "$BASE$p" -d "$d"
  else
    auth_cfg | curl -fsS -m 30 -K - -X "$m" "$BASE$p"
  fi
}
die() { echo "opencode-api: $*" >&2; exit 2; }

# Path identifiers must be a strict safe subset before they are placed in a URL
# path, and are percent-encoded on top of that as defence in depth.
valid_id() { case "$1" in ''|.|..|*[!A-Za-z0-9._-]*) return 1;; *) return 0;; esac; }
enc() { jq -rn --arg s "$1" '$s|@uri'; }
# Output escaping for server-controlled text. escfull escapes every C0/DEL/C1 control;
# esctext keeps tab and newline. Fields are escaped BEFORE joining, never with @tsv
# afterwards (@tsv would re-escape the backslashes this adds).
# SC2016: the jq program is deliberately single-quoted so $-variables stay jq's.
# shellcheck disable=SC2016
ESC_DEFS='def hex4: . as $n | [($n/4096|floor),(($n/256|floor)%16),(($n/16|floor)%16),($n%16)] | map("0123456789abcdef"[.:.+1]) | join(""); def escfull: tostring | gsub("(?<c>[\u0000-\u001f\u007f-\u009f])"; (.c|explode[0]) as $n | "\\u" + ($n|hex4)); def esctext: tostring | gsub("(?<c>[\u0000-\u0008\u000b-\u001f\u007f-\u009f])"; (.c|explode[0]) as $n | "\\u" + ($n|hex4));'

# Deny-list attached to every free-model session (best effort, evolves over time).
# Action name for the shell tool is "shell" (NOT "bash"); patterns match the command.
DENY_SHELL=('ssh*' '*ssh *' 'scp*' 'sudo*' 'nixos-rebuild*' '*nixos-rebuild*' 'nookctl*' '*nookctl*'
            '*/run/secrets*' '*.ssh/*' '*nookbridge.sock*' '*operator.sock*')
deny_rules() {
  local out='[' first=1 r
  for r in "${DENY_SHELL[@]}"; do
    [ $first = 1 ] || out+=','; first=0
    out+="{\"action\":\"shell\",\"resource\":$(jq -Rn --arg r "$r" '$r'),\"effect\":\"deny\"}"
  done
  echo "$out]"
}
is_free() { case "$1" in *-free|big-pickle) return 0;; *) return 1;; esac; }

usage() { cat <<'EOF'
opencode-api <cmd> [args]
  models                                  list models (provider/id, variants)
  sessions [DIR]                          list sessions (optionally only those in DIR)
  create --dir D --title T --model PROV/ID [--variant V] [--agent build|plan] --reason "..." [--new-reason "..."]
        Refuses if a session with the same title or dir already exists unless --new-reason is given.
        Free models (-free) automatically get the deny-list attached.
  prompt SID "text" [--force]               send a prompt (async); --force permits non-bernie/ title
        To send the literal text --force, use: prompt SID --force --force
  wait SID [SECS]                         poll until the session is idle (default 600s)
  last SID [N]                            last N assistant text blocks (default 1)
  switch SID PROV/ID [VARIANT]            switch model/effort for subsequent turns
  deny SID                                (re)attach the free-model deny-list
  fork SID                                fork full history into a new session
  interrupt SID | diff SID | info SID
  permissions SID                         list pending permission requests for a session
        Columns: request ID (JSON string), action (JSON string), resources (JSON),
        proposed saved patterns (JSON).
  permission SID REQUESTID                inspect one exact pending permission request
  reply SID REQUESTID once|reject [--reject-all-pending]
        once:   approve only this request.
        reject: V2 rejects every pending request in the session, not just this one.
                --reject-all-pending is required for every rejection (the exact request is
                re-fetched and the current pending count is reported before the reply).
        The exact pending request is re-fetched and checked against SID/REQUESTID first;
        stale or not-found requests fail closed without sending.
  (prompt|switch|deny|fork|interrupt|reply|permissions|permission accept --force anywhere to act on non-bernie/ sessions)
EOF
}
owned_session() {
  local id=$1 force=${2:-false} title
  title=$(api GET "/api/session/$id" | jq -r '.data.title // ""') || return 1
  if [ -z "$title" ]; then echo "opencode-api: session $id not found" >&2; return 4; fi
  if [[ $title != bernie/* && $force != true ]]; then
    echo "opencode-api: refusing session $id (title is not bernie/*): $(jq -rn --arg t "$title" "$ESC_DEFS"'$t|escfull')" >&2
    return 4
  fi
  printf '%s' "$title"
}

cmd=${1:-}; shift || true
force=false
case "$cmd" in
  prompt|switch|deny|fork|interrupt|reply|permissions|permission)
    rest=(); force_used=0; literal_prompt_force=false
    if [ "$cmd" = prompt ] && [ "$#" -eq 2 ] && [ "${2:-}" = --force ]; then literal_prompt_force=true; fi
    for a in "$@"; do
      if [ "$a" = --force ] && [ "$force_used" = 0 ] && [ "$literal_prompt_force" != true ]; then
        force=true; force_used=1
      else
        rest+=("$a")
      fi
    done
    set -- "${rest[@]}" ;;
  *)
    for a in "$@"; do [ "$a" != --force ] || die "--force is not valid for $cmd"; done ;;
esac
case "$cmd" in
  models) api GET /api/model | jq -r "$ESC_DEFS"'.data[]|"\((.providerID|escfull))/\((.modelID|escfull))\t\([.variants[]?.id|escfull]|join(","))"' ;;
  sessions)
    api GET /api/session | jq -r --arg d "${1:-}" "$ESC_DEFS"'.data[]|select($d==""or(.location.directory//"")==$d)
      |[(.id|escfull),(.agent|escfull),((.model.providerID+"/"+.model.id+(if .model.variant then ":"+.model.variant else "" end))|escfull),(.time.updated|escfull),((.title//"")|escfull)]|join("\t")' ;;
  create)
    dir='' title='' model='' variant='' agent=build reason='' newreason=''
    while [ $# -gt 0 ]; do case $1 in
      --dir|--title|--model|--variant|--agent|--reason|--new-reason)
        [ $# -ge 2 ] || die "missing value for $1"
        case $1 in --dir) dir=$2;; --title) title=$2;; --model) model=$2;; --variant) variant=$2;; --agent) agent=$2;; --reason) reason=$2;; --new-reason) newreason=$2;; esac
        shift 2;; *) die "unknown flag $1";; esac; done
    [ -n "$dir" ] && [ -n "$title" ] && [ -n "$model" ] && [ -n "$reason" ] || die "need --dir --title --model --reason"
    echo "reason: $reason" >&2
    [[ $title == bernie/* ]] || title="bernie/$title"
    prov=${model%%/*}; mid=${model#*/}; [ -n "$prov" ] && [ -n "$mid" ] && [ "$prov" != "$model" ] || die "model must be PROVIDER/ID"
    existing=$(api GET /api/session | jq -r --arg d "$dir" --arg t "$title" '.data[]|select((.location.directory//"")==$d or .title==$t)|"\(.id)\t\(.title//"")"')
    if [ -n "$existing" ] && [ -z "$newreason" ]; then
      echo "opencode-api: matching session already exists; use 'sessions' to inspect or pass --new-reason to create another" >&2
      exit 3
    fi
    body=$(jq -n --arg t "$title" --arg a "$agent" --arg p "$prov" --arg m "$mid" --arg v "$variant" --arg d "$dir" \
      '{title:$t,agent:$a,model:({id:$m,providerID:$p}+(if $v!="" then {variant:$v} else {} end)),location:{directory:$d}}')
    if is_free "$mid"; then body=$(echo "$body" | jq --argjson r "$(deny_rules)" '.permissions=$r'); echo "free model: deny-list attached" >&2; fi
    created=$(api POST /api/session "$body" | jq -er "$ESC_DEFS"'if (.data|type)=="object" and ((.data.id|type)=="string") and ((.data.id|length)>0) then [(.data.id|escfull),((.data.title//"")|escfull)]|join("\t") else error("no session id") end') || die "session creation failed"
    cid=${created%%$'\t'*}; ctitle=${created#*$'\t'}
    [ -n "$cid" ] || die "session creation failed"
    printf '%s\n' "$ctitle" >&2
    printf '%s\n' "$cid" ;;
  prompt)
    [ $# -eq 2 ] || die "prompt SID text [--force]"
    owned_session "$1" "$force" >/dev/null || exit $?
    api POST "/api/session/$1/prompt" "$(jq -n --arg t "$2" '{text:$t}')" | jq -r "$ESC_DEFS"'(.data.id // .) | if type=="string" then escfull else (tojson|esctext) end' ;;
  wait)
    sid=${1:?sid}; max=${2:-600}; t=0; seen=0; st=idle
    while [ $t -lt "$max" ]; do
      st=$(api GET /api/session/active | jq -r --arg s "$sid" '.data[$s].type // "idle"') || st=unknown
      if [ "$st" = unknown ]; then sleep 2; t=$((t+2)); continue; fi
      if [ "$st" = running ]; then seen=1; elif [ $seen = 1 ] || [ $t -ge 8 ]; then break; fi
      sleep 2; t=$((t+2))
    done
    pend=$(api GET "/api/session/$sid/permission" | jq -r '.data|length') || pend=unknown
    printf 'state=%s pending_permissions=%s\n' "$(jq -rn --arg s "$st" "$ESC_DEFS"'$s|escfull')" "$(jq -rn --arg s "$pend" "$ESC_DEFS"'$s|escfull')" ;;
  last) api GET "/api/session/${1:?sid}/message?order=desc&limit=20" | jq -r --argjson n "${2:-1}" \
        "$ESC_DEFS"'[.data[]|select(.type=="assistant")|.content[]?|select(.type=="text")|.text]|.[:$n]|reverse|.[]|esctext' ;;
  switch)
    [ $# -ge 2 ] && [ $# -le 3 ] || die "switch SID PROVIDER/ID [VARIANT] [--force]"
    sid=$1; model=$2; v=${3:-}; prov=${model%%/*}; mid=${model#*/}
    [ -n "$prov" ] && [ -n "$mid" ] && [ "$prov" != "$model" ] || die "model must be PROVIDER/ID"
    owned_session "$sid" "$force" >/dev/null || exit $?
    api POST "/api/session/$sid/model" "$(jq -n --arg p "$prov" --arg m "$mid" --arg v "$v" '{model:({id:$m,providerID:$p}+(if $v!="" then {variant:$v} else {} end))}')" >/dev/null
    if is_free "$mid"; then api PATCH "/api/session/$sid" "$(jq -n --argjson r "$(deny_rules)" '{permissions:$r}')" >/dev/null; echo "deny-list attached" >&2; fi
    echo "switched $sid -> $model${v:+:$v}" ;;
  deny|fork|interrupt)
    [ $# -eq 1 ] || die "$cmd SID [--force]"
    owned_session "$1" "$force" >/dev/null || exit $?
    case $cmd in
      deny) api PATCH "/api/session/$1" "$(jq -n --argjson r "$(deny_rules)" '{permissions:$r}')" >/dev/null; echo "deny-list attached" ;;
      fork) api POST "/api/session/$1/fork" '{}' | jq -r "$ESC_DEFS"'(.data.id // .) | if type=="string" then escfull else (tojson|esctext) end' ;;
      interrupt) api POST "/api/session/$1/interrupt" | jq -r "$ESC_DEFS"'tojson|esctext' ;;
    esac ;;
  diff) api GET "/api/session/${1:?sid}/diff" | jq -Rrs "$ESC_DEFS"'esctext' ;;
  info) api GET "/api/session/${1:?sid}" | jq -ac '.data|{id,title,agent,model,cost,tokens,time}' ;;
  permissions)
    [ $# -eq 1 ] || die "permissions SID [--force]"
    valid_id "$1" || die "invalid session id"
    owned_session "$1" "$force" >/dev/null || exit $?
    list=$(api GET "/api/session/$(enc "$1")/permission") || die "could not list permission requests for $1"
    printf '%s' "$list" | jq -e --arg sid "$1" 'if type!="object" then false
      elif (.data|type)!="array" then false
      else all(.data[]; type=="object" and ((.id|type)=="string") and ((.id|length)>0) and (.sessionID==$sid)) end' >/dev/null \
      || die "malformed permission list response for session $1"
    printf '%s' "$list" | jq -r "$ESC_DEFS"'def sj: tojson | gsub("(?<c>[\u007f-\u009f])"; (.c|explode[0]) as $n | "\\u" + ($n|hex4)); .data[]
      |[((.id//"")|sj),((.action//"")|sj),((.resources//[])|sj),((.save//[])|sj)]|join("\t")' ;;
  permission)
    [ $# -eq 2 ] || die "permission SID REQUESTID [--force]"
    if ! valid_id "$1" || ! valid_id "$2"; then die "invalid session or request id"; fi
    owned_session "$1" "$force" >/dev/null || exit $?
    req=$(api GET "/api/session/$(enc "$1")/permission/$(enc "$2")") || die "permission request $2 not found in session $1"
    printf '%s' "$req" | jq -e --arg sid "$1" --arg rid "$2" \
      'if (.data|type)!="object" then false
       elif ((.data.id//"")!=$rid) then false
       elif ((.data.sessionID//"")!=$sid) then false
       else true end' >/dev/null \
      || die "permission request $2 does not belong to session $1"
    printf '%s' "$req" | jq -r "$ESC_DEFS"'def sj: tojson | gsub("(?<c>[\u007f-\u009f])"; (.c|explode[0]) as $n | "\\u" + ($n|hex4)); .data
      |"id: \(.id//"")",
       "action: \((.action//"")|sj)",
       "resources: \((.resources//[])|sj)",
       "saved patterns (proposed): \((.save//[])|sj)"' ;;
  reply)
    [ $# -ge 3 ] || die "reply SID REQUESTID once|reject [--reject-all-pending] [--force]"
    sid=$1 rid=$2 choice=$3; shift 3
    reject_all=false
    while [ $# -gt 0 ]; do case $1 in
      --reject-all-pending) reject_all=true; shift;;
      *) die "unknown flag $1";; esac; done
    case $choice in once|reject) ;; *) die "choice must be once or reject";; esac
    [ "$reject_all" != true ] || [ "$choice" = reject ] || die "--reject-all-pending is only valid with reject"
    if ! valid_id "$sid" || ! valid_id "$rid"; then die "invalid session or request id"; fi
    owned_session "$sid" "$force" >/dev/null || exit $?
    # Re-fetch the exact pending request and fail closed if it is stale/absent or
    # does not belong to the supplied session, before any mutating POST.
    req=$(api GET "/api/session/$(enc "$sid")/permission/$(enc "$rid")") \
      || die "pending permission request $rid not found in session $sid; refusing"
    printf '%s' "$req" | jq -e --arg sid "$sid" --arg rid "$rid" \
      'if (.data|type)!="object" then false
       elif ((.data.id//"")!=$rid) then false
       elif ((.data.sessionID//"")!=$sid) then false
       else true end' >/dev/null \
      || die "pending permission request $rid does not belong to session $sid; refusing"
    if [ "$choice" = reject ]; then
      all=$(api GET "/api/session/$(enc "$sid")/permission") || die "could not list pending permission requests for $sid"
      count=$(printf '%s' "$all" | jq -er 'if (.data|type)=="array" then (.data|length) else error("bad list") end') \
        || die "could not determine pending permission count for $sid"
      if [ "$reject_all" != true ]; then
        die "reject rejects every pending request in session $sid (V2 fails all pending asks), including the $count currently pending; re-run with --reject-all-pending"
      fi
      echo "reject: $count pending request(s) in session $sid will be rejected (V2 rejects every pending ask)" >&2
    fi
    api POST "/api/session/$(enc "$sid")/permission/$(enc "$rid")/reply" \
      "$(jq -cn --arg d "$choice" '{decision:$d}')" >/dev/null || die "reply POST failed"
    echo "replied $choice to $rid in session $sid" ;;
  ""|-h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
