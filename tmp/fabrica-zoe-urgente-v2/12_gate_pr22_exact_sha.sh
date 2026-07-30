#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/home/ubuntu/work/Zoe-Coder-Router"
GATE_WT="/home/ubuntu/worktrees/zoe-coder-router-pr22-gate-e6da982"
BRANCH="fix/20-runner-semantic-clean-integration"
BASE_SHA="b705b03cdcc04bdd0d43df0f514f196f9a012430"
HEAD_SHA="e6da982e59a585565c8c631a3f6b4d00da3506c0"
VENV="/tmp/zcr18-builder-venv"
RUNTIME="/usr/local/lib/zoe-coder-router/zoe_coder_router.py"
RUNTIME_SHA="fb715130494523c5720982bfd0bd6093744881b4f1a33fdff8209c234b2bb362"
EVIDENCE="/tmp/evidence/pr22-gate-${HEAD_SHA}"

fail() {
  echo "ERRO: $*" >&2
  exit 1
}

cleanup_on_error() {
  if [[ -d "$GATE_WT" ]]; then
    git -C "$ROOT" worktree remove --force "$GATE_WT" >/dev/null 2>&1 || true
  fi
}
trap cleanup_on_error ERR

mkdir -p "$EVIDENCE"

exec > >(tee "$EVIDENCE/gate.log") 2>&1

echo "===== 1. GUARDAS ====="

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail "timer não está congelado"

ACTIVE_UNITS="$(
  systemctl list-units 'zoe-coder-job@*.service' 'zoe-coder-wake@*.service' \
    --state=active,activating --no-legend --no-pager 2>/dev/null | wc -l
)"
[[ "$ACTIVE_UNITS" -eq 0 ]] || fail "há jobs/wakes ativos: $ACTIVE_UNITS"

