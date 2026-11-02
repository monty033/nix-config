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
api() { # api METHOD PATH [JSON] [MAX_SECONDS]
  local m=$1 p=$2 d=${3:-} t=${4:-30}
  if [ -n "$d" ]; then
    auth_cfg | curl -fsS -m "$t" -K - -H 'Content-Type: application/json' -X "$m" "$BASE$p" -d "$d"
  else
    auth_cfg | curl -fsS -m "$t" -K - -X "$m" "$BASE$p"
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
  watch SID [SECS]                        block on server events until the session needs attention
        Prints one WAKE line and exits 0: "WAKE idle" (no turn was running for eight seconds,
        or the session was found finished when the budget ran out), "WAKE permission.asked",
        "WAKE form.created", "WAKE session.execution.succeeded|failed|interrupted",
        "WAKE session.step.failed", "WAKE session.deleted".
        Exit 3 if nothing woke it within SECS (default 1800, counted from the start of the
        command), 2 if the event stream never opened or closed under it. A request carrying
        no session id still wakes you, so re-check the permission list before acting on a
        wake you cannot attribute. Ask it instead of polling on a timer.
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
  watch)
    # Wait for the server to say something instead of asking it on a timer.
    # Quiet by default: exactly one line, then exit, so a background job can
    # wake on it. WAKE names are event names wherever an event has one.
    [ $# -ge 1 ] && [ $# -le 2 ] || die "watch SID [SECS]"
    sid=$1; max=${2:-1800}
    valid_id "$sid" || die "invalid session id"
    case "$max" in ''|*[!0-9]*) die "SECS must be a whole number of seconds" ;; esac
    [ "$max" -ge 1 ] || die "SECS must be at least 1"
    start=$SECONDS

    # The budget is the whole command, not just the stream: the probes and the
    # idle confirmations below spend from the same SECS a caller passes in.
    remaining() { local r=$(( max - (SECONDS - start) )); [ "$r" -ge 1 ] || r=1; printf '%s' "$r"; }
    # Server text reaches a terminal or a log, so it goes through the same
    # escaping the rest of this file uses; @tsv alone does not cover C1.
    esc() { printf '%s' "$1" | jq -Rr "$ESC_DEFS"'esctext'; }
    count_of() { # count_of PATH WHAT - refuse an unexpected shape rather than count a hash
      local n
      n=$(api GET "$1" "" "$(remaining)" | jq -r '.data | if type=="array" then length else "invalid" end') \
        || die "cannot read $2 for $sid"
      [ "$n" != invalid ] || die "unexpected $2 payload for $sid"
      printf '%s' "$n"
    }
    blocked() { # blocked - the two lists that mean a human is being waited on
      # Each probe is checked by its own exit status: a die inside a command
      # substitution ends only the subshell, never this one.
      local p f
      p=$(count_of "/api/session/$sid/permission" "pending permissions") || exit 2
      [ "$p" -eq 0 ] || { printf 'WAKE permission.asked\n'; exit 0; }
      f=$(count_of "/api/session/$sid/form" "pending forms") || exit 2
      [ "$f" -eq 0 ] || { printf 'WAKE form.created\n'; exit 0; }
    }

    # A prompt returns as soon as the turn is accepted, so the event that ends a
    # short turn can fire before this attaches. Answer from current state first.
    blocked
    # Idle is believed only after eight seconds in which no turn was seen running,
    # matching what wait does: a turn not yet accepted is not finished.
    attach=0
    while :; do
      st=$(api GET /api/session/active "" "$(remaining)" \
        | jq -r --arg s "$sid" '.data[$s].type // "idle"') \
        || die "cannot read session state from $BASE"
      # A running turn means the interesting part has not happened yet: watch
      # the stream rather than the state, or the why of the ending is lost.
      [ "$st" = running ] && { attach=1; break; }
      if [ "$st" = idle ] && [ $((SECONDS - start)) -ge 8 ]; then
        # Re-read the human-blocking lists at the moment of the decision: a
        # request raised during the confirmation must not read as nothing to do.
        blocked
        printf 'WAKE idle\n'; exit 0
      fi
      [ $((SECONDS - start)) -ge "$max" ] && break
      [ "$st" = idle ] || { attach=1; break; }  # an unexpected state: let events explain it
      sleep 1
    done
    if [ "$attach" != 1 ]; then
      printf 'opencode-api: no wake event within %ss; the turn never started\n' "$max" >&2
      exit 3
    fi

    # curl's own -m timeout is this command's normal exit path, so it is silent;
    # a missing or refused credential is already caught by the probes above.
    exec 3< <(auth_cfg | curl -sSN -m "$(remaining)" -K - -H 'Accept: text/event-stream' "$BASE/api/event" 2>/dev/null)
    closed=0; last_type=none; buf=
    while :; do
      [ $((SECONDS - start)) -ge "$max" ] && break
      before=$SECONDS
      if IFS= read -r -t 30 line <&3; then
        case "$line" in
          '')  # a blank line ends an SSE frame; anything before it is the payload
            [ -n "$buf" ] || continue
            json=$buf; buf= ;;
          data:*) buf="${buf}${buf:+$'\n'}${line#data: }"; continue ;;
          *) continue ;;  # ": heartbeat" and other comment lines
        esac
        parsed=$(printf '%s' "$json" | jq -r '
          .type as $t
          | [$t, (.data.sessionID // ""),
             (if ($t|test("^(permission\\.asked|form\\.created|session\\.execution\\.(succeeded|failed|interrupted)|session\\.step\\.failed|session\\.deleted)$")) then "1" else "0" end),
             (((.data.action // .data.title // .data.reason // "") | tostring))
            ] | @tsv') || parsed=
        if [ -z "$parsed" ]; then
          # Never drop a payload silently: a session blocked on a request whose
          # shape changed would otherwise wait out the timeout with no trace.
          printf 'opencode-api: unparsed event payload, ignored\n' >&2
          continue
        fi
        IFS=$'\t' read -r type esid wake detail <<<"$parsed"
        [ "$type" = server.connected ] && continue
        last_type=$type
        # A request that carries no session id is reported rather than dropped:
        # waking on another session's question costs a look, dropping our own
        # leaves it blocked with nobody watching.
        if [ "$wake" = 1 ] && { [ "$esid" = "$sid" ] || [ -z "$esid" ]; }; then
          printf 'WAKE %s\t%s\n' "$(esc "$type")" "$(esc "$detail")"
          exit 0
        fi
        continue
      fi
      # read failed: either 30 quiet seconds or the stream ended. No time spent
      # means the stream is at EOF, so this is not a timeout.
      if [ $((SECONDS - before)) -lt 1 ]; then closed=1; break; fi
    done
    exec 3<&-
    elapsed=$((SECONDS - start))
    if [ "$closed" = 1 ]; then
      die "event stream closed after ${elapsed}s; last event: $(esc "$last_type")"
    fi
    # The budget is spent. The turn may still have finished while we watched: a
    # completion event lost between the state probe and the attach must not read
    # as "nothing happened", so ask the session once before giving up.
    blocked
    st=$(api GET /api/session/active "" "$(remaining)" \
      | jq -r --arg s "$sid" '.data[$s].type // "idle"') \
      || die "cannot read session state from $BASE"
    [ "$st" = idle ] && { blocked; printf 'WAKE idle\n'; exit 0; }
    printf 'opencode-api: no wake event within %ss; last event: %s\n' "$elapsed" "$(esc "$last_type")" >&2
    exit 3 ;;

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
