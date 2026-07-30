#!/usr/bin/env bash
set -Eeuo pipefail

WORKER_HOST="201.23.86.157"
WORKER_USER="ubuntu"
WORKER_NAME="win-codex-wak-01"
SSH_KEY="/home/ubuntu/.ssh/ssh-key-2026-06-03.key"
KNOWN_HOSTS="/home/ubuntu/.ssh/known_hosts_onca_8x1"
CODEX_VERSION="0.145.0"

RUNTIME="/usr/local/lib/zoe-coder-router/zoe_coder_router.py"
CONFIG="/etc/zoe-coder-router/config.toml"
DB="/var/lib/zoe-coder-router/runtime.db"
EXPECTED_RUNTIME_SHA256="f181fd627dceff10d46d23598eb54d8cfb5a15b070231aa34b4c09e907fc7d85"
EXPECTED_CONFIG_SHA256="8f2e0632474bc12b62dea0e5539131ceb05f99631bf970ff06a1058bbef20ddf"
EXPECTED_DB_SHA256="b0ab9b08edc54cf6ba3d1f60aaef9ae93fea3392d01f55a40275776e7b119374"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="/tmp/evidence/onca-8x1-phase2c-${STAMP}"
mkdir -p "$EVIDENCE_DIR"
LOG="$EVIDENCE_DIR/phase2c.log"
exec > >(tee "$LOG") 2>&1

fail() {
  local code="$1"; shift
  echo "ERRO: $*" >&2
  echo "OPERACAO_ONCA_8X1: BLOCKED"
  echo "PHASE=2C_CODEX_REAL_CANARY"
  echo "FAILURE_CODE=$code"
  echo "EVIDENCE_DIR=$EVIDENCE_DIR"
  exit 1
}

SSH=(
  ssh -i "$SSH_KEY"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o ConnectTimeout=15
  "${WORKER_USER}@${WORKER_HOST}"
)

SCP=(
  scp -q -i "$SSH_KEY"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o ConnectTimeout=15
)

