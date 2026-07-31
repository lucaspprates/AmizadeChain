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
START_SHA='c3db2c39e58326c932e1a9276b1da9b4cecd45bb'
WRITER='codex_terra_remote_writer_yolo'
EXPECTED_SUBJECT='test(router): cover capacity plan rejection paths'

WORKER='201.23.86.157'
KEY='/home/ubuntu/.ssh/ssh-key-2026-06-03.key'
KNOWN='/home/ubuntu/.ssh/known_hosts_onca_8x1'

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
MISSION="ZCR19_NEGATIVE_TEST_COVERAGE_${STAMP}"
PROMPT_ROOT='/var/lib/zoe-coder-router/prompts/ZCR19'
PROMPT="$PROMPT_ROOT/test-coverage-${START_SHA}-${STAMP}.md"
TMP="$(mktemp -d /tmp/zcr19-test-coverage-writer.XXXXXX)"
EVIDENCE_FINAL="$OPS/ETAPA-6B-TEST-COVERAGE-WRITER-$STAMP"
JOB_ID=''

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  local code="$1"
  shift
  echo 'MANUAL_ETAPA_6B: FAIL' >&2
  echo "FAILURE_CODE=$code" >&2
  echo "DETAIL=$*" >&2
  [[ -n "$JOB_ID" ]] && echo "JOB_ID=$JOB_ID" >&2
  echo "EVIDENCE_TMP=$TMP" >&2
  exit 1
}

router() {
  sudo -n -u ubuntu -g zoe-coders -H -- \
    python3 "$RUNTIME" --config "$CONFIG" "$@"
}

