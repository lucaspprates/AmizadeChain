#!/usr/bin/env bash
set -Eeuo pipefail

REPO='/home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler'
OPS='/var/backups/zoe-coder-router/manual-8-etapas-20260731T104654Z'
DB='/var/lib/zoe-coder-router/runtime.db'

WORKER='201.23.86.157'
KEY='/home/ubuntu/.ssh/ssh-key-2026-06-03.key'
KNOWN='/home/ubuntu/.ssh/known_hosts_onca_8x1'
JOB_ID='5d3be2b8-28aa-4c0c-a66a-cd6607093935'
REMOTE_REPO="/var/lib/zoe-worker/jobs/$JOB_ID/repo"

BRANCH='type/18-factory-scheduler-maintenance'
START_SHA='a3b3f438dd2d6b365187248f11bcd661dba047fa'
NEW_SHA='c3db2c39e58326c932e1a9276b1da9b4cecd45bb'
EXPECTED_REMOTE_SHA='a3b3f438dd2d6b365187248f11bcd661dba047fa'
EXPECTED_SUBJECT='fix(router): validate capacity plan job admission'

TMP_LOG="$(mktemp /tmp/zcr19-etapa4-v3.XXXXXX.log)"

cleanup() {
  rm -f "$TMP_LOG"
}
trap cleanup EXIT

fail() {
  printf 'MANUAL_ETAPA_4: FAIL: %s\n' "$*" >&2
  exit 1
}

[[ "$(id -un)" == 'ubuntu' ]] || fail 'user must be ubuntu'
[[ "$(hostname -s)" == 'zoe-infranetwork-com-br' ]] || fail 'unexpected hostname'
[[ -d "$REPO" ]] || fail 'repository worktree missing'
[[ -r "$KEY" ]] || fail 'worker SSH key missing'
[[ -r "$KNOWN" ]] || fail 'worker known_hosts missing'
sudo -n true >/dev/null 2>&1 || fail 'passwordless sudo unavailable'
sudo -n test -d "$OPS" || fail 'operation directory missing or inaccessible to root'
sudo -n test -r "$DB" || fail 'runtime database missing or unreadable to root'

TIMER="$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
[[ "$TIMER" == 'inactive' ]] || fail "reconcile timer is $TIMER"

ACTIVE_UNITS="$(
  systemctl list-units \
    'zoe-coder-job@*.service' \
    --state=active,activating \
    --no-legend \
    --no-pager 2>/dev/null |
  awk 'NF{n++} END{print n+0}'
)"
[[ "$ACTIVE_UNITS" == '0' ]] || fail "active coder job units: $ACTIVE_UNITS"

ACTIVE_WRITERS="$(
  sudo -n -u ubuntu -g zoe-coders -H -- \
  python3 - "$DB" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
