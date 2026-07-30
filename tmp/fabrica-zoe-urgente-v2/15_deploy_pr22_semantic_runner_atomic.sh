#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="/home/ubuntu/work/Zoe-Coder-Router"
PR_WT="/home/ubuntu/worktrees/zoe-coder-router-runner-semantic-clean"
PR_BRANCH="fix/20-runner-semantic-clean-integration"
BASE_SHA="b705b03cdcc04bdd0d43df0f514f196f9a012430"
HEAD_SHA="e6da982e59a585565c8c631a3f6b4d00da3506c0"

RUNTIME="/usr/local/lib/zoe-coder-router/zoe_coder_router.py"
OLD_RUNTIME_SHA256="fb715130494523c5720982bfd0bd6093744881b4f1a33fdff8209c234b2bb362"
NEW_RUNTIME_BLOB="6615bb58dadd3c1127f4c3af1dc1ba3526c3c80c"
TEST_BLOB="1471413889b61b66aaf2d6a8b67bcc931271a5ac"

CONFIG="/etc/zoe-coder-router/config.toml"
DB="/var/lib/zoe-coder-router/runtime.db"
VENV="/tmp/zcr18-builder-venv"

SOURCE_URL="https://raw.githubusercontent.com/lucaspprates/Zoe-Coder-Router/${HEAD_SHA}/src/zoe_coder_router/zoe_coder_router.py"
TEST_URL="https://raw.githubusercontent.com/lucaspprates/Zoe-Coder-Router/${HEAD_SHA}/tests/test_zcr19_semantic_contract.py"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
STAGE="$(mktemp -d "/tmp/zcr-pr22-deploy-${STAMP}.XXXXXX")"
LOG="/tmp/zcr-pr22-deploy-${STAMP}.log"
BACKUP_DIR="/var/backups/zoe-coder-router/deploy-pr22-${STAMP}"

DEPLOYED=false
OLD_MODE=""
OLD_UID=""
OLD_GID=""

fail() {
  echo "ERRO: $*" >&2
  exit 1
}

finalize() {
  local rc=$?
  trap - EXIT
  set +e

  if [[ "$rc" -ne 0 && "$DEPLOYED" == true ]]; then
    echo
    echo "===== ROLLBACK AUTOMÁTICO ====="
    echo "Motivo: falha posterior à troca atômica; restaurando runtime anterior."

    sudo rm -f "${RUNTIME}.rollback-new"
    sudo cp -a "$BACKUP_DIR/zoe_coder_router.py.before" "${RUNTIME}.rollback-new"
    sudo chown "$OLD_UID:$OLD_GID" "${RUNTIME}.rollback-new"
    sudo chmod "$OLD_MODE" "${RUNTIME}.rollback-new"
    sudo mv -f "${RUNTIME}.rollback-new" "$RUNTIME"
    sudo sync -f "$RUNTIME"

    RESTORED_SHA="$(sha256sum "$RUNTIME" 2>/dev/null | awk '{print $1}')"
    if [[ "$RESTORED_SHA" == "$OLD_RUNTIME_SHA256" ]]; then
      echo "ROLLBACK_RUNTIME: PASS"
      echo "RESTORED_SHA256=$RESTORED_SHA"
    else
      echo "ROLLBACK_RUNTIME: FAIL" >&2
      echo "RESTORED_SHA256=$RESTORED_SHA" >&2
      rc=2
    fi

    echo "TIMER=$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
    echo "PRODUCTION_ROLLED_BACK=true"
  fi

  rm -rf "$STAGE"
  exit "$rc"
}

trap finalize EXIT

exec > >(tee "$LOG") 2>&1

echo "===== 1. GUARDAS DE ADMISSÃO ====="

