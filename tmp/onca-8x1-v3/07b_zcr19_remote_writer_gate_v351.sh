#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

SOURCE_COMMIT="8cdf2f1c7a2edb1ad9edbb3e6f9c62aad9583b77"
SOURCE_BLOB="db397cb3b15e8fda46a4e691f4840e53fcd401df"
SOURCE_URL="https://raw.githubusercontent.com/lucaspprates/AmizadeChain/${SOURCE_COMMIT}/tmp/onca-8x1-v3/07_zcr19_remote_writer_gate_v35.sh"
TARGET="/tmp/07_zcr19_remote_writer_gate_v351_patched.sh"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="/tmp/evidence/zcr19-v351-wrapper-${STAMP}"
mkdir -p "$EVIDENCE"

fail() {
  echo "ERRO: $*" >&2
  echo "OPERACAO_ZCR19_V351_WRAPPER: BLOCKED"
  echo "EVIDENCE_DIR=$EVIDENCE"
  exit 1
}

[[ "$(id -un)" == "ubuntu" ]] || fail USER_MISMATCH
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail HOST_MISMATCH

curl -fsSL --retry 3 --retry-delay 1 "$SOURCE_URL" -o "$TARGET"
[[ "$(git hash-object "$TARGET")" == "$SOURCE_BLOB" ]] || fail SOURCE_BLOB_MISMATCH
cp -a "$TARGET" "$EVIDENCE/07_zcr19_remote_writer_gate_v35.sh.before"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys
path=Path(sys.argv[1])
text=path.read_text(encoding="utf-8")
old='if ! python3 - "$DB" <<\'PY\' > "$EVIDENCE/active-zcr19-jobs.json"'
new='if ! sudo -u ubuntu -g zoe-coders -H -- python3 - "$DB" <<\'PY\' > "$EVIDENCE/active-zcr19-jobs.json"'
if text.count(old) != 1:
    raise SystemExit(f"expected one DB read guard, found {text.count(old)}")
text=text.replace(old,new,1)
path.write_text(text,encoding="utf-8")
PY

chmod 700 "$TARGET"
bash -n "$TARGET" || fail PATCHED_SCRIPT_SYNTAX_FAILED
grep -Fq 'sudo -u ubuntu -g zoe-coders -H -- python3 - "$DB"' "$TARGET" || fail DB_GROUP_GUARD_MISSING
PATCHED_SHA256="$(sha256sum "$TARGET" | awk '{print $1}')"
printf '%s  %s\n' "$SOURCE_BLOB" source-git-blob > "$EVIDENCE/MANIFEST"
printf '%s  %s\n' "$PATCHED_SHA256" 07_zcr19_remote_writer_gate_v351_patched.sh >> "$EVIDENCE/MANIFEST"

echo "OPERACAO_ZCR19_V351_WRAPPER: PASS"
echo "SOURCE_COMMIT=$SOURCE_COMMIT"
echo "SOURCE_BLOB=$SOURCE_BLOB"
echo "PATCHED_SHA256=$PATCHED_SHA256"
echo "DB_READ_IDENTITY=ubuntu:zoe-coders"
echo "EVIDENCE_DIR=$EVIDENCE"

exec bash "$TARGET"
