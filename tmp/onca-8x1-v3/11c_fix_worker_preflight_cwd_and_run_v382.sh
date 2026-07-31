#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

SOURCE_COMMIT="9faf0dbc14418e15373ce80d8173346f784ceb57"
SOURCE_BLOB="337188ce0cc1dbd7fa883d0e066e288e3e3613ff"
SOURCE_URL="https://raw.githubusercontent.com/lucaspprates/AmizadeChain/${SOURCE_COMMIT}/tmp/onca-8x1-v3/11_pr17_exact_sha_gate_v38.sh"
TARGET="/tmp/11_pr17_exact_sha_gate_v382_patched.sh"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="/tmp/evidence/zcr17-v382-worker-cwd-${STAMP}"
mkdir -p "$EVIDENCE"

fail() {
  echo "ERRO: $*" >&2
  echo "OPERACAO_ZCR17_V382_WRAPPER: BLOCKED"
  echo "EVIDENCE_DIR=$EVIDENCE"
  exit 1
}

[[ "$(id -un)" == "ubuntu" ]] || fail USER_MISMATCH
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail HOST_MISMATCH

curl -fsSL --retry 3 --retry-delay 1 "$SOURCE_URL" -o "$TARGET"
[[ "$(git hash-object "$TARGET")" == "$SOURCE_BLOB" ]] || fail SOURCE_BLOB_MISMATCH
cp -a "$TARGET" "$EVIDENCE/11_pr17_exact_sha_gate_v38.sh.before"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

old_a = '''  if [[ -f "$EVIDENCE/gate-bridge-result.json" ]]; then
    python3 - "$EVIDENCE/gate-bridge-result.json" <<'PY' | tee "$EVIDENCE/gate-terminal-readable.json"'''
new_a = '''  if [[ -f "$EVIDENCE/gate-bridge-result.json" ]]; then
    set +e
    python3 - "$EVIDENCE/gate-bridge-result.json" <<'PY' | tee "$EVIDENCE/gate-terminal-readable.json"'''
old_b = '''    CLASSIFY_RC=${PIPESTATUS[0]}
    [[ "$CLASSIFY_RC" -ne 10 ]] || fail GATE_REJECTED "findings em gate-terminal-readable.json"'''
new_b = '''    CLASSIFY_RC=${PIPESTATUS[0]}
    set -e
    [[ "$CLASSIFY_RC" -ne 10 ]] || fail GATE_REJECTED "findings em gate-terminal-readable.json"'''
old_c = '''set -Eeuo pipefail
python3 -m pytest --version
rg --version | head -1'''
new_c = '''set -Eeuo pipefail
cd /
python3 -m pytest --version
rg --version | head -1'''

for label, old in (("classification_pipeline", old_a), ("classification_rc", old_b), ("worker_cwd", old_c)):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected one {label} block, found {count}")

text = text.replace(old_a, new_a, 1)
text = text.replace(old_b, new_b, 1)
text = text.replace(old_c, new_c, 1)
path.write_text(text, encoding="utf-8")
PY

chmod 700 "$TARGET"
bash -n "$TARGET" || fail PATCHED_SCRIPT_SYNTAX_FAILED
grep -Fq 'CLASSIFY_RC=${PIPESTATUS[0]}' "$TARGET" || fail REJECTION_CAPTURE_RC_MISSING
grep -Fq $'set -Eeuo pipefail\ncd /\npython3 -m pytest --version' "$TARGET" || fail WORKER_CWD_PATCH_MISSING

PATCHED_SHA256="$(sha256sum "$TARGET" | awk '{print $1}')"
printf '%s  %s\n' "$SOURCE_BLOB" source-git-blob > "$EVIDENCE/MANIFEST"
printf '%s  %s\n' "$PATCHED_SHA256" 11_pr17_exact_sha_gate_v382_patched.sh >> "$EVIDENCE/MANIFEST"

cat <<EOF
OPERACAO_ZCR17_V382_WRAPPER: PASS
SOURCE_COMMIT=$SOURCE_COMMIT
SOURCE_BLOB=$SOURCE_BLOB
PATCHED_SHA256=$PATCHED_SHA256
GATE_REJECTION_CAPTURE=PASS
WORKER_PREFLIGHT_CWD=/
EVIDENCE_DIR=$EVIDENCE
EOF

exec bash "$TARGET"
