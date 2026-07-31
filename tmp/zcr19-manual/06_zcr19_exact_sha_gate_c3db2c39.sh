#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

REPO='/home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler'
OPS='/var/backups/zoe-coder-router/manual-8-etapas-20260731T104654Z'
DB='/var/lib/zoe-coder-router/runtime.db'
RUNTIME='/usr/local/lib/zoe-coder-router/zoe_coder_router.py'
ZOE_CODER='/usr/local/bin/zoe-coder'
CONFIG='/etc/zoe-coder-router/config.toml'

BRANCH='type/18-factory-scheduler-maintenance'
BASE_SHA='0d935aa174850fa2581538c952d9fcbc832c6e80'
PREVIOUS_SHA='a3b3f438dd2d6b365187248f11bcd661dba047fa'
TARGET_SHA='c3db2c39e58326c932e1a9276b1da9b4cecd45bb'
GATE='codex_terra_remote_gate'

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TEMP_WORKTREE="/tmp/zcr19-gate-${STAMP}"
TEMP_BRANCH="onca/zcr19-gate-${STAMP}"
PROMPT_ROOT='/var/lib/zoe-coder-router/prompts/ZCR19'
GATE_PROMPT="$PROMPT_ROOT/gate-${TARGET_SHA}-${STAMP}.md"
LOCAL_LOG="$(mktemp /tmp/zcr19-gate-execute.XXXXXX.log)"
EVIDENCE_TMP="$(mktemp -d /tmp/zcr19-gate-evidence.XXXXXX)"
EVIDENCE_FINAL="$OPS/ETAPA-6-EXACT-SHA-GATE-$TARGET_SHA"
GATE_JOB_ID=''

fail() {
  local code="$1"
  shift
  printf 'MANUAL_ETAPA_6: FAIL\n' >&2
  printf 'FAILURE_CODE=%s\n' "$code" >&2
  printf 'DETAIL=%s\n' "$*" >&2
  [[ -n "$GATE_JOB_ID" ]] && printf 'GATE_JOB_ID=%s\n' "$GATE_JOB_ID" >&2
  printf 'EVIDENCE_TMP=%s\n' "$EVIDENCE_TMP" >&2
  exit 1
}

cleanup() {
  set +e
  rm -f "$LOCAL_LOG"
  if [[ -e "$TEMP_WORKTREE/.git" || -d "$TEMP_WORKTREE" ]]; then
    git -C "$REPO" worktree remove --force "$TEMP_WORKTREE" >/dev/null 2>&1
  fi
  if git -C "$REPO" show-ref --verify --quiet "refs/heads/$TEMP_BRANCH"; then
    git -C "$REPO" branch -D "$TEMP_BRANCH" >/dev/null 2>&1
  fi
}
trap cleanup EXIT

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
[[ -r "$CONFIG" ]] || sudo -n test -r "$CONFIG" || fail CONFIG_UNREADABLE "$CONFIG"

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
[[ "$(git -C "$REPO" rev-list --count "$PREVIOUS_SHA..$TARGET_SHA")" == '1' ]] ||
  fail CORRECTION_COMMIT_COUNT_MISMATCH 'expected one correction commit'

ROUTE_JSON="$(
  router route \
    --project zoe-coder-router \
    --task-type gate \
    --mode read_only \
    --coder "$GATE" \
    --available
)"
printf '%s\n' "$ROUTE_JSON" > "$EVIDENCE_TMP/route.json"
python3 - "$EVIDENCE_TMP/route.json" "$GATE" <<'PY' ||
  fail GATE_ROUTE_MISMATCH 'route did not resolve exactly the independent gate'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
expected = sys.argv[2]
if payload.get("route") != [expected]:
    raise SystemExit(1)
if payload.get("project") != "zoe-coder-router":
    raise SystemExit(1)
if payload.get("task_type") != "gate" or payload.get("mode") != "read_only":
    raise SystemExit(1)
PY

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
- previous reviewed SHA: $PREVIOUS_SHA
- exact target SHA: $TARGET_SHA
- branch published at target: $BRANCH

Hard rules:
- read-only review; do not modify files, index, refs, configuration, database, credentials, or systemd
- do not commit, push, reset, checkout, merge, rebase, install packages, or generate tracked/untracked files
- verify HEAD is exactly $TARGET_SHA and the worktree is clean at review start and review end
- review the complete diff $BASE_SHA..$TARGET_SHA and specifically the correction $PREVIOUS_SHA..$TARGET_SHA
- this is an isolated worker; do not require production systemd units to exist on the worker

Material finding that must be independently resolved:
validate_capacity_plan previously admitted reserved jobs without validating every job's project/orchestration scope, declared role and mode, task class, authorized selected coder, independent gate profile, fallback chain, auto-fallback state, exact gate SHA, worktree existence, worktree cleanliness, and exact worktree HEAD.