count = conn.execute(
    """
    SELECT COUNT(*)
      FROM jobs
     WHERE mode='write'
       AND status IN (
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
)"
[[ "$ACTIVE_WRITERS" == '0' ]] || fail "active writers in DB: $ACTIVE_WRITERS"

[[ "$(git -C "$REPO" branch --show-current)" == "$BRANCH" ]] ||
  fail 'unexpected local branch'
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$NEW_SHA" ]] ||
  fail 'local HEAD differs from rescued commit'
[[ "$(git -C "$REPO" rev-parse HEAD^)" == "$START_SHA" ]] ||
  fail 'rescued commit is not directly based on expected SHA'
[[ "$(git -C "$REPO" rev-list --count "$START_SHA..$NEW_SHA")" == '1' ]] ||
  fail 'expected exactly one new commit'
[[ -z "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail 'local worktree is not clean'

COMMIT_SUBJECT="$(git -C "$REPO" show -s --format='%s' "$NEW_SHA")"
[[ "$COMMIT_SUBJECT" == "$EXPECTED_SUBJECT" ]] ||
  fail "unexpected commit subject: $COMMIT_SUBJECT"

CHANGED_FILES="$(
  git -C "$REPO" diff --name-only "$START_SHA" "$NEW_SHA" | sort
)"
EXPECTED_FILES="$(
  printf '%s\n' \
    'src/zoe_coder_router/zoe_coder_router.py' \
    'tests/test_factory_scheduler_maintenance.py' |
  sort
)"
[[ "$CHANGED_FILES" == "$EXPECTED_FILES" ]] ||
  fail "changed-file scope mismatch: $CHANGED_FILES"

git -C "$REPO" diff --check "$START_SHA" "$NEW_SHA"

SSH=(
  ssh
  -i "$KEY"
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$KNOWN"
  "ubuntu@$WORKER"
)

REMOTE_HEAD="$(
  "${SSH[@]}" \
    "sudo -u onca-runner -H git -C '$REMOTE_REPO' rev-parse HEAD"
)"
[[ "$REMOTE_HEAD" == "$NEW_SHA" ]] ||
  fail "worker HEAD differs from rescued commit: $REMOTE_HEAD"

REMOTE_COUNT="$(
  "${SSH[@]}" \
    "sudo -u onca-runner -H git -C '$REMOTE_REPO' rev-list --count '$START_SHA..$NEW_SHA'"
)"
[[ "$REMOTE_COUNT" == '1' ]] ||
  fail "worker commit count differs from 1: $REMOTE_COUNT"

REMOTE_STATUS="$(
  "${SSH[@]}" \
    "sudo -u onca-runner -H git -C '$REMOTE_REPO' status --porcelain=v1 --untracked-files=all"
)"
[[ -z "$REMOTE_STATUS" ]] || fail 'worker worktree is not clean'

{
  echo '===== MANUAL ETAPA 4 V3 / LOCAL INVARIANTS ====='
  echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "control_host=$(hostname -s)"
  echo "control_user=$(id -un)"
  echo "branch=$BRANCH"
  echo "start_sha=$START_SHA"
  echo "new_sha=$NEW_SHA"
  echo "commit_subject=$COMMIT_SUBJECT"
  echo "changed_files_begin"
  printf '%s\n' "$CHANGED_FILES"
  echo "changed_files_end"
  echo "active_job_units=$ACTIVE_UNITS"
  echo "active_writers_db=$ACTIVE_WRITERS"
  echo "timer=$TIMER"
  echo "worker=$WORKER"
  echo "worker_repo=$REMOTE_REPO"
  echo "worker_head=$REMOTE_HEAD"
  echo "worker_commit_count=$REMOTE_COUNT"

  echo
  echo '===== ATOMIC ADMISSION FUNCTION ====='
  sed -n \
    '/^def admit_validated_capacity_plan/,/^def reconcile_terminal_receipts/p' \
    "$REPO/src/zoe_coder_router/zoe_coder_router.py"

  echo
  echo '===== REMOTE WORKER VALIDATION ====='
  "${SSH[@]}" \
    "sudo -u onca-runner -H env \
       REPO='$REMOTE_REPO' \
       START_SHA='$START_SHA' \
       NEW_SHA='$NEW_SHA' \
       bash -s" <<'REMOTE_TESTS'
set -Eeuo pipefail

cd "$REPO"

[[ "$(git rev-parse HEAD)" == "$NEW_SHA" ]]
[[ "$(git rev-parse HEAD^)" == "$START_SHA" ]]
[[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]]

echo '===== CAPACITY PLAN REGRESSIONS ====='
PYTEST_ADDOPTS='-p no:cacheprovider' \
PYTHONDONTWRITEBYTECODE=1 \
python3 -B -m pytest -q \
  tests/test_factory_scheduler_maintenance.py \
  -k 'capacity_plan'

echo
echo '===== SCHEDULER MAINTENANCE ====='
PYTEST_ADDOPTS='-p no:cacheprovider' \
PYTHONDONTWRITEBYTECODE=1 \
python3 -B -m pytest -q \
  tests/test_factory_scheduler_maintenance.py

echo
echo '===== PROVENANCE AND SMOKE ====='
PYTEST_ADDOPTS='-p no:cacheprovider' \
PYTHONDONTWRITEBYTECODE=1 \
python3 -B -m pytest -q \
  tests/test_opencode_result_provenance.py \
  tests/test_opencode_terminal_result_smoke.py

echo
echo '===== FULL SUITE ====='
PYTEST_ADDOPTS='-p no:cacheprovider' \
PYTHONDONTWRITEBYTECODE=1 \
python3 -B -m pytest -q

echo
echo '===== COMPILEALL ====='
PYTHONDONTWRITEBYTECODE=1 \
python3 -B -m compileall -q src tests
echo 'compileall=PASS'

echo
echo '===== DIFF CHECK ====='
git diff --check "$START_SHA" "$NEW_SHA"
echo 'diff_check=PASS'

echo
echo '===== FINAL WORKTREE ====='
[[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]]
echo 'worktree_clean=true'

echo
echo 'REMOTE_WORKER_VALIDATION: PASS'
REMOTE_TESTS

  echo
  echo 'MANUAL_ETAPA_4: PASS'
} 2>&1 | tee "$TMP_LOG"

sudo -n install \
  -m 0600 \
  -o root \
  -g root \
  "$TMP_LOG" \
  "$OPS/ETAPA-4-LOCAL-AND-WORKER-VALIDATION.txt"

git -C "$REPO" fetch -q origin "$BRANCH"
ORIGIN_HEAD="$(git -C "$REPO" rev-parse "origin/$BRANCH")"
[[ "$ORIGIN_HEAD" == "$EXPECTED_REMOTE_SHA" ]] ||
  fail "origin branch changed concurrently: $ORIGIN_HEAD"

echo
echo 'MANUAL_ETAPA_4_READBACK: PASS'
echo "LOCAL_HEAD=$(git -C "$REPO" rev-parse HEAD)"
echo "ORIGIN_HEAD=$ORIGIN_HEAD"
echo "WORKER_HEAD=$REMOTE_HEAD"
echo "COMMIT_COUNT=$(git -C "$REPO" rev-list --count "$START_SHA..HEAD")"
echo "ACTIVE_UNITS=$ACTIVE_UNITS"
echo "ACTIVE_WRITERS_DB=$ACTIVE_WRITERS"
echo "TIMER=$TIMER"
echo "EVIDENCE=$OPS/ETAPA-4-LOCAL-AND-WORKER-VALIDATION.txt"
echo 'NEXT=PUBLICAR_FAST_FORWARD_PR19'