control_readback() {
  [[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail CONTROL_PLANE_HOST_MISMATCH "$(hostname -s)"
  [[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
    fail TIMER_NOT_FROZEN "timer não está inactive"

  local active_units
  active_units="$(
    systemctl list-units 'zoe-coder-job@*.service' 'zoe-coder-wake@*.service' \
      --state=active,activating --no-legend --no-pager 2>/dev/null | wc -l
  )"
  [[ "$active_units" -eq 0 ]] || fail ACTIVE_UNITS_PRESENT "$active_units"

  [[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$EXPECTED_RUNTIME_SHA256" ]] ||
    fail RUNTIME_SHA_MISMATCH "runtime divergente"
  [[ "$(sudo sha256sum "$CONFIG" | awk '{print $1}')" == "$EXPECTED_CONFIG_SHA256" ]] ||
    fail CONFIG_SHA_MISMATCH "config divergente"
  [[ "$(sudo sha256sum "$DB" | awk '{print $1}')" == "$EXPECTED_DB_SHA256" ]] ||
    fail DB_SHA_MISMATCH "db divergente"

  echo "timer=inactive"
  echo "active_units=0"
  echo "runtime_sha256=$EXPECTED_RUNTIME_SHA256"
  echo "config_sha256=$EXPECTED_CONFIG_SHA256"
  echo "runtime_db_sha256=$EXPECTED_DB_SHA256"
}

echo "===== 1. GUARDAS DO CONTROL PLANE ====="
sudo -v
control_readback

echo
echo "===== 2. CANÁRIO REAL DO CODEX NO WORKER ====="

set +e
"${SSH[@]}" bash -s -- "$WORKER_NAME" "$CODEX_VERSION" "$STAMP" <<'REMOTE'
set -Eeuo pipefail

EXPECTED_HOST="$1"
EXPECTED_VERSION="$2"
STAMP="$3"
EVIDENCE="/var/tmp/onca-8x1-phase2c-${STAMP}"
REPO="$(mktemp -d "/tmp/onca-codex-canary-${STAMP}.XXXXXX")"
mkdir -p "$EVIDENCE"

remote_fail() {
  local code="$1"; shift
  echo "WORKER_PHASE2C: BLOCKED"
  echo "WORKER_FAILURE_CODE=$code"
  echo "WORKER_FAILURE_DETAIL=$*"
  echo "WORKER_EVIDENCE=$EVIDENCE"
  exit 20
}

cleanup() {
  rm -rf "$REPO"
}
trap cleanup EXIT

[[ "$(hostname -s)" == "$EXPECTED_HOST" ]] || remote_fail HOSTNAME_MISMATCH "$(hostname -s)"
[[ "$(id -un)" == "ubuntu" ]] || remote_fail USER_MISMATCH "$(id -un)"
[[ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || true)" == "0" ]] ||
  remote_fail USERNS_RESTRICTION_NOT_ZERO "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || true)"
unshare -Ur true || remote_fail UNSHARE_USER_FAILED "unshare -Ur true"
unshare -Urn true || remote_fail UNSHARE_NET_FAILED "unshare -Urn true"
bwrap --unshare-user --unshare-net --uid 0 --gid 0 --ro-bind / / /bin/true ||
  remote_fail BWRAP_FAILED "bwrap user+net"

export PATH="$HOME/.local/bin:$PATH"
command -v codex >/dev/null || remote_fail CODEX_NOT_FOUND "PATH=$PATH"
CODEX_OUTPUT_VERSION="$(codex --version)"
[[ "$CODEX_OUTPUT_VERSION" == "codex-cli $EXPECTED_VERSION" ]] ||
  remote_fail CODEX_VERSION_MISMATCH "$CODEX_OUTPUT_VERSION"
AUTH_STATUS="$(codex login status 2>&1 || true)"
grep -q 'Logged in using ChatGPT' <<<"$AUTH_STATUS" ||
  remote_fail CODEX_AUTH_MISSING "$AUTH_STATUS"

codex exec --help > "$EVIDENCE/codex-exec-help.txt"
grep -q -- '--json' "$EVIDENCE/codex-exec-help.txt" || remote_fail CODEX_JSON_FLAG_MISSING "--json"
grep -q -- '--sandbox' "$EVIDENCE/codex-exec-help.txt" || remote_fail CODEX_SANDBOX_FLAG_MISSING "--sandbox"
grep -q -- '--ephemeral' "$EVIDENCE/codex-exec-help.txt" || remote_fail CODEX_EPHEMERAL_FLAG_MISSING "--ephemeral"

git -C "$REPO" init -q
git -C "$REPO" config user.name 'onca-canary'
git -C "$REPO" config user.email 'onca-canary@invalid.local'
printf '# ONCA Codex Worker Canary\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm 'chore: initialize canary'
START_SHA="$(git -C "$REPO" rev-parse HEAD)"

PROMPT='Work only inside the current Git repository. Create exactly one new file named ONCA_CANARY.txt containing exactly the single line ONCA_CODEX_WORKER_OK followed by a newline. Do not modify README.md, Git configuration, or any other repository file. Do not create a commit. After verifying the file, finish with exactly ONCA_CODEX_CANARY_COMPLETE.'

set +e
timeout --signal=TERM --kill-after=20s 300s \
  codex exec \
    --json \
    --ephemeral \
    --sandbox workspace-write \
    --cd "$REPO" \
    -c 'features.plugins=false' \
    "$PROMPT" \
  > "$EVIDENCE/codex-jsonl.log" \
  2> "$EVIDENCE/codex-stderr.log"
CODEX_RC=$?
set -e

[[ "$CODEX_RC" -eq 0 ]] || remote_fail CODEX_EXEC_FAILED "rc=$CODEX_RC"
[[ -f "$REPO/ONCA_CANARY.txt" ]] || remote_fail CANARY_FILE_MISSING "$REPO/ONCA_CANARY.txt"
printf 'ONCA_CODEX_WORKER_OK\n' | cmp -s - "$REPO/ONCA_CANARY.txt" ||
  remote_fail CANARY_CONTENT_MISMATCH "exact bytes differ"
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$START_SHA" ]] || remote_fail CANARY_COMMIT_CREATED "HEAD mudou"

mapfile -t CHANGED < <(git -C "$REPO" status --porcelain=v1 --untracked-files=all)
[[ "${#CHANGED[@]}" -eq 1 ]] || remote_fail CANARY_UNEXPECTED_CHANGE_COUNT "${#CHANGED[@]}:${CHANGED[*]-}"
[[ "${CHANGED[0]}" == '?? ONCA_CANARY.txt' ]] || remote_fail CANARY_UNEXPECTED_CHANGE "${CHANGED[0]}"

python3 - "$EVIDENCE/codex-jsonl.log" "$EVIDENCE/last-agent-message.txt" <<'PY' ||
import json
import sys
from pathlib import Path

stream = Path(sys.argv[1])
out = Path(sys.argv[2])
messages = []
fatal = []
turn_completed = False
for raw in stream.read_text(encoding="utf-8", errors="replace").splitlines():
    try:
        event = json.loads(raw)
    except json.JSONDecodeError:
        continue
    etype = event.get("type")
    if etype in {"error", "turn.failed"}:
        fatal.append(event)
    if etype == "turn.completed":
        turn_completed = True
    item = event.get("item") or {}
    if etype == "item.completed" and item.get("type") == "agent_message":
        messages.append(str(item.get("text") or ""))
assert not fatal, fatal
assert turn_completed is True
assert messages, "no agent_message"
last = messages[-1].strip()
out.write_text(last + "\n", encoding="utf-8")
assert last == "ONCA_CODEX_CANARY_COMPLETE", repr(last)
PY
  remote_fail TERMINAL_MARKER_MISSING "last agent message diverged"

CANARY_SHA256="$(sha256sum "$REPO/ONCA_CANARY.txt" | awk '{print $1}')"
cat > "$EVIDENCE/result.json" <<JSON
{
  "phase": "2C_CODEX_REAL_CANARY",
  "status": "PASS",
  "host": "$(hostname -s)",
  "user": "$(id -un)",
  "codex_version": "$CODEX_OUTPUT_VERSION",
  "auth_status": "Logged in using ChatGPT",
  "userns_restriction": 0,
  "unshare_user": "PASS",
  "unshare_net": "PASS",
  "bubblewrap": "PASS",
  "sandbox": "workspace-write",
  "start_sha": "$START_SHA",
  "head_sha": "$(git -C "$REPO" rev-parse HEAD)",
  "changed_paths": ["ONCA_CANARY.txt"],
  "canary_sha256": "$CANARY_SHA256",
  "terminal_marker": "ONCA_CODEX_CANARY_COMPLETE",
  "codex_exit_code": 0
}
JSON
(
  cd "$EVIDENCE"
  sha256sum codex-exec-help.txt codex-jsonl.log codex-stderr.log last-agent-message.txt result.json > SHA256SUMS
)

echo "worker_host=$(hostname -s)"
echo "worker_codex_version=$CODEX_OUTPUT_VERSION"
echo "worker_codex_auth=Logged_in_using_ChatGPT"
echo "worker_userns=PASS"
echo "worker_bubblewrap=PASS"
echo "worker_codex_exec=PASS"
echo "worker_sandbox=workspace-write"
echo "worker_canary_file=ONCA_CANARY.txt"
echo "worker_canary_sha256=$CANARY_SHA256"
echo "worker_terminal_marker=ONCA_CODEX_CANARY_COMPLETE"
echo "worker_evidence=$EVIDENCE"
echo "WORKER_PHASE2C: PASS"
REMOTE
REMOTE_RC=$?
set -e

[[ "$REMOTE_RC" -eq 0 ]] || fail WORKER_CANARY_RC_$REMOTE_RC "canário remoto falhou"

REMOTE_EVIDENCE="/var/tmp/onca-8x1-phase2c-${STAMP}"
"${SCP[@]}" "${WORKER_USER}@${WORKER_HOST}:${REMOTE_EVIDENCE}/result.json" "$EVIDENCE_DIR/worker-result.json" ||
  fail WORKER_RESULT_COPY_FAILED "result.json"
"${SCP[@]}" "${WORKER_USER}@${WORKER_HOST}:${REMOTE_EVIDENCE}/SHA256SUMS" "$EVIDENCE_DIR/worker-SHA256SUMS" ||
  fail WORKER_MANIFEST_COPY_FAILED "SHA256SUMS"
"${SCP[@]}" "${WORKER_USER}@${WORKER_HOST}:${REMOTE_EVIDENCE}/codex-stderr.log" "$EVIDENCE_DIR/worker-codex-stderr.log" ||
  fail WORKER_STDERR_COPY_FAILED "codex-stderr.log"
"${SCP[@]}" "${WORKER_USER}@${WORKER_HOST}:${REMOTE_EVIDENCE}/last-agent-message.txt" "$EVIDENCE_DIR/worker-last-agent-message.txt" ||
  fail WORKER_LAST_MESSAGE_COPY_FAILED "last-agent-message.txt"

EXPECTED_RESULT_SHA="$(awk '$2 == "result.json" {print $1}' "$EVIDENCE_DIR/worker-SHA256SUMS")"
[[ -n "$EXPECTED_RESULT_SHA" ]] || fail WORKER_RESULT_HASH_MISSING "manifesto sem result.json"
[[ "$(sha256sum "$EVIDENCE_DIR/worker-result.json" | awk '{print $1}')" == "$EXPECTED_RESULT_SHA" ]] ||
  fail WORKER_RESULT_HASH_MISMATCH "result.json copiado divergiu"
[[ "$(cat "$EVIDENCE_DIR/worker-last-agent-message.txt")" == "ONCA_CODEX_CANARY_COMPLETE" ]] ||
  fail WORKER_LAST_MESSAGE_MISMATCH "mensagem terminal divergente"

python3 - "$EVIDENCE_DIR/worker-result.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
data = json.loads(p.read_text(encoding="utf-8"))
assert data["phase"] == "2C_CODEX_REAL_CANARY"
assert data["status"] == "PASS"
assert data["host"] == "win-codex-wak-01"
assert data["codex_version"] == "codex-cli 0.145.0"
assert data["auth_status"] == "Logged in using ChatGPT"
assert data["userns_restriction"] == 0
assert data["unshare_user"] == "PASS"
assert data["unshare_net"] == "PASS"
assert data["bubblewrap"] == "PASS"
assert data["sandbox"] == "workspace-write"
assert data["start_sha"] == data["head_sha"]
assert data["changed_paths"] == ["ONCA_CANARY.txt"]
assert data["terminal_marker"] == "ONCA_CODEX_CANARY_COMPLETE"
assert data["codex_exit_code"] == 0
print("worker_result_readback=PASS")
PY

echo
echo "===== 3. READBACK DO CONTROL PLANE ====="
control_readback

(
  cd "$EVIDENCE_DIR"
  sha256sum worker-result.json worker-SHA256SUMS worker-codex-stderr.log worker-last-agent-message.txt > SHA256SUMS
  sha256sum -c SHA256SUMS
)

echo
echo "OPERACAO_ONCA_8X1_PHASE2C: PASS"
echo "WORKER=${WORKER_USER}@${WORKER_HOST}"
echo "WORKER_HOSTNAME=$WORKER_NAME"
echo "CODEX_VERSION=$CODEX_VERSION"
echo "CODEX_AUTH=PASS"
echo "USERNS=PASS"
echo "BUBBLEWRAP=PASS"
echo "CODEX_REAL_EXEC=PASS"
echo "SANDBOX=workspace-write"
echo "EVIDENCE_DIR=$EVIDENCE_DIR"
echo "TIMER=inactive"
echo "ACTIVE_JOB_OR_WAKE_UNITS=0"
echo "CONTROL_PLANE_CHANGED=false"
echo "WORKER_CHANGED=canary_temp_only"