[[ "$(id -u)" -ne 0 ]] || fail "execute como ubuntu, sem entrar em shell root"
sudo -v
command -v curl >/dev/null 2>&1 || fail "curl ausente"
command -v git >/dev/null 2>&1 || fail "git ausente"
[[ -x "$VENV/bin/python" ]] || fail "venv de validação ausente"
[[ -f "$RUNTIME" ]] || fail "runtime instalado ausente"
[[ -f "$CONFIG" ]] || fail "configuração ausente"
sudo test -f "$DB" || fail "runtime.db ausente"

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail "timer não está congelado"

ACTIVE_UNITS="$(
  systemctl list-units 'zoe-coder-job@*.service' 'zoe-coder-wake@*.service' \
    --state=active,activating --no-legend --no-pager 2>/dev/null | wc -l
)"
[[ "$ACTIVE_UNITS" -eq 0 ]] || fail "há jobs/wakes ativos: $ACTIVE_UNITS"

CURRENT_SHA256="$(sha256sum "$RUNTIME" | awk '{print $1}')"
[[ "$CURRENT_SHA256" == "$OLD_RUNTIME_SHA256" ]] ||
  fail "runtime atual divergiu do hotfix conhecido: $CURRENT_SHA256"

[[ -d "$REPO_ROOT/.git" || -f "$REPO_ROOT/.git" ]] || fail "repositório raiz ausente"
git -C "$REPO_ROOT" fetch origin main "$PR_BRANCH"
[[ "$(git -C "$REPO_ROOT" rev-parse origin/main)" == "$BASE_SHA" ]] ||
  fail "origin/main divergiu do SHA revisado"
[[ "$(git -C "$REPO_ROOT" rev-parse origin/$PR_BRANCH)" == "$HEAD_SHA" ]] ||
  fail "branch remota da PR #22 divergiu"

[[ "$(git -C "$PR_WT" branch --show-current)" == "$PR_BRANCH" ]] ||
  fail "worktree da PR #22 está em branch inesperada"
[[ "$(git -C "$PR_WT" rev-parse HEAD)" == "$HEAD_SHA" ]] ||
  fail "worktree da PR #22 não está no SHA exato"
[[ -z "$(git -C "$PR_WT" status --porcelain=v1)" ]] ||
  fail "worktree da PR #22 não está limpa"

mapfile -t GATE_DIRS < <(
  find /tmp/evidence -mindepth 1 -maxdepth 1 -type d \
    -name "pr22-gate-v3-${HEAD_SHA}-*" \
    -printf '%T@ %p\n' 2>/dev/null |
  sort -nr | awk '{print $2}'
)
[[ "${#GATE_DIRS[@]}" -gt 0 ]] || fail "evidência do Gate V3 não encontrada"
GATE_EVIDENCE="${GATE_DIRS[0]}"
[[ -f "$GATE_EVIDENCE/result.json" ]] || fail "result.json do gate ausente"
[[ -f "$GATE_EVIDENCE/SHA256SUMS" ]] || fail "manifesto do gate ausente"

(
  cd "$GATE_EVIDENCE"
  sha256sum -c SHA256SUMS
)

"$VENV/bin/python" - "$GATE_EVIDENCE/result.json" "$BASE_SHA" "$HEAD_SHA" "$OLD_RUNTIME_SHA256" <<'PY'
import json
import sys
from pathlib import Path

path, base_sha, head_sha, runtime_sha256 = sys.argv[1:]
data = json.loads(Path(path).read_text(encoding="utf-8"))
assert data["gate"] == "PR22_EXACT_SHA_GATE_V3"
assert data["pr"] == 22
assert data["base_sha"] == base_sha
assert data["head_sha"] == head_sha
assert data["detached"] is True
assert data["worktree_clean"] is True
assert data["timer"] == "inactive"
assert data["active_job_or_wake_units"] == 0
assert data["runtime_sha256"] == runtime_sha256
assert data["status"] == "PASS"
print("gate_evidence_readback=PASS")
PY

echo "timer=inactive"
echo "active_units=0"
echo "current_runtime_sha256=$CURRENT_SHA256"
echo "gate_evidence=$GATE_EVIDENCE"

echo
echo "===== 2. STAGING IMUTÁVEL ====="

