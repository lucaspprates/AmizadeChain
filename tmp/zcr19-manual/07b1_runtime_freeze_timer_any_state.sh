#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

OPS='/var/backups/zoe-coder-router/manual-8-etapas-20260731T104654Z'
DB='/var/lib/zoe-coder-router/runtime.db'
GH_REPO='lucaspprates/Zoe-Coder-Router'

PR19='19'
MAIN_EXPECTED='ad9cb37f37ceb1353f58a4c2c24de50ce50b9c4a'
PR19_HEAD='7148c751257832c7953c59a17578985b7bf6e52e'
FAILED_7B="$OPS/ETAPA-7B-FINAL-MERGE-PR19-20260731T142039Z-FAILED"
FAILED_7B0="$OPS/ETAPA-7B0-TIMER-CONTAINMENT-20260731T143759Z-FAILED"

TIMER_UNIT='zoe-coder-reconcile.timer'
SERVICE_UNIT='zoe-coder-reconcile.service'
GUARD_DIR="/run/systemd/system/${TIMER_UNIT}.d"
GUARD_FILE="$GUARD_DIR/99-zcr-manual-merge-freeze.conf"
ALLOW_PATH='/run/zoe-coder-router/ALLOW_RECONCILE_TIMER_STAGE8'

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_TMP="$(mktemp -d /tmp/zcr19-stage7b1.XXXXXX)"
EVIDENCE_FINAL="$OPS/ETAPA-7B1-RUNTIME-FREEZE-$STAMP"
PERSISTED=''
GUARD_APPLIED='false'