active_jobs() {
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

ACTIVE_JOBS="$(active_jobs)"
[[ "$ACTIVE_JOBS" == '0' ]] || fail ACTIVE_JOBS_PRESENT "$ACTIVE_JOBS"

git -C "$REPO" fetch -q origin "$BRANCH"
LOCAL_HEAD="$(git -C "$REPO" rev-parse HEAD)"
ORIGIN_HEAD="$(git -C "$REPO" rev-parse "origin/$BRANCH")"
REMOTE_HEAD="$(git -C "$REPO" ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')"

[[ "$(git -C "$REPO" branch --show-current)" == "$BRANCH" ]] ||
  fail BRANCH_MISMATCH "$(git -C "$REPO" branch --show-current)"
[[ "$LOCAL_HEAD" == "$START_SHA" ]] || fail LOCAL_HEAD_MISMATCH "$LOCAL_HEAD"
[[ "$ORIGIN_HEAD" == "$START_SHA" ]] || fail ORIGIN_HEAD_MISMATCH "$ORIGIN_HEAD"
[[ "$REMOTE_HEAD" == "$START_SHA" ]] || fail REMOTE_HEAD_MISMATCH "$REMOTE_HEAD"
[[ -z "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail SOURCE_WORKTREE_DIRTY 'source worktree is not clean'

ROUTE_JSON="$(
  router route \
    --project zoe-coder-router \
    --task-type bugfix \
    --mode write \
    --coder "$WRITER" \
    --available
)"
printf '%s\n' "$ROUTE_JSON" > "$TMP/route.json"

python3 -c '
import json, sys
payload=json.load(open(sys.argv[1], encoding="utf-8"))
assert payload.get("project") == "zoe-coder-router"
assert payload.get("task_type") == "bugfix"
assert payload.get("mode") == "write"
assert payload.get("route") == [sys.argv[2]]
' "$TMP/route.json" "$WRITER" ||
  fail WRITER_ROUTE_MISMATCH 'writer route did not resolve exactly'

sudo -n install -d -m 0770 -o root -g zoe-coders "$PROMPT_ROOT"

cat > "$TMP/prompt.md" <<EOF_PROMPT
You are the admitted remote Writer correcting the independent Gate finding for Zoe Coder Router Issue #18 / Draft PR #19.

Immutable starting state:
- repository: lucaspprates/Zoe-Coder-Router
- branch: $BRANCH
- exact starting SHA: $START_SHA
- prior Gate job: 0e965769-bb00-4a02-9784-6d4c4c86911c
- prior Gate result: FAIL only because required negative test paths were not all covered

Scope:
- modify only tests/test_factory_scheduler_maintenance.py
- do not modify production code, configuration, fixtures, documentation, runtime, bridge, database, systemd, or any other path
- preserve every existing test
- if a required negative test reveals a production-code defect, do not modify source code and do not commit; report the defect

Required deterministic regression coverage:
1. selected_coder is missing or empty;
2. selected_coder names a nonexistent coder;
3. coder allowed_projects rejects the project;
4. project allowed_write/allowed_read rejects the selected coder;
5. coder mode is incompatible with the job mode;
6. selected coder is not authorized by the explicit task route;
7. fallback_chain contains malformed JSON, distinct from a valid but wrong chain;
8. a gate uses an explicitly routed task_type outside gate, qa, release_validation;
9. worktree exists as a directory but is not a Git repository.

For every new rejection case:
- drive validate_capacity_plan through the real SQLite job row and real config object;
- assert ok is false;
- assert error is invalid_capacity_plan_job;
- assert the exact job_id;
- assert invalid_field;
- assert an appropriate stable reason value or stable reason fragment;
- assert no previously reserved writer or gate is moved to queued;
- keep each branch independently reachable so one earlier check does not mask the intended branch.

Keep the existing valid-plan, dirty-worktree, missing-worktree, exact-SHA, HEAD mismatch, auto-fallback, role, status, project, task-type, atomic validation, and admission-race tests intact.

Run:
- PYTEST_ADDOPTS='-p no:cacheprovider' PYTHONDONTWRITEBYTECODE=1 python3 -B -m pytest -q tests/test_factory_scheduler_maintenance.py -k 'capacity_plan'
- PYTEST_ADDOPTS='-p no:cacheprovider' PYTHONDONTWRITEBYTECODE=1 python3 -B -m pytest -q tests/test_factory_scheduler_maintenance.py
- PYTEST_ADDOPTS='-p no:cacheprovider' PYTHONDONTWRITEBYTECODE=1 python3 -B -m pytest -q tests/test_opencode_result_provenance.py tests/test_opencode_terminal_result_smoke.py
- PYTEST_ADDOPTS='-p no:cacheprovider' PYTHONDONTWRITEBYTECODE=1 python3 -B -m pytest -q
- PYTHONDONTWRITEBYTECODE=1 python3 -B -m compileall -q src tests
- git diff --check $START_SHA..HEAD

Commit exactly once with this message:
$EXPECTED_SUBJECT

Do not push manually. The bridge owns result transport and fast-forward publication.
Verify exactly one file changed, exactly one commit was created, and the worktree is clean.

Your final response must be exactly this single JSON object on one line, with no Markdown and no additional text:
{"terminal_status":"complete"}
EOF_PROMPT

sudo -n install \
  -m 0440 \
  -o ubuntu \
  -g zoe-coders \
  "$TMP/prompt.md" \
  "$PROMPT"

PROMPT_SHA="$(sha256sum "$PROMPT" | awk '{print $1}')"

JOB_ID="$(
  router submit \
    --project zoe-coder-router \
    --repo "$REPO" \
    --worktree "$REPO" \
    --branch "$BRANCH" \
    --issue 18 \
    --mission "$MISSION" \
    --task-type bugfix \
    --mode write \
    --prompt-file "$PROMPT" \
    --coder "$WRITER" \
    --priority 100 \
    --max-attempts 1 \
    --no-fallback \
    --idempotency-key "ZCR19-NEGATIVE-TEST-COVERAGE-$START_SHA-$PROMPT_SHA-$STAMP"
)"
[[ "$JOB_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
  fail WRITER_SUBMIT_INVALID "$JOB_ID"
printf '%s\n' "$JOB_ID" > "$TMP/job-id.txt"

set +e
sudo -n -u ubuntu -g zoe-coders -H -- \
env \
  HOME=/home/ubuntu \
  ZOE_CODER_CONFIG="$CONFIG" \
  CODEX_HOME=/var/lib/zoe-coder-router/codex-host-isolated-home \
  DISPLAY=:101 \
  XDG_DATA_HOME=/var/lib/zoe-coder-router/opencode-state \
  "$ZOE_CODER" --config "$CONFIG" execute "$JOB_ID" \
  >"$TMP/writer-execute.log" 2>&1
WRITER_RC=$?
set -e

router show "$JOB_ID" > "$TMP/writer-show.json"

STATUS="$(job_field "$TMP/writer-show.json" status)"
EXIT_CODE="$(job_field "$TMP/writer-show.json" exit_code)"
MODE="$(job_field "$TMP/writer-show.json" mode)"
SELECTED="$(job_field "$TMP/writer-show.json" selected_coder)"
STDOUT_PATH="$(job_field "$TMP/writer-show.json" stdout_path)"
STDERR_PATH="$(job_field "$TMP/writer-show.json" stderr_path)"
RESULT_PATH="$(job_field "$TMP/writer-show.json" result_path)"

for pair in \
  "$STDOUT_PATH:router-stdout.jsonl" \
  "$STDERR_PATH:router-stderr.log" \
  "$RESULT_PATH:router-result.json"; do
  src="${pair%%:*}"
  dst="${pair#*:}"
  if [[ -n "$src" ]] && sudo -n test -f "$src"; then
    sudo -n cp "$src" "$TMP/$dst"
    sudo -n chown ubuntu:ubuntu "$TMP/$dst"
    chmod 0600 "$TMP/$dst"
  fi
done

BRIDGE_DIR="/var/log/zoe-coder-router/remote/$JOB_ID"
if sudo -n test -d "$BRIDGE_DIR"; then
  sudo -n cp -a "$BRIDGE_DIR" "$TMP/bridge-remote"
  sudo -n chown -R ubuntu:ubuntu "$TMP/bridge-remote"
  chmod -R u+rwX,go-rwx "$TMP/bridge-remote"
fi

[[ "$WRITER_RC" == '0' ]] || fail WRITER_EXECUTION_FAILED "rc=$WRITER_RC status=$STATUS"
[[ "$STATUS" == 'succeeded' ]] || fail WRITER_STATUS_NOT_SUCCEEDED "$STATUS"
[[ "$EXIT_CODE" == '0' ]] || fail WRITER_EXIT_CODE_MISMATCH "$EXIT_CODE"
[[ "$MODE" == 'write' ]] || fail WRITER_MODE_MISMATCH "$MODE"
[[ "$SELECTED" == "$WRITER" ]] || fail WRITER_PROFILE_MISMATCH "$SELECTED"

git -C "$REPO" fetch -q origin "$BRANCH"
NEW_SHA="$(git -C "$REPO" rev-parse HEAD)"
ORIGIN_AFTER="$(git -C "$REPO" rev-parse "origin/$BRANCH")"
REMOTE_AFTER="$(git -C "$REPO" ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')"

[[ "$NEW_SHA" != "$START_SHA" ]] || fail WRITER_HEAD_UNCHANGED "$NEW_SHA"
[[ "$ORIGIN_AFTER" == "$NEW_SHA" ]] || fail ORIGIN_AFTER_MISMATCH "$ORIGIN_AFTER"
[[ "$REMOTE_AFTER" == "$NEW_SHA" ]] || fail REMOTE_AFTER_MISMATCH "$REMOTE_AFTER"
git -C "$REPO" merge-base --is-ancestor "$START_SHA" "$NEW_SHA" ||
  fail NEW_SHA_NOT_DESCENDANT "$NEW_SHA"
[[ "$(git -C "$REPO" rev-list --count "$START_SHA..$NEW_SHA")" == '1' ]] ||
  fail WRITER_COMMIT_COUNT_MISMATCH 'expected exactly one commit'
[[ "$(git -C "$REPO" diff --name-only "$START_SHA" "$NEW_SHA")" == 'tests/test_factory_scheduler_maintenance.py' ]] ||
  fail WRITER_SCOPE_MISMATCH "$(git -C "$REPO" diff --name-only "$START_SHA" "$NEW_SHA")"
[[ "$(git -C "$REPO" show -s --format='%s' "$NEW_SHA")" == "$EXPECTED_SUBJECT" ]] ||
  fail WRITER_SUBJECT_MISMATCH "$(git -C "$REPO" show -s --format='%s' "$NEW_SHA")"
[[ -z "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail SOURCE_WORKTREE_DIRTY_AFTER 'source worktree is not clean'
git -C "$REPO" diff --check "$START_SHA" "$NEW_SHA"

SSH=(
  ssh
  -i "$KEY"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$KNOWN"
  -o ConnectTimeout=15
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=20
  "ubuntu@$WORKER"
)

REMOTE_REPO="/var/lib/zoe-worker/jobs/$JOB_ID/repo"
"${SSH[@]}" "sudo -n -u onca-runner -H bash -s -- '$REMOTE_REPO' '$NEW_SHA'" \
  > "$TMP/independent-test-readback.log" 2>&1 <<'REMOTE'
set -Eeuo pipefail
REPO="$1"
EXPECTED_SHA="$2"

test "$(git -C "$REPO" rev-parse HEAD)" = "$EXPECTED_SHA"
test -z "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)"
cd "$REPO"

echo '===== CAPACITY PLAN REGRESSIONS ====='
PYTEST_ADDOPTS='-p no:cacheprovider' PYTHONDONTWRITEBYTECODE=1 \
python3 -B -m pytest -q tests/test_factory_scheduler_maintenance.py -k 'capacity_plan'

echo '===== SCHEDULER MAINTENANCE ====='
PYTEST_ADDOPTS='-p no:cacheprovider' PYTHONDONTWRITEBYTECODE=1 \
python3 -B -m pytest -q tests/test_factory_scheduler_maintenance.py

echo '===== PROVENANCE AND SMOKE ====='
PYTEST_ADDOPTS='-p no:cacheprovider' PYTHONDONTWRITEBYTECODE=1 \
python3 -B -m pytest -q \
  tests/test_opencode_result_provenance.py \
  tests/test_opencode_terminal_result_smoke.py

echo '===== FULL SUITE ====='
PYTEST_ADDOPTS='-p no:cacheprovider' PYTHONDONTWRITEBYTECODE=1 \
python3 -B -m pytest -q

echo '===== COMPILEALL ====='
PYTHONDONTWRITEBYTECODE=1 python3 -B -m compileall -q src tests
echo 'compileall=PASS'

echo '===== DIFF CHECK ====='
git diff --check HEAD^ HEAD
echo 'diff_check=PASS'

test -z "$(git status --porcelain=v1 --untracked-files=all)"
echo 'worker_worktree_clean=true'
echo 'INDEPENDENT_TEST_READBACK=PASS'
REMOTE

ACTIVE_JOBS_AFTER="$(active_jobs)"
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
  echo '===== MANUAL ETAPA 6B SUMMARY ====='
  echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "job_id=$JOB_ID"
  echo "writer_status=$STATUS"
  echo "writer_exit_code=$EXIT_CODE"
  echo "writer_profile=$SELECTED"
  echo "start_sha=$START_SHA"
  echo "new_sha=$NEW_SHA"
  echo "commit_subject=$EXPECTED_SUBJECT"
  echo 'changed_file=tests/test_factory_scheduler_maintenance.py'
  echo "origin_head=$ORIGIN_AFTER"
  echo "remote_head=$REMOTE_AFTER"
  echo "active_jobs=$ACTIVE_JOBS_AFTER"
  echo "active_units=$ACTIVE_UNITS_AFTER"
  echo "timer=$TIMER_AFTER"
  echo
  cat "$TMP/independent-test-readback.log"
} | tee "$TMP/SUMMARY.txt"

sudo -n rm -rf "$EVIDENCE_FINAL"
sudo -n install -d -m 0700 -o root -g root "$EVIDENCE_FINAL"
sudo -n cp -a "$TMP/." "$EVIDENCE_FINAL/"
sudo -n chown -R root:root "$EVIDENCE_FINAL"
sudo -n chmod -R go-rwx "$EVIDENCE_FINAL"

echo
echo 'MANUAL_ETAPA_6B: PASS'
echo "JOB_ID=$JOB_ID"
echo "START_SHA=$START_SHA"
echo "NEW_SHA=$NEW_SHA"
echo "WRITER_PROFILE=$WRITER"
echo 'CHANGED_FILE=tests/test_factory_scheduler_maintenance.py'
echo "ACTIVE_JOBS=$ACTIVE_JOBS_AFTER"
echo "ACTIVE_UNITS=$ACTIVE_UNITS_AFTER"
echo "TIMER=$TIMER_AFTER"
echo "EVIDENCE=$EVIDENCE_FINAL"
echo 'NEXT=REEXECUTAR_GATE_INDEPENDENTE_EXACT_SHA'
