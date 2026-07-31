#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

SOURCE_COMMIT="04af84d5cc1a85618297442a08ce3ba85835160d"
SOURCE_BLOB="824c76f7e8108c4079bda597c6e916ab4a198012"
SOURCE_URL="https://raw.githubusercontent.com/lucaspprates/AmizadeChain/${SOURCE_COMMIT}/tmp/onca-8x1-v3/11c_fix_worker_preflight_cwd_and_run_v382.sh"
TARGET="/tmp/11_pr17_exact_sha_gate_v383_patched.sh"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="/tmp/evidence/zcr17-v383-auth-stream-${STAMP}"
mkdir -p "$EVIDENCE"

fail() {
  echo "ERRO: $*" >&2
  echo "OPERACAO_ZCR17_V383_WRAPPER: BLOCKED"
  echo "EVIDENCE_DIR=$EVIDENCE"
  exit 1
}

[[ "$(id -un)" == "ubuntu" ]] || fail USER_MISMATCH
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail HOST_MISMATCH

curl -fsSL --retry 3 --retry-delay 1 "$SOURCE_URL" -o "$TARGET"
[[ "$(git hash-object "$TARGET")" == "$SOURCE_BLOB" ]] || fail SOURCE_BLOB_MISMATCH
cp -a "$TARGET" "$EVIDENCE/11c_fix_worker_preflight_cwd_and_run_v382.sh.before"

python3 - "$TARGET" <<'PY_PATCH'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = '''  'Do not create or modify files. Reply with exactly AUTH_OK.' \\
  | tee "$TMP/auth.jsonl"
grep -Fq '\"text\":\"AUTH_OK\"' "$TMP/auth.jsonl"
echo WORKER_AUTH_INFERENCE=PASS'''
new = '''  'Do not create or modify files. Reply with exactly AUTH_OK.' \\
  2>&1 | tee "$TMP/auth.jsonl"
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
count = text.count(old)
if count != 1:
    raise SystemExit(f"expected one auth inference block, found {count}")
text = text.replace(old, new, 1)
path.write_text(text, encoding="utf-8")
PY_PATCH

chmod 700 "$TARGET"
bash -n "$TARGET" || fail PATCHED_SCRIPT_SYNTAX_FAILED
grep -Fq '2>&1 | tee "$TMP/auth.jsonl"' "$TARGET" || fail AUTH_STDERR_CAPTURE_MISSING
grep -Fq 'WORKER_AUTH_JSON=PASS' "$TARGET" || fail AUTH_JSON_VALIDATOR_MISSING
grep -Fq 'agent_message' "$TARGET" || fail AUTH_AGENT_MESSAGE_VALIDATOR_MISSING

PATCHED_SHA256="$(sha256sum "$TARGET" | awk '{print $1}')"
printf '%s  %s\n' "$SOURCE_BLOB" source-git-blob > "$EVIDENCE/MANIFEST"
printf '%s  %s\n' "$PATCHED_SHA256" 11_pr17_exact_sha_gate_v383_patched.sh >> "$EVIDENCE/MANIFEST"

cat <<EOF
OPERACAO_ZCR17_V383_WRAPPER: PASS
SOURCE_COMMIT=$SOURCE_COMMIT
SOURCE_BLOB=$SOURCE_BLOB
PATCHED_SHA256=$PATCHED_SHA256
WORKER_PREFLIGHT_CWD=/
AUTH_STREAM_CAPTURE=stdout_plus_stderr
AUTH_VALIDATION=structured_agent_message
GATE_REJECTION_CAPTURE=PASS
EVIDENCE_DIR=$EVIDENCE
EOF

exec bash "$TARGET"
