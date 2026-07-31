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
FAILED_7B1="$OPS/ETAPA-7B1-RUNTIME-FREEZE-20260731T144636Z-FAILED"

TIMER_UNIT='zoe-coder-reconcile.timer'
SERVICE_UNIT='zoe-coder-reconcile.service'
GUARD_DIR="/run/systemd/system/${TIMER_UNIT}.d"
GUARD_FILE="$GUARD_DIR/99-zcr-manual-merge-freeze.conf"
ALLOW_PATH='/run/zoe-coder-router/ALLOW_RECONCILE_TIMER_STAGE8'

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_TMP="$(mktemp -d /tmp/zcr19-stage7b2.XXXXXX)"
EVIDENCE_FINAL="$OPS/ETAPA-7B2-ACTIVE-JOB-DIAGNOSIS-$STAMP"
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
  {
    echo 'MANUAL_ETAPA_7B2: FAIL'
    echo "FAILURE_CODE=$code"
    echo "DETAIL=$*"
  } | tee -a "$EVIDENCE_TMP/FAILURE.txt" >&2
  persist_evidence FAILED || true
  echo "EVIDENCE=${PERSISTED:-$EVIDENCE_TMP}" >&2
  exit 1
}

capture_control_state() {
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
  systemctl list-units \
    'zoe-coder-job@*.service' \
    'zoe-coder-wake@*.service' \
    --all --no-legend --no-pager \
    > "$dir/job-wake-units-all.txt" 2>&1 || true

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
    echo "guard_file_present=$(sudo -n test -f "$GUARD_FILE" && echo true || echo false)"
    echo "allow_path_present=$(sudo -n test -e "$ALLOW_PATH" && echo true || echo false)"
  } > "$dir/runtime-guard.txt"

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

snapshot_active_jobs() {
  local json_path="$1"
  local tsv_path="$2"
  sudo -n -u ubuntu -g zoe-coders -H -- \
  python3 - "$DB" "$json_path" "$tsv_path" <<'PY'
import datetime as dt
import json
import os
import sqlite3
import sys

db_path, json_path, tsv_path = sys.argv[1:4]
conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
conn.row_factory = sqlite3.Row

columns = {row["name"] for row in conn.execute("PRAGMA table_info(jobs)")}
wanted = [
    "id", "mission_id", "kanban_task_id", "project", "worktree", "branch", "issue",
    "task_type", "mode", "selected_coder", "status", "priority", "attempt",
    "max_attempts", "auto_fallback", "execution_id", "pid", "pid_start_ticks",
    "started_at", "heartbeat_at", "process_heartbeat_at", "progress_heartbeat_at",
    "last_output_at", "last_tool_call_at", "provider_request_started_at",
    "provider_request_id", "updated_at", "created_at", "completed_at", "exit_code",
    "result_path", "stdout_path", "stderr_path", "error", "wake_pending",
    "wake_status", "watchdog_state", "stall_detected_at", "recovery_attempt",
    "last_progress_kind", "last_progress_summary", "progress_sequence",
]
selected = [name for name in wanted if name in columns]
query = (
    "SELECT " + ",".join(selected) + " FROM jobs "
    "WHERE status IN ('awaiting_capacity_plan','queued','dispatching','running') "
    "ORDER BY priority DESC, created_at ASC"
)
rows = [dict(row) for row in conn.execute(query).fetchall()]

def process_alive(pid, expected_ticks):
    if not isinstance(pid, int) or pid <= 0:
        return False
    stat_path = f"/proc/{pid}/stat"
    try:
        raw = open(stat_path, encoding="utf-8").read().strip()
        rest = raw.rsplit(")", 1)[1].split()
        current_ticks = rest[19]
        if expected_ticks not in (None, "") and str(expected_ticks) != current_ticks:
            return False
        os.kill(pid, 0)
        return True
    except (OSError, IndexError, ValueError):
        return False

def age_seconds(value):
    if not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(str(value))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return max(0, int((dt.datetime.now(dt.timezone.utc) - parsed).total_seconds()))
    except ValueError:
        return None

for row in rows:
    row["process_alive"] = process_alive(row.get("pid"), row.get("pid_start_ticks"))
    row["updated_age_seconds"] = age_seconds(row.get("updated_at"))
    row["heartbeat_age_seconds"] = age_seconds(
        row.get("process_heartbeat_at") or row.get("heartbeat_at")
    )
    job_id = row["id"]
    row["events"] = [
        dict(event)
        for event in conn.execute(
            "SELECT id,event_type,actor,payload,created_at "
            "FROM events WHERE job_id=? ORDER BY id DESC LIMIT 100",
            (job_id,),
        ).fetchall()
    ]

wake_lease = [
    dict(row)
    for row in conn.execute(
        "SELECT * FROM wake_lease ORDER BY singleton"
    ).fetchall()
]
payload = {
    "captured_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    "active_job_count": len(rows),
    "jobs": rows,
    "wake_lease": wake_lease,
}
with open(json_path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, ensure_ascii=False, sort_keys=True)
    fh.write("\n")

def clean(value):
    if value is None:
        return ""
    return str(value).replace("\t", " ").replace("\n", " ")[:500]

with open(tsv_path, "w", encoding="utf-8") as fh:
    fh.write(
        "index\tid\tstatus\tproject\tmode\tselected_coder\tpid\tprocess_alive\t"
        "updated_age_seconds\theartbeat_age_seconds\n"
    )
    for index, row in enumerate(rows, 1):
        values = [
            index, row.get("id"), row.get("status"), row.get("project"),
            row.get("mode"), row.get("selected_coder"), row.get("pid"),
            str(bool(row.get("process_alive"))).lower(),
            row.get("updated_age_seconds"), row.get("heartbeat_age_seconds"),
        ]
        fh.write("\t".join(clean(value) for value in values) + "\n")
conn.close()
PY
}

