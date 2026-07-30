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
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="/tmp/evidence/onca-8x1-phase1-${STAMP}"
LOG="${EVIDENCE}/preflight.log"
mkdir -p "$EVIDENCE"
exec > >(tee "$LOG") 2>&1

fail() {
  echo "OPERACAO_ONCA_8X1: BLOCKED"
  echo "PHASE=1_PREFLIGHT"
  echo "FAILURE_CODE=$1"
  echo "EVIDENCE_DIR=$EVIDENCE"
  exit 1
}

active_units() {
  systemctl list-units 'zoe-coder-job@*.service' 'zoe-coder-wake@*.service' \
    --state=active,activating --no-legend --no-pager 2>/dev/null | awk 'NF{n++} END{print n+0}'
}

SSH=(
  ssh -i "$SSH_KEY"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o ConnectTimeout=15
  "${WORKER_USER}@${WORKER_HOST}"
)

echo "===== 1. CONTROL PLANE — ESTADO SEGURO ====="
[[ "$(id -un)" == "ubuntu" ]] || fail "CONTROL_PLANE_USER_NOT_UBUNTU"
[[ -f "$SSH_KEY" ]] || fail "SSH_KEY_MISSING"
KEY_MODE="$(stat -c '%a' "$SSH_KEY")"
case "$KEY_MODE" in
  400|600) ;;
  *) fail "SSH_KEY_MODE_${KEY_MODE}" ;;
esac
[[ -f "$RUNTIME" ]] || fail "RUNTIME_MISSING"
[[ -f "$CONFIG" ]] || fail "CONFIG_MISSING"
sudo -n test -f "$DB" || fail "DB_MISSING_OR_SUDO_UNAVAILABLE"

TIMER_BEFORE="$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
[[ "$TIMER_BEFORE" == "inactive" ]] || fail "TIMER_NOT_INACTIVE_${TIMER_BEFORE}"
UNITS_BEFORE="$(active_units)"
[[ "$UNITS_BEFORE" -eq 0 ]] || fail "ACTIVE_JOB_OR_WAKE_UNITS_${UNITS_BEFORE}"

RUNTIME_SHA_BEFORE="$(sha256sum "$RUNTIME" | awk '{print $1}')"
CONFIG_SHA_BEFORE="$(sudo -n sha256sum "$CONFIG" | awk '{print $1}')"
DB_SHA_BEFORE="$(sudo -n sha256sum "$DB" | awk '{print $1}')"
[[ "$RUNTIME_SHA_BEFORE" == "$EXPECTED_RUNTIME_SHA256" ]] || fail "RUNTIME_SHA_DIVERGED_${RUNTIME_SHA_BEFORE}"
[[ "$CONFIG_SHA_BEFORE" == "$EXPECTED_CONFIG_SHA256" ]] || fail "CONFIG_SHA_DIVERGED_${CONFIG_SHA_BEFORE}"

echo "control_plane_host=$(hostname -f 2>/dev/null || hostname)"
echo "timer=$TIMER_BEFORE"
echo "active_units=$UNITS_BEFORE"
echo "runtime_sha256=$RUNTIME_SHA_BEFORE"
echo "config_sha256=$CONFIG_SHA_BEFORE"
echo "runtime_db_sha256=$DB_SHA_BEFORE"
echo "ssh_key_mode=$KEY_MODE"

sudo -n python3 - "$CONFIG" > "$EVIDENCE/router-sanitized-inventory.json" <<'PY'
import json
import sys
import tomllib
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as fh:
    cfg = tomllib.load(fh)
runtime = cfg.get("runtime", {})
coders = {}
for name, item in sorted(cfg.get("coders", {}).items()):
    coders[name] = {
        "adapter": item.get("adapter"),
        "binary": item.get("binary"),
        "model": item.get("model"),
        "reasoning": item.get("reasoning"),
        "mode": item.get("mode"),
        "enabled": item.get("enabled", True),
        "max_concurrency": item.get("max_concurrency", 1),
        "allowed_projects": item.get("allowed_projects", ["*"]),
        "sandbox": item.get("sandbox"),
    }
projects = {}
for name, item in sorted(cfg.get("projects", {}).items()):
    projects[name] = {
        "repo_path": item.get("repo_path"),
        "default_write": item.get("default_write"),
        "default_read": item.get("default_read"),
        "allowed_write": item.get("allowed_write", []),
        "allowed_read": item.get("allowed_read", []),
        "max_write_lanes": item.get("max_write_lanes"),
        "routes": item.get("routes", {}),
    }