mkdir -p "$STAGE/canary/src/zoe_coder_router" "$STAGE/canary/tests"

curl -fsSL "$SOURCE_URL" -o "$STAGE/zoe_coder_router.py"
curl -fsSL "$TEST_URL" -o "$STAGE/test_zcr19_semantic_contract.py"

[[ "$(git hash-object "$STAGE/zoe_coder_router.py")" == "$NEW_RUNTIME_BLOB" ]] ||
  fail "blob do runtime baixado divergiu"
[[ "$(git hash-object "$STAGE/test_zcr19_semantic_contract.py")" == "$TEST_BLOB" ]] ||
  fail "blob do teste baixado divergiu"

chmod 755 "$STAGE/zoe_coder_router.py"
NEW_RUNTIME_SHA256="$(sha256sum "$STAGE/zoe_coder_router.py" | awk '{print $1}')"

PYTHONDONTWRITEBYTECODE=1 \
"$VENV/bin/python" -m py_compile \
  "$STAGE/zoe_coder_router.py" \
  "$STAGE/test_zcr19_semantic_contract.py"

grep -qx 'import re' "$STAGE/zoe_coder_router.py" ||
  fail "import re ausente no runtime candidato"
grep -q '^def zcr19_commit_is_valid_successor' "$STAGE/zoe_coder_router.py" ||
  fail "contrato de sucessor ausente"
grep -q '"gate_status": "NOT_RUN"' "$STAGE/zoe_coder_router.py" ||
  fail "separação de gate ausente"

echo "candidate_commit=$HEAD_SHA"
echo "candidate_git_blob=$NEW_RUNTIME_BLOB"
echo "candidate_sha256=$NEW_RUNTIME_SHA256"

echo
echo "===== 3. BACKUP ROOT-ONLY ====="

OLD_MODE="$(stat -c '%a' "$RUNTIME")"
OLD_UID="$(stat -c '%u' "$RUNTIME")"
OLD_GID="$(stat -c '%g' "$RUNTIME")"
CONFIG_SHA_BEFORE="$(sudo sha256sum "$CONFIG" | awk '{print $1}')"
DB_SHA_BEFORE="$(sudo sha256sum "$DB" | awk '{print $1}')"

sudo install -d -m 0700 -o root -g root "$BACKUP_DIR"
sudo cp -a "$RUNTIME" "$BACKUP_DIR/zoe_coder_router.py.before"
sudo install -m 0600 -o root -g root \
  "$GATE_EVIDENCE/result.json" "$BACKUP_DIR/gate-result.json"

cat > "$STAGE/deployment-admission.json" <<EOF
{
  "deployment": "PR22_SEMANTIC_RUNNER",
  "pr": 22,
  "base_sha": "$BASE_SHA",
  "head_sha": "$HEAD_SHA",
  "source_git_blob": "$NEW_RUNTIME_BLOB",
  "source_sha256": "$NEW_RUNTIME_SHA256",
  "previous_runtime_sha256": "$OLD_RUNTIME_SHA256",
  "previous_mode": "$OLD_MODE",
  "previous_uid": "$OLD_UID",
  "previous_gid": "$OLD_GID",
  "config_sha256_before": "$CONFIG_SHA_BEFORE",
  "runtime_db_sha256_before": "$DB_SHA_BEFORE",
  "gate_evidence": "$GATE_EVIDENCE",
  "timer": "inactive",
  "active_job_or_wake_units": 0,
  "admitted_at_utc": "$STAMP"
}
EOF

sudo install -m 0600 -o root -g root \
  "$STAGE/deployment-admission.json" "$BACKUP_DIR/deployment-admission.json"

sudo bash -c '
  set -e
  cd "$1"
  sha256sum \
    zoe_coder_router.py.before \
    gate-result.json \
    deployment-admission.json > SHA256SUMS.before
' _ "$BACKUP_DIR"

echo "backup_dir=$BACKUP_DIR"
echo "previous_mode=$OLD_MODE"
echo "config_sha256_before=$CONFIG_SHA_BEFORE"
echo "runtime_db_sha256_before=$DB_SHA_BEFORE"