[[ "$(id -un)" == 'ubuntu' ]] || fail USER_MISMATCH 'execute como ubuntu'
[[ "$(hostname -s)" == 'zoe-infranetwork-com-br' ]] || fail HOST_MISMATCH "$(hostname -s)"
sudo -n true >/dev/null 2>&1 || fail SUDO_UNAVAILABLE 'sudo NOPASSWD obrigatório'
command -v gh >/dev/null 2>&1 || fail GH_MISSING 'gh CLI não encontrado'
command -v python3 >/dev/null 2>&1 || fail PYTHON_MISSING 'python3 não encontrado'
command -v systemd-escape >/dev/null 2>&1 || fail SYSTEMD_ESCAPE_MISSING 'systemd-escape não encontrado'
sudo -n test -d "$OPS" || fail OPS_MISSING "$OPS"
sudo -n test -r "$DB" || fail DB_UNREADABLE "$DB"
sudo -n test -d "$FAILED_7B" || fail FAILED_7B_EVIDENCE_MISSING "$FAILED_7B"
sudo -n test -d "$FAILED_7B0" || fail FAILED_7B0_EVIDENCE_MISSING "$FAILED_7B0"
sudo -n test -d "$FAILED_7B1" || fail FAILED_7B1_EVIDENCE_MISSING "$FAILED_7B1"
gh auth status > "$EVIDENCE_TMP/gh-auth-status.txt" 2>&1 ||
  fail GH_AUTH_FAILED 'gh auth status falhou'

capture_control_state before
verify_git_state ''

sudo -n test ! -e "$ALLOW_PATH" ||
  fail ALLOW_PATH_PRESENT "$ALLOW_PATH"

TIMER_BEFORE="$(systemctl is-active "$TIMER_UNIT" 2>/dev/null || true)"
case "$TIMER_BEFORE" in
  active|inactive) ;;
  *) fail TIMER_UNEXPECTED_STATE "$TIMER_BEFORE" ;;
esac

# Freeze only future reconciliation. Existing job units are not stopped.
sudo -n systemctl stop "$TIMER_UNIT" \
  > "$EVIDENCE_TMP/timer-stop-before-freeze.txt" 2>&1 ||
  fail TIMER_STOP_FAILED "$TIMER_UNIT"

EXPECTED_GUARD="$(cat <<EOF_EXPECTED
[Unit]
ConditionPathExists=$ALLOW_PATH
RefuseManualStart=yes
EOF_EXPECTED
)"

if sudo -n test -f "$GUARD_FILE"; then
  EXISTING_GUARD="$(sudo -n cat "$GUARD_FILE")"
  [[ "$EXISTING_GUARD" == "$EXPECTED_GUARD" ]] ||
    fail GUARD_FILE_CONFLICT "$GUARD_FILE"
else
  sudo -n install -d -m 0755 -o root -g root "$GUARD_DIR"
  printf '%s\n' "$EXPECTED_GUARD" |
    sudo -n tee "$GUARD_FILE" >/dev/null
  sudo -n chown root:root "$GUARD_FILE"
  sudo -n chmod 0644 "$GUARD_FILE"
fi
GUARD_APPLIED='true'

sudo -n systemctl daemon-reload \
  > "$EVIDENCE_TMP/daemon-reload.txt" 2>&1 ||
  fail DAEMON_RELOAD_FAILED "$TIMER_UNIT"
sudo -n systemctl stop "$TIMER_UNIT" \
  > "$EVIDENCE_TMP/timer-stop-after-freeze.txt" 2>&1 ||
  fail TIMER_STOP_AFTER_FREEZE_FAILED "$TIMER_UNIT"

