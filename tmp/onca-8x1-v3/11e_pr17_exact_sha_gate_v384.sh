#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

SOURCE_COMMIT="9faf0dbc14418e15373ce80d8173346f784ceb57"
SOURCE_BLOB="337188ce0cc1dbd7fa883d0e066e288e3e3613ff"
SOURCE_URL="https://raw.githubusercontent.com/lucaspprates/AmizadeChain/${SOURCE_COMMIT}/tmp/onca-8x1-v3/11_pr17_exact_sha_gate_v38.sh"
TARGET="/tmp/11_pr17_exact_sha_gate_v384_patched.sh"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="/tmp/evidence/zcr17-v384-clean-patch-${STAMP}"
mkdir -p "$EVIDENCE"

fail() {
  echo "ERRO: $*" >&2
  echo "OPERACAO_ZCR17_V384_WRAPPER: BLOCKED"
  echo "EVIDENCE_DIR=$EVIDENCE"
  exit 1
}

[[ "$(id -un)" == "ubuntu" ]] || fail USER_MISMATCH
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail HOST_MISMATCH

curl -fsSL --retry 3 --retry-delay 1 "$SOURCE_URL" -o "$TARGET"
[[ "$(git hash-object "$TARGET")" == "$SOURCE_BLOB" ]] || fail SOURCE_BLOB_MISMATCH
cp -a "$TARGET" "$EVIDENCE/11_pr17_exact_sha_gate_v38.sh.before"

python3 - "$TARGET" <<'PY_PATCH'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

patches = []

old_cwd = '''set -Eeuo pipefail
python3 -m pytest --version
rg --version | head -1'''
new_cwd = '''set -Eeuo pipefail
cd /
python3 -m pytest --version
rg --version | head -1'''
patches.append(("worker_cwd", old_cwd, new_cwd))

old_auth = '''  | tee "$TMP/auth.jsonl"
grep -Fq '"text":"AUTH_OK"' "$TMP/auth.jsonl"
echo WORKER_AUTH_INFERENCE=PASS'''
new_auth = '''  2>&1 | tee "$TMP/auth.jsonl"
python3 - "$TMP/auth.jsonl" <<'PY_AUTH'
import json
import sys

found = False
with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    for line in fh:
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if record.get("type") != "item.completed":
            continue
        item = record.get("item") or {}
        if item.get("type") == "agent_message" and str(item.get("text", "")).strip() == "AUTH_OK":
            found = True
            break
if not found:
    raise SystemExit("AUTH_OK agent_message not found")
print("WORKER_AUTH_JSON=PASS")
PY_AUTH
echo WORKER_AUTH_INFERENCE=PASS'''
patches.append(("auth_stream", old_auth, new_auth))

old_reject_a = '''  if [[ -f "$EVIDENCE/gate-bridge-result.json" ]]; then
    python3 - "$EVIDENCE/gate-bridge-result.json" <<'PY' | tee "$EVIDENCE/gate-terminal-readable.json"'''
new_reject_a = '''  if [[ -f "$EVIDENCE/gate-bridge-result.json" ]]; then
    set +e
    python3 - "$EVIDENCE/gate-bridge-result.json" <<'PY' | tee "$EVIDENCE/gate-terminal-readable.json"'''
patches.append(("gate_rejection_pipeline", old_reject_a, new_reject_a))

old_reject_b = '''    CLASSIFY_RC=${PIPESTATUS[0]}
    [[ "$CLASSIFY_RC" -ne 10 ]] || fail GATE_REJECTED "findings em gate-terminal-readable.json"'''
new_reject_b = '''    CLASSIFY_RC=${PIPESTATUS[0]}
    set -e
    [[ "$CLASSIFY_RC" -ne 10 ]] || fail GATE_REJECTED "findings em gate-terminal-readable.json"'''
patches.append(("gate_rejection_rc", old_reject_b, new_reject_b))

for label, old, new in patches:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one {label} block, found {count}")
    text = text.replace(old, new, 1)

path.write_text(text, encoding="utf-8")
PY_PATCH

chmod 700 "$TARGET"
bash -n "$TARGET" || fail PATCHED_SCRIPT_SYNTAX_FAILED

grep -Fq $'set -Eeuo pipefail\ncd /\npython3 -m pytest --version' "$TARGET" ||
  fail WORKER_CWD_PATCH_MISSING
grep -Fq '2>&1 | tee "$TMP/auth.jsonl"' "$TARGET" ||
  fail AUTH_STDERR_CAPTURE_MISSING
grep -Fq 'WORKER_AUTH_JSON=PASS' "$TARGET" ||
  fail AUTH_JSON_VALIDATOR_MISSING
grep -Fq 'CLASSIFY_RC=${PIPESTATUS[0]}' "$TARGET" ||
  fail GATE_REJECTION_CAPTURE_MISSING

PATCHED_SHA256="$(sha256sum "$TARGET" | awk '{print $1}')"
printf '%s  %s\n' "$SOURCE_BLOB" source-git-blob > "$EVIDENCE/MANIFEST"
printf '%s  %s\n' "$PATCHED_SHA256" 11_pr17_exact_sha_gate_v384_patched.sh >> "$EVIDENCE/MANIFEST"

cat <<EOF
OPERACAO_ZCR17_V384_WRAPPER: PASS
SOURCE_COMMIT=$SOURCE_COMMIT
SOURCE_BLOB=$SOURCE_BLOB
PATCHED_SHA256=$PATCHED_SHA256
PATCH_BASE=V38_DIRECT
WORKER_PREFLIGHT_CWD=/
AUTH_STREAM_CAPTURE=stdout_plus_stderr
AUTH_VALIDATION=structured_agent_message
GATE_REJECTION_CAPTURE=PASS
EVIDENCE_DIR=$EVIDENCE
EOF

exec bash "$TARGET"
