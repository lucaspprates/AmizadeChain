#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

SOURCE_COMMIT="74a4040a324299e2a366fd23ac31f0094f9ab382"
SOURCE_BLOB="0103071d6f2a2976aae232f467c96f642a9c9b58"
SOURCE_URL="https://raw.githubusercontent.com/lucaspprates/AmizadeChain/${SOURCE_COMMIT}/tmp/onca-8x1-v3/10_zcr19_symlink_fix_and_gate_v37.sh"
TARGET="/tmp/10_zcr19_symlink_fix_and_gate_v371_patched.sh"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="/tmp/evidence/zcr19-v371-login-readback-${STAMP}"
mkdir -p "$EVIDENCE"

fail() {
  echo "ERRO: $*" >&2
  echo "OPERACAO_ZCR19_V371_LOGIN_READBACK: BLOCKED"
  echo "EVIDENCE_DIR=$EVIDENCE"
  exit 1
}

[[ "$(id -un)" == "ubuntu" ]] || fail USER_MISMATCH
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail HOST_MISMATCH

curl -fsSL --retry 3 --retry-delay 1 "$SOURCE_URL" -o "$TARGET"
[[ "$(git hash-object "$TARGET")" == "$SOURCE_BLOB" ]] || fail SOURCE_BLOB_MISMATCH
cp -a "$TARGET" "$EVIDENCE/10_zcr19_symlink_fix_and_gate_v37.sh.before"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = '''"${SSH[@]}" "sudo -n -u onca-runner -H bash -s" <<'REMOTE' | tee "$EVIDENCE/worker-toolchain-readback.log"'''
new = '''"${SSH[@]}" "sudo -n -u onca-runner -H bash -s" <<'REMOTE' 2>&1 | tee "$EVIDENCE/worker-toolchain-readback.log"'''
count = text.count(old)
if count != 1:
    raise SystemExit(f"expected exactly one worker readback pipeline, found {count}")
text = text.replace(old, new, 1)
path.write_text(text, encoding="utf-8")
PY

chmod 700 "$TARGET"
bash -n "$TARGET" || fail PATCHED_SCRIPT_SYNTAX_FAILED
grep -Fq "<<'REMOTE' 2>&1 | tee" "$TARGET" || fail STDERR_CAPTURE_PATCH_MISSING

PATCHED_SHA256="$(sha256sum "$TARGET" | awk '{print $1}')"
printf '%s  %s\n' "$SOURCE_BLOB" source-git-blob > "$EVIDENCE/MANIFEST"
printf '%s  %s\n' "$PATCHED_SHA256" 10_zcr19_symlink_fix_and_gate_v371_patched.sh >> "$EVIDENCE/MANIFEST"

cat <<EOF
OPERACAO_ZCR19_V371_LOGIN_READBACK: PASS
SOURCE_COMMIT=$SOURCE_COMMIT
SOURCE_BLOB=$SOURCE_BLOB
PATCHED_SHA256=$PATCHED_SHA256
CODEX_LOGIN_READBACK=stdout_plus_stderr
EVIDENCE_DIR=$EVIDENCE
EOF

exec bash "$TARGET"
