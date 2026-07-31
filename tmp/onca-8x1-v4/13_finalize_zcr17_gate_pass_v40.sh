#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

RUNTIME="/usr/local/lib/zoe-coder-router/zoe_coder_router.py"
CONFIG="/etc/zoe-coder-router/config.toml"
DB="/var/lib/zoe-coder-router/runtime.db"
BRIDGE="/usr/local/bin/onca-codex-remote"
REPO="/home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler"
PR17_BRANCH="fix/16-opencode-result-provenance"
PR19_BRANCH="type/18-factory-scheduler-maintenance"
PR17_PREVIOUS_SHA="31b2a8811cf931a5b4e155b30a3cb79927e1111c"
PR17_VALIDATED_SHA="0d935aa174850fa2581538c952d9fcbc832c6e80"
PR19_CURRENT_SHA="e1c8ad08c2783abcf26ed9776b2a9c42f8803896"
GATE_JOB_ID="30233ddf-f111-48f1-a61e-2798c3e7c592"
GATE_PROFILE="codex_terra_remote_gate"
EXPECTED_RUNTIME_SHA256="f181fd627dceff10d46d23598eb54d8cfb5a15b070231aa34b4c09e907fc7d85"
EXPECTED_CONFIG_SHA256="3af46a9069e406a75b8e3e66368fa3a2c688711616bc86a5df12d9e4135595e4"
EXPECTED_BRIDGE_SHA256="4d37ed3baba38dc5d35ac9e11928dd0969dd5e7fbdf3c0f4c3e4af2acafdd4b6"
REMOTE_GATE_DIR="/var/log/zoe-coder-router/remote/$GATE_JOB_ID"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="/tmp/evidence/zcr17-semantic-finalizer-v40-$STAMP"
mkdir -p "$EVIDENCE"