[[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$RUNTIME_SHA" ]] ||
  fail "runtime instalado divergiu"
[[ -x "$VENV/bin/python" ]] || fail "venv ausente"
[[ -d "$ROOT/.git" || -f "$ROOT/.git" ]] || fail "repositório raiz ausente"
[[ ! -e "$GATE_WT" ]] || fail "worktree de gate já existe: $GATE_WT"

echo "timer=inactive"
echo "active_units=0"
echo "runtime_sha256=$RUNTIME_SHA"

echo
echo "===== 2. SHA REMOTO E WORKTREE DETACHED ====="

git -C "$ROOT" fetch origin main "$BRANCH"

REMOTE_HEAD="$(git -C "$ROOT" rev-parse "origin/$BRANCH")"
[[ "$REMOTE_HEAD" == "$HEAD_SHA" ]] || fail "head remoto inesperado: $REMOTE_HEAD"
[[ "$(git -C "$ROOT" rev-parse origin/main)" == "$BASE_SHA" ]] || fail "base remota divergiu"

git -C "$ROOT" worktree add --detach "$GATE_WT" "$HEAD_SHA"

[[ "$(git -C "$GATE_WT" rev-parse HEAD)" == "$HEAD_SHA" ]] || fail "gate não está no SHA exato"
[[ -z "$(git -C "$GATE_WT" branch --show-current)" ]] || fail "gate não está detached"
[[ -z "$(git -C "$GATE_WT" status --porcelain=v1)" ]] || fail "worktree de gate nasceu suja"

git -C "$GATE_WT" merge-base --is-ancestor "$BASE_SHA" "$HEAD_SHA" ||
  fail "head não descende da base"

CHANGED="$(git -C "$GATE_WT" diff --name-only "$BASE_SHA"..."$HEAD_SHA" | sort)"
EXPECTED=$'src/zoe_coder_router/zoe_coder_router.py\ntests/test_zcr19_semantic_contract.py'
[[ "$CHANGED" == "$EXPECTED" ]] || fail "escopo inesperado:\n$CHANGED"

printf '%s\n' "$CHANGED" > "$EVIDENCE/changed-files.txt"

echo "base_sha=$BASE_SHA"
echo "head_sha=$HEAD_SHA"
echo "detached=true"
echo "changed_files=2"

echo
echo "===== 3. REVISÃO DE CONTRATO ====="

cd "$GATE_WT"

SOURCE="src/zoe_coder_router/zoe_coder_router.py"
TESTS="tests/test_zcr19_semantic_contract.py"

[[ "$(stat -c '%a' "$SOURCE")" == "755" ]] || fail "modo do runtime não é 755"
grep -qx 'import re' "$SOURCE" || fail "import re ausente"
grep -q '^def zcr19_commit_is_valid_successor' "$SOURCE" || fail "verificação de sucessor ausente"
grep -q 'merge-base.*--is-ancestor' "$SOURCE" || fail "ancestralidade não é verificada"
grep -q 'git.*diff.*--quiet' "$SOURCE" || fail "delta material não é verificado"
grep -q '"runner_contract_status"' "$SOURCE" || fail "runner_contract_status ausente"
grep -q '"gate_status": "NOT_RUN"' "$SOURCE" || fail "gate_status não está separado"
grep -q 'process_exit_code=None' "$SOURCE" || fail "preflight simula exit code"
grep -q 'test_success_rejects_non_descendant_and_empty_commits' "$TESTS" || fail "teste de commit inválido ausente"
grep -q 'test_preflight_factory_event_has_no_process_exit_code' "$TESTS" || fail "teste de preflight ausente"

echo "contract_static_review=PASS"

echo
echo "===== 4. TESTES INDEPENDENTES ====="

PYTHONDONTWRITEBYTECODE=1 \
"$VENV/bin/python" -m py_compile "$SOURCE" "$TESTS"

git diff --check "$BASE_SHA"..."$HEAD_SHA"

PYTHONDONTWRITEBYTECODE=1 \
"$VENV/bin/python" -m pytest -p no:cacheprovider -q "$TESTS" |
  tee "$EVIDENCE/focused-tests.txt"

PYTHONDONTWRITEBYTECODE=1 \
"$VENV/bin/python" -m pytest -p no:cacheprovider -q |
  tee "$EVIDENCE/full-tests.txt"

PYTHONDONTWRITEBYTECODE=1 \
"$VENV/bin/python" - <<'PY'
import zoe_coder_router.zoe_coder_router as router
assert router.ZCR19_MISSION == "ZCR19"
assert router.ZCR19_COMPLETE == "ZCR19_PRE_GATE_CORRECTIONS_COMPLETE"
assert router.zcr19_markers("BLOCKED_REAL\n") == ["BLOCKED_REAL"]
print("module_import_and_contract_smoke=PASS")
PY

[[ -z "$(git status --porcelain=v1)" ]] || fail "testes sujaram a worktree"

echo
echo "===== 5. EVIDÊNCIA E READBACK ====="

cat > "$EVIDENCE/result.json" <<EOF
{
  "gate": "PR22_EXACT_SHA_GATE",
  "repository": "lucaspprates/Zoe-Coder-Router",
  "pr": 22,
  "base_sha": "$BASE_SHA",
  "head_sha": "$HEAD_SHA",
  "worktree": "$GATE_WT",
  "detached": true,
  "worktree_clean": true,
  "timer": "inactive",
  "active_job_or_wake_units": 0,
  "runtime_sha256": "$RUNTIME_SHA",
  "status": "PASS"
}
EOF

(
  cd "$EVIDENCE"
  sha256sum changed-files.txt focused-tests.txt full-tests.txt gate.log result.json > SHA256SUMS
)

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail "timer mudou durante o gate"
[[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$RUNTIME_SHA" ]] ||
  fail "runtime instalado mudou durante o gate"
[[ "$(git rev-parse HEAD)" == "$HEAD_SHA" ]] || fail "HEAD do gate mudou"
[[ -z "$(git status --porcelain=v1)" ]] || fail "worktree final não está limpa"

cat <<EOF

PR22_EXACT_SHA_GATE: PASS
PR=22
BASE_SHA=$BASE_SHA
HEAD_SHA=$HEAD_SHA
EVIDENCE_DIR=$EVIDENCE
TIMER=inactive
PRODUCTION_CHANGED=false
EOF
