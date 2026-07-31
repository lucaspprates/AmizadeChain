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
TIMER_UNIT='zoe-coder-reconcile.timer'
SERVICE_UNIT='zoe-coder-reconcile.service'

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_TMP="$(mktemp -d /tmp/zcr19-stage7b0.XXXXXX)"
EVIDENCE_FINAL="$OPS/ETAPA-7B0-TIMER-CONTAINMENT-$STAMP"
PERSISTED=''

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
  {
    echo 'MANUAL_ETAPA_7B0: FAIL'
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
  hostnamectl > "$dir/hostnamectl.txt" 2>&1 || true
  uptime -s > "$dir/uptime-start.txt" 2>&1 || true
  cat /proc/sys/kernel/random/boot_id > "$dir/boot-id.txt" 2>&1 || true

  systemctl is-active "$TIMER_UNIT" > "$dir/timer-is-active.txt" 2>&1 || true
  systemctl is-enabled "$TIMER_UNIT" > "$dir/timer-is-enabled.txt" 2>&1 || true
  systemctl status "$TIMER_UNIT" --no-pager -l > "$dir/timer-status.txt" 2>&1 || true
  systemctl show "$TIMER_UNIT" \
    -p Id -p Names -p Description -p LoadState -p ActiveState -p SubState \
    -p UnitFileState -p FragmentPath -p SourcePath -p Triggers -p TriggeredBy \
    -p NextElapseUSecRealtime -p LastTriggerUSec -p Result -p InvocationID \
    > "$dir/timer-show.txt" 2>&1 || true
  systemctl cat "$TIMER_UNIT" > "$dir/timer-cat.txt" 2>&1 || true

  systemctl is-active "$SERVICE_UNIT" > "$dir/service-is-active.txt" 2>&1 || true
  systemctl is-enabled "$SERVICE_UNIT" > "$dir/service-is-enabled.txt" 2>&1 || true
  systemctl status "$SERVICE_UNIT" --no-pager -l > "$dir/service-status.txt" 2>&1 || true
  systemctl show "$SERVICE_UNIT" \
    -p Id -p Names -p Description -p LoadState -p ActiveState -p SubState \
    -p UnitFileState -p FragmentPath -p SourcePath -p Result -p InvocationID \
    -p ExecMainStartTimestamp -p ExecMainExitTimestamp -p ExecMainStatus \
    > "$dir/service-show.txt" 2>&1 || true
  systemctl cat "$SERVICE_UNIT" > "$dir/service-cat.txt" 2>&1 || true

  systemctl list-timers --all --no-pager > "$dir/list-timers-all.txt" 2>&1 || true
  systemctl list-dependencies "$TIMER_UNIT" --all --no-pager > "$dir/timer-dependencies.txt" 2>&1 || true

  sudo -n journalctl \
    -u "$TIMER_UNIT" -u "$SERVICE_UNIT" \
    --since '2026-07-31 13:45:00 UTC' \
    --no-pager -o short-iso-precise \
    > "$dir/reconcile-journal.txt" 2>&1 || true

  if sudo -n test -r /var/log/auth.log; then
    sudo -n grep -E \
      'zoe-coder-reconcile\.(timer|service)|systemctl.*(start|restart|enable|reenable|unmask)' \
      /var/log/auth.log \
      > "$dir/auth-log-relevant.txt" 2>&1 || true
  fi

  sudo -n find /etc/systemd/system /run/systemd/system \
    -maxdepth 4 \( -type l -o -type f \) \
    -iname '*zoe-coder-reconcile*' -ls \
    > "$dir/reconcile-unit-files.txt" 2>&1 || true

  {
    echo "active_jobs=$(active_jobs)"
    echo "active_worker_units=$(active_worker_units)"
  } > "$dir/runtime-counts.txt"

  gh pr view "$PR19" --repo "$GH_REPO" \
    --json state,isDraft,mergeable,headRefOid,baseRefName \
    > "$dir/pr19.json" 2>&1 || true
  gh api "repos/$GH_REPO/commits/main" --jq '.sha' \
    > "$dir/main-sha.txt" 2>&1 || true
}

[[ "$(id -un)" == 'ubuntu' ]] || fail USER_MISMATCH 'execute como ubuntu'
[[ "$(hostname -s)" == 'zoe-infranetwork-com-br' ]] || fail HOST_MISMATCH "$(hostname -s)"
sudo -n true >/dev/null 2>&1 || fail SUDO_UNAVAILABLE 'sudo NOPASSWD obrigatório'
command -v gh >/dev/null 2>&1 || fail GH_MISSING 'gh CLI não encontrado'
command -v python3 >/dev/null 2>&1 || fail PYTHON_MISSING 'python3 não encontrado'
sudo -n test -d "$OPS" || fail OPS_MISSING "$OPS"
sudo -n test -r "$DB" || fail DB_UNREADABLE "$DB"
sudo -n test -d "$FAILED_7B" || fail FAILED_7B_EVIDENCE_MISSING "$FAILED_7B"
gh auth status > "$EVIDENCE_TMP/gh-auth-status.txt" 2>&1 || fail GH_AUTH_FAILED 'gh auth status falhou'

capture_state before

TIMER_BEFORE="$(systemctl is-active "$TIMER_UNIT" 2>/dev/null || true)"
[[ "$TIMER_BEFORE" == 'active' ]] || fail TIMER_NOT_ACTIVE_ANYMORE "$TIMER_BEFORE"

