#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/home/ubuntu/work/Zoe-Coder-Router"
TARGET="/home/ubuntu/worktrees/zoe-coder-router-runner-semantic-clean"
BRANCH="fix/20-runner-semantic-clean-integration"
BASE_SHA="b705b03cdcc04bdd0d43df0f514f196f9a012430"

RUNTIME="/usr/local/lib/zoe-coder-router/zoe_coder_router.py"
RUNTIME_SHA="fb715130494523c5720982bfd0bd6093744881b4f1a33fdff8209c234b2bb362"
SOURCE_REL="src/zoe_coder_router/zoe_coder_router.py"
VENV="/tmp/zcr18-builder-venv"
PREFLIGHT="/tmp/FABRICA_ZOE_URGENTE_V2/scripts/00_preflight_control_plane.sh"

SEMANTIC_COMMITS=(
  "d9a606e37cfa97fe76150a67957426096148e368"
  "74a62de95a7353ced7f4a7ab7486f98f25990cf2"
  "7198ed264da90520066fed22c61ef510f7582bab"
  "66ea771be8a231b955d719417d2242c3bca2407d"
)

fail() {
  echo "ERRO: $*" >&2
  exit 1
}

cleanup_cherry_pick() {
  if [[ -d "$TARGET" ]] && git -C "$TARGET" rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null 2>&1; then
    git -C "$TARGET" cherry-pick --abort >/dev/null 2>&1 || true
  fi
}

trap cleanup_cherry_pick ERR

echo "===== 1. GUARDAS DO CONTROL PLANE ====="

[[ -x "$PREFLIGHT" ]] || fail "preflight V2 ausente ou não executável: $PREFLIGHT"
"$PREFLIGHT" | tee /tmp/zcr20-clean-integration.preflight.log
grep -qx 'CONTROL_PLANE_PREFLIGHT_V2: PASS' \
  /tmp/zcr20-clean-integration.preflight.log ||
  fail "preflight V2 não aprovou"

