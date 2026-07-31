#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

SOURCE_URL='https://raw.githubusercontent.com/lucaspprates/AmizadeChain/87803d84355b03dd466399621a54a5cfc6e79c87/tmp/zcr19-manual/07b2_freeze_and_diagnose_active_job.sh'
SOURCE_SHA256='5a13843932ced47350c1580722dca53fe5a18d9171b6c5119cd1661cf36947b1'
SOURCE_BLOB='059416037eeee067b9c9b5ceecd850c9dea172b5'
SOURCE='/tmp/07b2_freeze_and_diagnose_active_job.original.sh'
PATCHED='/tmp/07b2_freeze_and_diagnose_active_job.schema-compatible.sh'

curl -fsSL "$SOURCE_URL" -o "$SOURCE"
printf '%s  %s\n' "$SOURCE_SHA256" "$SOURCE" | sha256sum -c -
test "$(git hash-object "$SOURCE")" = "$SOURCE_BLOB"
bash -n "$SOURCE"

python3 - "$SOURCE" "$PATCHED" <<'PY'
from pathlib import Path
import sys

source_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
text = source_path.read_text(encoding="utf-8")

old_query = '''wake_lease = [
    dict(row)
    for row in conn.execute(
        "SELECT * FROM wake_lease ORDER BY singleton"
    ).fetchall()
]
'''
new_query = '''tables = {
    row["name"]
    for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
}
wake_lease_table_present = "wake_lease" in tables
if wake_lease_table_present:
    wake_lease = [
        dict(row)
        for row in conn.execute(
            "SELECT * FROM wake_lease ORDER BY singleton"
        ).fetchall()
    ]
else:
    wake_lease = []
'''

old_payload = '''payload = {
    "captured_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    "active_job_count": len(rows),
'''
new_payload = '''payload = {
    "captured_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    "wake_lease_table_present": wake_lease_table_present,
    "active_job_count": len(rows),
'''

old_output = 'print(f"ACTIVE_JOB_COUNT={len(jobs)}")\n'
new_output = '''print(
    "WAKE_LEASE_TABLE_PRESENT="
    + str(bool(payload.get("wake_lease_table_present"))).lower()
)
print(f"ACTIVE_JOB_COUNT={len(jobs)}")
'''

replacements = [
    (old_query, new_query, "wake_lease query"),
    (old_payload, new_payload, "snapshot payload"),
    (old_output, new_output, "classification output"),
]
for old, new, label in replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"PATCH_SOURCE_MISMATCH: {label}: occurrences={count}")
    text = text.replace(old, new, 1)

target_path.write_text(text, encoding="utf-8")
target_path.chmod(0o700)
PY

bash -n "$PATCHED"
echo "PATCHED_SHA256=$(sha256sum "$PATCHED" | awk '{print $1}')"
echo "PATCHED_BLOB=$(git hash-object "$PATCHED")"
echo 'SCHEMA_COMPATIBILITY_PATCH=PASS'
exec "$PATCHED"