cleanup() {
  rm -rf "$EVIDENCE_TMP"
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
  if [[ "$GUARD_APPLIED" == 'true' ]]; then
    sudo -n systemctl stop "$TIMER_UNIT" >/dev/null 2>&1 || true
  fi
  {
    echo 'MANUAL_ETAPA_7B1: FAIL'
    echo "FAILURE_CODE=$code"
    echo "DETAIL=$*"
  } | tee -a "$EVIDENCE_TMP/FAILURE.txt" >&2
  persist_evidence FAILED || true
  echo "EVIDENCE=${PERSISTED:-$EVIDENCE_TMP}" >&2
  exit 1
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

active_worker_units() {
  systemctl list-units \
    'zoe-coder-job@*.service' \
    'zoe-coder-wake@*.service' \
    --state=active,activating \
    --no-legend \
    --no-pager 2>/dev/null |
  awk 'NF{n++} END{print n+0}'
}

capture_state() {
  local phase="$1"
  local dir="$EVIDENCE_TMP/$phase"
  mkdir -p "$dir"

  date -u +%Y-%m-%dT%H:%M:%SZ > "$dir/timestamp.txt"
  cat /proc/sys/kernel/random/boot_id > "$dir/boot-id.txt" 2>&1 || true
  uptime -s > "$dir/uptime-start.txt" 2>&1 || true

  systemctl is-active "$TIMER_UNIT" > "$dir/timer-is-active.txt" 2>&1 || true
  systemctl is-enabled "$TIMER_UNIT" > "$dir/timer-is-enabled.txt" 2>&1 || true
  systemctl status "$TIMER_UNIT" --no-pager -l > "$dir/timer-status.txt" 2>&1 || true
  systemctl show "$TIMER_UNIT" \
    -p Id -p Names -p Description -p LoadState -p ActiveState -p SubState \
    -p UnitFileState -p FragmentPath -p SourcePath -p Triggers -p TriggeredBy \
    -p NextElapseUSecRealtime -p LastTriggerUSec -p Result -p InvocationID \
    -p Conditions -p RefuseManualStart \
    > "$dir/timer-show.txt" 2>&1 || true
  systemctl cat "$TIMER_UNIT" > "$dir/timer-cat.txt" 2>&1 || true

  systemctl is-active "$SERVICE_UNIT" > "$dir/service-is-active.txt" 2>&1 || true
  systemctl status "$SERVICE_UNIT" --no-pager -l > "$dir/service-status.txt" 2>&1 || true
  systemctl show "$SERVICE_UNIT" \
    -p Id -p Names -p Description -p LoadState -p ActiveState -p SubState \
    -p UnitFileState -p FragmentPath -p SourcePath -p Result -p InvocationID \
    -p ExecMainStartTimestamp -p ExecMainExitTimestamp -p ExecMainStatus \
    > "$dir/service-show.txt" 2>&1 || true

  systemctl list-timers --all --no-pager > "$dir/list-timers-all.txt" 2>&1 || true

  sudo -n journalctl \
    -u "$TIMER_UNIT" -u "$SERVICE_UNIT" \
    --since '2026-07-31 13:45:00 UTC' \
    --no-pager -o short-iso-precise \
    > "$dir/reconcile-journal.txt" 2>&1 || true

  if sudo -n test -r /var/log/auth.log; then
    sudo -n grep -E \
      'zoe-coder-reconcile\.(timer|service)|systemctl.*(start|restart|enable|reenable|unmask|mask|stop|daemon-reload)' \
      /var/log/auth.log \
      > "$dir/auth-log-relevant.txt" 2>&1 || true
  fi

  sudo -n find /etc/systemd/system /run/systemd/system \
    -maxdepth 5 \( -type l -o -type f \) \
    -iname '*zoe-coder-reconcile*' -ls \
    > "$dir/reconcile-unit-files.txt" 2>&1 || true

  {
    echo "active_jobs=$(active_jobs)"
    echo "active_worker_units=$(active_worker_units)"
    echo "guard_file_present=$(sudo -n test -f "$GUARD_FILE" && echo true || echo false)"
    echo "allow_path_present=$(sudo -n test -e "$ALLOW_PATH" && echo true || echo false)"
  } > "$dir/runtime-counts.txt"

  gh pr view "$PR19" --repo "$GH_REPO" \
    --json state,isDraft,mergeable,headRefOid,baseRefName \
    > "$dir/pr19.json" 2>&1 || true
  gh api "repos/$GH_REPO/commits/main" --jq '.sha' \
    > "$dir/main-sha.txt" 2>&1 || true
}

verify_git_state() {
  local suffix="$1"
  local pr_state pr_draft pr_head pr_base main_remote

  pr_state="$(gh pr view "$PR19" --repo "$GH_REPO" --json state --jq '.state')"
  pr_draft="$(gh pr view "$PR19" --repo "$GH_REPO" --json isDraft --jq '.isDraft')"
  pr_head="$(gh pr view "$PR19" --repo "$GH_REPO" --json headRefOid --jq '.headRefOid')"
  pr_base="$(gh pr view "$PR19" --repo "$GH_REPO" --json baseRefName --jq '.baseRefName')"
  main_remote="$(gh api "repos/$GH_REPO/commits/main" --jq '.sha')"

  [[ "$pr_state" == 'OPEN' ]] || fail "PR19_STATE_CHANGED${suffix}" "$pr_state"
  [[ "$pr_draft" == 'true' ]] || fail "PR19_DRAFT_CHANGED${suffix}" "$pr_draft"
  [[ "$pr_head" == "$PR19_HEAD" ]] || fail "PR19_HEAD_CHANGED${suffix}" "$pr_head"
  [[ "$pr_base" == 'main' ]] || fail "PR19_BASE_CHANGED${suffix}" "$pr_base"
  [[ "$main_remote" == "$MAIN_EXPECTED" ]] || fail "MAIN_CHANGED${suffix}" "$main_remote"
}

[[ "$(id -un)" == 'ubuntu' ]] || fail USER_MISMATCH 'execute como ubuntu'
[[ "$(hostname -s)" == 'zoe-infranetwork-com-br' ]] || fail HOST_MISMATCH "$(hostname -s)"
sudo -n true >/dev/null 2>&1 || fail SUDO_UNAVAILABLE 'sudo NOPASSWD obrigatório'
command -v gh >/dev/null 2>&1 || fail GH_MISSING 'gh CLI não encontrado'
command -v python3 >/dev/null 2>&1 || fail PYTHON_MISSING 'python3 não encontrado'
sudo -n test -d "$OPS" || fail OPS_MISSING "$OPS"
sudo -n test -r "$DB" || fail DB_UNREADABLE "$DB"
sudo -n test -d "$FAILED_7B" || fail FAILED_7B_EVIDENCE_MISSING "$FAILED_7B"
sudo -n test -d "$FAILED_7B0" || fail FAILED_7B0_EVIDENCE_MISSING "$FAILED_7B0"
gh auth status > "$EVIDENCE_TMP/gh-auth-status.txt" 2>&1 ||
  fail GH_AUTH_FAILED 'gh auth status falhou'

capture_state before
verify_git_state ''

TIMER_BEFORE="$(systemctl is-active "$TIMER_UNIT" 2>/dev/null || true)"
TIMER_ENABLEMENT_BEFORE="$(systemctl is-enabled "$TIMER_UNIT" 2>/dev/null || true)"
case "$TIMER_BEFORE" in
  active|inactive) ;;
  *) fail TIMER_UNEXPECTED_STATE "$TIMER_BEFORE" ;;
