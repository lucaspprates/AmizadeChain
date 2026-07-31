#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

SOURCE_URL='https://raw.githubusercontent.com/lucaspprates/AmizadeChain/cbfb1c38372a28f134fbc5790b494ef68bb6a8af/tmp/zcr19-manual/07b4_finalize_merge_pr19_preserve_owned_queue.sh'
SOURCE_SHA256='e99d5a6ddf887a44fc793ac3a02c9cdef97d45d358c26f42eedd9e6833d62fc6'
SOURCE_BLOB='c73dff806ea998f205512a1549ebe973b8bc1b4e'
SOURCE='/tmp/07b4_finalize_merge_pr19_preserve_owned_queue.original.sh'
PATCHED='/tmp/07b4_finalize_merge_pr19_preserve_owned_queue.heredoc-safe.sh'

curl -fsSL "$SOURCE_URL" -o "$SOURCE"
printf '%s  %s\n' "$SOURCE_SHA256" "$SOURCE" | sha256sum -c -
test "$(git hash-object "$SOURCE")" = "$SOURCE_BLOB"
bash -n "$SOURCE"

python3 - "$SOURCE" "$PATCHED" <<'PY_PATCH_WRAPPER'
from pathlib import Path
import sys

source_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
text = source_path.read_text(encoding="utf-8")

line_replacements = [
    ("- job: `$PRESERVED_JOB_ID`;", "- job: $PRESERVED_JOB_ID;", "job markdown"),
    ("- mission: `$PRESERVED_JOB_MISSION`;", "- mission: $PRESERVED_JOB_MISSION;", "mission markdown"),
    ("- project/issue: `infraops-ai#220`;", "- project/issue: infraops-ai#220;", "project issue markdown"),
    (
        "- branch/head: `$PRESERVED_JOB_BRANCH` at `$PRESERVED_JOB_WORKTREE_HEAD`;",
        "- branch/head: $PRESERVED_JOB_BRANCH at $PRESERVED_JOB_WORKTREE_HEAD;",
        "branch head markdown",
    ),
]

for old, new, label in line_replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"PATCH_SOURCE_MISMATCH:{label}:occurrences={count}")
    text = text.replace(old, new, 1)

old_gate = '''bash -n "$PATCHED"
echo "PATCHED_SHA256=$(sha256sum "$PATCHED" | awk '{print $1}')"
echo "PATCHED_BLOB=$(git hash-object "$PATCHED")"
echo 'PRESERVED_OWNED_QUEUE_PATCH=PASS'
exec "$PATCHED"
'''
new_gate = '''bash -n "$PATCHED"
python3 - "$PATCHED" <<'PY_HEREDOC_CHECK'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
match = re.search(
    r'cat > "\$EVIDENCE_TMP/pr19-final-body\.md" <<EOF_BODY\n(.*?)\nEOF_BODY',
    text,
    re.DOTALL,
)
if not match:
    raise SystemExit("HEREDOC_BODY_NOT_FOUND")
body = match.group(1)
unescaped = [m.start() for m in re.finditer(r'(?<!\\)`', body)]
if unescaped:
    raise SystemExit(f"UNESCAPED_BACKTICKS_IN_PR_BODY:{unescaped}")
required = [
    "$PRESERVED_JOB_ID",
    "$PRESERVED_JOB_MISSION",
    "infraops-ai#220",
    "$PRESERVED_JOB_BRANCH",
    "$PRESERVED_JOB_WORKTREE_HEAD",
]
missing = [item for item in required if item not in body]
if missing:
    raise SystemExit(f"PRESERVED_JOB_BODY_FIELDS_MISSING:{missing}")
print("HEREDOC_BACKTICK_CHECK=PASS")
PY_HEREDOC_CHECK
echo "PATCHED_SHA256=$(sha256sum "$PATCHED" | awk '{print $1}')"
echo "PATCHED_BLOB=$(git hash-object "$PATCHED")"
echo 'PRESERVED_OWNED_QUEUE_PATCH=PASS'
exec "$PATCHED"
'''

count = text.count(old_gate)
if count != 1:
    raise SystemExit(f"PATCH_SOURCE_MISMATCH:execution_gate:occurrences={count}")
text = text.replace(old_gate, new_gate, 1)

target_path.write_text(text, encoding="utf-8")
target_path.chmod(0o700)
PY_PATCH_WRAPPER

bash -n "$PATCHED"
echo "WRAPPER_PATCHED_SHA256=$(sha256sum "$PATCHED" | awk '{print $1}')"
echo "WRAPPER_PATCHED_BLOB=$(git hash-object "$PATCHED")"
echo 'HEREDOC_SAFE_WRAPPER_PATCH=PASS'
exec "$PATCHED"
