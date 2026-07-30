#!/usr/bin/env bash
set -Eeuo pipefail

WT="/home/ubuntu/worktrees/zoe-coder-router-runner-semantic-clean"
BRANCH="fix/20-runner-semantic-clean-integration"
EXPECTED_HEAD="3e089a1ca5a4045c949acce0c4343e6ab01539f0"
BASE_SHA="b705b03cdcc04bdd0d43df0f514f196f9a012430"
VENV="/tmp/zcr18-builder-venv"
RUNTIME="/usr/local/lib/zoe-coder-router/zoe_coder_router.py"
RUNTIME_SHA="fb715130494523c5720982bfd0bd6093744881b4f1a33fdff8209c234b2bb362"
SOURCE="src/zoe_coder_router/zoe_coder_router.py"
TESTS="tests/test_zcr19_semantic_contract.py"

fail() {
  echo "ERRO: $*" >&2
  exit 1
}

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail "timer não está congelado"
[[ -d "$WT" ]] || fail "worktree ausente: $WT"
[[ "$(git -C "$WT" branch --show-current)" == "$BRANCH" ]] || fail "branch inesperada"
[[ "$(git -C "$WT" rev-parse HEAD)" == "$EXPECTED_HEAD" ]] || fail "HEAD inesperado"
[[ -z "$(git -C "$WT" status --porcelain=v1)" ]] || fail "worktree não está limpa"
[[ -x "$VENV/bin/python" ]] || fail "venv ausente"
[[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$RUNTIME_SHA" ]] || fail "runtime instalado divergiu"
gh auth status >/dev/null 2>&1 || fail "gh não autenticado"

cd "$WT"

echo "===== 1. CORREÇÃO DE IMPORT E MODO ====="

"$VENV/bin/python" - "$SOURCE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

if "\nimport re\n" not in text:
    candidates = ["\nimport os\n", "\nimport pathlib\n", "\nimport json\n"]
    for anchor in candidates:
        if anchor in text:
            text = text.replace(anchor, anchor + "import re\n", 1)
            break
    else:
        raise SystemExit("ERRO: não encontrei âncora segura para import re")

path.write_text(text, encoding="utf-8")
PY

chmod 755 "$SOURCE"

grep -q '^import re$' "$SOURCE" || fail "import re não foi aplicado"
[[ "$(stat -c '%a' "$SOURCE")" == "755" ]] || fail "modo executável não foi restaurado"

git diff --check

echo

echo "===== 2. TESTES ====="

PYTHONDONTWRITEBYTECODE=1 \
"$VENV/bin/python" -m py_compile "$SOURCE" "$TESTS"

FOCUSED_OUTPUT="$(
  PYTHONDONTWRITEBYTECODE=1 \
  "$VENV/bin/python" -m pytest -p no:cacheprovider -q "$TESTS"
)"
printf '%s\n' "$FOCUSED_OUTPUT"

FULL_OUTPUT="$(
  PYTHONDONTWRITEBYTECODE=1 \
  "$VENV/bin/python" -m pytest -p no:cacheprovider -q
)"
printf '%s\n' "$FULL_OUTPUT"

git diff --check

CHANGED="$(git status --porcelain=v1 | sed -E 's/^.. //' | sed -E 's/.* -> //' | sort)"
[[ "$CHANGED" == "$SOURCE" ]] || fail "escopo inesperado após correção: $CHANGED"

echo

echo "===== 3. COMMIT ====="

git add "$SOURCE"
git diff --cached --check
git commit -m "fix(runner): import regex dependency in clean integration"
FINAL_SHA="$(git rev-parse HEAD)"

[[ -z "$(git status --porcelain=v1)" ]] || fail "worktree suja após commit"
git merge-base --is-ancestor "$BASE_SHA" "$FINAL_SHA" || fail "HEAD não descende da base"

echo

echo "===== 4. PUSH E DRAFT PR ====="

git push -u origin "$BRANCH"

PR_URL="$(
  gh pr list --head "$BRANCH" --state all --limit 1 --json url --jq '.[0].url // empty'
)"

if [[ -z "$PR_URL" ]]; then
  BODY="$(mktemp)"
  trap 'rm -f "$BODY"' EXIT
  cat > "$BODY" <<EOF
Relates to #20.

## Objetivo

Integrar o contrato semântico fail-closed sobre a base limpa \
\`$BASE_SHA\`, capturando o runtime realmente implantado por SHA256 e sem carregar PR #17 ou PR #19 por dependência de branch.

## Runtime capturado

- SHA256 instalado: \
\`$RUNTIME_SHA\`
- contrato de continuidade da wake preservado;
- modo executável do módulo restaurado;
- dependência explícita \
\`import re\` adicionada após o gate de importação detectar a ausência.

## Validação

\`\`\`text
$FOCUSED_OUTPUT
$FULL_OUTPUT
py_compile: PASS
git diff --check: PASS
\`\`\`

## Segurança

Draft only. Sem deploy, merge, banco, systemd, AppArmor, timer, ZCR19 ou Factory Console.
EOF
  PR_URL="$(
    gh pr create \
      --draft \
      --base main \
      --head "$BRANCH" \
      --title "[P0] Integrate fail-closed runner on deployed runtime baseline" \
      --body-file "$BODY"
  )"
fi

echo

echo "===== 5. READBACK ====="

gh pr view "$PR_URL" \
  --json number,url,isDraft,state,mergeable,headRefName,headRefOid,baseRefName,baseRefOid \
  --jq '{number,url,draft:.isDraft,state,mergeable,head:.headRefName,head_sha:.headRefOid,base:.baseRefName,base_sha:.baseRefOid}'

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] || fail "timer mudou"
[[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$RUNTIME_SHA" ]] || fail "runtime instalado foi alterado"
[[ "$(git -C /home/ubuntu/worktrees/zoe-coder-router-zcr19-contract rev-parse HEAD)" == "66ea771be8a231b955d719417d2242c3bca2407d" ]] || fail "PR #21 original foi alterada"
[[ "$(git -C /home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler rev-parse HEAD)" == "d80ed678333dc70d1b92479a821bf2d1467c4424" ]] || fail "ZCR19 original foi alterada"

cat <<EOF

RUNNER_SEMANTIC_CLEAN_INTEGRATION_RESUMED: PASS
FINAL_SHA=$FINAL_SHA
PR_URL=$PR_URL
TIMER=inactive
PRODUCTION_CHANGED=false
EOF
