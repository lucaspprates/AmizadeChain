#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

WORKER_HOST="201.23.86.157"
WORKER_USER="ubuntu"
WORKER_NAME="win-codex-wak-01"
SSH_KEY="/home/ubuntu/.ssh/ssh-key-2026-06-03.key"
KNOWN_HOSTS="/home/ubuntu/.ssh/known_hosts_onca_8x1"
WORKTREE="/home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler"
BRANCH="type/18-factory-scheduler-maintenance"
EXPECTED_HEAD="fc2329960d2dffb301b9ad1bde9f7ea5b4789795"
RUNTIME="/usr/local/lib/zoe-coder-router/zoe_coder_router.py"
CONFIG="/etc/zoe-coder-router/config.toml"
BRIDGE="/usr/local/bin/onca-codex-remote"
EXPECTED_RUNTIME_SHA256="f181fd627dceff10d46d23598eb54d8cfb5a15b070231aa34b4c09e907fc7d85"
EXPECTED_CONFIG_SHA256="3af46a9069e406a75b8e3e66368fa3a2c688711616bc86a5df12d9e4135595e4"
EXPECTED_BRIDGE_SHA256="4d37ed3baba38dc5d35ac9e11928dd0969dd5e7fbdf3c0f4c3e4af2acafdd4b6"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="/tmp/evidence/onca-worker-gate-toolchain-${STAMP}"
mkdir -p "$EVIDENCE"

fail() {
  echo "ERRO: $*" >&2
  echo "ONCA_WORKER_GATE_TOOLCHAIN: BLOCKED"
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

[[ "$(id -un)" == "ubuntu" ]] || fail "execute como ubuntu"
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail "host de controle inesperado"
sudo -v

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] || fail "timer não está inactive"
[[ "$(active_units)" -eq 0 ]] || fail "há units ativas"
[[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$EXPECTED_RUNTIME_SHA256" ]] || fail "runtime divergente"
[[ "$(sudo sha256sum "$CONFIG" | awk '{print $1}')" == "$EXPECTED_CONFIG_SHA256" ]] || fail "config divergente"
[[ "$(sha256sum "$BRIDGE" | awk '{print $1}')" == "$EXPECTED_BRIDGE_SHA256" ]] || fail "bridge divergente"
[[ "$(git -C "$WORKTREE" branch --show-current)" == "$BRANCH" ]] || fail "branch divergente"
[[ "$(git -C "$WORKTREE" rev-parse HEAD)" == "$EXPECTED_HEAD" ]] || fail "HEAD divergente"
[[ -z "$(git -C "$WORKTREE" status --porcelain=v1 --untracked-files=all)" ]] || fail "worktree suja"

git -C "$WORKTREE" fetch -q origin "$BRANCH"
[[ "$(git -C "$WORKTREE" rev-parse "origin/$BRANCH")" == "$EXPECTED_HEAD" ]] || fail "origin divergente"

SSH=(ssh -i "$SSH_KEY" -o BatchMode=yes -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=20
  "${WORKER_USER}@${WORKER_HOST}")

"${SSH[@]}" 'bash -s' <<'REMOTE' | tee "$EVIDENCE/worker-toolchain.log"
set -Eeuo pipefail
cd /
test "$(hostname -s)" = "win-codex-wak-01"
sudo -n true
id onca-runner

printf 'before_pytest='; python3 -m pytest --version 2>/dev/null || echo absent
printf 'before_rg='; rg --version 2>/dev/null | head -1 || echo absent

sudo apt-get update -qq
sudo env DEBIAN_FRONTEND=noninteractive \
  apt-get install -y --no-install-recommends python3-pytest ripgrep

python3 -m pytest --version
rg --version | head -1

sudo -u onca-runner -H bash -lc '
  set -Eeuo pipefail
  cd /
  python3 -m pytest --version
  rg --version | head -1
  codex --version
  codex login status
'

printf 'pytest_package='; dpkg-query -W -f='${Version}\n' python3-pytest
printf 'ripgrep_package='; dpkg-query -W -f='${Version}\n' ripgrep
printf 'worker_host='; hostname -s
printf 'runner_uid='; id -u onca-runner
printf 'runner_gid='; id -g onca-runner
printf 'WORKER_GATE_TOOLCHAIN_READY=PASS\n'
REMOTE

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] || fail "timer mudou"
[[ "$(active_units)" -eq 0 ]] || fail "units apareceram"
[[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$EXPECTED_RUNTIME_SHA256" ]] || fail "runtime mudou"
[[ "$(sudo sha256sum "$CONFIG" | awk '{print $1}')" == "$EXPECTED_CONFIG_SHA256" ]] || fail "config mudou"
[[ "$(sha256sum "$BRIDGE" | awk '{print $1}')" == "$EXPECTED_BRIDGE_SHA256" ]] || fail "bridge mudou"
[[ "$(git -C "$WORKTREE" rev-parse HEAD)" == "$EXPECTED_HEAD" ]] || fail "HEAD mudou"
[[ -z "$(git -C "$WORKTREE" status --porcelain=v1 --untracked-files=all)" ]] || fail "worktree mudou"

sha256sum "$EVIDENCE/worker-toolchain.log" > "$EVIDENCE/SHA256SUMS"

cat <<EOF
ONCA_WORKER_GATE_TOOLCHAIN: PASS
WORKER=$WORKER_NAME
PYTEST=installed
RIPGREP=installed
RUN_USER=onca-runner
CONTROL_RUNTIME_CHANGED=false
CONTROL_CONFIG_CHANGED=false
CONTROL_BRIDGE_CHANGED=false
WORKTREE_CHANGED=false
TIMER=inactive
ACTIVE_UNITS=0
EVIDENCE_DIR=$EVIDENCE
NEXT_PHASE=ZCR19_GATE_FINDING_CORRECTION
EOF
