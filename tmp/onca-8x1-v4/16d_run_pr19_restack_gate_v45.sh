#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

GUARD_COMMIT="56e07c220cff127ed50bcf1f01c612320d3b922b"
GUARD_BLOB="5774d37553f53efd387dadbbb8ffd4f1c9f84a86"
GUARD_URL="https://raw.githubusercontent.com/lucaspprates/AmizadeChain/${GUARD_COMMIT}/tmp/onca-8x1-v4/15c_fix_and_run_onca_codex_auth_guard_v44.sh"
GUARD_TARGET="/tmp/15c_fix_and_run_onca_codex_auth_guard_v44.sh"

RESTACK_COMMIT="7c9e0fba417fb4b416c41ea93717b724f55ddb2b"
RESTACK_INSTALLER_BLOB="ab3d7a68c662c335017cf97d9e59be08c13d0da7"
RESTACK_URL="https://raw.githubusercontent.com/lucaspprates/AmizadeChain/${RESTACK_COMMIT}/tmp/onca-8x1-v4/14_run_pr19_restack_and_gate_v41.sh"
RESTACK_INSTALLER="/tmp/14_run_pr19_restack_and_gate_v41.sh"
RESTACK_PAYLOAD="/tmp/14_pr19_restack_and_exact_gate_v45_patched.sh"
EXPECTED_PAYLOAD_SHA256="360242331f868e482e779c8a7845c48207c0b195ef4a01570035c603fe0b305f"
EXPECTED_PAYLOAD_GIT_BLOB="1f04f57473bfb462c4c378d78035b4b7153d0a2e"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="/tmp/evidence/pr19-restack-gate-v45-patcher-${STAMP}"
mkdir -p "$EVIDENCE"

fail() {
  local code="$1"
  shift
  echo "ERRO: $*" >&2
  echo "ONCA_PR19_RESTACK_GATE_V45: BLOCKED"
  echo "FAILURE_CODE=$code"
  echo "REMOTE_BRANCH_UPDATED=false"
  echo "CONTROL_PLANE_CHANGED=false"
  echo "EVIDENCE_DIR=$EVIDENCE"
  exit 1
}

