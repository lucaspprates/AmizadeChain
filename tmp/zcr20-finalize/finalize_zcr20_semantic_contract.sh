#!/usr/bin/env bash
set -Eeuo pipefail

BRANCH="fix/20-zcr19-runner-semantic-contract"
EXPECTED_HEAD="d9a606e37cfa97fe76150a67957426096148e368"
BASE="type/18-factory-scheduler-maintenance"
VENV="/tmp/zcr18-builder-venv"
TARGET="/home/ubuntu/worktrees/zcr20-runner-semantic-contract"

fail() {
  echo "ERRO: $*" >&2
  exit 1
}

echo "===== 1. GUARDS ====="

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail "timer não está congelado"
[[ -x "$VENV/bin/python" ]] || fail "venv de testes inexistente"
command -v git >/dev/null 2>&1 || fail "git ausente"
command -v gh >/dev/null 2>&1 || fail "gh ausente"
gh auth status >/dev/null 2>&1 || fail "gh não autenticado"

ROOT=""
for candidate in \
  /home/ubuntu/work/Zoe-Coder-Router \
  /home/ubuntu/work/Zoe-Coder-Router-issue-11
do
  if [[ -d "$candidate/.git" || -f "$candidate/.git" ]]; then
    ROOT="$candidate"
    break
  fi
done
[[ -n "$ROOT" ]] || fail "repositório Zoe-Coder-Router não encontrado"

git -C "$ROOT" fetch origin "$BRANCH" "$BASE"

REMOTE_HEAD="$(git -C "$ROOT" rev-parse "origin/$BRANCH")"
[[ "$REMOTE_HEAD" == "$EXPECTED_HEAD" ]] ||
  fail "remote HEAD inesperado: $REMOTE_HEAD"

WT=""
while IFS= read -r git_marker; do
  path="${git_marker%/.git}"
  [[ -d "$path" ]] || continue
  if [[ "$(git -C "$path" branch --show-current 2>/dev/null || true)" == "$BRANCH" ]]; then
    WT="$path"
    break
  fi
done < <(find /home/ubuntu/work /home/ubuntu/worktrees -maxdepth 4 \
  \( -type d -o -type f \) -name .git 2>/dev/null | sort -u)

if [[ -z "$WT" ]]; then
  [[ ! -e "$TARGET" ]] || fail "target worktree já existe sem branch reconhecida: $TARGET"
  if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    LOCAL_HEAD="$(git -C "$ROOT" rev-parse "$BRANCH")"
    [[ "$LOCAL_HEAD" == "$EXPECTED_HEAD" ]] ||
      fail "branch local diverge: $LOCAL_HEAD"
    git -C "$ROOT" worktree add "$TARGET" "$BRANCH"
  else
    git -C "$ROOT" worktree add -b "$BRANCH" "$TARGET" "origin/$BRANCH"
  fi
  WT="$TARGET"
fi

[[ "$(git -C "$WT" branch --show-current)" == "$BRANCH" ]] ||
  fail "branch inesperada na worktree"
[[ "$(git -C "$WT" rev-parse HEAD)" == "$EXPECTED_HEAD" ]] ||
  fail "HEAD inesperado na worktree"
[[ -z "$(git -C "$WT" status --porcelain=v1)" ]] ||
  fail "worktree não está limpa"

echo "Root:   $ROOT"
echo "WT:     $WT"
echo "Branch: $BRANCH"
echo "HEAD:   $EXPECTED_HEAD"
echo "Timer:  inactive"

echo
echo "===== 2. PATCH SEMÂNTICO ====="

"$VENV/bin/python" - "$WT" <<'PY'
from pathlib import Path
import sys

wt = Path(sys.argv[1])
source = wt / "src/zoe_coder_router/zoe_coder_router.py"
tests = wt / "tests/test_zcr19_semantic_contract.py"

src = source.read_text(encoding="utf-8")