print(json.dumps({
    "runtime": {
        "max_global_workers": runtime.get("max_global_workers"),
        "max_write_workers": runtime.get("max_write_workers"),
        "max_gate_workers": runtime.get("max_gate_workers"),
        "heartbeat_interval_seconds": runtime.get("heartbeat_interval_seconds"),
        "stale_after_seconds": runtime.get("stale_after_seconds"),
        "hermes": {
            "enabled": runtime.get("hermes", {}).get("enabled"),
            "binary": runtime.get("hermes", {}).get("binary"),
            "profile": runtime.get("hermes", {}).get("profile"),
        },
    },
    "coders": coders,
    "projects": projects,
}, indent=2, ensure_ascii=False))
PY

echo "router_sanitized_inventory=$EVIDENCE/router-sanitized-inventory.json"
if command -v codex >/dev/null 2>&1; then
  echo "control_plane_codex=$(command -v codex)"
  codex --version 2>&1 | sed 's/^/control_plane_codex_version=/' || true
  codex login status 2>&1 | sed 's/^/control_plane_codex_auth=/' || true
else
  echo "control_plane_codex=missing"
fi
[[ -f /home/ubuntu/.codex/auth.json ]] && echo "control_plane_auth_file=present" || echo "control_plane_auth_file=absent"

echo
echo "===== 2. SSH E INVENTÁRIO DO WORKER ====="
mkdir -p "$(dirname "$KNOWN_HOSTS")"
touch "$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS"

set +e
"${SSH[@]}" "EXPECTED_HOST='$WORKER_NAME' bash -s" <<'REMOTE' | tee "$EVIDENCE/worker-inventory.txt"
set -Eeuo pipefail

fail_remote() {
  echo "worker_preflight=BLOCKED"
  echo "worker_failure_code=$1"
  exit 20
}

HOST="$(hostnamectl --static 2>/dev/null || hostname)"
[[ "$HOST" == "$EXPECTED_HOST" ]] || fail_remote "HOSTNAME_MISMATCH_${HOST}"
[[ "$HOST" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || fail_remote "HOSTNAME_NOT_LOWERCASE_${HOST}"
[[ "$(id -un)" == "ubuntu" ]] || fail_remote "REMOTE_USER_NOT_UBUNTU"
sudo -n true || fail_remote "PASSWORDLESS_SUDO_UNAVAILABLE"

. /etc/os-release
ARCH="$(uname -m)"
KERNEL="$(uname -r)"
CPU="$(nproc)"
MEM_KIB="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
ROOT_FREE_KIB="$(df -Pk / | awk 'NR==2{print $4}')"

echo "worker_host=$HOST"
echo "worker_user=$(id -un)"
echo "worker_os_id=${ID:-unknown}"
echo "worker_os_version=${VERSION_ID:-unknown}"
echo "worker_arch=$ARCH"
echo "worker_kernel=$KERNEL"
echo "worker_cpu_count=$CPU"
echo "worker_mem_kib=$MEM_KIB"
echo "worker_root_free_kib=$ROOT_FREE_KIB"
echo "worker_sudo_nopasswd=PASS"

for key in kernel.unprivileged_userns_clone user.max_user_namespaces kernel.apparmor_restrict_unprivileged_userns; do
  value="$(sysctl -n "$key" 2>/dev/null || echo unavailable)"
  echo "worker_sysctl_${key//./_}=$value"
done

if unshare -Ur true >/dev/null 2>&1; then
  echo "worker_unprivileged_userns=PASS"
else
  fail_remote "UNPRIVILEGED_USERNS_FAILED"
fi

if command -v bwrap >/dev/null 2>&1; then
  echo "worker_bwrap=$(command -v bwrap)"
  if bwrap --unshare-user --uid 0 --gid 0 --ro-bind / / /bin/true >/dev/null 2>&1; then
    echo "worker_bwrap_smoke=PASS"
  else
    echo "worker_bwrap_smoke=FAIL_PREEXISTING"
  fi
else
  echo "worker_bwrap=missing"
  echo "worker_bwrap_smoke=BOOTSTRAP_REQUIRED"
fi

for command in git curl python3 jq rsync node npm codex; do
  if command -v "$command" >/dev/null 2>&1; then
    path="$(command -v "$command")"
    echo "worker_tool_${command}=$path"
    case "$command" in
      git) git --version | sed 's/^/worker_version_git=/' ;;
      curl) curl --version | head -1 | sed 's/^/worker_version_curl=/' ;;
      python3) python3 --version 2>&1 | sed 's/^/worker_version_python3=/' ;;
      node) node --version | sed 's/^/worker_version_node=/' ;;
      npm) npm --version | sed 's/^/worker_version_npm=/' ;;
      codex) codex --version 2>&1 | sed 's/^/worker_version_codex=/' ;;
    esac
  else
    echo "worker_tool_${command}=missing"
  fi
