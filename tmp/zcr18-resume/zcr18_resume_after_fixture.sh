#!/usr/bin/env bash
set -Eeuo pipefail

VENV="/tmp/zcr18-builder-venv"
WT="/home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler"
BRANCH="type/18-factory-scheduler-maintenance"
BASE="fix/16-opencode-result-provenance"
BASE_SHA="31b2a8811cf931a5b4e155b30a3cb79927e1111c"
FILE="$WT/tests/test_opencode_terminal_result_smoke.py"

die() {
  echo "ERRO: $*" >&2
  exit 1
}

echo "===== 1. GUARDS ====="

[[ -x "$VENV/bin/python" ]] || die "venv inexistente: $VENV"
[[ -d "$WT" ]] || die "worktree inexistente: $WT"
[[ -d "$WT/.git" || -f "$WT/.git" ]] || die "worktree Git inválida: $WT"
[[ -f "$FILE" ]] || die "fixture inexistente: $FILE"

TIMER_STATE="$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
[[ "$TIMER_STATE" == "inactive" ]] || die "timer não está congelado: $TIMER_STATE"

CURRENT_BRANCH="$(git -C "$WT" branch --show-current)"
[[ "$CURRENT_BRANCH" == "$BRANCH" ]] || die "branch inesperada: $CURRENT_BRANCH"

git -C "$WT" merge-base --is-ancestor "$BASE_SHA" HEAD ||
  die "HEAD não descende do SHA esperado da PR #17: $BASE_SHA"

gh auth status >/dev/null 2>&1 || die "gh não está autenticado"

echo "Timer:  $TIMER_STATE"
echo "Branch: $CURRENT_BRANCH"
echo "HEAD:   $(git -C "$WT" rev-parse HEAD)"

echo
echo "===== 2. CORRIGINDO FIXTURE DE PROVENIÊNCIA ====="

"$VENV/bin/python" - "$FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

old = '''def submit(cfg, repo: Path, tmp_path, no_fallback: bool) -> str:
    prompt = tmp_path / "prompt.md"
    prompt.write_text("read-only provenance smoke\\n", encoding="utf-8")
'''

new = '''def submit(cfg, repo: Path, tmp_path, no_fallback: bool) -> str:
    # This suite verifies terminal provenance, not ephemeral-prompt rejection.
    # Create its prompt inside the configured durable root so the production
    # fail-closed contract remains active and independently tested.
    prompt_root = Path(cfg["runtime"]["state_dir"]) / "prompts"
    prompt_root.mkdir(parents=True, exist_ok=True)
    prompt = prompt_root / "prompt.md"
    prompt.write_text("read-only provenance smoke\\n", encoding="utf-8")
'''

if new in text:
    print("Fixture já corrigida; nenhuma duplicação aplicada.")
elif old in text:
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print("Fixture corrigida.")
else:
    raise SystemExit("ERRO: bloco esperado da fixture não foi encontrado.")
PY

grep -n -A11 "def submit(cfg, repo: Path" "$FILE"

echo
echo "===== 3. TESTE FOCADO ====="

cd "$WT"
"$VENV/bin/python" -m pytest -q tests/test_opencode_terminal_result_smoke.py

echo
echo "PROVENIÊNCIA TERMINAL: PASS"

echo
echo "===== 4. SUÍTE COMPLETA ====="

"$VENV/bin/python" -m compileall -q src scripts tests
"$VENV/bin/python" -m pytest -q
git diff --check

test -s tests/test_factory_scheduler_maintenance.py
grep -q "GLOBAL_CAPACITY_PLAN" src/zoe_coder_router/zoe_coder_router.py
grep -q -- "--no-block" src/zoe_coder_router/zoe_coder_router.py
grep -q "requeue" src/zoe_coder_router/zoe_coder_router.py

echo
echo "COMPILE, TESTES, CONTRATO E DIFF CHECK: PASS"

echo
echo "===== 5. ESCOPO FINAL ====="

git status --short
echo
git diff --stat

CHANGED="$(
  git status --porcelain=v1 |
  sed -E 's/^.. //' |
  sed -E 's/.* -> //'
)"

