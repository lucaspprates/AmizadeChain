#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

REPO='/home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler'
OPS='/var/backups/zoe-coder-router/manual-8-etapas-20260731T104654Z'
DB='/var/lib/zoe-coder-router/runtime.db'
RUNTIME='/usr/local/lib/zoe-coder-router/zoe_coder_router.py'
CONFIG='/etc/zoe-coder-router/config.toml'
ZOE_CODER='/usr/local/bin/zoe-coder'

BRANCH='type/18-factory-scheduler-maintenance'
BASE_SHA='0d935aa174850fa2581538c952d9fcbc832c6e80'
PREVIOUS_SHA='c3db2c39e58326c932e1a9276b1da9b4cecd45bb'
TARGET_SHA='7148c751257832c7953c59a17578985b7bf6e52e'
GATE='codex_terra_remote_gate'

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TEMP_WORKTREE="/tmp/zcr19-final-gate-${STAMP}"
TEMP_BRANCH="onca/zcr19-final-gate-${STAMP}"
PROMPT_ROOT='/var/lib/zoe-coder-router/prompts/ZCR19'
GATE_PROMPT="$PROMPT_ROOT/final-gate-${TARGET_SHA}-${STAMP}.md"
LOCAL_LOG="$(mktemp /tmp/zcr19-final-gate-execute.XXXXXX.log)"
EVIDENCE_TMP="$(mktemp -d /tmp/zcr19-final-gate-evidence.XXXXXX)"
EVIDENCE_FINAL="$OPS/ETAPA-6C-FINAL-EXACT-SHA-GATE-$TARGET_SHA"
GATE_JOB_ID=''
PERSISTED=''

cleanup() {
  set +e
  rm -f "$LOCAL_LOG"
  if [[ -e "$TEMP_WORKTREE/.git" || -d "$TEMP_WORKTREE" ]]; then
    git -C "$REPO" worktree remove --force "$TEMP_WORKTREE" >/dev/null 2>&1
  fi
  if git -C "$REPO" show-ref --verify --quiet "refs/heads/$TEMP_BRANCH"; then
    git -C "$REPO" branch -D "$TEMP_BRANCH" >/dev/null 2>&1
  fi
  set -e
}
trap cleanup EXIT

persist_evidence() {
  local suffix="$1"
  local target="${EVIDENCE_FINAL}-${suffix}"
  if [[ -n "$PERSISTED" ]]; then
    return 0
  fi
  sudo -n rm -rf "$target"
  sudo -n install -d -m 0700 -o root -g root "$target"
  sudo -n cp -a "$EVIDENCE_TMP/." "$target/"
  sudo -n chown -R root:root "$target"
  sudo -n chmod -R go-rwx "$target"
  PERSISTED="$target"
}

fail() {
  local code="$1"
  shift
  {
    echo 'MANUAL_ETAPA_6C: FAIL'
    echo "FAILURE_CODE=$code"
    echo "DETAIL=$*"
    [[ -n "$GATE_JOB_ID" ]] && echo "GATE_JOB_ID=$GATE_JOB_ID"
  } | tee -a "$EVIDENCE_TMP/FAILURE.txt" >&2
  persist_evidence FAILED || true
  echo "EVIDENCE=${PERSISTED:-$EVIDENCE_TMP}" >&2
  exit 1
}

router() {
  sudo -n -u ubuntu -g zoe-coders -H -- \
    python3 "$RUNTIME" --config "$CONFIG" "$@"
}

job_field() {
  local json_path="$1"
  local field="$2"
  python3 - "$json_path" "$field" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))["job"]
for part in sys.argv[2].split("."):
    value = value.get(part) if isinstance(value, dict) else None
print("" if value is None else value)
PY
}

active_count() {
  sudo -n -u ubuntu -g zoe-coders -H -- \
  python3 - "$DB" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
count = conn.execute(
    """
    SELECT COUNT(*)
      FROM jobs
     WHERE status IN (
       'awaiting_capacity_plan',
       'queued',
       'dispatching',
       'running'
     )
    """
).fetchone()[0]
conn.close()
print(count)
PY
}