fail() {
  local code="$1"
  shift
  echo "ERRO: $*" >&2
  echo "ZCR17_SEMANTIC_FINALIZER_V40: BLOCKED"
  echo "FAILURE_CODE=$code"
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

sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

sudo_sha256_of() {
  sudo sha256sum "$1" | awk '{print $1}'
}

[[ "$(id -un)" == "ubuntu" ]] || fail USER_MISMATCH "execute como ubuntu"
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail HOST_MISMATCH "host atual=$(hostname -s)"
sudo -v

printf '===== 1. GUARDAS DO CONTROL PLANE =====\n'
TIMER="$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
ACTIVE_UNITS="$(active_units)"
RUNTIME_SHA="$(sha256_of "$RUNTIME")"
CONFIG_SHA="$(sudo_sha256_of "$CONFIG")"
BRIDGE_SHA="$(sha256_of "$BRIDGE")"
printf 'timer=%s\nactive_units=%s\nruntime_sha256=%s\nconfig_sha256=%s\nbridge_sha256=%s\n' \
  "$TIMER" "$ACTIVE_UNITS" "$RUNTIME_SHA" "$CONFIG_SHA" "$BRIDGE_SHA" |
  tee "$EVIDENCE/control-plane-before.txt"

[[ "$TIMER" == "inactive" ]] || fail TIMER_NOT_INACTIVE "$TIMER"
[[ "$ACTIVE_UNITS" -eq 0 ]] || fail ACTIVE_UNITS_PRESENT "$ACTIVE_UNITS"
[[ "$RUNTIME_SHA" == "$EXPECTED_RUNTIME_SHA256" ]] || fail RUNTIME_SHA_MISMATCH "$RUNTIME_SHA"
[[ "$CONFIG_SHA" == "$EXPECTED_CONFIG_SHA256" ]] || fail CONFIG_SHA_MISMATCH "$CONFIG_SHA"
[[ "$BRIDGE_SHA" == "$EXPECTED_BRIDGE_SHA256" ]] || fail BRIDGE_SHA_MISMATCH "$BRIDGE_SHA"
[[ -d "$REPO" ]] || fail REPO_MISSING "$REPO"
[[ -z "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail SOURCE_WORKTREE_NOT_CLEAN "$REPO"

printf '\n===== 2. READBACK IMUTÁVEL DAS BRANCHES =====\n'
git -C "$REPO" fetch -q origin "$PR17_BRANCH" "$PR19_BRANCH"
REMOTE_PR17="$(git -C "$REPO" rev-parse "origin/$PR17_BRANCH")"
REMOTE_PR19="$(git -C "$REPO" rev-parse "origin/$PR19_BRANCH")"
printf 'remote_pr17=%s\nremote_pr19=%s\n' "$REMOTE_PR17" "$REMOTE_PR19" |
  tee "$EVIDENCE/remote-heads.txt"
[[ "$REMOTE_PR17" == "$PR17_VALIDATED_SHA" ]] || fail PR17_HEAD_MISMATCH "$REMOTE_PR17"
[[ "$REMOTE_PR19" == "$PR19_CURRENT_SHA" ]] || fail PR19_HEAD_MISMATCH "$REMOTE_PR19"

git -C "$REPO" cat-file -e "$PR17_PREVIOUS_SHA^{commit}" || fail PR17_PREVIOUS_COMMIT_MISSING
PARENT="$(git -C "$REPO" rev-parse "$PR17_VALIDATED_SHA^")"
COMMIT_COUNT="$(git -C "$REPO" rev-list --count "$PR17_PREVIOUS_SHA..$PR17_VALIDATED_SHA")"
COMMIT_SUBJECT="$(git -C "$REPO" show -s --format=%s "$PR17_VALIDATED_SHA")"
printf 'previous_sha=%s\nvalidated_sha=%s\nparent=%s\ncommit_count=%s\nsubject=%s\n' \
  "$PR17_PREVIOUS_SHA" "$PR17_VALIDATED_SHA" "$PARENT" "$COMMIT_COUNT" "$COMMIT_SUBJECT" |
  tee "$EVIDENCE/pr17-commit-readback.txt"
[[ "$PARENT" == "$PR17_PREVIOUS_SHA" ]] || fail PR17_PARENT_MISMATCH "$PARENT"
[[ "$COMMIT_COUNT" -eq 1 ]] || fail PR17_COMMIT_COUNT_MISMATCH "$COMMIT_COUNT"

git -C "$REPO" diff --name-only "$PR17_PREVIOUS_SHA..$PR17_VALIDATED_SHA" | sort > "$EVIDENCE/pr17-changed-files.txt"
printf '%s\n' \
  'src/zoe_coder_router/zoe_coder_router.py' \
  'tests/test_opencode_result_provenance.py' | sort > "$EVIDENCE/pr17-expected-files.txt"
diff -u "$EVIDENCE/pr17-expected-files.txt" "$EVIDENCE/pr17-changed-files.txt" \
  > "$EVIDENCE/pr17-files-diff.txt" || fail PR17_SCOPE_MISMATCH "consulte pr17-files-diff.txt"
echo 'PR17_COMMIT_SCOPE=PASS'

printf '\n===== 3. RESULTADO SEMÂNTICO DO GATE =====\n'
sudo test -f "$REMOTE_GATE_DIR/result.json" || fail GATE_RESULT_MISSING "$REMOTE_GATE_DIR/result.json"
sudo cp "$REMOTE_GATE_DIR/result.json" "$EVIDENCE/gate-result.json"
sudo chown ubuntu:ubuntu "$EVIDENCE/gate-result.json"
chmod 0600 "$EVIDENCE/gate-result.json"

python3 - "$EVIDENCE/gate-result.json" "$PR17_VALIDATED_SHA" "$PR17_BRANCH" "$GATE_JOB_ID" <<'PY' \
  | tee "$EVIDENCE/gate-semantic-summary.json"
import json
import sys
from pathlib import Path

path, expected_sha, expected_branch, expected_job = sys.argv[1:]
value = json.loads(Path(path).read_text(encoding="utf-8"))
errors = []

def require(condition, message):
    if not condition:
        errors.append(message)

require(value.get("job_id") == expected_job, "job_id mismatch")
require(value.get("status") == "PASS", "runner status is not PASS")
require(value.get("failure_code") is None, "failure_code is not null")
require(value.get("runner_exit_code") == 0, "runner_exit_code is not zero")
require(value.get("codex_exit_code") == 0, "codex_exit_code is not zero")
terminal = value.get("terminal_object")
require(isinstance(terminal, dict), "terminal_object is not an object")
require((terminal or {}).get("gate_status") == "PASS", "gate_status is not PASS")
require(not (terminal or {}).get("findings"), "terminal findings are not empty")
require(value.get("mode") == "read_only", "mode is not read_only")
require(value.get("start_sha") == expected_sha, "start_sha mismatch")
require(value.get("head_sha") == expected_sha, "head_sha mismatch")
require(value.get("worktree_clean") is True, "worktree_clean is not true")
require(value.get("changed_paths") == [], "changed_paths is not empty")
require(value.get("git_status_porcelain") == [], "git_status_porcelain is not empty")
# The remote runner may report the named source branch while the Router ledger is
# pinned to the exact SHA.  Exactness is proved by start_sha + head_sha, not by
# requiring the informational branch field to equal a SHA.
require(value.get("branch") in {expected_branch, expected_sha}, "unexpected branch field")

summary = {
    "schema": "onca-zcr17-gate-semantic-readback/v1",
    "status": "PASS" if not errors else "FAIL",
    "job_id": value.get("job_id"),
    "gate_status": (terminal or {}).get("gate_status"),
    "mode": value.get("mode"),
    "start_sha": value.get("start_sha"),
    "head_sha": value.get("head_sha"),
    "branch_field": value.get("branch"),
    "branch_field_semantics": "informational; exactness proved by start_sha/head_sha",
    "worktree_clean": value.get("worktree_clean"),
    "changed_paths": value.get("changed_paths"),
    "result_bundle_nullable": value.get("result_bundle") is None,
    "errors": errors,
}
print(json.dumps(summary, indent=2, ensure_ascii=False, sort_keys=True))
if errors:
    raise SystemExit(1)
PY
[[ "${PIPESTATUS[0]}" -eq 0 ]] || fail GATE_SEMANTIC_READBACK_FAILED "consulte gate-semantic-summary.json"

echo 'GATE_SEMANTIC_RESULT=PASS'

printf '\n===== 4. ARTEFATOS DO GATE =====\n'
for relative in \
  result.json \
  evidence/codex.stdout.jsonl \
  evidence/codex.stderr.log \
  evidence/meta.json \
  evidence/prompt.txt \
  evidence/input.bundle.sha256
 do
  sudo test -f "$REMOTE_GATE_DIR/$relative" || fail GATE_ARTIFACT_MISSING "$relative"
 done
sudo find "$REMOTE_GATE_DIR" -maxdepth 3 -type f -printf '%P | %s bytes\n' | sort |
  tee "$EVIDENCE/gate-artifact-inventory.txt"
sudo sha256sum \
  "$REMOTE_GATE_DIR/result.json" \
  "$REMOTE_GATE_DIR/evidence/codex.stdout.jsonl" \
  "$REMOTE_GATE_DIR/evidence/codex.stderr.log" \
  "$REMOTE_GATE_DIR/evidence/meta.json" \
  "$REMOTE_GATE_DIR/evidence/prompt.txt" \
  "$REMOTE_GATE_DIR/evidence/input.bundle.sha256" |
  tee "$EVIDENCE/gate-artifact-sha256.txt"

sudo python3 - "$REMOTE_GATE_DIR/evidence/codex.stdout.jsonl" <<'PY' \
  > "$EVIDENCE/gate-codex-event-summary.json"
import json
import sys
from pathlib import Path

messages = []
commands = []
for line in Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines():
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        continue
    if record.get("type") != "item.completed":
        continue
    item = record.get("item") or {}
    if item.get("type") == "agent_message":
        messages.append(str(item.get("text", "")))
    elif item.get("type") == "command_execution":
        commands.append({
            "command": item.get("command"),
            "exit_code": item.get("exit_code"),
            "status": item.get("status"),
        })

terminal_pass = False
for message in messages:
    try:
        parsed = json.loads(message.strip())
    except json.JSONDecodeError:
        continue
    if isinstance(parsed, dict) and parsed.get("gate_status") == "PASS":
        terminal_pass = True

summary = {
    "agent_messages": len(messages),
    "command_executions": len(commands),
    "terminal_gate_pass_seen": terminal_pass,
    "commands": commands,
}
print(json.dumps(summary, indent=2, ensure_ascii=False, sort_keys=True))
if not terminal_pass:
    raise SystemExit(1)
PY
[[ "$?" -eq 0 ]] || fail GATE_EVENT_STREAM_INVALID "terminal PASS ausente"
cat "$EVIDENCE/gate-codex-event-summary.json"

printf '\n===== 5. LEDGER SOMENTE LEITURA =====\n'
sudo -u ubuntu -g zoe-coders -H -- python3 - "$DB" "$GATE_JOB_ID" "$PR17_VALIDATED_SHA" "$GATE_PROFILE" <<'PY' \
  | tee "$EVIDENCE/ledger-readback.json"
import json
import sqlite3
import sys

db, gate_job, expected_sha, expected_profile = sys.argv[1:]
conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
conn.row_factory = sqlite3.Row
row = conn.execute("SELECT * FROM jobs WHERE id=?", (gate_job,)).fetchone()
if row is None:
    raise SystemExit("gate job missing from ledger")
job = dict(row)
errors = []
if job.get("status") != "succeeded":
    errors.append(f"status={job.get('status')}")
if job.get("selected_coder") != expected_profile:
    errors.append(f"selected_coder={job.get('selected_coder')}")
if job.get("mode") != "read_only":
    errors.append(f"mode={job.get('mode')}")
if job.get("branch") != expected_sha:
    errors.append(f"ledger branch is not exact SHA: {job.get('branch')}")
if job.get("exit_code") != 0:
    errors.append(f"exit_code={job.get('exit_code')}")
active = [dict(item) for item in conn.execute(
    """
    SELECT id,mission_id,status,selected_coder,mode
    FROM jobs
    WHERE (mission_id='ZCR17' OR mission_id LIKE 'ZCR17_%')
      AND status IN ('awaiting_receipt','awaiting_capacity_plan','queued','dispatching','running')
    ORDER BY created_at
    """
).fetchall()]
related = [dict(item) for item in conn.execute(
    """
    SELECT id,mission_id,status,selected_coder,mode,branch,exit_code,completed_at
    FROM jobs
    WHERE mission_id='ZCR17' OR mission_id LIKE 'ZCR17_%'
    ORDER BY created_at DESC
    LIMIT 12
    """
).fetchall()]
conn.close()
if active:
    errors.append("active ZCR17 jobs remain")
print(json.dumps({
    "status": "PASS" if not errors else "FAIL",
    "gate_job": {
        "id": job.get("id"),
        "mission_id": job.get("mission_id"),
        "status": job.get("status"),
        "selected_coder": job.get("selected_coder"),
        "mode": job.get("mode"),
        "branch": job.get("branch"),
        "exit_code": job.get("exit_code"),
        "completed_at": job.get("completed_at"),
    },
    "active_zcr17_jobs": active,
    "recent_zcr17_jobs": related,
    "errors": errors,
}, indent=2, ensure_ascii=False, sort_keys=True))
if errors:
    raise SystemExit(1)
PY
[[ "${PIPESTATUS[0]}" -eq 0 ]] || fail LEDGER_READBACK_FAILED "consulte ledger-readback.json"

echo 'LEDGER_GATE_READBACK=PASS'

printf '\n===== 6. DIAGNÓSTICO DA PILHA PR17 -> PR19 =====\n'
MERGE_BASE="$(git -C "$REPO" merge-base "$PR17_VALIDATED_SHA" "$PR19_CURRENT_SHA")"
set +e
git -C "$REPO" merge-base --is-ancestor "$PR17_VALIDATED_SHA" "$PR19_CURRENT_SHA"
PR17_IS_ANCESTOR_RC=$?
git -C "$REPO" merge-tree --write-tree "$PR17_VALIDATED_SHA" "$PR19_CURRENT_SHA" \
  > "$EVIDENCE/pr19-merge-tree.txt" 2>&1
MERGE_TREE_RC=$?
set -e

if [[ "$PR17_IS_ANCESTOR_RC" -eq 0 ]]; then
  RESTACK_REQUIRED=false
else
  RESTACK_REQUIRED=true
fi
if [[ "$MERGE_TREE_RC" -eq 0 ]]; then
  MERGE_TREE_CLASSIFICATION="CLEAN_MERGE_PREDICTED"
else
  MERGE_TREE_CLASSIFICATION="CONFLICTS_OR_UNSUPPORTED"
fi
printf 'merge_base=%s\npr17_is_ancestor_rc=%s\nrestack_required=%s\nmerge_tree_rc=%s\nmerge_tree_classification=%s\n' \
  "$MERGE_BASE" "$PR17_IS_ANCESTOR_RC" "$RESTACK_REQUIRED" "$MERGE_TREE_RC" "$MERGE_TREE_CLASSIFICATION" |
  tee "$EVIDENCE/stack-diagnostic.txt"
[[ "$MERGE_BASE" == "$PR17_PREVIOUS_SHA" ]] || fail STACK_MERGE_BASE_UNEXPECTED "$MERGE_BASE"

printf '\n===== 7. READBACK FINAL =====\n'
FINAL_TIMER="$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
FINAL_ACTIVE="$(active_units)"
FINAL_RUNTIME="$(sha256_of "$RUNTIME")"
FINAL_CONFIG="$(sudo_sha256_of "$CONFIG")"
FINAL_BRIDGE="$(sha256_of "$BRIDGE")"
[[ "$FINAL_TIMER" == "inactive" ]] || fail TIMER_CHANGED "$FINAL_TIMER"
[[ "$FINAL_ACTIVE" -eq 0 ]] || fail ACTIVE_UNITS_APPEARED "$FINAL_ACTIVE"
[[ "$FINAL_RUNTIME" == "$EXPECTED_RUNTIME_SHA256" ]] || fail RUNTIME_CHANGED "$FINAL_RUNTIME"
[[ "$FINAL_CONFIG" == "$EXPECTED_CONFIG_SHA256" ]] || fail CONFIG_CHANGED "$FINAL_CONFIG"
[[ "$FINAL_BRIDGE" == "$EXPECTED_BRIDGE_SHA256" ]] || fail BRIDGE_CHANGED "$FINAL_BRIDGE"
[[ -z "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)" ]] || fail SOURCE_WORKTREE_CHANGED

find "$EVIDENCE" -maxdepth 1 -type f ! -name SHA256SUMS -print0 | sort -z |
  xargs -0 sha256sum > "$EVIDENCE/SHA256SUMS"

cat <<EOF

ZCR17_SEMANTIC_FINALIZER_V40: PASS
PR17_PREVIOUS_SHA=$PR17_PREVIOUS_SHA
PR17_VALIDATED_SHA=$PR17_VALIDATED_SHA
PR17_WRITER_COMMIT_COUNT=$COMMIT_COUNT
PR17_GATE_JOB_ID=$GATE_JOB_ID
PR17_GATE_STATUS=PASS
PR17_GATE_EXACT_SHA=$PR17_VALIDATED_SHA
PR17_GATE_READ_ONLY=PASS
FINALIZER_FAILURE_CLASSIFICATION=POST_GATE_ASSERTION_BUG
WORKER_BRANCH_FIELD_ACCEPTED=$PR17_BRANCH
EXACTNESS_PROOF=start_sha_and_head_sha
RESULT_BUNDLE_NULLABLE=true
PR19_HEAD=$PR19_CURRENT_SHA
PR19_RESTACK_REQUIRED=$RESTACK_REQUIRED
PR19_MERGE_TREE_CLASSIFICATION=$MERGE_TREE_CLASSIFICATION
CONTROL_RUNTIME_CHANGED=false
CONTROL_CONFIG_CHANGED=false
CONTROL_BRIDGE_CHANGED=false
TIMER=$FINAL_TIMER
ACTIVE_UNITS=$FINAL_ACTIVE
EVIDENCE_DIR=$EVIDENCE
NEXT_PHASE=PR19_RESTACK_ON_$PR17_VALIDATED_SHA
EOF
