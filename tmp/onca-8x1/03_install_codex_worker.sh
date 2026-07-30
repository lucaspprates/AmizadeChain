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
EVIDENCE_DIR="/tmp/evidence/onca-8x1-phase2a-${STAMP}"
mkdir -p "$EVIDENCE_DIR"
LOG="$EVIDENCE_DIR/phase2a.log"
exec > >(tee "$LOG") 2>&1

fail() {
  local code="$1"; shift
  echo "ERRO: $*" >&2
  echo "OPERACAO_ONCA_8X1: BLOCKED"
  echo "PHASE=2A_CODEX_INSTALL"
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

check_control_plane() {
  [[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail CONTROL_PLANE_HOST_MISMATCH "$(hostname -s)"
  [[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] || fail TIMER_NOT_INACTIVE "timer mudou"
  local active
  active="$(systemctl list-units 'zoe-coder-job@*.service' 'zoe-coder-wake@*.service' --state=active,activating --no-legend --no-pager 2>/dev/null | wc -l)"
  [[ "$active" -eq 0 ]] || fail ACTIVE_UNITS_PRESENT "$active"
  [[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$EXPECTED_RUNTIME_SHA256" ]] || fail RUNTIME_SHA_MISMATCH "runtime"
  [[ "$(sudo sha256sum "$CONFIG" | awk '{print $1}')" == "$EXPECTED_CONFIG_SHA256" ]] || fail CONFIG_SHA_MISMATCH "config"
  [[ "$(sudo sha256sum "$DB" | awk '{print $1}')" == "$EXPECTED_DB_SHA256" ]] || fail DB_SHA_MISMATCH "db"
}

sudo -v

echo "===== 1. GUARDAS DO CONTROL PLANE ====="
check_control_plane
echo "control_plane=PASS"
echo "timer=inactive"
echo "active_units=0"

echo
echo "===== 2. INSTALAÇÃO OFICIAL DO CODEX NO WORKER ====="
set +e
"${SSH[@]}" bash -s -- "$WORKER_NAME" "$CODEX_VERSION" "$STAMP" <<'REMOTE'
set -Eeuo pipefail
EXPECTED_HOST="$1"
CODEX_VERSION="$2"
STAMP="$3"
REMOTE_EVIDENCE="/var/tmp/onca-8x1-phase2a-${STAMP}"
mkdir -p "$REMOTE_EVIDENCE"

remote_fail() {
  local code="$1"; shift
  echo "WORKER_PHASE2A: BLOCKED"
  echo "WORKER_FAILURE_CODE=$code"
  echo "WORKER_FAILURE_DETAIL=$*"
  exit 20
}

[[ "$(hostname -s)" == "$EXPECTED_HOST" ]] || remote_fail HOSTNAME_MISMATCH "$(hostname -s)"
[[ "$(id -un)" == "ubuntu" ]] || remote_fail USER_MISMATCH "$(id -un)"
[[ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null)" == "0" ]] || remote_fail USERNS_RESTRICTION_NOT_ZERO "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || true)"
unshare -Ur true || remote_fail UNSHARE_USER_FAILED "unshare -Ur true"
bwrap --unshare-user --unshare-net --uid 0 --gid 0 --ro-bind / / /bin/true || remote_fail BWRAP_FAILED "bwrap"

command -v curl >/dev/null || remote_fail CURL_MISSING "curl"
install -d -m 0755 "$HOME/.local/bin" "$HOME/.codex"
INSTALLER="$REMOTE_EVIDENCE/codex-install.sh"
curl -fsSL --connect-timeout 15 --max-time 120 https://chatgpt.com/codex/install.sh -o "$INSTALLER" || remote_fail INSTALLER_DOWNLOAD_FAILED "chatgpt.com/codex/install.sh"
chmod 0700 "$INSTALLER"
INSTALLER_SHA256="$(sha256sum "$INSTALLER" | awk '{print $1}')"

CODEX_NON_INTERACTIVE=1 \
CODEX_INSTALL_DIR="$HOME/.local/bin" \
CODEX_HOME="$HOME/.codex" \
sh "$INSTALLER" --release "$CODEX_VERSION" || remote_fail CODEX_INSTALL_FAILED "release=$CODEX_VERSION"

CODEX="$HOME/.local/bin/codex"
[[ -x "$CODEX" ]] || remote_fail CODEX_BINARY_MISSING "$CODEX"
CODEX_VERSION_OUTPUT="$($CODEX --version)"
[[ "$CODEX_VERSION_OUTPUT" == "codex-cli $CODEX_VERSION" ]] || remote_fail CODEX_VERSION_MISMATCH "$CODEX_VERSION_OUTPUT"
CODEX_SHA256="$(sha256sum "$CODEX" | awk '{print $1}')"

set +e
LOGIN_STATUS="$($CODEX login status 2>&1)"
LOGIN_RC=$?
set -e
printf '%s\n' "$LOGIN_STATUS" > "$REMOTE_EVIDENCE/login-status.txt"

cat > "$REMOTE_EVIDENCE/result.json" <<JSON
{
  "phase": "2A_CODEX_INSTALL",
  "status": "PASS",
  "host": "$(hostname -s)",
  "user": "$(id -un)",
  "codex_version": "$CODEX_VERSION_OUTPUT",
  "codex_path": "$CODEX",
  "codex_sha256": "$CODEX_SHA256",
  "installer_sha256": "$INSTALLER_SHA256",
  "login_status_rc": $LOGIN_RC,
  "control_plane_auth_copied": false
}
JSON
sha256sum "$REMOTE_EVIDENCE/result.json" "$REMOTE_EVIDENCE/login-status.txt" > "$REMOTE_EVIDENCE/SHA256SUMS"

echo "worker_host=$(hostname -s)"
echo "codex_path=$CODEX"
echo "codex_version=$CODEX_VERSION_OUTPUT"
echo "codex_sha256=$CODEX_SHA256"
echo "installer_sha256=$INSTALLER_SHA256"
echo "codex_login_status_rc=$LOGIN_RC"
echo "codex_login_status=$LOGIN_STATUS"
echo "worker_evidence=$REMOTE_EVIDENCE"
echo "WORKER_PHASE2A: PASS"
REMOTE
WORKER_RC=$?
set -e
[[ "$WORKER_RC" -eq 0 ]] || fail WORKER_INSTALL_RC_${WORKER_RC} "instalação no worker falhou"

echo
echo "===== 3. READBACK DO CONTROL PLANE ====="
check_control_plane
echo "control_plane_readback=PASS"

cat > "$EVIDENCE_DIR/result.json" <<JSON
{
  "phase": "2A_CODEX_INSTALL",
  "status": "PASS",
  "worker": "${WORKER_USER}@${WORKER_HOST}",
  "worker_hostname": "$WORKER_NAME",
  "codex_version": "$CODEX_VERSION",
  "timer": "inactive",
  "active_job_or_wake_units": 0,
  "control_plane_changed": false,
  "worker_changed": true,
  "authentication_required": true
}
JSON
sha256sum "$EVIDENCE_DIR/result.json" > "$EVIDENCE_DIR/SHA256SUMS"

echo
echo "OPERACAO_ONCA_8X1_PHASE2A: PASS"
echo "WORKER=${WORKER_USER}@${WORKER_HOST}"
echo "WORKER_HOSTNAME=$WORKER_NAME"
echo "CODEX_VERSION=$CODEX_VERSION"
echo "AUTHENTICATION_REQUIRED=true"
echo "EVIDENCE_DIR=$EVIDENCE_DIR"
echo "TIMER=inactive"
echo "ACTIVE_JOB_OR_WAKE_UNITS=0"
echo "CONTROL_PLANE_CHANGED=false"
echo "WORKER_CHANGED=true"