[[ "$(id -un)" == 'ubuntu' ]] || fail USER_MISMATCH 'execute como ubuntu'
[[ "$(hostname -s)" == 'zoe-infranetwork-com-br' ]] || fail HOST_MISMATCH "$(hostname -s)"
sudo -n true >/dev/null 2>&1 || fail SUDO_UNAVAILABLE 'sudo NOPASSWD obrigatório'
sudo -n test -d "$OPS" || fail OPS_MISSING "$OPS"
sudo -n test -r "$DB" || fail DB_UNREADABLE "$DB"
[[ -r "$RUNTIME" ]] || fail RUNTIME_MISSING "$RUNTIME"
[[ -x "$ZOE_CODER" ]] || fail ZOE_CODER_MISSING "$ZOE_CODER"
sudo -n test -r "$CONFIG" || fail CONFIG_UNREADABLE "$CONFIG"

TIMER="$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
[[ "$TIMER" == 'inactive' ]] || fail TIMER_NOT_INACTIVE "$TIMER"

ACTIVE_UNITS="$(
  systemctl list-units \
    'zoe-coder-job@*.service' \
    'zoe-coder-wake@*.service' \
    --state=active,activating \
    --no-legend \
    --no-pager 2>/dev/null |
  awk 'NF{n++} END{print n+0}'
)"
[[ "$ACTIVE_UNITS" == '0' ]] || fail ACTIVE_UNITS_PRESENT "$ACTIVE_UNITS"

ACTIVE_JOBS="$(active_count)"
[[ "$ACTIVE_JOBS" == '0' ]] || fail ACTIVE_JOBS_PRESENT "$ACTIVE_JOBS"

git -C "$REPO" fetch -q origin "$BRANCH"
[[ "$(git -C "$REPO" branch --show-current)" == "$BRANCH" ]] ||
  fail BRANCH_MISMATCH "$(git -C "$REPO" branch --show-current)"
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$TARGET_SHA" ]] ||
  fail LOCAL_HEAD_MISMATCH "$(git -C "$REPO" rev-parse HEAD)"
[[ "$(git -C "$REPO" rev-parse "origin/$BRANCH")" == "$TARGET_SHA" ]] ||
  fail ORIGIN_HEAD_MISMATCH "$(git -C "$REPO" rev-parse "origin/$BRANCH")"