esac

sudo -n test ! -e "$ALLOW_PATH" ||
  fail ALLOW_PATH_PRESENT "$ALLOW_PATH"

SERVICE_STATE="$(systemctl is-active "$SERVICE_UNIT" 2>/dev/null || true)"
if [[ "$SERVICE_STATE" == 'active' || "$SERVICE_STATE" == 'activating' ]]; then
  for _ in $(seq 1 30); do
    sleep 2
    SERVICE_STATE="$(systemctl is-active "$SERVICE_UNIT" 2>/dev/null || true)"
    [[ "$SERVICE_STATE" != 'active' && "$SERVICE_STATE" != 'activating' ]] && break
  done
fi
[[ "$SERVICE_STATE" != 'active' && "$SERVICE_STATE" != 'activating' ]] ||
  fail RECONCILE_SERVICE_STILL_ACTIVE "$SERVICE_STATE"

PRE_JOBS="$(active_jobs)"
PRE_UNITS="$(active_worker_units)"
[[ "$PRE_JOBS" == '0' ]] || fail ACTIVE_JOBS_BEFORE_FREEZE "$PRE_JOBS"
[[ "$PRE_UNITS" == '0' ]] || fail ACTIVE_UNITS_BEFORE_FREEZE "$PRE_UNITS"

sudo -n systemctl stop "$TIMER_UNIT" \
  > "$EVIDENCE_TMP/timer-stop-before-freeze.txt" 2>&1 ||
  fail TIMER_STOP_FAILED "$TIMER_UNIT"

sudo -n install -d -m 0755 -o root -g root "$GUARD_DIR"
sudo -n tee "$GUARD_FILE" > /dev/null <<EOF_GUARD
[Unit]
ConditionPathExists=$ALLOW_PATH
RefuseManualStart=yes
EOF_GUARD
sudo -n chown root:root "$GUARD_FILE"
sudo -n chmod 0644 "$GUARD_FILE"
GUARD_APPLIED='true'

sudo -n systemctl daemon-reload \
  > "$EVIDENCE_TMP/daemon-reload.txt" 2>&1 ||
  fail DAEMON_RELOAD_FAILED "$TIMER_UNIT"
sudo -n systemctl stop "$TIMER_UNIT" \
  > "$EVIDENCE_TMP/timer-stop-after-freeze.txt" 2>&1 ||
  fail TIMER_STOP_AFTER_FREEZE_FAILED "$TIMER_UNIT"

sudo -n test -f "$GUARD_FILE" || fail GUARD_FILE_MISSING "$GUARD_FILE"
grep -Fxq "ConditionPathExists=$ALLOW_PATH" "$GUARD_FILE" ||
  fail GUARD_CONDITION_MISSING "$GUARD_FILE"
