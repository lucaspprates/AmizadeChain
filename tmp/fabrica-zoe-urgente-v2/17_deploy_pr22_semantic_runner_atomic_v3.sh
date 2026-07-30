#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE="/tmp/16_deploy_pr22_semantic_runner_atomic_v2.sh"
SOURCE_BLOB="55cb70fcafaa5d32beeaa774f6a6a251a2669a88"
PATCHED="/tmp/17_deploy_pr22_semantic_runner_atomic_v3.generated.sh"

RUNTIME="/usr/local/lib/zoe-coder-router/zoe_coder_router.py"
SAFE_RUNTIME_SHA256="fb715130494523c5720982bfd0bd6093744881b4f1a33fdff8209c234b2bb362"

fail() {
  echo "ERRO: $*" >&2
  exit 1
}

echo "===== 0. GUARDAS DO PATCHER V3 ====="

[[ "$(id -u)" -ne 0 ]] || fail "execute como ubuntu, sem shell root"
[[ -f "$SOURCE" ]] || fail "deploy V2 ausente: $SOURCE"
[[ "$(git hash-object "$SOURCE")" == "$SOURCE_BLOB" ]] ||
  fail "deploy V2 divergiu do blob imutável esperado"

[[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$SAFE_RUNTIME_SHA256" ]] ||
  fail "runtime não está no SHA seguro após rollback"
[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail "timer não está inativo"

ACTIVE_UNITS="$(
  systemctl list-units 'zoe-coder-job@*.service' 'zoe-coder-wake@*.service' \
    --state=active,activating --no-legend --no-pager 2>/dev/null | wc -l
)"
[[ "$ACTIVE_UNITS" -eq 0 ]] || fail "há jobs/wakes ativos: $ACTIVE_UNITS"

echo "source_v2_blob=$SOURCE_BLOB"
echo "runtime_safe_sha256=$SAFE_RUNTIME_SHA256"
echo "timer=inactive"
echo "active_units=0"

echo
echo "===== 1. PATCH ÚNICO E DETERMINÍSTICO ====="

python3 - "$SOURCE" "$PATCHED" <<'PATCHPY'
from pathlib import Path
import sys

source = Path(sys.argv[1])
target = Path(sys.argv[2])
text = source.read_text(encoding="utf-8")

old = r'''PYTHONPATH="$STAGE/canary/src" PYTHONDONTWRITEBYTECODE=1 \
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
'''

new = r'''PYTHONPATH="$STAGE/canary/src" PYTHONDONTWRITEBYTECODE=1 \
"$VENV/bin/python" - <<'PY' > "$STAGE/import-smoke.txt"
import zoe_coder_router.zoe_coder_router as router

assert router.ZCR19_MISSION == "ZCR19"
assert router.ZCR19_COMPLETE == "ZCR19_PRE_GATE_CORRECTIONS_COMPLETE"
assert router.zcr19_markers("BLOCKED_REAL\n") == ["BLOCKED_REAL"]
assert router.zcr19_markers("ZCR19_PRE_GATE_CORRECTIONS_COMPLETE\n") == [
    "ZCR19_PRE_GATE_CORRECTIONS_COMPLETE"
]
print("installed_module_import_and_fail_closed_contract=PASS")
PY
cat "$STAGE/import-smoke.txt"
'''

count = text.count(old)
if count != 1:
    raise SystemExit(f"ERRO: bloco vulnerável esperado exatamente uma vez; encontrado={count}")

patched = text.replace(old, new, 1)

if patched.count(new) != 1:
    raise SystemExit("ERRO: bloco corrigido não foi materializado exatamente uma vez")
if 'tee "$STAGE/import-smoke.txt"\nimport zoe_coder_router' in patched:
    raise SystemExit("ERRO: forma vulnerável ainda presente")
if patched.count("PR22_SEMANTIC_RUNNER_DEPLOY_V2: PASS") != 1:
    raise SystemExit("ERRO: contrato terminal do deploy V2 divergiu")

target.write_text(patched, encoding="utf-8")
PATCHPY

chmod 700 "$PATCHED"
bash -n "$PATCHED"

PATCHED_BLOB="$(git hash-object "$PATCHED")"
PATCHED_SHA256="$(sha256sum "$PATCHED" | awk '{print $1}')"

echo "patch_count=1"
echo "patched_blob=$PATCHED_BLOB"
echo "patched_sha256=$PATCHED_SHA256"
echo "bash_n=PASS"

echo
echo "===== 2. DEPLOY COMPLETO COM ROLLBACK ====="

"$PATCHED"

echo
echo "PR22_SEMANTIC_RUNNER_DEPLOY_V3_PATCHER: PASS"
echo "PATCHED_FROM_BLOB=$SOURCE_BLOB"
echo "PATCHED_BLOB=$PATCHED_BLOB"
echo "TIMER=$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
echo "PRODUCTION_CHANGED=true"
