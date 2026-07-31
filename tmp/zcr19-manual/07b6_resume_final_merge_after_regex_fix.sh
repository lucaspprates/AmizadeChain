#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

SOURCE_URL='https://raw.githubusercontent.com/lucaspprates/AmizadeChain/7abfa51e5baf076c4102a6483545ac8ff361277f/tmp/zcr19-manual/07b5_finalize_merge_pr19_heredoc_safe.sh'
SOURCE_SHA256='9605926a2352e02adc224be818e79b09272f689fbf774ce678baf99fa5f2868b'
SOURCE_BLOB='6dfcd8eb672591cc7fc9b180c05953eee6e4de09'
SOURCE='/tmp/07b5_finalize_merge_pr19_heredoc_safe.original.sh'
PATCHED='/tmp/07b5_finalize_merge_pr19_heredoc_safe.regex-fixed.sh'

curl -fsSL "$SOURCE_URL" -o "$SOURCE"
printf '%s  %s\n' "$SOURCE_SHA256" "$SOURCE" | sha256sum -c -
test "$(git hash-object "$SOURCE")" = "$SOURCE_BLOB"
bash -n "$SOURCE"

python3 - "$SOURCE" "$PATCHED" <<'PY_PATCH'
from pathlib import Path
import sys

source_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
lines = source_path.read_text(encoding="utf-8").splitlines(keepends=True)

replacement = r'''    r'cat > "[$]EVIDENCE_TMP/pr19-final-body[.]md" <<EOF_BODY\\\\n(.*?)\\\\nEOF_BODY',''' + "\n"

matches = 0
for index, line in enumerate(lines):
    if (
        "r'cat >" in line
        and "pr19-final-body" in line
        and "EOF_BODY" in line
    ):
        lines[index] = replacement
        matches += 1

if matches != 1:
    raise SystemExit(f"REGEX_LINE_PATCH_MISMATCH:occurrences={matches}")

text = "".join(lines)
required = r'''r'cat > "[$]EVIDENCE_TMP/pr19-final-body[.]md" <<EOF_BODY\\\\n(.*?)\\\\nEOF_BODY','''
if text.count(required) != 1:
    raise SystemExit("REGEX_LINE_PATCH_NOT_PERSISTED")

target_path.write_text(text, encoding="utf-8")
target_path.chmod(0o700)
PY_PATCH

bash -n "$PATCHED"

python3 - "$PATCHED" <<'PY_VALIDATE'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
required = r'''r'cat > "[$]EVIDENCE_TMP/pr19-final-body[.]md" <<EOF_BODY\\\\n(.*?)\\\\nEOF_BODY','''
if text.count(required) != 1:
    raise SystemExit("DOUBLE_ESCAPED_NEWLINE_VALIDATION_FAILED")
if "PR_BODY_UPDATE_TRANSPORT=REST_PATCH" not in text:
    raise SystemExit("REST_PATCH_VALIDATION_MISSING")
if "HEREDOC_BACKTICK_CHECK=PASS" not in text:
    raise SystemExit("HEREDOC_CHECK_VALIDATION_MISSING")
print("NESTED_REGEX_ESCAPE_CHECK=PASS")
PY_VALIDATE

echo "PATCHED_SHA256=$(sha256sum "$PATCHED" | awk '{print $1}')"
echo "PATCHED_BLOB=$(git hash-object "$PATCHED")"
echo 'HEREDOC_REGEX_FIX=PASS'
exec "$PATCHED"