REMOTE_HEAD="$(git -C "$REPO" ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')"
[[ "$REMOTE_HEAD" == "$TARGET_SHA" ]] || fail REMOTE_HEAD_MISMATCH "$REMOTE_HEAD"
[[ -z "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail SOURCE_WORKTREE_DIRTY 'source worktree is not clean'
git -C "$REPO" merge-base --is-ancestor "$BASE_SHA" "$TARGET_SHA" ||
  fail BASE_NOT_ANCESTOR "$BASE_SHA"
[[ "$(git -C "$REPO" rev-parse "$TARGET_SHA^")" == "$PREVIOUS_SHA" ]] ||
  fail CORRECTION_PARENT_MISMATCH "$(git -C "$REPO" rev-parse "$TARGET_SHA^")"
[[ "$(git -C "$REPO" rev-list --count "$PREVIOUS_SHA..$TARGET_SHA")" == '1' ]] ||
  fail CORRECTION_COMMIT_COUNT_MISMATCH 'expected one test-only correction commit'
[[ "$(git -C "$REPO" diff --name-only "$PREVIOUS_SHA" "$TARGET_SHA")" == 'tests/test_factory_scheduler_maintenance.py' ]] ||
  fail CORRECTION_SCOPE_MISMATCH "$(git -C "$REPO" diff --name-only "$PREVIOUS_SHA" "$TARGET_SHA")"

ROUTE_JSON="$(
  router route \
    --project zoe-coder-router \
    --task-type gate \
    --mode read_only \
    --coder "$GATE" \
    --available
)"
printf '%s\n' "$ROUTE_JSON" > "$EVIDENCE_TMP/route.json"

set +e
python3 - "$EVIDENCE_TMP/route.json" "$GATE" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
expected = sys.argv[2]
assert payload.get("route") == [expected], payload
assert payload.get("project") == "zoe-coder-router", payload
assert payload.get("task_type") == "gate", payload
assert payload.get("mode") == "read_only", payload
PY
ROUTE_RC=$?
set -e
[[ "$ROUTE_RC" == '0' ]] || fail GATE_ROUTE_MISMATCH 'route did not resolve exactly the independent gate'

git -C "$REPO" worktree add -q -b "$TEMP_BRANCH" "$TEMP_WORKTREE" "$TARGET_SHA"
[[ "$(git -C "$TEMP_WORKTREE" rev-parse HEAD)" == "$TARGET_SHA" ]] ||
  fail TEMP_HEAD_MISMATCH "$(git -C "$TEMP_WORKTREE" rev-parse HEAD)"
[[ -z "$(git -C "$TEMP_WORKTREE" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail TEMP_WORKTREE_DIRTY 'temporary gate worktree is not clean'

sudo -n install -d -m 0770 -o root -g zoe-coders "$PROMPT_ROOT"

cat > "$EVIDENCE_TMP/gate-prompt.md" <<EOF_GATE
You are the independent read-only Gate for Zoe Coder Router Issue #18 and Draft PR #19.

Immutable target:
- repository: lucaspprates/Zoe-Coder-Router
- PR base SHA: $BASE_SHA
- previous Gate-rejected SHA: $PREVIOUS_SHA
- exact target SHA: $TARGET_SHA
- published branch: $BRANCH

Hard rules:
- read-only review; do not modify files, index, refs, configuration, database, credentials, or systemd
- do not commit, push, reset, checkout, merge, rebase, install packages, or create tracked/untracked files
- verify HEAD is exactly $TARGET_SHA and the worktree is clean at review start and end
- review the complete diff $BASE_SHA..$TARGET_SHA and specifically the test-only correction $PREVIOUS_SHA..$TARGET_SHA
- changed_paths in your final object means paths changed by this Gate during review and therefore must be []

Previous material finding to close:
The prior Gate found incomplete negative-path coverage for capacity-plan admission. The correction must independently test each relevant rejection branch, including:
1. missing selected_coder;
2. nonexistent selected_coder;
3. coder allowed_projects/project allow-list rejection;
4. project allowed_write or allowed_read rejection;
5. coder mode mismatch;
6. route rejection where selected coder is not authorized by the task route;
7. malformed fallback_chain JSON;
8. gate task_type restriction after an explicitly routed but non-gate task;
9. existing directory that is not a Git worktree;
10. the already-covered status, unknown project, declared-role/mode mismatch, unrouted task type, gate profile/no-fallback, fallback membership, auto-fallback, exact SHA, missing worktree, dirty worktree, HEAD mismatch, and admission-race atomicity paths.

Required conclusions:
- every validation branch above has a deterministic assertion of error, job_id and invalid_field;
- rejection never queues another valid reservation;
- the runtime implementation is unchanged by the correction commit;
- existing 4-writer + 2-gate accounting, durable prompt, wake lease, provenance and no-fallback contracts remain intact.

Run independently:
- PYTEST_ADDOPTS='-p no:cacheprovider' PYTHONDONTWRITEBYTECODE=1 python3 -B -m pytest -q tests/test_factory_scheduler_maintenance.py -k 'capacity_plan'
- PYTEST_ADDOPTS='-p no:cacheprovider' PYTHONDONTWRITEBYTECODE=1 python3 -B -m pytest -q tests/test_factory_scheduler_maintenance.py
- PYTEST_ADDOPTS='-p no:cacheprovider' PYTHONDONTWRITEBYTECODE=1 python3 -B -m pytest -q tests/test_opencode_result_provenance.py tests/test_opencode_terminal_result_smoke.py
- PYTEST_ADDOPTS='-p no:cacheprovider' PYTHONDONTWRITEBYTECODE=1 python3 -B -m pytest -q
- PYTHONDONTWRITEBYTECODE=1 python3 -B -m compileall -q src tests
- git diff --check $BASE_SHA..$TARGET_SHA

Only PASS with no material correctness, security, compatibility, test, scope, atomicity or contract findings.

Your final non-empty output line must be one compact JSON object with no Markdown fences and no output after it. Use exactly this shape:
{"gate_status":"PASS or FAIL","exact_sha":"$TARGET_SHA","mode":"read_only","start_sha":"$TARGET_SHA","end_sha":"$TARGET_SHA","changed_paths":[],"focused_tests":"PASS or FAIL","full_tests":"PASS or FAIL","compileall":"PASS or FAIL","diff_check":"PASS or FAIL","findings":[]}
EOF_GATE

sudo -n install \
  -m 0440 \
  -o ubuntu \
  -g zoe-coders \
  "$EVIDENCE_TMP/gate-prompt.md" \
  "$GATE_PROMPT"

PROMPT_SHA="$(sha256sum "$GATE_PROMPT" | awk '{print $1}')"

GATE_JOB_ID="$(
  router submit \
    --project zoe-coder-router \
    --repo "$TEMP_WORKTREE" \
    --worktree "$TEMP_WORKTREE" \
    --branch "$TARGET_SHA" \
    --issue 18 \
    --mission "ZCR19_FINAL_GATE_$TARGET_SHA" \
    --task-type gate \
    --mode read_only \
    --prompt-file "$GATE_PROMPT" \
    --coder "$GATE" \
    --priority 100 \
    --max-attempts 1 \
    --no-fallback \
    --idempotency-key "ZCR19-FINAL-EXACT-SHA-GATE-$TARGET_SHA-$PROMPT_SHA-$STAMP"
)"
[[ "$GATE_JOB_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
  fail GATE_SUBMIT_INVALID "$GATE_JOB_ID"
printf '%s\n' "$GATE_JOB_ID" > "$EVIDENCE_TMP/gate-job-id.txt"

cat > "$EVIDENCE_TMP/pre-execution.txt" <<EOF
job_id=$GATE_JOB_ID
gate_profile=$GATE
mode=read_only
target_sha=$TARGET_SHA
prompt_sha256=$PROMPT_SHA
timer=$TIMER
active_units=$ACTIVE_UNITS
active_jobs=$ACTIVE_JOBS
EOF

echo 'MANUAL_ETAPA_6C_GATE: STARTED'
echo "GATE_JOB_ID=$GATE_JOB_ID"
echo "TARGET_SHA=$TARGET_SHA"
echo "GATE_PROFILE=$GATE"
echo 'MODE=read_only'
echo 'NOTE=the command is blocking and may be silent while the remote Gate works'

set +e
sudo -n -u ubuntu -g zoe-coders -H -- \
env \
  HOME=/home/ubuntu \
  ZOE_CODER_CONFIG="$CONFIG" \
  CODEX_HOME=/var/lib/zoe-coder-router/codex-host-isolated-home \
  DISPLAY=:101 \
  XDG_DATA_HOME=/var/lib/zoe-coder-router/opencode-state \
  "$ZOE_CODER" --config "$CONFIG" execute "$GATE_JOB_ID" \
  >"$LOCAL_LOG" 2>&1
GATE_RC=$?
set -e

cp "$LOCAL_LOG" "$EVIDENCE_TMP/gate-execute.log"
router show "$GATE_JOB_ID" > "$EVIDENCE_TMP/gate-show.json"

STATUS="$(job_field "$EVIDENCE_TMP/gate-show.json" status)"
MODE="$(job_field "$EVIDENCE_TMP/gate-show.json" mode)"
SELECTED="$(job_field "$EVIDENCE_TMP/gate-show.json" selected_coder)"
JOB_BRANCH="$(job_field "$EVIDENCE_TMP/gate-show.json" branch)"
EXIT_CODE="$(job_field "$EVIDENCE_TMP/gate-show.json" exit_code)"
STDOUT_PATH="$(job_field "$EVIDENCE_TMP/gate-show.json" stdout_path)"
STDERR_PATH="$(job_field "$EVIDENCE_TMP/gate-show.json" stderr_path)"
RESULT_PATH="$(job_field "$EVIDENCE_TMP/gate-show.json" result_path)"

for pair in \
  "$STDOUT_PATH:router-stdout.jsonl" \
  "$STDERR_PATH:router-stderr.log" \
  "$RESULT_PATH:router-result.json"; do
  src="${pair%%:*}"
  dst="${pair#*:}"
  if [[ -n "$src" ]] && sudo -n test -f "$src"; then
    sudo -n cp "$src" "$EVIDENCE_TMP/$dst"
    sudo -n chown ubuntu:ubuntu "$EVIDENCE_TMP/$dst"
    chmod 0600 "$EVIDENCE_TMP/$dst"
  fi
done

BRIDGE_DIR="/var/log/zoe-coder-router/remote/$GATE_JOB_ID"
if sudo -n test -d "$BRIDGE_DIR"; then
  sudo -n cp -a "$BRIDGE_DIR" "$EVIDENCE_TMP/bridge-remote"
  sudo -n chown -R ubuntu:ubuntu "$EVIDENCE_TMP/bridge-remote"
  chmod -R u+rwX,go-rwx "$EVIDENCE_TMP/bridge-remote"
fi

set +e
python3 - "$EVIDENCE_TMP" "$TARGET_SHA" > "$EVIDENCE_TMP/terminal-validation.txt" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
target = sys.argv[2]
terminal = None
bridge = root / "bridge-remote" / "result.json"
if bridge.exists():
    payload = json.loads(bridge.read_text(encoding="utf-8"))
    candidate = payload.get("terminal_object")
    if isinstance(candidate, dict):
        terminal = candidate
if terminal is None:
    stdout = root / "router-stdout.jsonl"
    candidates = []
    if stdout.exists():
        for line in stdout.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                obj = json.loads(line)
            except Exception:
                continue
            item = obj.get("item") if isinstance(obj, dict) else None
            if isinstance(item, dict) and item.get("type") == "agent_message":
                text = str(item.get("text", ""))
                for raw in re.findall(r'\{[^\n]*"gate_status"[^\n]*\}', text):
                    try:
                        candidates.append(json.loads(raw))
                    except Exception:
                        pass
    if candidates:
        terminal = candidates[-1]
print(json.dumps(terminal, indent=2, ensure_ascii=False, sort_keys=True))
if not isinstance(terminal, dict):
    raise SystemExit(20)
checks = {
    "gate_status": terminal.get("gate_status") == "PASS",
    "exact_sha": terminal.get("exact_sha") == target,
    "mode": terminal.get("mode") == "read_only",
    "start_sha": terminal.get("start_sha") == target,
    "end_sha": terminal.get("end_sha") == target,
    "changed_paths": terminal.get("changed_paths") == [],
    "focused_tests": terminal.get("focused_tests") == "PASS",
    "full_tests": terminal.get("full_tests") == "PASS",
    "compileall": terminal.get("compileall") == "PASS",
    "diff_check": terminal.get("diff_check") == "PASS",
    "findings": terminal.get("findings") == [],
}
failed = [name for name, ok in checks.items() if not ok]
if failed:
    print("FAILED_FIELDS=" + ",".join(failed))
    raise SystemExit(21)
PY
TERMINAL_RC=$?
set -e

if [[ "$GATE_RC" != '0' ]]; then
  fail GATE_EXECUTION_FAILED "rc=$GATE_RC status=$STATUS terminal_rc=$TERMINAL_RC"
fi
[[ "$STATUS" == 'succeeded' ]] || fail GATE_STATUS_NOT_SUCCEEDED "$STATUS"
[[ "$MODE" == 'read_only' ]] || fail GATE_MODE_MISMATCH "$MODE"
[[ "$SELECTED" == "$GATE" ]] || fail GATE_PROFILE_MISMATCH "$SELECTED"
[[ "$JOB_BRANCH" == "$TARGET_SHA" ]] || fail GATE_SHA_FIELD_MISMATCH "$JOB_BRANCH"
[[ "$EXIT_CODE" == '0' ]] || fail GATE_EXIT_CODE_MISMATCH "$EXIT_CODE"
[[ "$TERMINAL_RC" == '0' ]] || fail GATE_TERMINAL_REJECTED "terminal_rc=$TERMINAL_RC"

[[ "$(git -C "$TEMP_WORKTREE" rev-parse HEAD)" == "$TARGET_SHA" ]] ||
  fail GATE_END_HEAD_MISMATCH "$(git -C "$TEMP_WORKTREE" rev-parse HEAD)"
[[ -z "$(git -C "$TEMP_WORKTREE" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail GATE_CHANGED_WORKTREE "$(git -C "$TEMP_WORKTREE" status --porcelain=v1 --untracked-files=all)"
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$TARGET_SHA" ]] ||
  fail SOURCE_END_HEAD_MISMATCH "$(git -C "$REPO" rev-parse HEAD)"
[[ -z "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail SOURCE_END_DIRTY 'source worktree became dirty'

git -C "$REPO" fetch -q origin "$BRANCH"
[[ "$(git -C "$REPO" rev-parse "origin/$BRANCH")" == "$TARGET_SHA" ]] ||
  fail ORIGIN_END_MISMATCH "$(git -C "$REPO" rev-parse "origin/$BRANCH")"
[[ "$(git -C "$REPO" ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')" == "$TARGET_SHA" ]] ||
  fail REMOTE_END_MISMATCH 'remote branch changed during Gate'

ACTIVE_JOBS_AFTER="$(active_count)"
ACTIVE_UNITS_AFTER="$(
  systemctl list-units \
    'zoe-coder-job@*.service' \
    'zoe-coder-wake@*.service' \
    --state=active,activating \
    --no-legend \
    --no-pager 2>/dev/null |
  awk 'NF{n++} END{print n+0}'
)"
TIMER_AFTER="$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
[[ "$ACTIVE_JOBS_AFTER" == '0' ]] || fail ACTIVE_JOBS_AFTER "$ACTIVE_JOBS_AFTER"
[[ "$ACTIVE_UNITS_AFTER" == '0' ]] || fail ACTIVE_UNITS_AFTER "$ACTIVE_UNITS_AFTER"
[[ "$TIMER_AFTER" == 'inactive' ]] || fail TIMER_AFTER "$TIMER_AFTER"

{
  echo 'MANUAL_ETAPA_6C: PASS'
  echo "GATE_JOB_ID=$GATE_JOB_ID"
  echo "GATE_STATUS=$STATUS"
  echo "GATE_PROFILE=$SELECTED"
  echo "GATE_MODE=$MODE"
  echo "GATE_EXACT_SHA=$JOB_BRANCH"
  echo "GATE_EXIT_CODE=$EXIT_CODE"
  echo "ACTIVE_JOBS=$ACTIVE_JOBS_AFTER"
  echo "ACTIVE_UNITS=$ACTIVE_UNITS_AFTER"
  echo "TIMER=$TIMER_AFTER"
  echo 'NEXT=INTEGRAR_STACK_PR17_PR19'
} | tee "$EVIDENCE_TMP/SUMMARY.txt"

persist_evidence PASS

echo
echo 'MANUAL_ETAPA_6C_READBACK: PASS'
echo "EVIDENCE=$PERSISTED"