grep -Fxq 'RefuseManualStart=yes' "$GUARD_FILE" ||
  fail GUARD_REFUSE_START_MISSING "$GUARD_FILE"

# Prove the runtime guard: an explicit start must not leave the timer active.
set +e
sudo -n systemctl start "$TIMER_UNIT" \
  > "$EVIDENCE_TMP/guard-start-test.txt" 2>&1
START_TEST_RC=$?
set -e
START_TEST_STATE="$(systemctl is-active "$TIMER_UNIT" 2>/dev/null || true)"
if [[ "$START_TEST_STATE" == 'active' || "$START_TEST_STATE" == 'activating' ]]; then
  sudo -n systemctl stop "$TIMER_UNIT" >/dev/null 2>&1 || true
  fail GUARD_START_TEST_FAILED "rc=$START_TEST_RC state=$START_TEST_STATE"
fi

sleep 3
capture_state after
verify_git_state '_AFTER'

TIMER_AFTER="$(systemctl is-active "$TIMER_UNIT" 2>/dev/null || true)"
TIMER_ENABLEMENT_AFTER="$(systemctl is-enabled "$TIMER_UNIT" 2>/dev/null || true)"
REFUSE_AFTER="$(systemctl show "$TIMER_UNIT" -p RefuseManualStart --value 2>/dev/null || true)"
SERVICE_AFTER="$(systemctl is-active "$SERVICE_UNIT" 2>/dev/null || true)"
FINAL_JOBS="$(active_jobs)"
FINAL_UNITS="$(active_worker_units)"

[[ "$TIMER_AFTER" == 'inactive' ]] || fail TIMER_STILL_ACTIVE "$TIMER_AFTER"
[[ "$REFUSE_AFTER" == 'yes' ]] || fail REFUSE_MANUAL_START_NOT_APPLIED "$REFUSE_AFTER"
sudo -n test ! -e "$ALLOW_PATH" || fail ALLOW_PATH_CREATED "$ALLOW_PATH"
[[ "$SERVICE_AFTER" != 'active' && "$SERVICE_AFTER" != 'activating' ]] ||
  fail RECONCILE_SERVICE_ACTIVE_AFTER "$SERVICE_AFTER"
[[ "$FINAL_JOBS" == '0' ]] || fail ACTIVE_JOBS_PRESENT "$FINAL_JOBS"
[[ "$FINAL_UNITS" == '0' ]] || fail ACTIVE_UNITS_PRESENT "$FINAL_UNITS"

{
  echo 'MANUAL_ETAPA_7B1: PASS'
  echo "TIMER_BEFORE=$TIMER_BEFORE"
  echo "TIMER_ENABLEMENT_BEFORE=$TIMER_ENABLEMENT_BEFORE"
  echo "TIMER_AFTER=$TIMER_AFTER"
  echo "TIMER_ENABLEMENT_AFTER=$TIMER_ENABLEMENT_AFTER"
  echo "REFUSE_MANUAL_START=$REFUSE_AFTER"
  echo "START_TEST_RC=$START_TEST_RC"
  echo "START_TEST_STATE=$START_TEST_STATE"
  echo "RECONCILE_SERVICE=$SERVICE_AFTER"
  echo "ACTIVE_JOBS=$FINAL_JOBS"
  echo "ACTIVE_UNITS=$FINAL_UNITS"
  echo 'PR19_UNCHANGED=true'
  echo "PR19_HEAD=$PR19_HEAD"
  echo "MAIN=$MAIN_EXPECTED"
  echo "GUARD_FILE=$GUARD_FILE"
  echo "ALLOW_PATH=$ALLOW_PATH"
  echo 'CONTAINMENT=runtime-dropin-condition'
  echo 'NEXT=RERUN_ETAPA_7B'
} | tee "$EVIDENCE_TMP/RESULT.txt"

persist_evidence PASS

echo
echo 'MANUAL_ETAPA_7B1_READBACK: PASS'
echo "EVIDENCE=$PERSISTED"
