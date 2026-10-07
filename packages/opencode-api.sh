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
  (prompt|switch|deny|fork|interrupt accept --force anywhere to act on non-bernie/ sessions)
EOF
}
owned_session() {
  local id=$1 force=${2:-false} title
  title=$(api GET "/api/session/$id" | jq -r '.data.title // ""') || return 1
  if [ -z "$title" ]; then echo "opencode-api: session $id not found" >&2; return 4; fi
  if [[ $title != bernie/* && $force != true ]]; then
    echo "opencode-api: refusing session $id (title is not bernie/*): $title" >&2
    return 4
  fi
  printf '%s' "$title"
}

cmd=${1:-}; shift || true
force=false
case "$cmd" in
  prompt|switch|deny|fork|interrupt)
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
  models) api GET /api/model | jq -r '.data[]|"\(.providerID)/\(.modelID)\t\([.variants[]?.id]|join(","))"' ;;
  sessions)
    api GET /api/session | jq -r --arg d "${1:-}" '.data[]|select($d==""or(.location.directory//"")==$d)
      |[.id,.agent,(.model.providerID+"/"+.model.id+(if .model.variant then ":"+.model.variant else "" end)),(.time.updated|tostring),(.title//"")]|@tsv' ;;
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
    created=$(api POST /api/session "$body" | jq -r '.data|[.id,.title]|@tsv') || die "session creation failed"
    cid=${created%%$'\t'*}; ctitle=${created#*$'\t'}
    [ -n "$cid" ] || die "session creation failed"
    echo "$ctitle" >&2; printf '%s\n' "$cid" ;;
  prompt)
    [ $# -eq 2 ] || die "prompt SID text [--force]"
    owned_session "$1" "$force" >/dev/null || exit $?
    api POST "/api/session/$1/prompt" "$(jq -n --arg t "$2" '{text:$t}')" | jq -r '.data.id // .' ;;
  wait)
    sid=${1:?sid}; max=${2:-600}; t=0; seen=0; st=idle
    while [ $t -lt "$max" ]; do
      st=$(api GET /api/session/active | jq -r --arg s "$sid" '.data[$s].type // "idle"') || st=unknown
      if [ "$st" = unknown ]; then sleep 2; t=$((t+2)); continue; fi
      if [ "$st" = running ]; then seen=1; elif [ $seen = 1 ] || [ $t -ge 8 ]; then break; fi
      sleep 2; t=$((t+2))
    done
    pend=$(api GET "/api/session/$sid/permission" | jq -r '.data|length') || pend=unknown
    echo "state=$st pending_permissions=$pend" ;;
  last) api GET "/api/session/${1:?sid}/message?order=desc&limit=20" | jq -r --argjson n "${2:-1}" \
        '[.data[]|select(.type=="assistant")|.content[]?|select(.type=="text")|.text]|.[:$n]|reverse|.[]' ;;
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
      fork) api POST "/api/session/$1/fork" '{}' | jq -r '.data.id // .' ;;
      interrupt) api POST "/api/session/$1/interrupt" | jq -c . ;;
    esac ;;
  diff) api GET "/api/session/${1:?sid}/diff" ;;
  info) api GET "/api/session/${1:?sid}" | jq -c '.data|{id,title,agent,model,cost,tokens,time}' ;;
  ""|-h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