[[ -d "$ROOT/.git" || -f "$ROOT/.git" ]] || fail "repositório raiz ausente: $ROOT"
[[ -f "$RUNTIME" ]] || fail "runtime instalado ausente"
[[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$RUNTIME_SHA" ]] ||
  fail "runtime instalado diverge do SHA aprovado"
[[ -x "$VENV/bin/python" ]] || fail "venv de testes ausente"
command -v git >/dev/null 2>&1 || fail "git ausente"
command -v gh >/dev/null 2>&1 || fail "gh ausente"
gh auth status >/dev/null 2>&1 || fail "gh não autenticado"

echo
echo "===== 2. FETCH E BASE EXATA ====="

git -C "$ROOT" fetch --prune origin main \
  fix/20-zcr19-runner-semantic-contract

[[ "$(git -C "$ROOT" rev-parse origin/main)" == "$BASE_SHA" ]] ||
  fail "origin/main divergiu do ponto revisado $BASE_SHA"

git -C "$ROOT" cat-file -e "${BASE_SHA}^{commit}" ||
  fail "base commit inexistente"

for sha in "${SEMANTIC_COMMITS[@]}"; do
  git -C "$ROOT" cat-file -e "${sha}^{commit}" ||
    fail "commit semântico inexistente: $sha"
done

if git -C "$ROOT" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  fail "branch remota já existe: $BRANCH"
fi

if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  fail "branch local já existe: $BRANCH"
fi

[[ ! -e "$TARGET" ]] || fail "worktree alvo já existe: $TARGET"

git -C "$ROOT" worktree add -b "$BRANCH" "$TARGET" "$BASE_SHA"

[[ "$(git -C "$TARGET" rev-parse HEAD)" == "$BASE_SHA" ]] ||
  fail "worktree não iniciou no SHA base"
[[ -z "$(git -C "$TARGET" status --porcelain=v1)" ]] ||
  fail "worktree nasceu suja"

echo
echo "===== 3. CAPTURA DO RUNTIME REAL ====="

install -m 0644 "$RUNTIME" "$TARGET/$SOURCE_REL"

[[ "$(sha256sum "$TARGET/$SOURCE_REL" | awk '{print $1}')" == "$RUNTIME_SHA" ]] ||
  fail "cópia do runtime divergiu"

grep -q 'GLOBAL_CAPACITY_RESTORED' "$TARGET/$SOURCE_REL" ||
  fail "runtime capturado não contém contrato de restauração global"
grep -q 'ZOE_WOKEN_AND_CAPACITY_RESTORED' "$TARGET/$SOURCE_REL" ||
  fail "runtime capturado não contém evento de capacidade restaurada"
grep -q 'CAPACITY_NOT_RESTORED_AFTER_WAKE' "$TARGET/$SOURCE_REL" ||
  fail "runtime capturado não contém falha explícita de restauração"

git -C "$TARGET" diff --check
"$VENV/bin/python" -m py_compile "$TARGET/$SOURCE_REL"
(
  cd "$TARGET"
  "$VENV/bin/python" -m pytest -q
)

[[ -n "$(git -C "$TARGET" status --porcelain=v1)" ]] ||
  fail "runtime instalado não produziu delta contra a base"

git -C "$TARGET" add "$SOURCE_REL"
git -C "$TARGET" diff --cached --check
git -C "$TARGET" commit -m \
  "chore(runtime): capture deployed wake-continuity hotfix"

BASELINE_SHA="$(git -C "$TARGET" rev-parse HEAD)"
echo "BASELINE_SHA=$BASELINE_SHA"

echo
echo "===== 4. TRANSPLANTE DO CONTRATO SEMÂNTICO ====="

for sha in "${SEMANTIC_COMMITS[@]}"; do
  echo "cherry-pick $sha"
  if ! git -C "$TARGET" cherry-pick "$sha"; then
    echo "CHERRY_PICK_FAILED=$sha" >&2
    git -C "$TARGET" status --short >&2 || true
    git -C "$TARGET" cherry-pick --abort >/dev/null 2>&1 || true
    fail "transplante semântico falhou; nenhum push foi feito"
  fi
done

echo
echo "===== 5. GATES LOCAIS ====="

cd "$TARGET"

"$VENV/bin/python" -m py_compile \
  src/zoe_coder_router/zoe_coder_router.py \
  tests/test_zcr19_semantic_contract.py

FOCUSED_OUTPUT="$("$VENV/bin/python" -m pytest -q \
  tests/test_zcr19_semantic_contract.py)"
printf '%s\n' "$FOCUSED_OUTPUT"

FULL_OUTPUT="$("$VENV/bin/python" -m pytest -q)"
printf '%s\n' "$FULL_OUTPUT"

git diff --check
[[ -z "$(git status --porcelain=v1)" ]] ||
  fail "worktree ficou suja após testes"

grep -q 'def zcr19_commit_is_valid_successor' \
  src/zoe_coder_router/zoe_coder_router.py ||
  fail "contrato de sucessor válido ausente"
grep -q '"runner_contract_status"' \
  src/zoe_coder_router/zoe_coder_router.py ||
  fail "runner_contract_status ausente"
grep -q '"gate_status": "NOT_RUN"' \
  src/zoe_coder_router/zoe_coder_router.py ||
  fail "separação de gate ausente"
grep -q 'process_exit_code=None' \
  src/zoe_coder_router/zoe_coder_router.py ||
  fail "preflight ainda simula exit code"

CHANGED="$(
  git diff --name-only "$BASE_SHA"...HEAD | sort
)"
EXPECTED=$'src/zoe_coder_router/zoe_coder_router.py\ntests/test_zcr19_semantic_contract.py'
[[ "$CHANGED" == "$EXPECTED" ]] ||
  fail "escopo inesperado contra a base:
$CHANGED"

FINAL_SHA="$(git rev-parse HEAD)"
[[ "$FINAL_SHA" != "$BASE_SHA" ]] || fail "nenhum SHA novo foi criado"
git merge-base --is-ancestor "$BASE_SHA" "$FINAL_SHA" ||
  fail "HEAD final não descende da base"

echo
echo "===== 6. PUSH E DRAFT PR ====="

git push -u origin "$BRANCH"

BODY="$(mktemp)"
trap 'rm -f "$BODY"; cleanup_cherry_pick' EXIT

cat > "$BODY" <<EOF
Relates to #20.

## Objetivo

Integrar o contrato semântico fail-closed sobre uma base limpa, sem carregar
PR #17 ou PR #19 por dependência de branch.

## Base comprovada

- repository base: \`$BASE_SHA\`;
- runtime instalado capturado por SHA256:
  \`$RUNTIME_SHA\`;
- baseline commit local: \`$BASELINE_SHA\`;
- semantic source: PR #21, commits
  \`${SEMANTIC_COMMITS[*]}\`.

## Contrato

- exit code isolado nunca prova sucesso;
- terminal tipado e único;
- branch, HEAD, limpeza e timer verificados externamente;
- commit deve existir, descender do starting SHA e conter delta material;
- runner contract e gate status permanecem separados;
- preflight não invocado registra process exit code nulo.

## Validação

\`\`\`text
$FOCUSED_OUTPUT
$FULL_OUTPUT
py_compile: PASS
git diff --check: PASS
\`\`\`

## Segurança

Draft only. Sem deploy, merge, timer restart, banco, systemd, AppArmor,
ZCR19 ou Factory Console.
EOF

PR_URL="$(
  gh pr create \
    --draft \
    --base main \
    --head "$BRANCH" \
    --title "[P0] Integrate fail-closed runner on deployed runtime baseline" \
    --body-file "$BODY"
)"

echo
echo "===== 7. READBACK FINAL ====="

gh pr view "$PR_URL" \
  --json number,url,isDraft,state,mergeable,headRefName,headRefOid,baseRefName,baseRefOid \
  --jq '{
    number,
    url,
    draft: .isDraft,
    state,
    mergeable,
    head: .headRefName,
    head_sha: .headRefOid,
    base: .baseRefName,
    base_sha: .baseRefOid
  }'

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail "timer mudou durante a integração"

[[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$RUNTIME_SHA" ]] ||
  fail "runtime instalado foi alterado"

[[ "$(git -C /home/ubuntu/worktrees/zoe-coder-router-zcr19-contract rev-parse HEAD)" == \
   "66ea771be8a231b955d719417d2242c3bca2407d" ]] ||
  fail "PR #21 original foi alterada"

[[ "$(git -C /home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler rev-parse HEAD)" == \
   "d80ed678333dc70d1b92479a821bf2d1467c4424" ]] ||
  fail "ZCR19 original foi alterada"

cat <<EOF

RUNNER_SEMANTIC_CLEAN_INTEGRATION: PASS
BASE_SHA=$BASE_SHA
DEPLOYED_RUNTIME_SHA256=$RUNTIME_SHA
BASELINE_SHA=$BASELINE_SHA
FINAL_SHA=$FINAL_SHA
PR_URL=$PR_URL
TIMER=inactive
PRODUCTION_CHANGED=false
EOF
