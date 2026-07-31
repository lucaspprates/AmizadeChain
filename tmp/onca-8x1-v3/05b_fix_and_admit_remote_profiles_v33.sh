#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

SOURCE_COMMIT="f225fbfd4a0c3a6fa0c74022436e8c318e5e0216"
SOURCE_URL="https://raw.githubusercontent.com/lucaspprates/AmizadeChain/${SOURCE_COMMIT}/tmp/onca-8x1-v3/05_admit_remote_profiles_v32.sh"
EXPECTED_SOURCE_BLOB="fb05e37f81efd10505e0ea543cef2e8a827b0658"
TARGET="/tmp/05_admit_remote_profiles_v33_patched.sh"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="/tmp/evidence/onca-router-route-admission-v33-${STAMP}"

fail() {
  echo "ERRO: $*" >&2
  echo "OPERACAO_ONCA_ROUTER_ROUTE_ADMISSION_V33: BLOCKED"
  echo "EVIDENCE_DIR=$EVIDENCE"
  exit 1
}

[[ "$(id -un)" == "ubuntu" ]] || fail "USER_MISMATCH"
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail "HOST_MISMATCH"
mkdir -p "$EVIDENCE"

curl -fsSL --retry 3 --retry-delay 1 "$SOURCE_URL" -o "$TARGET"
[[ "$(git hash-object "$TARGET")" == "$EXPECTED_SOURCE_BLOB" ]] || fail "SOURCE_BLOB_MISMATCH"
cp -a "$TARGET" "$EVIDENCE/05_admit_remote_profiles_v32.sh.before"

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = 'conn.execute("CREATE TABLE provider_capacity (coder TEXT PRIMARY KEY, state TEXT NOT NULL, reason TEXT NOT NULL, blocked_at TEXT NOT NULL)")\n'
replacement = needle + 'conn.execute("CREATE TABLE jobs (status TEXT NOT NULL, selected_coder TEXT NOT NULL)")\n'
count = text.count(needle)
if count != 1:
    raise SystemExit(f"expected exactly one provider_capacity fixture, found {count}")
if 'CREATE TABLE jobs (status TEXT NOT NULL, selected_coder TEXT NOT NULL)' in text:
    raise SystemExit("jobs fixture already present")
text = text.replace(needle, replacement, 1)
path.write_text(text, encoding="utf-8")
PY

chmod 700 "$TARGET"
bash -n "$TARGET" || fail "PATCHED_SCRIPT_SYNTAX_FAILED"
grep -Fq 'CREATE TABLE jobs (status TEXT NOT NULL, selected_coder TEXT NOT NULL)' "$TARGET" ||
  fail "JOBS_FIXTURE_MISSING_AFTER_PATCH"

PATCHED_SHA256="$(sha256sum "$TARGET" | awk '{print $1}')"
printf '%s  %s\n' "$EXPECTED_SOURCE_BLOB" "source-git-blob" > "$EVIDENCE/MANIFEST"
printf '%s  %s\n' "$PATCHED_SHA256" "05_admit_remote_profiles_v33_patched.sh" >> "$EVIDENCE/MANIFEST"

cat <<EOF
ONCA_ROUTER_ADMISSION_V33_PATCH: PASS
SOURCE_COMMIT=$SOURCE_COMMIT
SOURCE_BLOB=$EXPECTED_SOURCE_BLOB
PATCHED_SHA256=$PATCHED_SHA256
FIXTURE_TABLES=provider_capacity,jobs
EVIDENCE_DIR=$EVIDENCE
EOF

exec bash "$TARGET"