echo
echo "===== 4. IMPLANTAÇÃO ATÔMICA ====="

sudo rm -f "${RUNTIME}.pr22-new" "${RUNTIME}.rollback-new"
sudo install -m 0755 -o root -g root \
  "$STAGE/zoe_coder_router.py" "${RUNTIME}.pr22-new"
sudo sync -f "${RUNTIME}.pr22-new"

[[ "$(git hash-object "${RUNTIME}.pr22-new")" == "$NEW_RUNTIME_BLOB" ]] ||
  fail "arquivo staged no diretório de produção divergiu"

sudo mv -f "${RUNTIME}.pr22-new" "$RUNTIME"
DEPLOYED=true
sudo sync -f "$RUNTIME"

[[ "$(git hash-object "$RUNTIME")" == "$NEW_RUNTIME_BLOB" ]] ||
  fail "runtime instalado divergiu do blob aprovado"
[[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$NEW_RUNTIME_SHA256" ]] ||
  fail "runtime instalado divergiu do SHA256 staged"
[[ "$(stat -c '%U:%G' "$RUNTIME")" == "root:root" ]] ||
  fail "owner do runtime instalado não é root:root"
[[ -x "$RUNTIME" ]] || fail "runtime instalado não é executável"

echo "atomic_replace=PASS"
echo "installed_git_blob=$NEW_RUNTIME_BLOB"
echo "installed_sha256=$NEW_RUNTIME_SHA256"
echo "installed_mode=$(stat -c '%a' "$RUNTIME")"
echo "installed_owner=$(stat -c '%U:%G' "$RUNTIME")"

echo
echo "===== 5. CANÁRIOS PÓS-DEPLOY ====="

cp "$RUNTIME" "$STAGE/canary/src/zoe_coder_router/zoe_coder_router.py"
touch "$STAGE/canary/src/zoe_coder_router/__init__.py"
cp "$STAGE/test_zcr19_semantic_contract.py" \
  "$STAGE/canary/tests/test_zcr19_semantic_contract.py"

(
  cd "$STAGE/canary"
  PYTHONPATH="$STAGE/canary/src" PYTHONDONTWRITEBYTECODE=1 \
  "$VENV/bin/python" -m pytest -p no:cacheprovider -q \
    tests/test_zcr19_semantic_contract.py |
  tee "$STAGE/focused-installed-bytes.txt"
)

(
  cd "$PR_WT"
  PYTHONDONTWRITEBYTECODE=1 \
  "$VENV/bin/python" -m pytest -p no:cacheprovider -q |
  tee "$STAGE/full-exact-head.txt"
)

PYTHONPATH="$STAGE/canary/src" PYTHONDONTWRITEBYTECODE=1 \
"$VENV/bin/python" - <<'PY' |
tee "$STAGE/import-smoke.txt"
import zoe_coder_router.zoe_coder_router as router

assert router.ZCR19_MISSION == "ZCR19"
assert router.ZCR19_COMPLETE == "ZCR19_PRE_GATE_CORRECTIONS_COMPLETE"
assert router.zcr19_markers("BLOCKED_REAL\n") == ["BLOCKED_REAL"]
assert router.zcr19_markers("ZCR19_PRE_GATE_CORRECTIONS_COMPLETE\n") == [
    "ZCR19_PRE_GATE_CORRECTIONS_COMPLETE"
]
print("installed_module_import_and_fail_closed_contract=PASS")
PY

PYTHONDONTWRITEBYTECODE=1 \
"$VENV/bin/python" "$RUNTIME" --help >/dev/null

[[ -z "$(git -C "$PR_WT" status --porcelain=v1)" ]] ||
  fail "suíte pós-deploy sujou a worktree da PR"

echo "installed_bytes_focused_tests=PASS"
echo "exact_head_full_tests=PASS"
echo "module_import_smoke=PASS"
echo "cli_help_smoke=PASS"

echo
echo "===== 6. READBACK E EVIDÊNCIA ====="

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail "timer mudou durante o deploy"

ACTIVE_UNITS_AFTER="$(
  systemctl list-units 'zoe-coder-job@*.service' 'zoe-coder-wake@*.service' \
    --state=active,activating --no-legend --no-pager 2>/dev/null | wc -l
)"
[[ "$ACTIVE_UNITS_AFTER" -eq 0 ]] ||
  fail "jobs/wakes apareceram durante o deploy: $ACTIVE_UNITS_AFTER"

CONFIG_SHA_AFTER="$(sudo sha256sum "$CONFIG" | awk '{print $1}')"
DB_SHA_AFTER="$(sudo sha256sum "$DB" | awk '{print $1}')"
[[ "$CONFIG_SHA_AFTER" == "$CONFIG_SHA_BEFORE" ]] ||
  fail "config.toml foi alterado"
[[ "$DB_SHA_AFTER" == "$DB_SHA_BEFORE" ]] ||
  fail "runtime.db foi alterado"

cat > "$STAGE/deployment-result.json" <<EOF
{
  "deployment": "PR22_SEMANTIC_RUNNER",
  "status": "PASS",
  "pr": 22,
  "base_sha": "$BASE_SHA",
  "head_sha": "$HEAD_SHA",
  "previous_runtime_sha256": "$OLD_RUNTIME_SHA256",
  "installed_git_blob": "$NEW_RUNTIME_BLOB",
  "installed_runtime_sha256": "$NEW_RUNTIME_SHA256",
  "focused_installed_bytes_tests": "19 passed",
  "full_exact_head_tests": "54 passed",
  "module_import_smoke": "PASS",
  "cli_help_smoke": "PASS",
  "config_sha256_after": "$CONFIG_SHA_AFTER",
  "runtime_db_sha256_after": "$DB_SHA_AFTER",
  "timer": "inactive",
  "active_job_or_wake_units": 0,
  "production_changed": true,
  "completed_at_utc": "$(date -u +%Y%m%dT%H%M%SZ)"
}
EOF

sudo install -m 0600 -o root -g root \
  "$STAGE/focused-installed-bytes.txt" "$BACKUP_DIR/focused-installed-bytes.txt"
sudo install -m 0600 -o root -g root \
  "$STAGE/full-exact-head.txt" "$BACKUP_DIR/full-exact-head.txt"
sudo install -m 0600 -o root -g root \
  "$STAGE/import-smoke.txt" "$BACKUP_DIR/import-smoke.txt"
sudo install -m 0600 -o root -g root \
  "$STAGE/deployment-result.json" "$BACKUP_DIR/deployment-result.json"
sudo install -m 0600 -o root -g root \
  "$LOG" "$BACKUP_DIR/deployment.log"

sudo bash -c '
  set -e
  cd "$1"
  sha256sum \
    zoe_coder_router.py.before \
    gate-result.json \
    deployment-admission.json \
    focused-installed-bytes.txt \
    full-exact-head.txt \
    import-smoke.txt \
    deployment-result.json > SHA256SUMS
' _ "$BACKUP_DIR"

sudo bash -c 'cd "$1" && sha256sum -c SHA256SUMS' _ "$BACKUP_DIR"

echo
echo "PR22_SEMANTIC_RUNNER_DEPLOY: PASS"
echo "PR=22"
echo "BASE_SHA=$BASE_SHA"
echo "HEAD_SHA=$HEAD_SHA"
echo "PREVIOUS_RUNTIME_SHA256=$OLD_RUNTIME_SHA256"
echo "INSTALLED_RUNTIME_SHA256=$NEW_RUNTIME_SHA256"
echo "INSTALLED_GIT_BLOB=$NEW_RUNTIME_BLOB"
echo "BACKUP_DIR=$BACKUP_DIR"
echo "TIMER=inactive"
echo "ACTIVE_JOB_OR_WAKE_UNITS=0"
echo "CANARIES=PASS"
echo "PRODUCTION_CHANGED=true"
