#!/usr/bin/env bash
set -Eeuo pipefail

WORKER_HOST="201.23.86.157"
WORKER_USER="ubuntu"
WORKER_NAME="win-codex-wak-01"
SSH_KEY="/home/ubuntu/.ssh/ssh-key-2026-06-03.key"
KNOWN_HOSTS="/home/ubuntu/.ssh/known_hosts_onca_8x1"
RUNTIME="/usr/local/lib/zoe-coder-router/zoe_coder_router.py"
CONFIG="/etc/zoe-coder-router/config.toml"
DB="/var/lib/zoe-coder-router/runtime.db"
EXPECTED_RUNTIME_SHA256="f181fd627dceff10d46d23598eb54d8cfb5a15b070231aa34b4c09e907fc7d85"
EXPECTED_CONFIG_SHA256="8f2e0632474bc12b62dea0e5539131ceb05f99631bf970ff06a1058bbef20ddf"
EXPECTED_DB_SHA256="b0ab9b08edc54cf6ba3d1f60aaef9ae93fea3392d01f55a40275776e7b119374"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="/tmp/evidence/onca-8x1-phase1b-${STAMP}"
mkdir -p "$EVIDENCE_DIR"
LOG="$EVIDENCE_DIR/phase1b.log"
exec > >(tee "$LOG") 2>&1