replacements = [
    (
        '"gate_status": "NOT_RUN" if status == "BLOCKED" else "FAIL",',
        '"gate_status": "NOT_RUN",',
        "Factory Console gate_status",
    ),
    (
        '''readback["head"] == new_sha and new_sha != ZCR19_STARTING_SHA and readback["worktree_clean"]
                and readback["timer"] == "inactive" and zcr19_commit_exists(workspace, new_sha)''',
        '''readback["head"] == new_sha and new_sha != ZCR19_STARTING_SHA
                and readback["branch"] == ZCR19_BRANCH and readback["worktree_clean"]
                and readback["timer"] == "inactive" and zcr19_commit_exists(workspace, new_sha)''',
        "post-run branch readback",
    ),
    (
        '''"process_exit_code": process_rc, "gate_status": "PASS" if semantic == "COMPLETE" else "FAIL",
        "mission_complete": semantic == "COMPLETE", "push_required": semantic == "COMPLETE",''',
        '''"process_exit_code": process_rc,
        "runner_contract_status": "PASS" if semantic == "COMPLETE" else "FAIL",
        "gate_status": "NOT_RUN",
        "mission_complete": semantic == "COMPLETE", "push_required": semantic == "COMPLETE",''',
        "runner/gate status separation",
    ),
]

for old, new, label in replacements:
    count = src.count(old)
    if count == 0 and new in src:
        print(f"{label}: já aplicado")
        continue
    if count != 1:
        raise SystemExit(f"ERRO: {label}: esperado 1 bloco, encontrado {count}")
    src = src.replace(old, new, 1)
    print(f"{label}: aplicado")

source.write_text(src, encoding="utf-8")

txt = tests.read_text(encoding="utf-8")

old = '''    assert result["gate_status"] == "FAIL"
    assert result["mission_complete"] is False and result["push_required"] is False'''
new = '''    assert result["runner_contract_status"] == "FAIL"
    assert result["gate_status"] == "NOT_RUN"
    assert result["mission_complete"] is False and result["push_required"] is False'''
if old in txt:
    txt = txt.replace(old, new, 1)
elif new not in txt:
    raise SystemExit("ERRO: teste BLOCKED não encontrado")

old = '''    assert result["semantic_status"] == "COMPLETE"
    assert result["mission_complete"] is True and result["push_required"] is True'''
new = '''    assert result["semantic_status"] == "COMPLETE"
    assert result["runner_contract_status"] == "PASS"
    assert result["gate_status"] == "NOT_RUN"
    assert result["factory_console_event"]["gate_status"] == "NOT_RUN"
    assert result["mission_complete"] is True and result["push_required"] is True'''
if old in txt:
    txt = txt.replace(old, new, 1)
elif new not in txt:
    raise SystemExit("ERRO: teste COMPLETE não encontrado")

marker = "def test_complete_branch_mismatch_fails"
if marker not in txt:
    anchor = '''def test_complete_head_mismatch_fails(tmp_path, monkeypatch):
    repo, base, new = repository(tmp_path)
    monkeypatch.setattr(router, "ZCR19_STARTING_SHA", base)
    monkeypatch.setattr(router, "ZCR19_BRANCH", "maintenance")
    monkeypatch.setattr(router, "zcr19_readback", lambda _: {"head": base, "branch": "maintenance", "worktree_clean": True, "timer": "inactive"})
    out, err = tmp_path / "out", tmp_path / "err"; out.write_text(terminal(base, new)); err.write_text("")
    assert router.zcr19_semantic_result(out, err, 0, repo)["semantic_status"] == "INVALID_TERMINAL_RESULT"


'''
    addition = '''def test_complete_branch_mismatch_fails(tmp_path, monkeypatch):
    repo, base, new = repository(tmp_path)
    monkeypatch.setattr(router, "ZCR19_STARTING_SHA", base)
    monkeypatch.setattr(router, "ZCR19_BRANCH", "maintenance")
    monkeypatch.setattr(router, "zcr19_readback", lambda _: {
        "head": new, "branch": "wrong-branch",
        "worktree_clean": True, "timer": "inactive",
    })
    out, err = tmp_path / "out", tmp_path / "err"
    out.write_text(terminal(base, new))
    err.write_text("")
    result = router.zcr19_semantic_result(out, err, 0, repo)
    assert result["semantic_status"] == "INVALID_TERMINAL_RESULT"
    assert result["failure_code"] == "POSITIVE_CONTRACT_OR_READBACK_MISMATCH"


'''
    if anchor not in txt:
        raise SystemExit("ERRO: âncora do teste de HEAD não encontrada")
    txt = txt.replace(anchor, anchor + addition, 1)