Required checks:
1. Every declared job is an actual CAPACITY_RESERVED_STATE reservation.
2. Project exists and is in runtime.orchestration_projects.
3. Declared writer/gate role matches write/read_only mode.
4. task_type is explicitly routed; gates permit only gate, qa, or release_validation.
5. selected_coder exists, allows the project and mode, is allowed by the project and route, and gates use the authorized independent read-only no-fallback profile.
6. fallback_chain is valid JSON and exactly [selected_coder]; gate auto_fallback is zero.
7. Gate branch is a lowercase exact 40-character SHA.
8. Worktree exists, is Git, is clean, and gate HEAD equals the declared SHA.
9. Rejection evidence contains stable error, job_id, invalid_field, and reason.
10. No invalid plan can partially move reservations to queued, including a state change between validation and admission.
11. Existing 4-writer + 2-gate accounting, durable prompts, wake leases, provenance, and no-fallback contracts remain intact.
12. Tests cover the valid plan and every required negative/atomicity path.

Run independently:
- PYTEST_ADDOPTS='-p no:cacheprovider' PYTHONDONTWRITEBYTECODE=1 python3 -B -m pytest -q tests/test_factory_scheduler_maintenance.py -k 'capacity_plan'
- PYTEST_ADDOPTS='-p no:cacheprovider' PYTHONDONTWRITEBYTECODE=1 python3 -B -m pytest -q tests/test_factory_scheduler_maintenance.py
- PYTEST_ADDOPTS='-p no:cacheprovider' PYTHONDONTWRITEBYTECODE=1 python3 -B -m pytest -q tests/test_opencode_result_provenance.py tests/test_opencode_terminal_result_smoke.py
- PYTEST_ADDOPTS='-p no:cacheprovider' PYTHONDONTWRITEBYTECODE=1 python3 -B -m pytest -q
- PYTHONDONTWRITEBYTECODE=1 python3 -B -m compileall -q src tests
- git diff --check $BASE_SHA..$TARGET_SHA

