#!/usr/bin/env bash
set -Eeuo pipefail

WT="/home/ubuntu/worktrees/zoe-coder-router-zcr19-contract"
BRANCH="fix/20-zcr19-runner-semantic-contract"
EXPECTED_HEAD="74a62de95a7353ced7f4a7ab7486f98f25990cf2"
VENV="/tmp/zcr18-builder-venv"

fail() {
  echo "ERRO: $*" >&2
  exit 1
}

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail "timer não está congelado"
[[ -d "$WT" ]] || fail "worktree inexistente: $WT"
[[ "$(git -C "$WT" branch --show-current)" == "$BRANCH" ]] || fail "branch inesperada"
[[ "$(git -C "$WT" rev-parse HEAD)" == "$EXPECTED_HEAD" ]] || fail "HEAD inesperado"
[[ -z "$(git -C "$WT" status --porcelain=v1)" ]] || fail "worktree não está limpa"
[[ -x "$VENV/bin/python" ]] || fail "venv inexistente"
gh auth status >/dev/null 2>&1 || fail "gh não autenticado"

"$VENV/bin/python" - "$WT" <<'PY'
from pathlib import Path
import sys

wt = Path(sys.argv[1])
source = wt / "src/zoe_coder_router/zoe_coder_router.py"
tests = wt / "tests/test_zcr19_semantic_contract.py"

src = source.read_text(encoding="utf-8")

anchor = '''def zcr19_preflight(workspace: Path) -> tuple[bool, dict[str, Any]]:
    evidence = zcr19_readback(workspace)
    valid = (
        evidence["timer"] == "inactive"
        and evidence["branch"] == ZCR19_BRANCH
        and evidence["head"] == ZCR19_STARTING_SHA
        and evidence["worktree_clean"]
    )
    return valid, evidence


'''

helper = '''def zcr19_preflight(workspace: Path) -> tuple[bool, dict[str, Any]]:
    evidence = zcr19_readback(workspace)
    valid = (
        evidence["timer"] == "inactive"
        and evidence["branch"] == ZCR19_BRANCH
        and evidence["head"] == ZCR19_STARTING_SHA
        and evidence["worktree_clean"]
    )
    return valid, evidence


def zcr19_preflight_result(job_id: str, preflight: dict[str, Any]) -> dict[str, Any]:
    return {
        "job_id": job_id,
        "status": "blocked",
        "run_status": "PREFLIGHT_BLOCKED",
        "semantic_status": "PREFLIGHT_BLOCKED",
        "runner_contract_status": "FAIL",
        "codex_invoked": False,
        "process_exit_code": None,
        "gate_status": "NOT_RUN",
        "mission_complete": False,
        "push_required": False,
        "readback": preflight,
    }


'''

if helper not in src:
    if anchor not in src:
        raise SystemExit("ERRO: âncora de zcr19_preflight não encontrada")
    src = src.replace(anchor, helper, 1)

old = '''            result = {
                "job_id": job_id,
                "status": "blocked",
                "run_status": "PREFLIGHT_BLOCKED",
                "semantic_status": "PREFLIGHT_BLOCKED",
                "codex_invoked": False,
                "process_exit_code": None,
                "gate_status": "FAIL",
                "mission_complete": False,
                "push_required": False,
                "readback": preflight,
            }
'''
new = '''            result = zcr19_preflight_result(job_id, preflight)
'''
if new not in src:
    if old not in src:
        raise SystemExit("ERRO: bloco de resultado do preflight não encontrado")
    src = src.replace(old, new, 1)

source.write_text(src, encoding="utf-8")

txt = tests.read_text(encoding="utf-8")
marker = "def test_preflight_result_separates_runner_contract_and_gate_status"
if marker not in txt:
    txt += '''\n\ndef test_preflight_result_separates_runner_contract_and_gate_status():
    result = router.zcr19_preflight_result(
        "job-1",
        {"head": router.ZCR19_STARTING_SHA, "branch": router.ZCR19_BRANCH,
         "worktree_clean": True, "timer": "inactive"},
    )
    assert result["runner_contract_status"] == "FAIL"
    assert result["gate_status"] == "NOT_RUN"
    assert result["codex_invoked"] is False
    assert result["mission_complete"] is False
    assert result["push_required"] is False
'''

tests.write_text(txt, encoding="utf-8")
PY

cd "$WT"
"$VENV/bin/python" -m py_compile \
  src/zoe_coder_router/zoe_coder_router.py \
  tests/test_zcr19_semantic_contract.py
"$VENV/bin/python" -m pytest -q tests/test_zcr19_semantic_contract.py
"$VENV/bin/python" -m pytest -q
git diff --check

CHANGED="$(git status --porcelain=v1 | sed -E 's/^.. //' | sed -E 's/.* -> //')"
EXPECTED_FILES=$'src/zoe_coder_router/zoe_coder_router.py\ntests/test_zcr19_semantic_contract.py'
[[ "$(printf '%s\n' "$CHANGED" | sort)" == "$(printf '%s\n' "$EXPECTED_FILES" | sort)" ]] ||
  fail "escopo divergente:\n$CHANGED"

git add \
  src/zoe_coder_router/zoe_coder_router.py \
  tests/test_zcr19_semantic_contract.py
git diff --cached --check
git commit -m "fix(runner): keep preflight gate status not run"
FINAL_SHA="$(git rev-parse HEAD)"
git push origin "$BRANCH"

cat <<EOF
ZCR20_PREFLIGHT_STATUS_FINALIZED: PASS
FINAL_SHA=$FINAL_SHA
PR_URL=https://github.com/lucaspprates/Zoe-Coder-Router/pull/21
timer=$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)
EOF
