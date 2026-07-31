#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

SOURCE_COMMIT="12fe06bc7c796f8d10e7731ce6a97018888c94e1"
SOURCE_BLOB="adec443c25f900fd1412749e96f5cdcdc991f21e"
SOURCE_URL="https://raw.githubusercontent.com/lucaspprates/AmizadeChain/${SOURCE_COMMIT}/tmp/onca-8x1-v4/15b_onca_codex_auth_guard_v43.sh"
TARGET="/tmp/15c_onca_codex_auth_guard_v44_patched.sh"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="/tmp/evidence/onca-auth-guard-v44-patcher-${STAMP}"
mkdir -p "$EVIDENCE"

fail() {
  local code="$1"
  shift
  echo "ERRO: $*" >&2
  echo "ONCA_CODEX_AUTH_GUARD_V44_PATCHER: BLOCKED"
  echo "FAILURE_CODE=$code"
  echo "CONTROL_PLANE_CHANGED=false"
  echo "WORKER_CHANGED=false"
  echo "EVIDENCE_DIR=$EVIDENCE"
  exit 1
}

[[ "$(id -un)" == "ubuntu" ]] || fail USER_MISMATCH "execute como ubuntu"
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail HOST_MISMATCH "host atual=$(hostname -s)"

curl -fsSL --retry 3 --retry-delay 1 "$SOURCE_URL" -o "$TARGET"
[[ "$(git hash-object "$TARGET")" == "$SOURCE_BLOB" ]] ||
  fail SOURCE_BLOB_MISMATCH "Auth Guard V4.3 de origem divergiu"
cp -a "$TARGET" "$EVIDENCE/15b_onca_codex_auth_guard_v43.sh.before"

python3 - "$TARGET" <<'PY_PATCH'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

old_start = '''set +e
"${SSH[@]}" "sudo -n -u '$RUN_USER' -H bash -s" <<'REMOTE' 2>&1 |
  tee "$EVIDENCE/worker-auth-guard.log"'''
new_start = '''set +e
"${SSH[@]}" "sudo -n -u '$RUN_USER' -H bash -s" \\
  >"$EVIDENCE/worker-auth-guard.log" 2>&1 <<'REMOTE' '''.rstrip()

old_end = '''REMOTE
WORKER_RC=${PIPESTATUS[0]}
set -e'''
new_end = '''REMOTE
WORKER_RC=$?
set -e
cat "$EVIDENCE/worker-auth-guard.log"'''

for label, old, new in (
    ("ssh_pipeline_start", old_start, new_start),
    ("worker_rc_capture", old_end, new_end),
):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one {label} block, found {count}")
    text = text.replace(old, new, 1)

path.write_text(text, encoding="utf-8")
PY_PATCH

chmod 700 "$TARGET"
bash -n "$TARGET" || fail PATCHED_SCRIPT_SYNTAX_FAILED "bash -n falhou"

grep -Fq '>"$EVIDENCE/worker-auth-guard.log" 2>&1' "$TARGET" ||
  fail DIRECT_LOG_REDIRECT_MISSING "redirecionamento direto ausente"
grep -Fq 'WORKER_RC=$?' "$TARGET" ||
  fail DIRECT_RC_CAPTURE_MISSING "captura por $? ausente"
if grep -Fq 'WORKER_RC=${PIPESTATUS[0]}' "$TARGET"; then
  fail FRAGILE_PIPESTATUS_REMAINS "PIPESTATUS antigo ainda está presente"
fi

PATCHED_SHA256="$(sha256sum "$TARGET" | awk '{print $1}')"
PATCHED_BLOB="$(git hash-object "$TARGET")"
printf '%s  %s\n' "$SOURCE_BLOB" source-git-blob > "$EVIDENCE/MANIFEST"
printf '%s  %s\n' "$PATCHED_BLOB" patched-git-blob >> "$EVIDENCE/MANIFEST"
printf '%s  %s\n' "$PATCHED_SHA256" patched-sha256 >> "$EVIDENCE/MANIFEST"

cat <<EOF
ONCA_CODEX_AUTH_GUARD_V44_PATCHER: PASS
SOURCE_COMMIT=$SOURCE_COMMIT
SOURCE_BLOB=$SOURCE_BLOB
PATCHED_GIT_BLOB=$PATCHED_BLOB
PATCHED_SHA256=$PATCHED_SHA256
EXIT_CAPTURE=direct_dollar_question_mark
LOG_CAPTURE=direct_file_redirection
PIPESTATUS_DEPENDENCY=false
EVIDENCE_DIR=$EVIDENCE
EOF

echo
echo '===== AUTH GUARD V4.4 CORRIGIDO ====='
set +e
bash "$TARGET"
GUARD_RC=$?
set -e

if [[ "$GUARD_RC" -ne 0 ]]; then
  fail "AUTH_GUARD_RC_${GUARD_RC}" "Auth Guard corrigido bloqueou; use a classificação impressa acima"
fi

echo
cat <<EOF
ONCA_CODEX_AUTH_GUARD_V44_WRAPPER: PASS
AUTH_GUARD_RESULT=PASS
CONTROL_PLANE_CHANGED=false
WORKER_CHANGED=false
NEXT_PHASE=PR19_RESTACK_GATE_V44
EOF