[[ "$(id -un)" == "ubuntu" ]] || fail USER_MISMATCH "execute como ubuntu"
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail HOST_MISMATCH "host atual=$(hostname -s)"
[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail TIMER_NOT_INACTIVE "reconciler deve permanecer congelado"

curl -fsSL --retry 3 --retry-delay 1 "$GUARD_URL" -o "$GUARD_TARGET"
[[ "$(git hash-object "$GUARD_TARGET")" == "$GUARD_BLOB" ]] ||
  fail AUTH_GUARD_BLOB_MISMATCH "Auth Guard V4.4 divergente"
bash -n "$GUARD_TARGET" || fail AUTH_GUARD_SYNTAX_FAILED "bash -n do guard falhou"
chmod 700 "$GUARD_TARGET"

echo '===== FASE A — AUTENTICAÇÃO NO MESMO USUÁRIO DA FÁBRICA ====='
set +e
bash "$GUARD_TARGET"
GUARD_RC=$?
set -e
[[ "$GUARD_RC" -eq 0 ]] || fail AUTH_GUARD_FAILED "rc=$GUARD_RC"

echo
echo '===== FASE B — EXTRAÇÃO IMUTÁVEL DO V4.1 ====='
curl -fsSL --retry 3 --retry-delay 1 "$RESTACK_URL" -o "$RESTACK_INSTALLER"
[[ "$(git hash-object "$RESTACK_INSTALLER")" == "$RESTACK_INSTALLER_BLOB" ]] ||
  fail RESTACK_INSTALLER_BLOB_MISMATCH "instalador V4.1 divergente"
cp -a "$RESTACK_INSTALLER" "$EVIDENCE/14_run_pr19_restack_and_gate_v41.sh"

python3 - "$RESTACK_INSTALLER" "$RESTACK_PAYLOAD" <<'PY_EXTRACT'
import base64
import gzip
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(
    r"base64 -d <<'PAYLOAD' \| gzip -d > \"\$TARGET\"\n(?P<data>.*?)\nPAYLOAD\n",
    source,
    flags=re.DOTALL,
)
if not match:
    raise SystemExit("embedded PAYLOAD block not found")
encoded = "".join(match.group("data").split())
raw = gzip.decompress(base64.b64decode(encoded, validate=True))
Path(sys.argv[2]).write_bytes(raw)
PY_EXTRACT

[[ "$(sha256sum "$RESTACK_PAYLOAD" | awk '{print $1}')" == "$EXPECTED_PAYLOAD_SHA256" ]] ||
  fail RESTACK_PAYLOAD_SHA256_MISMATCH "payload V4.1 divergente"
[[ "$(git hash-object "$RESTACK_PAYLOAD")" == "$EXPECTED_PAYLOAD_GIT_BLOB" ]] ||
  fail RESTACK_PAYLOAD_BLOB_MISMATCH "blob do payload V4.1 divergente"
cp -a "$RESTACK_PAYLOAD" "$EVIDENCE/14_pr19_restack_and_exact_gate_v41.before.sh"

echo 'V41_PAYLOAD_READBACK=PASS'

echo
echo '===== FASE C — CORREÇÃO DETERMINÍSTICA DO AMBIENTE REMOTO ====='
python3 - "$RESTACK_PAYLOAD" "$EVIDENCE" <<'PY_PATCH'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
evidence = Path(sys.argv[2])
text = path.read_text(encoding="utf-8")

phase_marker = "===== 4. VALIDAÇÃO PRÉ-PUSH NO WORKER ====="
start = text.find(phase_marker)
if start < 0:
    raise SystemExit("phase-4 marker not found")
next_match = re.search(r"===== 5\.", text[start + len(phase_marker):])
end = len(text) if next_match is None else start + len(phase_marker) + next_match.start()
section = text[start:end]
(evidence / "phase4.before.txt").write_text(section, encoding="utf-8")

launch_lines = [
    line for line in section.splitlines()
    if ("bash -s" in line and ("SSH" in line or re.search(r"\bworker\b", line)))
]
if len(launch_lines) != 1:
    raise SystemExit(f"expected exactly one phase-4 remote bash launch, found {len(launch_lines)}: {launch_lines!r}")
launch = launch_lines[0]
if "onca-runner" in launch:
    raise SystemExit(f"phase-4 launch already names onca-runner; refusing blind patch: {launch}")

remote_shell = (
    "sudo -n -u onca-runner -H env "
    "-u OPENAI_API_KEY -u OPENAI_BASE_URL -u OPENAI_API_BASE "
    "-u CODEX_HOME -u XDG_CONFIG_HOME HOME=/home/onca-runner bash -s"
)
patched_launch = launch.replace("bash -s", remote_shell, 1)
if patched_launch == launch:
    raise SystemExit("remote bash launch replacement produced no change")
section = section.replace(launch, patched_launch, 1)

strict = "set -Eeuo pipefail"
strict_index = section.find(strict, section.find(patched_launch) + len(patched_launch))
if strict_index < 0:
    raise SystemExit("remote strict-mode line not found after patched launch")
insert_at = strict_index + len(strict)
preamble = r'''

[[ "$(id -un)" == "onca-runner" ]]
[[ "$HOME" == "/home/onca-runner" ]]
cd /
[[ -s /home/onca-runner/.codex/auth.json ]]
echo "prepush_user=$(id -un)"
echo "prepush_home=$HOME"
echo "prepush_pwd=$PWD"
echo "prepush_auth_file=present"
'''
section = section[:insert_at] + preamble + section[insert_at:]

prompt = "'Do not create or modify files. Reply with exactly AUTH_OK.'"
prompt_index = section.find(prompt)
if prompt_index < 0:
    raise SystemExit("AUTH_OK inference prompt not found in phase 4")
command_start = section.rfind("codex exec", 0, prompt_index)
if command_start < 0:
    raise SystemExit("codex exec start not found before AUTH_OK prompt")
command_tail_end = section.find("\n", prompt_index)
if command_tail_end < 0:
    command_tail_end = len(section)
command_window = section[command_start:command_tail_end + 1]
if "</dev/null" not in command_window:
    prompt_line_end = section.find("\n", prompt_index)
    if prompt_line_end < 0:
        raise SystemExit("AUTH_OK prompt line has no newline")
    prompt_line = section[section.rfind("\n", 0, prompt_index) + 1:prompt_line_end]
    indent = re.match(r"\s*", prompt_line).group(0)
    continuation = " \\" if prompt_line.rstrip().endswith("\\") else ""
    if continuation:
        redirect_line = f"{indent}</dev/null \\\n"
        section = section[:prompt_line_end + 1] + redirect_line + section[prompt_line_end + 1:]
    else:
        section = section[:prompt_line_end] + " </dev/null" + section[prompt_line_end:]

if "sudo -n -u onca-runner -H env" not in section:
    raise SystemExit("onca-runner remote launch missing after patch")
if "prepush_user=$(id -un)" not in section:
    raise SystemExit("remote identity preamble missing after patch")
if "</dev/null" not in section[command_start:section.find("AUTH_OK", command_start) + 400]:
    raise SystemExit("AUTH_OK codex stdin isolation missing after patch")

new_text = text[:start] + section + text[end:]
path.write_text(new_text, encoding="utf-8")
(evidence / "phase4.after.txt").write_text(section, encoding="utf-8")

print("REMOTE_PREPUSH_USER_PATCH=PASS")
print("REMOTE_PREPUSH_HOME_PATCH=PASS")
print("REMOTE_PREPUSH_AUTH_ENV_SANITIZED=PASS")
print("REMOTE_CODEX_STDIN_ISOLATED=PASS")
PY_PATCH

chmod 700 "$RESTACK_PAYLOAD"
bash -n "$RESTACK_PAYLOAD" || fail PATCHED_PAYLOAD_SYNTAX_FAILED "bash -n falhou"
PATCHED_SHA256="$(sha256sum "$RESTACK_PAYLOAD" | awk '{print $1}')"
PATCHED_BLOB="$(git hash-object "$RESTACK_PAYLOAD")"
printf '%s  %s\n' "$EXPECTED_PAYLOAD_GIT_BLOB" original-payload-git-blob > "$EVIDENCE/MANIFEST"
printf '%s  %s\n' "$PATCHED_BLOB" patched-payload-git-blob >> "$EVIDENCE/MANIFEST"
printf '%s  %s\n' "$PATCHED_SHA256" patched-payload-sha256 >> "$EVIDENCE/MANIFEST"

echo "PATCHED_PAYLOAD_SHA256=$PATCHED_SHA256"
echo "PATCHED_PAYLOAD_GIT_BLOB=$PATCHED_BLOB"
echo "EVIDENCE_DIR=$EVIDENCE"

echo
echo '===== FASE D — RESTACK + TESTES + GATE EXACT-SHA ====='
exec bash "$RESTACK_PAYLOAD"
