#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

GUARD_COMMIT="56e07c220cff127ed50bcf1f01c612320d3b922b"
GUARD_BLOB="5774d37553f53efd387dadbbb8ffd4f1c9f84a86"
GUARD_URL="https://raw.githubusercontent.com/lucaspprates/AmizadeChain/${GUARD_COMMIT}/tmp/onca-8x1-v4/15c_fix_and_run_onca_codex_auth_guard_v44.sh"
GUARD_TARGET="/tmp/15c_fix_and_run_onca_codex_auth_guard_v44.sh"

RESTACK_COMMIT="7c9e0fba417fb4b416c41ea93717b724f55ddb2b"
RESTACK_BLOB="ab3d7a68c662c335017cf97d9e59be08c13d0da7"
RESTACK_URL="https://raw.githubusercontent.com/lucaspprates/AmizadeChain/${RESTACK_COMMIT}/tmp/onca-8x1-v4/14_run_pr19_restack_and_gate_v41.sh"
RESTACK_TARGET="/tmp/14_run_pr19_restack_and_gate_v41.sh"

fail() {
  local code="$1"
  shift
  echo "ERRO: $*" >&2
  echo "ONCA_PR19_RESTACK_GATE_V44: BLOCKED"
  echo "FAILURE_CODE=$code"
  echo "REMOTE_BRANCH_UPDATED=false"
  echo "NEXT_ACTION=REPAIR_OR_REAUTH_WORKER_THEN_RERUN_SAME_V44_WRAPPER"
  exit 1
}

[[ "$(id -un)" == "ubuntu" ]] || fail USER_MISMATCH "execute como ubuntu"
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail HOST_MISMATCH "host atual=$(hostname -s)"

curl -fsSL --retry 3 --retry-delay 1 "$GUARD_URL" -o "$GUARD_TARGET"
[[ "$(git hash-object "$GUARD_TARGET")" == "$GUARD_BLOB" ]] ||
  fail AUTH_GUARD_V44_BLOB_MISMATCH "guard V4.4 divergente"
bash -n "$GUARD_TARGET" || fail AUTH_GUARD_V44_SYNTAX_FAILED "bash -n falhou"
chmod 700 "$GUARD_TARGET"

curl -fsSL --retry 3 --retry-delay 1 "$RESTACK_URL" -o "$RESTACK_TARGET"
[[ "$(git hash-object "$RESTACK_TARGET")" == "$RESTACK_BLOB" ]] ||
  fail RESTACK_V41_BLOB_MISMATCH "restack V4.1 divergente"
bash -n "$RESTACK_TARGET" || fail RESTACK_V41_SYNTAX_FAILED "bash -n falhou"
chmod 700 "$RESTACK_TARGET"

cat <<EOF
ONCA_PR19_RESTACK_GATE_V44_INSTALLER: PASS
AUTH_GUARD_COMMIT=$GUARD_COMMIT
AUTH_GUARD_BLOB=$GUARD_BLOB
RESTACK_COMMIT=$RESTACK_COMMIT
RESTACK_BLOB=$RESTACK_BLOB
EXECUTION_ORDER=FIXED_AUTH_GUARD_THEN_RESTACK_THEN_EXACT_SHA_GATE
EOF

echo
echo '===== FASE A — CODEX AUTH GUARD V4.4 ====='
set +e
bash "$GUARD_TARGET"
GUARD_RC=$?
set -e
if [[ "$GUARD_RC" -ne 0 ]]; then
  fail "CODEX_AUTH_GUARD_V44_RC_${GUARD_RC}" "credencial real do worker não passou"
fi

echo
echo '===== FASE B — PR19 RESTACK + EXACT-SHA GATE ====='
exec bash "$RESTACK_TARGET"