if printf '%s\n' "$CHANGED" |
   grep -Ei '(^|/)(\.env|runtime\.db|credentials?|secrets?|id_rsa|.*\.pem|.*\.key)$'
then
  die "possível artefato sensível detectado"
fi

ALLOWED_FILES=(
  "README.md"
  "config/config.example.toml"
  "src/zoe_coder_router/zoe_coder_router.py"
  "tests/fixtures/config-schema.json"
  "tests/test_factory_scheduler_maintenance.py"
  "tests/test_opencode_terminal_result_smoke.py"
)

while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  allowed=0
  for candidate in "${ALLOWED_FILES[@]}"; do
    if [[ "$path" == "$candidate" ]]; then
      allowed=1
      break
    fi
  done
  [[ "$allowed" == "1" ]] || die "arquivo fora do escopo: $path"
done <<< "$CHANGED"

echo
echo "===== 6. COMMIT ====="

git add "${ALLOWED_FILES[@]}"
git diff --cached --check

echo "Arquivos preparados:"
git diff --cached --name-status

if git diff --cached --quiet; then
  if [[ "$(git rev-parse HEAD)" == "$BASE_SHA" ]]; then
    die "nenhuma alteração preparada e HEAD ainda está no base SHA"
  fi
  echo "Nenhuma alteração nova para commit; usando commit já existente."
else
  git commit -m "fix(router): repair factory scheduler controls"
fi

FINAL_SHA="$(git rev-parse HEAD)"
echo
echo "Final SHA: $FINAL_SHA"

echo
echo "===== 7. PUSH ====="

git push -u origin "$BRANCH"

echo
echo "===== 8. DRAFT PR ====="

BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT

cat > "$BODY" <<EOF
Closes #18

## What changed

- dispatches Zoe wakes asynchronously without blocking reconciliation;
- enforces one global wake lease with stale/orphan recovery;
- restores six factory slots: four writers and two independent gates;
- separates writer, gate, QA and release-validation accounting;
- requires durable prompts and supports atomic prompt import;
- adds a native compare-and-set requeue command with SQLite backup;
- adds independent read-only route examples;
- validates the structured GLOBAL_CAPACITY_PLAN against ledger changes.

## Root cause

The reconciler synchronously waited for long-running systemd oneshot wake units. While Hermes reconciled, the timer and dispatcher were blocked. Capacity planning also treated writer creation as its primary success criterion and could leave admissible gates idle.

## Validation

- focused OpenCode terminal-provenance suite;
- full pytest suite;
- Python compileall;
- git diff --check;
- scheduler-maintenance contract assertions;
- isolated worktree;
- production reconciliation timer remained stopped.

## Safety

Draft only. No runtime deployment, timer restart, merge, production activation, credential mutation or secret storage.

## Stack

Intentionally based on PR #17 branch \`fix/16-opencode-result-provenance\` at SHA \`$BASE_SHA\`.
EOF

PR_URL="$(
  gh pr list \
    --head "$BRANCH" \
    --state all \
    --limit 1 \
    --json url \
    --jq '.[0].url // empty' \
    2>/dev/null || true
)"

if [[ -z "$PR_URL" ]]; then
  PR_URL="$(
    gh pr create \
      --draft \
      --base "$BASE" \
      --head "$BRANCH" \
      --title "[S1] Repair factory scheduler control plane" \
      --body-file "$BODY"
  )"
else
  echo "Draft PR já existente: $PR_URL"
fi

echo
echo "===== 9. READBACK ====="

echo "PR:     $PR_URL"
echo "Branch: $BRANCH"
echo "SHA:    $FINAL_SHA"
echo "Base:   $BASE"

gh pr view "$BRANCH" \
  --json number,url,isDraft,state,headRefName,baseRefName \
  --jq '{
    number,
    url,
    draft: .isDraft,
    state,
    head: .headRefName,
    base: .baseRefName
  }'

echo
echo "Diff empilhado:"
git diff --stat "origin/$BASE...$FINAL_SHA"

echo
echo "Timer:"
systemctl is-active zoe-coder-reconcile.timer || true

echo
echo "ZCR18_PATCH_AND_DRAFT_PR: PASS"