fail() {
  local code="$1"
  shift
  echo "ERRO: $*" >&2
  echo "OPERACAO_ONCA_8X1: BLOCKED"
  echo "PHASE=1B_USERNS_SANDBOX"
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

echo "===== 1. GUARDAS DO CONTROL PLANE ====="
[[ "$(id -un)" == "ubuntu" ]] || fail CONTROL_PLANE_USER "execute como ubuntu"
[[ -f "$SSH_KEY" ]] || fail SSH_KEY_MISSING "$SSH_KEY"
[[ "$(stat -c '%a' "$SSH_KEY")" == "600" ]] || fail SSH_KEY_MODE "modo da chave não é 600"
[[ -s "$KNOWN_HOSTS" ]] || fail KNOWN_HOSTS_MISSING "$KNOWN_HOSTS"
[[ -f "$RUNTIME" && -f "$CONFIG" ]] || fail CONTROL_PLANE_FILES_MISSING "runtime/config ausentes"
sudo -n test -f "$DB" || fail CONTROL_PLANE_DB_MISSING "$DB"

TIMER="$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
[[ "$TIMER" == "inactive" ]] || fail TIMER_NOT_FROZEN "$TIMER"
ACTIVE_UNITS="$(systemctl list-units 'zoe-coder-job@*.service' 'zoe-coder-wake@*.service' --state=active,activating --no-legend --no-pager 2>/dev/null | wc -l)"
[[ "$ACTIVE_UNITS" -eq 0 ]] || fail ACTIVE_UNITS_PRESENT "$ACTIVE_UNITS"

RUNTIME_SHA="$(sha256sum "$RUNTIME" | awk '{print $1}')"
CONFIG_SHA="$(sudo sha256sum "$CONFIG" | awk '{print $1}')"
DB_SHA="$(sudo sha256sum "$DB" | awk '{print $1}')"
[[ "$RUNTIME_SHA" == "$EXPECTED_RUNTIME_SHA256" ]] || fail RUNTIME_SHA_MISMATCH "$RUNTIME_SHA"
[[ "$CONFIG_SHA" == "$EXPECTED_CONFIG_SHA256" ]] || fail CONFIG_SHA_MISMATCH "$CONFIG_SHA"
[[ "$DB_SHA" == "$EXPECTED_DB_SHA256" ]] || fail DB_SHA_MISMATCH "$DB_SHA"

echo "control_plane_host=$(hostname -s)"
echo "timer=$TIMER"
echo "active_units=$ACTIVE_UNITS"
echo "runtime_sha256=$RUNTIME_SHA"
echo "config_sha256=$CONFIG_SHA"
echo "runtime_db_sha256=$DB_SHA"

echo
echo "===== 2. APLICAÇÃO REVERSÍVEL NO WORKER ====="
REMOTE_LOG="$EVIDENCE_DIR/worker-phase1b.log"
set +e
"${SSH[@]}" 'bash -se' -- "$WORKER_NAME" "$STAMP" <<'REMOTE' | tee "$REMOTE_LOG"
set -Eeuo pipefail

EXPECTED_HOST="$1"
STAMP="$2"
SYSCTL_FILE="/etc/sysctl.d/60-onca-8x1-userns.conf"
BACKUP_ROOT="/var/backups/onca-8x1/${STAMP}"
REMOTE_EVIDENCE="/var/tmp/onca-8x1-phase1b-${STAMP}"

remote_fail() {
  local code="$1"
  shift
  echo "WORKER_PHASE1B: BLOCKED"
  echo "WORKER_FAILURE_CODE=$code"
  echo "WORKER_FAILURE_DETAIL=$*"
  exit 20
}

[[ "$(hostname -s)" == "$EXPECTED_HOST" ]] || remote_fail HOSTNAME_MISMATCH "$(hostname -s)"
[[ "$(id -un)" == "ubuntu" ]] || remote_fail USER_MISMATCH "$(id -un)"
sudo -n true || remote_fail SUDO_NOPASSWD_FAILED "sudo -n true"
mkdir -p "$REMOTE_EVIDENCE"
sudo install -d -m 0700 -o root -g root "$BACKUP_ROOT"

PREVIOUS_VALUE="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo unavailable)"
PREVIOUS_FILE_STATE="absent"
if sudo test -e "$SYSCTL_FILE"; then
  PREVIOUS_FILE_STATE="present"
  sudo cp -a "$SYSCTL_FILE" "$BACKUP_ROOT/60-onca-8x1-userns.conf.before"
fi
printf '%s\n' "$PREVIOUS_VALUE" | sudo tee "$BACKUP_ROOT/previous-value.txt" >/dev/null
printf '%s\n' "$PREVIOUS_FILE_STATE" | sudo tee "$BACKUP_ROOT/previous-file-state.txt" >/dev/null

cat <<'CONF' | sudo tee "$SYSCTL_FILE" >/dev/null
# Temporary dedicated ONCA-8X1 worker.
# Restore/remove this file before reusing the VM for another purpose.
kernel.apparmor_restrict_unprivileged_userns=0
CONF
sudo chmod 0644 "$SYSCTL_FILE"
sudo sysctl --load "$SYSCTL_FILE"

CURRENT_VALUE="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo unavailable)"
[[ "$CURRENT_VALUE" == "0" ]] || remote_fail USERNS_SYSCTL_NOT_ZERO "$CURRENT_VALUE"

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq bubblewrap uidmap git curl ca-certificates jq python3 python3-venv >/dev/null

unshare -Ur true || remote_fail UNSHARE_USER_FAILED "unshare -Ur true"
unshare -Urn true || remote_fail UNSHARE_USER_NET_FAILED "unshare -Urn true"

BWRAP_VERSION="$(bwrap --version | head -1)"
bwrap \
  --unshare-user \
  --unshare-net \
  --uid 0 \
  --gid 0 \
  --ro-bind / / \
  /bin/true || remote_fail BWRAP_USER_NET_FAILED "$BWRAP_VERSION"

OPENAI_HTTP="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' https://api.openai.com || true)"
GITHUB_HTTP="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' https://github.com || true)"
[[ "$OPENAI_HTTP" != "000" ]] || remote_fail OPENAI_HTTPS_FAILED "$OPENAI_HTTP"
[[ "$GITHUB_HTTP" != "000" ]] || remote_fail GITHUB_HTTPS_FAILED "$GITHUB_HTTP"

cat > "$REMOTE_EVIDENCE/result.json" <<JSON
{
  "phase": "1B_USERNS_SANDBOX",
  "status": "PASS",
  "host": "$(hostname -s)",
  "user": "$(id -un)",
  "previous_userns_restriction": "$PREVIOUS_VALUE",
  "current_userns_restriction": "$CURRENT_VALUE",
  "sysctl_file": "$SYSCTL_FILE",
  "backup_root": "$BACKUP_ROOT",
  "unshare_user": "PASS",
  "unshare_user_net": "PASS",
  "bubblewrap": "$BWRAP_VERSION",
  "bubblewrap_user_net": "PASS",
  "openai_http": "$OPENAI_HTTP",
  "github_http": "$GITHUB_HTTP",
  "reboot_required": false
}
JSON
sha256sum "$REMOTE_EVIDENCE/result.json" > "$REMOTE_EVIDENCE/SHA256SUMS"

cat <<RESTORE | sudo tee "$BACKUP_ROOT/restore-userns.sh" >/dev/null
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$PREVIOUS_FILE_STATE" == "present" ]]; then
  install -m 0644 "$BACKUP_ROOT/60-onca-8x1-userns.conf.before" "$SYSCTL_FILE"
else
  rm -f "$SYSCTL_FILE"
fi
sysctl -w kernel.apparmor_restrict_unprivileged_userns="$PREVIOUS_VALUE"
RESTORE
sudo chmod 0700 "$BACKUP_ROOT/restore-userns.sh"

echo "worker_host=$(hostname -s)"
echo "worker_user=$(id -un)"
echo "previous_userns_restriction=$PREVIOUS_VALUE"
echo "current_userns_restriction=$CURRENT_VALUE"
echo "unshare_user=PASS"
echo "unshare_user_net=PASS"
echo "bubblewrap_version=$BWRAP_VERSION"
echo "bubblewrap_user_net=PASS"
echo "openai_http=$OPENAI_HTTP"
echo "github_http=$GITHUB_HTTP"
echo "worker_backup_root=$BACKUP_ROOT"
echo "worker_evidence=$REMOTE_EVIDENCE"
echo "worker_reboot_required=false"
echo "WORKER_PHASE1B: PASS"
REMOTE
REMOTE_RC=${PIPESTATUS[0]}
set -e
[[ "$REMOTE_RC" -eq 0 ]] || fail WORKER_PHASE1B_RC_${REMOTE_RC} "consulte $REMOTE_LOG"

grep -q '^WORKER_PHASE1B: PASS$' "$REMOTE_LOG" || fail WORKER_PASS_MARKER_MISSING "$REMOTE_LOG"
grep -q '^unshare_user=PASS$' "$REMOTE_LOG" || fail UNSHARE_USER_NOT_PROVEN "$REMOTE_LOG"
grep -q '^unshare_user_net=PASS$' "$REMOTE_LOG" || fail UNSHARE_NET_NOT_PROVEN "$REMOTE_LOG"
grep -q '^bubblewrap_user_net=PASS$' "$REMOTE_LOG" || fail BWRAP_NOT_PROVEN "$REMOTE_LOG"

echo
echo "===== 3. READBACK DO CONTROL PLANE ====="
TIMER_AFTER="$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
ACTIVE_AFTER="$(systemctl list-units 'zoe-coder-job@*.service' 'zoe-coder-wake@*.service' --state=active,activating --no-legend --no-pager 2>/dev/null | wc -l)"
RUNTIME_AFTER="$(sha256sum "$RUNTIME" | awk '{print $1}')"
CONFIG_AFTER="$(sudo sha256sum "$CONFIG" | awk '{print $1}')"
DB_AFTER="$(sudo sha256sum "$DB" | awk '{print $1}')"
[[ "$TIMER_AFTER" == "inactive" ]] || fail TIMER_CHANGED "$TIMER_AFTER"
[[ "$ACTIVE_AFTER" -eq 0 ]] || fail ACTIVE_UNITS_CHANGED "$ACTIVE_AFTER"
[[ "$RUNTIME_AFTER" == "$EXPECTED_RUNTIME_SHA256" ]] || fail RUNTIME_CHANGED "$RUNTIME_AFTER"
[[ "$CONFIG_AFTER" == "$EXPECTED_CONFIG_SHA256" ]] || fail CONFIG_CHANGED "$CONFIG_AFTER"
[[ "$DB_AFTER" == "$EXPECTED_DB_SHA256" ]] || fail DB_CHANGED "$DB_AFTER"

sha256sum "$LOG" "$REMOTE_LOG" > "$EVIDENCE_DIR/SHA256SUMS"

echo "timer=$TIMER_AFTER"
echo "active_units=$ACTIVE_AFTER"
echo "runtime_sha256=$RUNTIME_AFTER"
echo "config_sha256=$CONFIG_AFTER"
echo "runtime_db_sha256=$DB_AFTER"
echo
echo "OPERACAO_ONCA_8X1_PHASE1B: PASS"
echo "WORKER=${WORKER_USER}@${WORKER_HOST}"
echo "WORKER_HOSTNAME=$WORKER_NAME"
echo "USERNS=PASS"
echo "BUBBLEWRAP=PASS"
echo "EVIDENCE_DIR=$EVIDENCE_DIR"
echo "TIMER=inactive"
echo "ACTIVE_JOB_OR_WAKE_UNITS=0"
echo "CONTROL_PLANE_CHANGED=false"
echo "WORKER_CHANGED=true"
