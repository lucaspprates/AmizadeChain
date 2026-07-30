#!/usr/bin/env bash
set -Eeuo pipefail

WT="/home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler"
BRANCH="type/18-factory-scheduler-maintenance"
EXPECTED_HEAD="d80ed678333dc70d1b92479a821bf2d1467c4424"
PROMPT_COMMIT="df4c1a182c536b28636412e4152d7a8b3a93fec7"
PROMPT_BLOB="8d9bb6bba5356e1657bd329a932160ff6b00b66e"
PROMPT_URL="https://raw.githubusercontent.com/lucaspprates/AmizadeChain/${PROMPT_COMMIT}/tmp/zcr19-pregate-codex/ZCR19_PREGATE_CORRECTIONS.md"
PROMPT="/tmp/ZCR19_PREGATE_CORRECTIONS.md"
LOG="/tmp/zcr19_pregate_codex.run.log"

fail() {
  echo "ERRO: $*" >&2
  exit 1
}

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail "timer não está congelado"
[[ -d "$WT" ]] || fail "worktree inexistente: $WT"
[[ "$(git -C "$WT" branch --show-current)" == "$BRANCH" ]] ||
  fail "branch inesperada"
[[ "$(git -C "$WT" rev-parse HEAD)" == "$EXPECTED_HEAD" ]] ||
  fail "HEAD inesperado"
[[ -z "$(git -C "$WT" status --porcelain=v1)" ]] ||
  fail "worktree não está limpa"
[[ -x /tmp/zcr18-builder-venv/bin/python ]] ||
  fail "venv de testes inexistente"
command -v codex >/dev/null 2>&1 || fail "codex não encontrado"
command -v curl >/dev/null 2>&1 || fail "curl não encontrado"

curl -fsSL "$PROMPT_URL" -o "$PROMPT"
[[ "$(git hash-object "$PROMPT")" == "$PROMPT_BLOB" ]] ||
  fail "prompt baixado diverge do Git blob esperado"

CMD=(
  codex exec
  --ephemeral
  --sandbox workspace-write
  --cd "$WT"
)

if codex exec --help 2>&1 | grep -q -- '--disable'; then
  CMD+=(--disable plugins)
fi

printf 'Timer:  %s\n' "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
printf 'Branch: %s\n' "$(git -C "$WT" branch --show-current)"
printf 'HEAD:   %s\n' "$(git -C "$WT" rev-parse HEAD)"
printf 'Codex:  %s\n' "$(codex --version 2>/dev/null || true)"
printf 'Prompt: %s\n\n' "$PROMPT_BLOB"

set +e
"${CMD[@]}" - < "$PROMPT" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
set -e

echo
echo "===== READBACK ====="
echo "RC=$RC"
echo "timer=$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
echo "branch=$(git -C "$WT" branch --show-current)"
echo "head=$(git -C "$WT" rev-parse HEAD)"
echo "status:"
git -C "$WT" status --short

echo
if [[ "$RC" -eq 0 ]]; then
  echo "ZCR19_CODEX_RUN: PASS"
else
  echo "ZCR19_CODEX_RUN: FAILED"
fi

exit "$RC"
