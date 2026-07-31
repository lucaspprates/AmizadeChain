#!/usr/bin/env bash
set -Eeuo pipefail

REPO='/home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler'
OPS='/var/backups/zoe-coder-router/manual-8-etapas-20260731T104654Z'
DB='/var/lib/zoe-coder-router/runtime.db'

BRANCH='type/18-factory-scheduler-maintenance'
START_SHA='a3b3f438dd2d6b365187248f11bcd661dba047fa'
NEW_SHA='c3db2c39e58326c932e1a9276b1da9b4cecd45bb'
EXPECTED_ORIGIN_SHA='a3b3f438dd2d6b365187248f11bcd661dba047fa'
EXPECTED_SUBJECT='fix(router): validate capacity plan job admission'
VALIDATION_EVIDENCE="$OPS/ETAPA-4-LOCAL-AND-WORKER-VALIDATION.txt"

TMP_LOG="$(mktemp /tmp/zcr19-etapa5.XXXXXX.log)"

cleanup() {
  rm -f "$TMP_LOG"
}
trap cleanup EXIT

fail() {
  printf 'MANUAL_ETAPA_5: FAIL: %s\n' "$*" >&2
  exit 1
}

[[ "$(id -un)" == 'ubuntu' ]] || fail 'user must be ubuntu'
[[ "$(hostname -s)" == 'zoe-infranetwork-com-br' ]] || fail 'unexpected hostname'
[[ -d "$REPO" ]] || fail 'repository worktree missing'
sudo -n true >/dev/null 2>&1 || fail 'passwordless sudo unavailable'
sudo -n test -d "$OPS" || fail 'operation directory missing or inaccessible'
sudo -n test -r "$DB" || fail 'runtime database missing or unreadable'
sudo -n test -r "$VALIDATION_EVIDENCE" || fail 'stage 4 validation evidence missing'

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

git -C "$REPO" fetch -q origin "$BRANCH"

LOCAL_BRANCH="$(git -C "$REPO" branch --show-current)"
LOCAL_HEAD="$(git -C "$REPO" rev-parse HEAD)"
ORIGIN_BEFORE="$(git -C "$REPO" rev-parse "origin/$BRANCH")"
REMOTE_BEFORE="$(git -C "$REPO" ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')"

[[ "$LOCAL_BRANCH" == "$BRANCH" ]] || fail "unexpected local branch: $LOCAL_BRANCH"
[[ "$LOCAL_HEAD" == "$NEW_SHA" ]] || fail "local HEAD differs: $LOCAL_HEAD"
[[ "$ORIGIN_BEFORE" == "$EXPECTED_ORIGIN_SHA" ]] || fail "origin tracking SHA changed: $ORIGIN_BEFORE"
[[ "$REMOTE_BEFORE" == "$EXPECTED_ORIGIN_SHA" ]] || fail "remote branch SHA changed: $REMOTE_BEFORE"
[[ "$(git -C "$REPO" rev-parse HEAD^)" == "$START_SHA" ]] || fail 'commit parent differs'
[[ "$(git -C "$REPO" rev-list --count "$START_SHA..$NEW_SHA")" == '1' ]] || fail 'expected one new commit'
[[ -z "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)" ]] || fail 'worktree is not clean'

git -C "$REPO" merge-base --is-ancestor "$EXPECTED_ORIGIN_SHA" "$NEW_SHA" ||
  fail 'new SHA is not a fast-forward of remote branch'

[[ "$(git -C "$REPO" show -s --format='%s' "$NEW_SHA")" == "$EXPECTED_SUBJECT" ]] ||
  fail 'unexpected commit subject'

CHANGED_FILES="$(
  git -C "$REPO" diff --name-only "$START_SHA" "$NEW_SHA" | sort
)"
EXPECTED_FILES="$(
  printf '%s\n' \
    'src/zoe_coder_router/zoe_coder_router.py' \
    'tests/test_factory_scheduler_maintenance.py' |
  sort
)"
[[ "$CHANGED_FILES" == "$EXPECTED_FILES" ]] || fail 'changed-file scope mismatch'
git -C "$REPO" diff --check "$START_SHA" "$NEW_SHA"

{
  echo '===== MANUAL ETAPA 5 / PRE-PUSH ====='
  echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "hostname=$(hostname -s)"
  echo "user=$(id -un)"
  echo "branch=$BRANCH"
  echo "local_head=$LOCAL_HEAD"
  echo "origin_before=$ORIGIN_BEFORE"
  echo "remote_before=$REMOTE_BEFORE"
  echo "active_job_units=$ACTIVE_UNITS"
  echo "active_writers_db=$ACTIVE_WRITERS"
  echo "timer=$TIMER"
  echo "validation_evidence=$VALIDATION_EVIDENCE"
  echo 'push_mode=explicit_non_force_fast_forward'

  echo
  echo '===== PUSH ====='
  git -C "$REPO" push --porcelain \
    origin \
    "$NEW_SHA:refs/heads/$BRANCH"

  echo
  echo '===== READBACK ====='
  git -C "$REPO" fetch -q origin "$BRANCH"

  ORIGIN_AFTER="$(git -C "$REPO" rev-parse "origin/$BRANCH")"
  REMOTE_AFTER="$(git -C "$REPO" ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')"
  LOCAL_AFTER="$(git -C "$REPO" rev-parse HEAD)"

  [[ "$LOCAL_AFTER" == "$NEW_SHA" ]] || fail "local readback differs: $LOCAL_AFTER"
  [[ "$ORIGIN_AFTER" == "$NEW_SHA" ]] || fail "origin readback differs: $ORIGIN_AFTER"
  [[ "$REMOTE_AFTER" == "$NEW_SHA" ]] || fail "remote readback differs: $REMOTE_AFTER"
  [[ -z "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)" ]] ||
    fail 'worktree became dirty'

  echo "local_after=$LOCAL_AFTER"
  echo "origin_after=$ORIGIN_AFTER"
  echo "remote_after=$REMOTE_AFTER"
  echo 'worktree_clean=true'
  echo
  echo 'MANUAL_ETAPA_5: PASS'
} 2>&1 | tee "$TMP_LOG"

sudo -n install \
  -m 0600 \
  -o root \
  -g root \
  "$TMP_LOG" \
  "$OPS/ETAPA-5-FAST-FORWARD-PUBLISH.txt"

echo
echo 'MANUAL_ETAPA_5_READBACK: PASS'
echo "LOCAL_HEAD=$(git -C "$REPO" rev-parse HEAD)"
echo "ORIGIN_HEAD=$(git -C "$REPO" rev-parse "origin/$BRANCH")"
echo "REMOTE_HEAD=$(git -C "$REPO" ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')"
echo "COMMIT_COUNT=$(git -C "$REPO" rev-list --count "$START_SHA..HEAD")"
echo "ACTIVE_UNITS=$ACTIVE_UNITS"
echo "ACTIVE_WRITERS_DB=$ACTIVE_WRITERS"
echo "TIMER=$TIMER"
echo "EVIDENCE=$OPS/ETAPA-5-FAST-FORWARD-PUBLISH.txt"
echo 'NEXT=EXECUTAR_GATE_INDEPENDENTE_EXACT_SHA'