tests.write_text(txt, encoding="utf-8")
PY

echo
echo "===== 3. TESTES ====="

cd "$WT"

"$VENV/bin/python" -m py_compile \
  src/zoe_coder_router/zoe_coder_router.py \
  tests/test_zcr19_semantic_contract.py

"$VENV/bin/python" -m pytest -q tests/test_zcr19_semantic_contract.py
"$VENV/bin/python" -m pytest -q
git diff --check

echo
echo "TESTES E DIFF CHECK: PASS"

echo
echo "===== 4. ESCOPO ====="

git status --short
git diff --stat

CHANGED="$(git status --porcelain=v1 | sed -E 's/^.. //' | sed -E 's/.* -> //')"
EXPECTED_FILES=$'src/zoe_coder_router/zoe_coder_router.py\ntests/test_zcr19_semantic_contract.py'

[[ "$(printf '%s\n' "$CHANGED" | sort)" == "$(printf '%s\n' "$EXPECTED_FILES" | sort)" ]] ||
  fail "escopo divergente:
$CHANGED"

echo
echo "===== 5. COMMIT E PUSH ====="

git add \
  src/zoe_coder_router/zoe_coder_router.py \
  tests/test_zcr19_semantic_contract.py

git diff --cached --check
git commit -m "fix(runner): close ZCR19 semantic readback gaps"

FINAL_SHA="$(git rev-parse HEAD)"
git push origin "$BRANCH"

echo
echo "===== 6. DRAFT PR ====="

PR_URL="$(
  gh pr list \
    --head "$BRANCH" \
    --state all \
    --limit 1 \
    --json url \
    --jq '.[0].url // empty'
)"

if [[ -z "$PR_URL" ]]; then
  BODY="$(mktemp)"
  trap 'rm -f "$BODY"' EXIT
  cat > "$BODY" <<EOF
Closes #20

## Contract

- process exit code never proves mission success;
- positive completion requires one typed terminal object and external Git/systemd readback;
- post-run branch must still be \`type/18-factory-scheduler-maintenance\`;
- runner contract status is separated from the independent gate status;
- \`gate_status\` remains \`NOT_RUN\` during the Codex execution stage.

## Validation

- focused semantic-contract suite;
- full pytest suite;
- Python py_compile;
- git diff --check.

## Safety

Draft only. No runtime deployment, timer restart, sandbox-policy mutation, merge, or ZCR19 reexecution.
EOF

  PR_URL="$(
    gh pr create \
      --draft \
      --base "$BASE" \
      --head "$BRANCH" \
      --title "[P0] Enforce ZCR19 semantic success contract" \
      --body-file "$BODY"
  )"
fi

echo
echo "===== 7. READBACK ====="

gh pr view "$PR_URL" \
  --json number,url,isDraft,state,headRefName,headRefOid,baseRefName \
  --jq '{
    number,
    url,
    draft: .isDraft,
    state,
    head: .headRefName,
    sha: .headRefOid,
    base: .baseRefName
  }'

echo "timer=$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
echo "implementation_head=$(git -C /home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler rev-parse HEAD)"
echo "implementation_status:"
git -C /home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler status --short

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail "timer foi alterado"
[[ "$(git -C /home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler rev-parse HEAD)" == \
   "d80ed678333dc70d1b92479a821bf2d1467c4424" ]] ||
  fail "branch de implementação ZCR19 foi alterada"
[[ -z "$(git -C /home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler status --porcelain=v1)" ]] ||
  fail "worktree de implementação ZCR19 ficou suja"

echo
echo "ZCR20_SEMANTIC_CONTRACT_FINALIZED: PASS"
echo "FINAL_SHA=$FINAL_SHA"
echo "PR_URL=$PR_URL"
