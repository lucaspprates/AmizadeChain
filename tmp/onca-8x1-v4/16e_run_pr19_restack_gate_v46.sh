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
RESTACK_PAYLOAD="/tmp/14_pr19_restack_and_exact_gate_v46_patched.sh"
EXPECTED_PAYLOAD_SHA256="360242331f868e482e779c8a7845c48207c0b195ef4a01570035c603fe0b305f"
EXPECTED_PAYLOAD_GIT_BLOB="1f04f57473bfb462c4c378d78035b4b7153d0a2e"

WORKER_HOST="201.23.86.157"
WORKER_USER="ubuntu"
WORKER_NAME="win-codex-wak-01"
RUN_USER="onca-runner"
SSH_KEY="/home/ubuntu/.ssh/ssh-key-2026-06-03.key"
KNOWN_HOSTS="/home/ubuntu/.ssh/known_hosts_onca_8x1"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="/tmp/evidence/pr19-restack-gate-v46-patcher-${STAMP}"
mkdir -p "$EVIDENCE"

fail() {
  local code="$1"
  shift
  echo "ERRO: $*" >&2
  echo "ONCA_PR19_RESTACK_GATE_V46: BLOCKED"
  echo "FAILURE_CODE=$code"
  echo "REMOTE_BRANCH_UPDATED=false"
  echo "CONTROL_PLANE_CHANGED=false"
  echo "EVIDENCE_DIR=$EVIDENCE"
  exit 1
}

active_units() {
  systemctl list-units \
    'zoe-coder-job@*.service' \
    'zoe-coder-wake@*.service' \
    --state=active,activating \
    --no-legend --no-pager 2>/dev/null | wc -l
}