PR_STATE="$(gh pr view "$PR19" --repo "$GH_REPO" --json state --jq '.state')"
PR_DRAFT="$(gh pr view "$PR19" --repo "$GH_REPO" --json isDraft --jq '.isDraft')"
PR_HEAD="$(gh pr view "$PR19" --repo "$GH_REPO" --json headRefOid --jq '.headRefOid')"
PR_BASE="$(gh pr view "$PR19" --repo "$GH_REPO" --json baseRefName --jq '.baseRefName')"
MAIN_REMOTE="$(gh api "repos/$GH_REPO/commits/main" --jq '.sha')"

[[ "$PR_STATE" == 'OPEN' ]] || fail PR19_STATE_CHANGED "$PR_STATE"
[[ "$PR_DRAFT" == 'true' ]] || fail PR19_DRAFT_CHANGED "$PR_DRAFT"
[[ "$PR_HEAD" == "$PR19_HEAD" ]] || fail PR19_HEAD_CHANGED "$PR_HEAD"
[[ "$PR_BASE" == 'main' ]] || fail PR19_BASE_CHANGED "$PR_BASE"
[[ "$MAIN_REMOTE" == "$MAIN_EXPECTED" ]] || fail MAIN_CHANGED "$MAIN_REMOTE"

# Runtime-only containment: prevents any actor from restarting the timer until
# the controlled activation stage, without persisting across a reboot.
sudo -n systemctl mask --runtime --now "$TIMER_UNIT" \
  > "$EVIDENCE_TMP/runtime-mask.txt" 2>&1 ||
  fail TIMER_RUNTIME_MASK_FAILED "$TIMER_UNIT"

# Do not kill a reconciliation already in flight. Give a currently running
# oneshot time to complete naturally, then stop if it remains active.
for _ in $(seq 1 30); do
  SERVICE_STATE="$(systemctl is-active "$SERVICE_UNIT" 2>/dev/null || true)"
  [[ "$SERVICE_STATE" != 'active' && "$SERVICE_STATE" != 'activating' ]] && break
  sleep 2
done
SERVICE_STATE="$(systemctl is-active "$SERVICE_UNIT" 2>/dev/null || true)"
if [[ "$SERVICE_STATE" == 'active' || "$SERVICE_STATE" == 'activating' ]]; then
  fail RECONCILE_SERVICE_STILL_ACTIVE "$SERVICE_STATE"
fi

sleep 3
capture_state after

TIMER_AFTER="$(systemctl is-active "$TIMER_UNIT" 2>/dev/null || true)"
TIMER_ENABLEMENT_AFTER="$(systemctl is-enabled "$TIMER_UNIT" 2>/dev/null || true)"
FINAL_JOBS="$(active_jobs)"
FINAL_UNITS="$(active_worker_units)"

[[ "$TIMER_AFTER" == 'inactive' ]] || fail TIMER_STILL_ACTIVE "$TIMER_AFTER"
case "$TIMER_ENABLEMENT_AFTER" in
  masked|masked-runtime) ;;
  *) fail TIMER_NOT_MASKED_RUNTIME "$TIMER_ENABLEMENT_AFTER" ;;
esac
[[ "$FINAL_JOBS" == '0' ]] || fail ACTIVE_JOBS_PRESENT "$FINAL_JOBS"
[[ "$FINAL_UNITS" == '0' ]] || fail ACTIVE_UNITS_PRESENT "$FINAL_UNITS"

PR_STATE_AFTER="$(gh pr view "$PR19" --repo "$GH_REPO" --json state --jq '.state')"
PR_DRAFT_AFTER="$(gh pr view "$PR19" --repo "$GH_REPO" --json isDraft --jq '.isDraft')"
PR_HEAD_AFTER="$(gh pr view "$PR19" --repo "$GH_REPO" --json headRefOid --jq '.headRefOid')"
PR_BASE_AFTER="$(gh pr view "$PR19" --repo "$GH_REPO" --json baseRefName --jq '.baseRefName')"
MAIN_AFTER="$(gh api "repos/$GH_REPO/commits/main" --jq '.sha')"

[[ "$PR_STATE_AFTER" == 'OPEN' ]] || fail PR19_STATE_CHANGED_AFTER "$PR_STATE_AFTER"
[[ "$PR_DRAFT_AFTER" == 'true' ]] || fail PR19_DRAFT_CHANGED_AFTER "$PR_DRAFT_AFTER"
[[ "$PR_HEAD_AFTER" == "$PR19_HEAD" ]] || fail PR19_HEAD_CHANGED_AFTER "$PR_HEAD_AFTER"
[[ "$PR_BASE_AFTER" == 'main' ]] || fail PR19_BASE_CHANGED_AFTER "$PR_BASE_AFTER"
[[ "$MAIN_AFTER" == "$MAIN_EXPECTED" ]] || fail MAIN_CHANGED_AFTER "$MAIN_AFTER"

{
  echo 'MANUAL_ETAPA_7B0: PASS'
  echo "TIMER_BEFORE=$TIMER_BEFORE"
  echo "TIMER_AFTER=$TIMER_AFTER"
  echo "TIMER_ENABLEMENT_AFTER=$TIMER_ENABLEMENT_AFTER"
  echo "RECONCILE_SERVICE=$SERVICE_STATE"
  echo "ACTIVE_JOBS=$FINAL_JOBS"
  echo "ACTIVE_UNITS=$FINAL_UNITS"
  echo 'PR19_UNCHANGED=true'
  echo "PR19_HEAD=$PR19_HEAD"
  echo "MAIN=$MAIN_AFTER"
  echo 'CONTAINMENT=runtime-mask'
  echo 'NEXT=RERUN_ETAPA_7B_WITH_RUNTIME_TIMER_MASK'
} | tee "$EVIDENCE_TMP/RESULT.txt"

persist_evidence PASS

echo
echo 'MANUAL_ETAPA_7B0_READBACK: PASS'
echo "EVIDENCE=$PERSISTED"
