#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

WORKER_HOST="201.23.86.157"
WORKER_USER="ubuntu"
WORKER_NAME="win-codex-wak-01"
RUN_USER="onca-runner"
SSH_KEY="/home/ubuntu/.ssh/ssh-key-2026-06-03.key"
KNOWN_HOSTS="/home/ubuntu/.ssh/known_hosts_onca_8x1"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="/tmp/evidence/onca-codex-auth-guard-v43-${STAMP}"
mkdir -p "$EVIDENCE"

fail() {
  local code="$1"
  shift
  echo "ERRO: $*" >&2
  echo "ONCA_CODEX_AUTH_GUARD_V43: BLOCKED"
  echo "FAILURE_CODE=$code"
  echo "CONTROL_PLANE_CHANGED=false"
  echo "WORKER_CHANGED=false"
  echo "TIMER=$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
  echo "EVIDENCE_DIR=$EVIDENCE"
  exit 1
}

active_units() {
  systemctl list-units \
    'zoe-coder-job@*.service' \
    'zoe-coder-wake@*.service' \
    --state=active,activating \
    --no-legend --no-pager 2>/dev/null | wc -l
}

[[ "$(id -un)" == "ubuntu" ]] || fail USER_MISMATCH "execute como ubuntu"
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail HOST_MISMATCH "host atual=$(hostname -s)"
[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail TIMER_NOT_INACTIVE "reconciler deve permanecer congelado"
[[ "$(active_units)" -eq 0 ]] || fail ACTIVE_UNITS_PRESENT "há units ativas"
[[ -f "$SSH_KEY" ]] || fail SSH_KEY_MISSING "$SSH_KEY"
[[ "$(stat -c %a "$SSH_KEY")" == "600" ]] || fail SSH_KEY_MODE_INVALID "$(stat -c %a "$SSH_KEY")"
[[ -f "$KNOWN_HOSTS" ]] || fail KNOWN_HOSTS_MISSING "$KNOWN_HOSTS"

SSH=(
  ssh
  -i "$SSH_KEY"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o ConnectTimeout=15
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=4
  "${WORKER_USER}@${WORKER_HOST}"
)

set +e
"${SSH[@]}" "sudo -n -u '$RUN_USER' -H bash -s" <<'REMOTE' 2>&1 |
  tee "$EVIDENCE/worker-auth-guard.log"
set -Eeuo pipefail
umask 0077
cd /

EXPECTED_HOST="win-codex-wak-01"
EXPECTED_USER="onca-runner"
AUTH_FILE="/home/onca-runner/.codex/auth.json"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

[[ "$(hostname -s)" == "$EXPECTED_HOST" ]]
[[ "$(id -un)" == "$EXPECTED_USER" ]]
[[ "$HOME" == "/home/onca-runner" ]]

echo "worker_host=$(hostname -s)"
echo "run_user=$(id -un)"
echo "home=$HOME"
echo "pwd=$PWD"
echo "codex_binary=$(command -v codex)"
codex --version

for key in OPENAI_API_KEY OPENAI_BASE_URL OPENAI_API_BASE CODEX_HOME XDG_CONFIG_HOME; do
  if [[ -v "$key" ]]; then
    value="${!key}"
    if [[ -n "$value" ]]; then
      echo "env_${key}=present_nonempty"
    else
      echo "env_${key}=present_empty"
    fi
  else
    echo "env_${key}=absent"
  fi
done

if [[ -e "$AUTH_FILE" ]]; then
  stat -c 'auth_file=%n owner=%U:%G mode=%a bytes=%s mtime=%y' "$AUTH_FILE"
  python3 - "$AUTH_FILE" <<'PY_META'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    value = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    print(json.dumps({
        "auth_json_valid": False,
        "error_type": type(exc).__name__,
    }, sort_keys=True))
    raise SystemExit(0)

paths = []
def walk(node, prefix=""):
    if isinstance(node, dict):
        for key, child in sorted(node.items()):
            child_path = f"{prefix}.{key}" if prefix else str(key)
            paths.append({"path": child_path, "type": type(child).__name__})
            walk(child, child_path)
    elif isinstance(node, list):
        paths.append({"path": f"{prefix}[]", "type": "list", "count": len(node)})

walk(value)
print(json.dumps({
    "auth_json_valid": True,
    "top_level_type": type(value).__name__,
    "metadata_paths": paths,
}, ensure_ascii=False, sort_keys=True))
PY_META
else
  echo "auth_file_present=false"
fi

set +e
codex login status >"$TMP/login-status.log" 2>&1
LOGIN_STATUS_RC=$?
set -e
cat "$TMP/login-status.log"
echo "codex_login_status_rc=$LOGIN_STATUS_RC"

mkdir -p "$TMP/inference"
cd "$TMP/inference"
git init -q
git config user.name onca-auth-guard
git config user.email onca-auth-guard@invalid.local

parse_auth_ok() {
  python3 - "$1" <<'PY_AUTH'
import json
import sys
from pathlib import Path

for line in Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines():
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        continue
    if record.get("type") != "item.completed":
        continue
    item = record.get("item") or {}
    if item.get("type") == "agent_message" and str(item.get("text", "")).strip() == "AUTH_OK":
        print("AUTH_OK_STRUCTURED=true")
        raise SystemExit(0)
raise SystemExit(1)
PY_AUTH
}

classify_log() {
  local path="$1"
  if grep -Fq 'Missing bearer or basic authentication' "$path"; then
    echo "MISSING_AUTHORIZATION_HEADER"
  elif grep -Fq 'token_invalidated' "$path"; then
    echo "TOKEN_INVALIDATED"
  elif grep -Fq '401 Unauthorized' "$path"; then
    echo "HTTP_401_AUTHENTICATION"
  elif grep -Eq '(^|[^0-9])429([^0-9]|$)|rate.?limit|usage limit' "$path"; then
    echo "RATE_OR_USAGE_LIMIT"
  elif grep -Eq '(^|[^0-9])(500|502|503|504)([^0-9]|$)|service unavailable|overloaded' "$path"; then
    echo "OPENAI_TRANSIENT_SERVER_ERROR"
  elif grep -Eqi 'could not resolve|connection refused|timed out|network is unreachable|TLS|certificate' "$path"; then
    echo "NETWORK_OR_TLS_FAILURE"
  else
    echo "CODEX_INFERENCE_UNCLASSIFIED"
  fi
}

run_inference() {
  local label="$1"
  shift
  local output="$TMP/${label}.jsonl"
  set +e
  "$@" exec \
    --json \
    --ephemeral \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    --cd "$TMP/inference" \
    --model gpt-5.6-terra \
    -c 'features.plugins=false' \
    -c 'model_reasoning_effort="low"' \
    'Do not create or modify files. Reply with exactly AUTH_OK.' \
    </dev/null >"$output" 2>&1
  local command_rc=$?
  parse_auth_ok "$output" >"$TMP/${label}.parse.log" 2>&1
  local parse_rc=$?
  set -e

  echo "===== ${label^^}_INFERENCE ====="
  cat "$output"
  cat "$TMP/${label}.parse.log"
  echo "${label}_command_rc=$command_rc"
  echo "${label}_parse_rc=$parse_rc"

  if [[ "$command_rc" -eq 0 && "$parse_rc" -eq 0 ]]; then
    echo "${label}_auth=PASS"
    return 0
  fi
  echo "${label}_auth=BLOCKED"
  echo "${label}_failure_code=$(classify_log "$output")"
  return 1
}

if run_inference exact codex; then
  echo "AUTH_ENVIRONMENT=EXACT_FACTORY_ENVIRONMENT"
  echo "AUTH_FAILURE_CODE=NONE"
  echo "WORKER_AUTH_GUARD=PASS"
  exit 0
fi

EXACT_FAILURE="$(classify_log "$TMP/exact.jsonl")"

if run_inference sanitized \
  env \
    -u OPENAI_API_KEY \
    -u OPENAI_BASE_URL \
    -u OPENAI_API_BASE \
    -u CODEX_HOME \
    -u XDG_CONFIG_HOME \
    HOME=/home/onca-runner \
    codex; then
  echo "ONCA_CODEX_AUTH_INFERENCE=BLOCKED"
  echo "AUTH_FAILURE_CODE=ENVIRONMENT_AUTH_OVERRIDE"
  echo "EXACT_ENV_FAILURE_CODE=$EXACT_FAILURE"
  echo "SANITIZED_AUTH=PASS"
  echo "WORKER_AUTH_GUARD=BLOCKED"
  exit 43
fi

SANITIZED_FAILURE="$(classify_log "$TMP/sanitized.jsonl")"
echo "ONCA_CODEX_AUTH_INFERENCE=BLOCKED"
echo "AUTH_FAILURE_CODE=$SANITIZED_FAILURE"
echo "EXACT_ENV_FAILURE_CODE=$EXACT_FAILURE"
echo "SANITIZED_ENV_FAILURE_CODE=$SANITIZED_FAILURE"
echo "WORKER_AUTH_GUARD=BLOCKED"
exit 42
REMOTE
WORKER_RC=${PIPESTATUS[0]}
set -e

if [[ "$WORKER_RC" -ne 0 ]]; then
  FAILURE_CODE="$(grep -E '^AUTH_FAILURE_CODE=' "$EVIDENCE/worker-auth-guard.log" | tail -1 | cut -d= -f2- || true)"
  [[ -n "$FAILURE_CODE" ]] || FAILURE_CODE="WORKER_AUTH_GUARD_RC_${WORKER_RC}"
  fail "$FAILURE_CODE" "a inferência real no ambiente exato da fábrica não autenticou"
fi

grep -Fq 'WORKER_AUTH_GUARD=PASS' "$EVIDENCE/worker-auth-guard.log" ||
  fail AUTH_PASS_MARKER_MISSING "marcador PASS ausente"
grep -Fq 'exact_auth=PASS' "$EVIDENCE/worker-auth-guard.log" ||
  fail EXACT_ENV_AUTH_PASS_MISSING "ambiente real da fábrica não passou"

echo
cat <<EOF
ONCA_CODEX_AUTH_GUARD_V43: PASS
WORKER=$RUN_USER@$WORKER_HOST
WORKER_HOSTNAME=$WORKER_NAME
AUTH_METHOD=CHATGPT_LOCAL_CREDENTIALS
AUTH_ENVIRONMENT=EXACT_FACTORY_ENVIRONMENT
REAL_INFERENCE=PASS
CONTROL_PLANE_CHANGED=false
WORKER_CHANGED=false
TIMER=inactive
ACTIVE_UNITS=0
EVIDENCE_DIR=$EVIDENCE
NEXT_PHASE=PR19_RESTACK_GATE_V43
EOF
