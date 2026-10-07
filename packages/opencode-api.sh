# opencode-api body (wrapped by packages/opencode-api.nix via writeShellApplication)
# opencode-api: thin, guardrailed helper for the OpenCode v2 server on Hermes.
# Password is read from the sops-rendered file and never printed or sourced.

BASE="${OPENCODE_BASE:-http://100.81.254.49:4096}"
SECRET_FILE="${OPENCODE_SECRET_FILE:-/run/secrets/opencode-server-env}"

pw() { sed -n 's/^OPENCODE_SERVER_PASSWORD=//p' "$SECRET_FILE"; }
# Credentials go to curl through a config on stdin (printf is a builtin), so the
# password never appears in any process argv.
auth_cfg() {
  local p
  p=$(pw)
  [ -n "$p" ] || { echo "opencode-api: no OPENCODE_SERVER_PASSWORD in $SECRET_FILE" >&2; return 1; }
  printf 'user = "opencode:%s"\n' "$p"
}
api() { # api METHOD PATH [JSON]
  local m=$1 p=$2 d=${3:-}
  if [ -n "$d" ]; then
    auth_cfg | curl -sS -m 30 -K - -H 'Content-Type: application/json' -X "$m" "$BASE$p" -d "$d"
  else
    auth_cfg | curl -sS -m 30 -K - -X "$m" "$BASE$p"
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
  prompt SID "text"                       send a prompt (async)
  wait SID [SECS]                         poll until the session is idle (default 600s)
  last SID [N]                            last N assistant text blocks (default 1)
  switch SID PROV/ID [VARIANT]            switch model/effort for subsequent turns
  deny SID                                (re)attach the free-model deny-list
  fork SID                                fork full history into a new session
  interrupt SID | diff SID | info SID
EOF
}

cmd=${1:-}; shift || true
case "$cmd" in
  models) api GET /api/model | jq -r '.data[]|"\(.providerID)/\(.modelID)\t\([.variants[]?.id]|join(","))"' ;;
  sessions)
    api GET /api/session | jq -r --arg d "${1:-}" '.data[]|select($d==""or(.location.directory//"")==$d)
      |[.id,.agent,(.model.providerID+"/"+.model.id+(if .model.variant then ":"+.model.variant else "" end)),(.time.updated|tostring),(.title//"")]|@tsv' ;;
  create)
    dir='' title='' model='' variant='' agent=build reason='' newreason=''
    while [ $# -gt 0 ]; do case $1 in
      --dir) dir=$2; shift 2;; --title) title=$2; shift 2;; --model) model=$2; shift 2;;
      --variant) variant=$2; shift 2;; --agent) agent=$2; shift 2;; --reason) reason=$2; shift 2;;
      --new-reason) newreason=$2; shift 2;; *) die "unknown flag $1";; esac; done
    [ -n "$dir" ] && [ -n "$title" ] && [ -n "$model" ] && [ -n "$reason" ] || die "need --dir --title --model --reason"
    echo "reason: $reason" >&2
    [[ $title == bernie/* ]] || title="bernie/$title"
    prov=${model%%/*}; mid=${model#*/}; [ "$prov" != "$model" ] || die "model must be PROVIDER/ID"
    existing=$(api GET /api/session | jq -r --arg d "$dir" --arg t "$title" '.data[]|select((.location.directory//"")==$d or .title==$t)|"\(.id)\t\(.title//"")"')
    if [ -n "$existing" ] && [ -z "$newreason" ]; then
      echo "Existing sessions for this dir/title - continue one, or pass --new-reason:" >&2; echo "$existing" >&2; exit 3
    fi
    body=$(jq -n --arg t "$title" --arg a "$agent" --arg p "$prov" --arg m "$mid" --arg v "$variant" --arg d "$dir" \
      '{title:$t,agent:$a,model:({id:$m,providerID:$p}+(if $v!="" then {variant:$v} else {} end)),location:{directory:$d}}')
    if is_free "$mid"; then body=$(echo "$body" | jq --argjson r "$(deny_rules)" '.permissions=$r'); echo "free model: deny-list attached" >&2; fi
    api POST /api/session "$body" | jq -r '.data|"\(.id)\t\(.title)"' ;;
  prompt) [ $# -eq 2 ] || die "prompt SID text"; api POST "/api/session/$1/prompt" "$(jq -n --arg t "$2" '{text:$t}')" | jq -r '.data.id // .' ;;
  wait)
    sid=${1:?sid}; max=${2:-600}; t=0; seen=0; st=idle
    while [ $t -lt "$max" ]; do
      st=$(api GET /api/session/active | jq -r --arg s "$sid" '.data[$s].type // "idle"') || st=unknown
      if [ "$st" = unknown ]; then sleep 2; t=$((t+2)); continue; fi
      if [ "$st" = running ]; then seen=1; elif [ $seen = 1 ] || [ $t -ge 8 ]; then break; fi
      sleep 2; t=$((t+2))
    done
    pend=$(api GET "/api/session/$sid/permission" | jq -r '.data|length')
    echo "state=$st pending_permissions=$pend" ;;
  last) api GET "/api/session/${1:?sid}/message?order=desc&limit=20" | jq -r --argjson n "${2:-1}" \
        '[.data[]|select(.type=="assistant")|.content[]?|select(.type=="text")|.text]|.[:$n]|reverse|.[]' ;;
  switch)
    sid=${1:?sid}; model=${2:?PROV/ID}; v=${3:-}; prov=${model%%/*}; mid=${model#*/}
    api POST "/api/session/$sid/model" "$(jq -n --arg p "$prov" --arg m "$mid" --arg v "$v" '{model:({id:$m,providerID:$p}+(if $v!="" then {variant:$v} else {} end))}')" >/dev/null
    if is_free "$mid"; then api PATCH "/api/session/$sid" "$(jq -n --argjson r "$(deny_rules)" '{permissions:$r}')" >/dev/null; echo "deny-list attached" >&2; fi
    echo "switched $sid -> $model${v:+:$v}" ;;
  deny) api PATCH "/api/session/${1:?sid}" "$(jq -n --argjson r "$(deny_rules)" '{permissions:$r}')" >/dev/null; echo "deny-list attached" ;;
  fork) api POST "/api/session/${1:?sid}/fork" '{}' | jq -r '.data.id // .' ;;
  interrupt) api POST "/api/session/${1:?sid}/interrupt" | jq -c . ;;
  diff) api GET "/api/session/${1:?sid}/diff" ;;
  info) api GET "/api/session/${1:?sid}" | jq -c '.data|{id,title,agent,model,cost,tokens,time}' ;;
  ""|-h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