# Allow an in-flight reconciliation oneshot to finish, but do not kill it.
SERVICE_STATE="$(systemctl is-active "$SERVICE_UNIT" 2>/dev/null || true)"
if [[ "$SERVICE_STATE" == 'active' || "$SERVICE_STATE" == 'activating' ]]; then
  for _ in $(seq 1 30); do
    sleep 2
    SERVICE_STATE="$(systemctl is-active "$SERVICE_UNIT" 2>/dev/null || true)"
    [[ "$SERVICE_STATE" != 'active' && "$SERVICE_STATE" != 'activating' ]] && break
  done
fi
if [[ "$SERVICE_STATE" == 'active' || "$SERVICE_STATE" == 'activating' ]]; then
  capture_control_state reconcile-still-active
  fail RECONCILE_SERVICE_STILL_ACTIVE "$SERVICE_STATE"
fi

# Prove that the guard rejects an explicit timer start.
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
snapshot_active_jobs "$EVIDENCE_TMP/active-jobs.json" "$EVIDENCE_TMP/active-jobs.tsv"

mkdir -p "$EVIDENCE_TMP/jobs"
: > "$EVIDENCE_TMP/job-runtime.tsv"
printf 'index\tid\tstatus\tprocess_alive\tjob_unit\tjob_unit_state\twake_unit\twake_unit_state\n' \
  >> "$EVIDENCE_TMP/job-runtime.tsv"

while IFS=$'\t' read -r index job_id status project mode coder pid process_alive updated_age heartbeat_age; do
  [[ "$index" == 'index' ]] && continue
  [[ -n "$job_id" ]] || continue

  job_unit="$(systemd-escape --template=zoe-coder-job@.service "$job_id")"
  wake_unit="$(systemd-escape --template=zoe-coder-wake@.service "$job_id")"
  job_state="$(systemctl is-active "$job_unit" 2>/dev/null || true)"
  wake_state="$(systemctl is-active "$wake_unit" 2>/dev/null || true)"
  job_dir="$EVIDENCE_TMP/jobs/$index-$job_id"
  mkdir -p "$job_dir"

  systemctl status "$job_unit" --no-pager -l > "$job_dir/job-unit-status.txt" 2>&1 || true
  systemctl show "$job_unit" \
    -p Id -p Names -p LoadState -p ActiveState -p SubState -p Result \
    -p MainPID -p ControlPID -p ExecMainStartTimestamp -p ExecMainExitTimestamp \
    -p ExecMainStatus -p InvocationID \
    > "$job_dir/job-unit-show.txt" 2>&1 || true
  sudo -n journalctl -u "$job_unit" --since '2026-07-31 13:45:00 UTC' \
    --no-pager -o short-iso-precise > "$job_dir/job-unit-journal.txt" 2>&1 || true

  systemctl status "$wake_unit" --no-pager -l > "$job_dir/wake-unit-status.txt" 2>&1 || true
  systemctl show "$wake_unit" \
    -p Id -p Names -p LoadState -p ActiveState -p SubState -p Result \
    -p MainPID -p ControlPID -p ExecMainStartTimestamp -p ExecMainExitTimestamp \
    -p ExecMainStatus -p InvocationID \
    > "$job_dir/wake-unit-show.txt" 2>&1 || true
  sudo -n journalctl -u "$wake_unit" --since '2026-07-31 13:45:00 UTC' \
    --no-pager -o short-iso-precise > "$job_dir/wake-unit-journal.txt" 2>&1 || true

  if [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 0 )); then
    ps -o pid,ppid,lstart,etime,stat,user,group,cmd -p "$pid" \
      > "$job_dir/process.txt" 2>&1 || true
    sudo -n cat "/proc/$pid/cgroup" > "$job_dir/process-cgroup.txt" 2>&1 || true
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$index" "$job_id" "$status" "$process_alive" \
    "$job_unit" "$job_state" "$wake_unit" "$wake_state" \
    >> "$EVIDENCE_TMP/job-runtime.tsv"
done < "$EVIDENCE_TMP/active-jobs.tsv"

python3 - "$EVIDENCE_TMP/active-jobs.json" "$EVIDENCE_TMP/job-runtime.tsv" \
  > "$EVIDENCE_TMP/classification.txt" <<'PY'
import csv
import json
import sys

jobs_path, runtime_path = sys.argv[1:3]
payload = json.load(open(jobs_path, encoding="utf-8"))
jobs = payload.get("jobs", [])
with open(runtime_path, encoding="utf-8") as fh:
    runtime_rows = {
        row["id"]: row for row in csv.DictReader(fh, delimiter="\t")
    }

