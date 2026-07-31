#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

GUARD_COMMIT="55e196a2ecae4817b826d8fd449dc9a194327599"
GUARD_BLOB="6c2456209853626f7bc1338a1519ac70510281fd"
GUARD_URL="https://raw.githubusercontent.com/lucaspprates/AmizadeChain/${GUARD_COMMIT}/tmp/onca-8x1-v4/15_onca_codex_auth_guard_v42.sh"
GUARD_TARGET="/tmp/15_onca_codex_auth_guard_v42.sh"

RESTACK_COMMIT="7c9e0fba417fb4b416c41ea93717b724f55ddb2b"
RESTACK_BLOB="ab3d7a68c662c335017cf97d9e59be08c13d0da7"
RESTACK_URL="https://raw.githubusercontent.com/lucaspprates/AmizadeChain/${RESTACK_COMMIT}/tmp/onca-8x1-v4/14_run_pr19_restack_and_gate_v41.sh"
RESTACK_TARGET="/tmp/14_run_pr19_restack_and_gate_v41.sh"

fail() {
  local code="$1"
  shift
  echo "ERRO: $*" >&2
  echo "ONCA_PR19_RESTACK_GATE_V42: BLOCKED"
  echo "FAILURE_CODE=$code"
  echo "REMOTE_BRANCH_UPDATED=false"
  echo "NEXT_ACTION=REPAIR_OR_REAUTH_WORKER_THEN_RERUN_SAME_V42_WRAPPER"
  exit 1
}

[[ "$(id -un)" == "ubuntu" ]] || fail USER_MISMATCH "execute como ubuntu"
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail HOST_MISMATCH "host atual=$(hostname -s)"

curl -fsSL --retry 3 --retry-delay 1 "$GUARD_URL" -o "$GUARD_TARGET"
[[ "$(git hash-object "$GUARD_TARGET")" == "$GUARD_BLOB" ]] ||
  fail AUTH_GUARD_BLOB_MISMATCH "guard divergente"
bash -n "$GUARD_TARGET" || fail AUTH_GUARD_SYNTAX_FAILED "bash -n falhou"
chmod 700 "$GUARD_TARGET"

curl -fsSL --retry 3 --retry-delay 1 "$RESTACK_URL" -o "$RESTACK_TARGET"
[[ "$(git hash-object "$RESTACK_TARGET")" == "$RESTACK_BLOB" ]] ||
  fail RESTACK_V41_BLOB_MISMATCH "restack divergente"
bash -n "$RESTACK_TARGET" || fail RESTACK_V41_SYNTAX_FAILED "bash -n falhou"
chmod 700 "$RESTACK_TARGET"

cat <<EOF
ONCA_PR19_RESTACK_GATE_V42_INSTALLER: PASS
AUTH_GUARD_COMMIT=$GUARD_COMMIT
AUTH_GUARD_BLOB=$GUARD_BLOB
RESTACK_COMMIT=$RESTACK_COMMIT
RESTACK_BLOB=$RESTACK_BLOB
EXECUTION_ORDER=AUTH_GUARD_THEN_RESTACK_THEN_EXACT_SHA_GATE
EOF

echo
echo '===== FASE A — CODEX AUTH GUARD ====='
if ! bash "$GUARD_TARGET"; then
  fail CODEX_AUTH_GUARD_BLOCKED "credencial real do worker não passou"
fi

echo
echo '===== FASE B — PR19 RESTACK + EXACT-SHA GATE ====='
exec bash "$RESTACK_TARGET"