[[ "$(id -un)" == "ubuntu" ]] || fail USER_MISMATCH "execute como ubuntu"
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail HOST_MISMATCH "host atual=$(hostname -s)"
[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail TIMER_NOT_INACTIVE "reconciler deve permanecer congelado"
[[ "$(active_units)" -eq 0 ]] || fail ACTIVE_UNITS_PRESENT "há units ativas"
[[ -f "$SSH_KEY" ]] || fail SSH_KEY_MISSING "$SSH_KEY"
[[ "$(stat -c %a "$SSH_KEY")" == "600" ]] || fail SSH_KEY_MODE_INVALID "$(stat -c %a "$SSH_KEY")"
[[ -f "$KNOWN_HOSTS" ]] || fail KNOWN_HOSTS_MISSING "$KNOWN_HOSTS"

SSH=(
  ssh
  -i "$SSH_KEY"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o ConnectTimeout=15
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=4
  "${WORKER_USER}@${WORKER_HOST}"
)

echo '===== FASE A — AUTH GUARD JÁ VALIDADO ====='
curl -fsSL --retry 3 --retry-delay 1 "$GUARD_URL" -o "$GUARD_TARGET"
[[ "$(git hash-object "$GUARD_TARGET")" == "$GUARD_BLOB" ]] ||
  fail AUTH_GUARD_BLOB_MISMATCH "Auth Guard V4.4 divergente"
bash -n "$GUARD_TARGET" || fail AUTH_GUARD_SYNTAX_FAILED "bash -n do guard falhou"
chmod 700 "$GUARD_TARGET"
set +e
bash "$GUARD_TARGET"
GUARD_RC=$?
set -e
[[ "$GUARD_RC" -eq 0 ]] || fail AUTH_GUARD_FAILED "rc=$GUARD_RC"

echo
echo '===== FASE B — PREFLIGHT DA FRONTEIRA UBUNTU -> ONCA-RUNNER ====='
set +e
"${SSH[@]}" "bash -s" >"$EVIDENCE/privilege-boundary-preflight.log" 2>&1 <<'REMOTE_PREFLIGHT'
set -Eeuo pipefail
umask 0077
cd /

[[ "$(hostname -s)" == "win-codex-wak-01" ]]
[[ "$(id -un)" == "ubuntu" ]]
sudo -n true

echo "outer_user=$(id -un)"
echo "outer_home=$HOME"
echo "outer_pwd=$PWD"
echo "outer_sudo_nopasswd=PASS"

sudo -n -u onca-runner -H env \
  -u OPENAI_API_KEY \
  -u OPENAI_BASE_URL \
  -u OPENAI_API_BASE \
  -u CODEX_HOME \
  -u XDG_CONFIG_HOME \
  HOME=/home/onca-runner \
  bash -s </dev/null <<'INNER'
set -Eeuo pipefail
umask 0077
cd /
[[ "$(id -un)" == "onca-runner" ]]
[[ "$HOME" == "/home/onca-runner" ]]
[[ -s /home/onca-runner/.codex/auth.json ]]
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
cd "$TMP"
git init -q
git config user.name onca-boundary-check
git config user.email onca-boundary-check@invalid.local
codex exec \
  --json \
  --ephemeral \
  --dangerously-bypass-approvals-and-sandbox \
  --skip-git-repo-check \
  --cd "$TMP" \
  --model gpt-5.6-terra \
  -c 'features.plugins=false' \
  -c 'model_reasoning_effort="low"' \
  'Do not create or modify files. Reply with exactly AUTH_OK.' \
  </dev/null >"$TMP/auth.jsonl" 2>&1
python3 - "$TMP/auth.jsonl" <<'PY_AUTH'
import json
import sys
from pathlib import Path

for line in Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines():
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        continue
    if record.get("type") != "item.completed":
        continue
    item = record.get("item") or {}
    if item.get("type") == "agent_message" and str(item.get("text", "")).strip() == "AUTH_OK":
        print("INNER_AUTH_OK=PASS")
        raise SystemExit(0)
raise SystemExit("AUTH_OK agent_message not found")
PY_AUTH

echo "inner_user=$(id -un)"
echo "inner_home=$HOME"
echo "inner_auth_file=present"
echo "PRIVILEGE_BOUNDARY_AUTH=PASS"
INNER
REMOTE_PREFLIGHT
BOUNDARY_RC=$?
set -e
cat "$EVIDENCE/privilege-boundary-preflight.log"
[[ "$BOUNDARY_RC" -eq 0 ]] || fail PRIVILEGE_BOUNDARY_PREFLIGHT_FAILED "rc=$BOUNDARY_RC"
grep -Fq 'outer_sudo_nopasswd=PASS' "$EVIDENCE/privilege-boundary-preflight.log" ||
  fail OUTER_SUDO_PASS_MARKER_MISSING "sudo NOPASSWD não comprovado"
grep -Fq 'PRIVILEGE_BOUNDARY_AUTH=PASS' "$EVIDENCE/privilege-boundary-preflight.log" ||
  fail INNER_AUTH_PASS_MARKER_MISSING "onca-runner não autenticou na fronteira exata"

echo
echo '===== FASE C — EXTRAÇÃO IMUTÁVEL DO V4.1 ====='
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
echo '===== FASE D — PATCH SOMENTE NO PROCESSO CODEX ====='
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
    raise SystemExit(f"outer phase-4 launch must remain ubuntu, got: {launch}")

prompt = "'Do not create or modify files. Reply with exactly AUTH_OK.'"
prompt_index = section.find(prompt)
if prompt_index < 0:
    raise SystemExit("AUTH_OK inference prompt not found in phase 4")
command_start = section.rfind("codex exec", 0, prompt_index)
if command_start < 0:
    raise SystemExit("codex exec start not found before AUTH_OK prompt")

prefix = (
    "sudo -n -u onca-runner -H env "
    "-u OPENAI_API_KEY -u OPENAI_BASE_URL -u OPENAI_API_BASE "
    "-u CODEX_HOME -u XDG_CONFIG_HOME HOME=/home/onca-runner codex exec"
)
section = section[:command_start] + prefix + section[command_start + len("codex exec"):]

precheck = r'''sudo -n -u onca-runner -H env \
  -u OPENAI_API_KEY \
  -u OPENAI_BASE_URL \
  -u OPENAI_API_BASE \
  -u CODEX_HOME \
  -u XDG_CONFIG_HOME \
  HOME=/home/onca-runner \
  bash -lc 'cd /; test "$(id -un)" = onca-runner; test "$HOME" = /home/onca-runner; test -s /home/onca-runner/.codex/auth.json; echo prepush_codex_user=$(id -un); echo prepush_codex_home=$HOME; echo prepush_codex_auth_file=present'
'''
section = section[:command_start] + precheck + section[command_start:]

# command_start moved after insertion; locate the patched command again.
patched_command_start = section.find(prefix, command_start + len(precheck))
if patched_command_start < 0:
    raise SystemExit("patched Codex command not found")
prompt_index = section.find(prompt, patched_command_start)
if prompt_index < 0:
    raise SystemExit("AUTH_OK prompt disappeared after patch")
command_tail_end = section.find("\n", prompt_index)
if command_tail_end < 0:
    command_tail_end = len(section)
command_window = section[patched_command_start:command_tail_end + 1]
if "</dev/null" not in command_window:
    prompt_line_end = section.find("\n", prompt_index)
    if prompt_line_end < 0:
        raise SystemExit("AUTH_OK prompt line has no newline")
    prompt_line_start = section.rfind("\n", 0, prompt_index) + 1
    prompt_line = section[prompt_line_start:prompt_line_end]
    indent = re.match(r"\s*", prompt_line).group(0)
    if prompt_line.rstrip().endswith("\\"):
        section = section[:prompt_line_end + 1] + f"{indent}</dev/null \\\n" + section[prompt_line_end + 1:]
    else:
        section = section[:prompt_line_end] + " </dev/null" + section[prompt_line_end:]

if launch not in section:
    raise SystemExit("outer ubuntu launch changed unexpectedly")
if prefix not in section:
    raise SystemExit("inner onca-runner Codex prefix missing")
if "prepush_codex_user=$(id -un)" not in section:
    raise SystemExit("inner identity precheck missing")
if "</dev/null" not in section[patched_command_start:section.find("AUTH_OK", patched_command_start) + 500]:
    raise SystemExit("Codex stdin isolation missing")

new_text = text[:start] + section + text[end:]
path.write_text(new_text, encoding="utf-8")
(evidence / "phase4.after.txt").write_text(section, encoding="utf-8")

print("REMOTE_OUTER_USER=ubuntu")
print("REMOTE_SETUP_SUDO_PRESERVED=true")
print("CODEX_RUN_USER=onca-runner")
print("CODEX_HOME=/home/onca-runner")
print("CODEX_AUTH_ENV_SANITIZED=true")
print("CODEX_STDIN_ISOLATED=true")
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
echo '===== FASE E — RESTACK + TESTES + GATE EXACT-SHA ====='
exec bash "$RESTACK_PAYLOAD"