print(f"ACTIVE_JOB_COUNT={len(jobs)}")
for index, job in enumerate(jobs, 1):
    runtime = runtime_rows.get(job["id"], {})
    print(f"JOB_{index}_ID={job['id']}")
    print(f"JOB_{index}_STATUS={job.get('status')}")
    print(f"JOB_{index}_PROJECT={job.get('project')}")
    print(f"JOB_{index}_MODE={job.get('mode')}")
    print(f"JOB_{index}_CODER={job.get('selected_coder')}")
    print(f"JOB_{index}_PID={job.get('pid')}")
    print(f"JOB_{index}_PROCESS_ALIVE={str(bool(job.get('process_alive'))).lower()}")
    print(f"JOB_{index}_UNIT_STATE={runtime.get('job_unit_state', '')}")
    print(f"JOB_{index}_WAKE_STATE={runtime.get('wake_unit_state', '')}")
    print(f"JOB_{index}_UPDATED_AGE_SECONDS={job.get('updated_age_seconds')}")
    print(f"JOB_{index}_HEARTBEAT_AGE_SECONDS={job.get('heartbeat_age_seconds')}")

if not jobs:
    classification = "NO_ACTIVE_JOB_RACE_RESOLVED"
    next_action = "RERUN_ETAPA_7B_WITH_RUNTIME_FREEZE"
elif len(jobs) > 1:
    classification = "MULTIPLE_ACTIVE_JOBS"
    next_action = "REVIEW_ALL_ACTIVE_JOBS_BEFORE_ANY_LEDGER_MUTATION"
else:
    job = jobs[0]
    runtime = runtime_rows.get(job["id"], {})
    status = job.get("status")
    process_alive = bool(job.get("process_alive"))
    unit_live = runtime.get("job_unit_state") in {"active", "activating"}
    if status in {"dispatching", "running"} and (process_alive or unit_live):
        classification = "LIVE_EXECUTION"
        next_action = "WAIT_JOB_TERMINAL_THEN_RERUN_ETAPA_7B2"
    elif status in {"dispatching", "running"}:
        classification = "ORPHANED_ACTIVE_LEDGER"
        next_action = "PREPARE_EXACT_CAS_ORPHAN_RECOVERY"
    elif status in {"awaiting_capacity_plan", "queued"}:
        classification = "PENDING_LEDGER_JOB"
        next_action = "CLASSIFY_PENDING_JOB_OWNERSHIP_BEFORE_CANCELLATION"
    else:
        classification = "UNEXPECTED_ACTIVE_STATUS"
        next_action = "STOP_AND_REVIEW_LEDGER"

print(f"CLASSIFICATION={classification}")
print(f"NEXT={next_action}")
PY

capture_control_state after
verify_git_state '_AFTER'

TIMER_AFTER="$(systemctl is-active "$TIMER_UNIT" 2>/dev/null || true)"
REFUSE_AFTER="$(systemctl show "$TIMER_UNIT" -p RefuseManualStart --value 2>/dev/null || true)"
SERVICE_AFTER="$(systemctl is-active "$SERVICE_UNIT" 2>/dev/null || true)"
[[ "$TIMER_AFTER" == 'inactive' ]] || fail TIMER_STILL_ACTIVE "$TIMER_AFTER"
[[ "$REFUSE_AFTER" == 'yes' ]] || fail REFUSE_MANUAL_START_NOT_APPLIED "$REFUSE_AFTER"
[[ "$SERVICE_AFTER" != 'active' && "$SERVICE_AFTER" != 'activating' ]] ||
  fail RECONCILE_SERVICE_ACTIVE_AFTER "$SERVICE_AFTER"

{
  echo 'MANUAL_ETAPA_7B2: PASS'
  echo "TIMER_BEFORE=$TIMER_BEFORE"
  echo "TIMER_AFTER=$TIMER_AFTER"
  echo "REFUSE_MANUAL_START=$REFUSE_AFTER"
  echo "START_TEST_RC=$START_TEST_RC"
  echo "START_TEST_STATE=$START_TEST_STATE"
  echo "RECONCILE_SERVICE=$SERVICE_AFTER"
  cat "$EVIDENCE_TMP/classification.txt"
  echo 'PR19_UNCHANGED=true'
  echo "PR19_HEAD=$PR19_HEAD"
  echo "MAIN=$MAIN_EXPECTED"
  echo "GUARD_FILE=$GUARD_FILE"
  echo "ALLOW_PATH=$ALLOW_PATH"
  echo 'LEDGER_MUTATED=false'
} | tee "$EVIDENCE_TMP/RESULT.txt"

persist_evidence PASS

echo
echo 'MANUAL_ETAPA_7B2_READBACK: PASS'
echo "EVIDENCE=$PERSISTED"