done

HTTP_CODE="$(curl -L --max-time 15 -sS -o /dev/null -w '%{http_code}' https://chatgpt.com/codex/install.sh || true)"
echo "worker_codex_installer_http=$HTTP_CODE"
[[ "$HTTP_CODE" == "200" ]] || fail_remote "CODEX_INSTALLER_NETWORK_HTTP_${HTTP_CODE}"
getent ahosts api.openai.com >/dev/null 2>&1 || fail_remote "OPENAI_DNS_FAILED"
echo "worker_openai_dns=PASS"

timedatectl show -p NTPSynchronized --value 2>/dev/null | sed 's/^/worker_ntp_synchronized=/' || true
if command -v codex >/dev/null 2>&1; then
  codex login status 2>&1 | sed 's/^/worker_codex_auth=/' || true
else
  echo "worker_codex_auth=NOT_INSTALLED"
fi

echo "worker_preflight=READY_FOR_BOOTSTRAP"
REMOTE
WORKER_RC=${PIPESTATUS[0]}
set -e

ssh-keygen -lf "$KNOWN_HOSTS" > "$EVIDENCE/worker-host-key-fingerprints.txt" 2>/dev/null || true
cat "$EVIDENCE/worker-host-key-fingerprints.txt" | sed 's/^/worker_host_key=/' || true
[[ "$WORKER_RC" -eq 0 ]] || fail "WORKER_PREFLIGHT_RC_${WORKER_RC}"

echo
echo "===== 3. READBACK — PRODUÇÃO INALTERADA ====="
TIMER_AFTER="$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
UNITS_AFTER="$(active_units)"
RUNTIME_SHA_AFTER="$(sha256sum "$RUNTIME" | awk '{print $1}')"
CONFIG_SHA_AFTER="$(sudo -n sha256sum "$CONFIG" | awk '{print $1}')"
DB_SHA_AFTER="$(sudo -n sha256sum "$DB" | awk '{print $1}')"

[[ "$TIMER_AFTER" == "$TIMER_BEFORE" ]] || fail "TIMER_CHANGED_DURING_PREFLIGHT"
[[ "$UNITS_AFTER" -eq 0 ]] || fail "UNITS_APPEARED_DURING_PREFLIGHT_${UNITS_AFTER}"
[[ "$RUNTIME_SHA_AFTER" == "$RUNTIME_SHA_BEFORE" ]] || fail "RUNTIME_CHANGED_DURING_PREFLIGHT"
[[ "$CONFIG_SHA_AFTER" == "$CONFIG_SHA_BEFORE" ]] || fail "CONFIG_CHANGED_DURING_PREFLIGHT"
[[ "$DB_SHA_AFTER" == "$DB_SHA_BEFORE" ]] || fail "DB_CHANGED_DURING_PREFLIGHT"

cat > "$EVIDENCE/result.json" <<EOF
{
  "operation": "ONCA-8X1",
  "phase": 1,
  "status": "PASS",
  "control_plane": "$(hostname -f 2>/dev/null || hostname)",
  "worker": "${WORKER_USER}@${WORKER_HOST}",
  "worker_hostname": "${WORKER_NAME}",
  "runtime_sha256": "${RUNTIME_SHA_AFTER}",
  "config_sha256": "${CONFIG_SHA_AFTER}",
  "runtime_db_sha256": "${DB_SHA_AFTER}",
  "timer": "${TIMER_AFTER}",
  "active_job_or_wake_units": ${UNITS_AFTER},
  "production_changed": false,
  "completed_at_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

(
  cd "$EVIDENCE"
  sha256sum preflight.log worker-inventory.txt worker-host-key-fingerprints.txt \
    router-sanitized-inventory.json result.json > SHA256SUMS
  sha256sum -c SHA256SUMS
)

echo
echo "OPERACAO_ONCA_8X1_PHASE1: PASS"
echo "WORKER=${WORKER_USER}@${WORKER_HOST}"
echo "WORKER_HOSTNAME=${WORKER_NAME}"
echo "EVIDENCE_DIR=$EVIDENCE"
echo "TIMER=$TIMER_AFTER"
echo "ACTIVE_JOB_OR_WAKE_UNITS=$UNITS_AFTER"
echo "PRODUCTION_CHANGED=false"