Only PASS with no material correctness, security, compatibility, test, scope, atomicity, or contract findings.

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
    --mission "ZCR19_GATE_$TARGET_SHA" \
    --task-type gate \
    --mode read_only \
    --prompt-file "$GATE_PROMPT" \
    --coder "$GATE" \
    --priority 100 \
    --max-attempts 1 \
    --no-fallback \
    --idempotency-key "ZCR19-EXACT-SHA-GATE-$TARGET_SHA-$PROMPT_SHA-$STAMP"
)"
[[ "$GATE_JOB_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
  fail GATE_SUBMIT_INVALID "$GATE_JOB_ID"
printf '%s\n' "$GATE_JOB_ID" > "$EVIDENCE_TMP/gate-job-id.txt"

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

for item in "$STDOUT_PATH" "$STDERR_PATH" "$RESULT_PATH"; do
  if [[ -n "$item" ]] && sudo -n test -f "$item"; then
    sudo -n cp "$item" "$EVIDENCE_TMP/$(basename "$item")"
    sudo -n chown ubuntu:ubuntu "$EVIDENCE_TMP/$(basename "$item")"
    chmod 0600 "$EVIDENCE_TMP/$(basename "$item")"
  fi
done

BRIDGE_RESULT="/var/log/zoe-coder-router/remote/$GATE_JOB_ID/result.json"
if sudo -n test -f "$BRIDGE_RESULT"; then
  sudo -n cp "$BRIDGE_RESULT" "$EVIDENCE_TMP/bridge-result.json"
  sudo -n chown ubuntu:ubuntu "$EVIDENCE_TMP/bridge-result.json"
  chmod 0600 "$EVIDENCE_TMP/bridge-result.json"
fi

[[ "$GATE_RC" == '0' ]] || fail GATE_EXECUTION_FAILED "rc=$GATE_RC status=$STATUS"
[[ "$STATUS" == 'succeeded' ]] || fail GATE_STATUS_NOT_SUCCEEDED "$STATUS"
[[ "$MODE" == 'read_only' ]] || fail GATE_MODE_MISMATCH "$MODE"
[[ "$SELECTED" == "$GATE" ]] || fail GATE_PROFILE_MISMATCH "$SELECTED"
[[ "$JOB_BRANCH" == "$TARGET_SHA" ]] || fail GATE_SHA_FIELD_MISMATCH "$JOB_BRANCH"
[[ "$EXIT_CODE" == '0' ]] || fail GATE_EXIT_CODE_MISMATCH "$EXIT_CODE"

TERMINAL_JSON="$EVIDENCE_TMP/terminal-object.json"
if [[ -f "$EVIDENCE_TMP/bridge-result.json" ]]; then
  python3 - "$EVIDENCE_TMP/bridge-result.json" "$TERMINAL_JSON" <<'PY'
import json
import sys

source = json.load(open(sys.argv[1], encoding="utf-8"))
terminal = source.get("terminal_object")
if not isinstance(terminal, dict):
    raise SystemExit("terminal_object missing")
json.dump(terminal, open(sys.argv[2], "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
else
  python3 - "$EVIDENCE_TMP/stdout.jsonl" "$TERMINAL_JSON" <<'PY'
import json
import sys

last = None
for raw in open(sys.argv[1], encoding="utf-8"):
    try:
        event = json.loads(raw)
    except json.JSONDecodeError:
        continue
    item = event.get("item") or {}
    if item.get("type") != "agent_message":
        continue
    text = item.get("text")
    if not isinstance(text, str):
        continue
    for line in reversed([x.strip() for x in text.splitlines() if x.strip()]):
        try:
            candidate = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(candidate, dict) and "gate_status" in candidate:
            last = candidate
            break
if not isinstance(last, dict):
    raise SystemExit("gate terminal JSON missing")
json.dump(last, open(sys.argv[2], "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
fi

python3 - "$TERMINAL_JSON" "$TARGET_SHA" <<'PY' ||
  fail GATE_TERMINAL_REJECTED 'terminal object is not an exact-SHA read-only PASS'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
target = sys.argv[2]
checks = [
    value.get("gate_status") == "PASS",
    value.get("exact_sha") == target,
    value.get("mode") == "read_only",
    value.get("start_sha") == target,
    value.get("end_sha") == target,
    value.get("changed_paths") == [],
    value.get("focused_tests") == "PASS",
    value.get("full_tests") == "PASS",
    value.get("compileall") == "PASS",
    value.get("diff_check") == "PASS",
    value.get("findings") == [],
]
if not all(checks):
    raise SystemExit(1)
PY

[[ "$(git -C "$TEMP_WORKTREE" rev-parse HEAD)" == "$TARGET_SHA" ]] ||
  fail GATE_MUTATED_HEAD "$(git -C "$TEMP_WORKTREE" rev-parse HEAD)"
[[ -z "$(git -C "$TEMP_WORKTREE" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail GATE_MUTATED_WORKTREE 'temporary gate worktree changed'
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$TARGET_SHA" ]] ||
  fail SOURCE_HEAD_CHANGED "$(git -C "$REPO" rev-parse HEAD)"
[[ -z "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail SOURCE_WORKTREE_CHANGED 'source worktree changed'

git -C "$REPO" fetch -q origin "$BRANCH"
[[ "$(git -C "$REPO" rev-parse "origin/$BRANCH")" == "$TARGET_SHA" ]] ||
  fail ORIGIN_CHANGED_DURING_GATE "$(git -C "$REPO" rev-parse "origin/$BRANCH")"
[[ "$(git -C "$REPO" ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')" == "$TARGET_SHA" ]] ||
  fail REMOTE_CHANGED_DURING_GATE 'remote branch changed'

ACTIVE_AFTER="$(active_count)"
[[ "$ACTIVE_AFTER" == '0' ]] || fail ACTIVE_JOBS_AFTER_GATE "$ACTIVE_AFTER"
[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == 'inactive' ]] ||
  fail TIMER_CHANGED_DURING_GATE 'timer is not inactive'

{
  echo 'MANUAL_ETAPA_6: PASS'
  echo "GATE_JOB_ID=$GATE_JOB_ID"
  echo "GATE_STATUS=$STATUS"
  echo "GATE_PROFILE=$SELECTED"
  echo "GATE_MODE=$MODE"
  echo "GATE_EXACT_SHA=$JOB_BRANCH"
  echo "GATE_EXIT_CODE=$EXIT_CODE"
  echo "LOCAL_HEAD=$(git -C "$REPO" rev-parse HEAD)"
  echo "ORIGIN_HEAD=$(git -C "$REPO" rev-parse "origin/$BRANCH")"
  echo "ACTIVE_JOBS=$ACTIVE_AFTER"
  echo "ACTIVE_UNITS=$ACTIVE_UNITS"
  echo 'TIMER=inactive'
  echo "TERMINAL_OBJECT=$TERMINAL_JSON"
  echo 'NEXT=INTEGRAR_STACK_PR17_PR19'
} | tee "$EVIDENCE_TMP/readback.txt"

sudo -n install -d -m 0700 -o root -g root "$EVIDENCE_FINAL"
sudo -n cp -a "$EVIDENCE_TMP/." "$EVIDENCE_FINAL/"
sudo -n chown -R root:root "$EVIDENCE_FINAL"
sudo -n chmod -R go-rwx "$EVIDENCE_FINAL"

echo
echo 'MANUAL_ETAPA_6_READBACK: PASS'
echo "EVIDENCE=$EVIDENCE_FINAL"
