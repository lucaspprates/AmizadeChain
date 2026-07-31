#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

OPS='/var/backups/zoe-coder-router/manual-8-etapas-20260731T104654Z'
DB='/var/lib/zoe-coder-router/runtime.db'
GH_REPO='lucaspprates/Zoe-Coder-Router'

PR19='19'
MAIN_EXPECTED='ad9cb37f37ceb1353f58a4c2c24de50ce50b9c4a'
PR19_HEAD='7148c751257832c7953c59a17578985b7bf6e52e'

JOB_ID='fc91a851-81b8-4b55-8557-60a2ca9b69bd'
JOB_PROJECT='infraops-ai'
JOB_STATUS='queued'
JOB_MODE='write'
JOB_CODER='codex_terra_high'

STAGE7A_AT='2026-07-31T13:51:23Z'
FIRST_7B_FAILURE_AT='2026-07-31T14:20:39Z'
STAGE7B1_FAILURE_AT='2026-07-31T14:46:36Z'

FAILED_7B="$OPS/ETAPA-7B-FINAL-MERGE-PR19-20260731T142039Z-FAILED"
FAILED_7B0="$OPS/ETAPA-7B0-TIMER-CONTAINMENT-20260731T143759Z-FAILED"
FAILED_7B1="$OPS/ETAPA-7B1-RUNTIME-FREEZE-20260731T144636Z-FAILED"
PASS_7B2="$OPS/ETAPA-7B2-ACTIVE-JOB-DIAGNOSIS-20260731T151134Z-PASS"

TIMER_UNIT='zoe-coder-reconcile.timer'
SERVICE_UNIT='zoe-coder-reconcile.service'
GUARD_FILE="/run/systemd/system/${TIMER_UNIT}.d/99-zcr-manual-merge-freeze.conf"
ALLOW_PATH='/run/zoe-coder-router/ALLOW_RECONCILE_TIMER_STAGE8'

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_TMP="$(mktemp -d /tmp/zcr19-stage7b3.XXXXXX)"
EVIDENCE_FINAL="$OPS/ETAPA-7B3-PENDING-JOB-OWNERSHIP-$STAMP"
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
    echo 'MANUAL_ETAPA_7B3: FAIL'
    echo "FAILURE_CODE=$code"
    echo "DETAIL=$*"
  } | tee -a "$EVIDENCE_TMP/FAILURE.txt" >&2
  persist_evidence FAILED || true
  echo "EVIDENCE=${PERSISTED:-$EVIDENCE_TMP}" >&2
  exit 1
}

[[ "$(id -un)" == 'ubuntu' ]] || fail USER_MISMATCH 'execute como ubuntu'
[[ "$(hostname -s)" == 'zoe-infranetwork-com-br' ]] || fail HOST_MISMATCH "$(hostname -s)"
sudo -n true >/dev/null 2>&1 || fail SUDO_UNAVAILABLE 'sudo NOPASSWD obrigatório'
command -v gh >/dev/null 2>&1 || fail GH_MISSING 'gh CLI não encontrado'
command -v python3 >/dev/null 2>&1 || fail PYTHON_MISSING 'python3 não encontrado'
command -v systemd-escape >/dev/null 2>&1 || fail SYSTEMD_ESCAPE_MISSING 'systemd-escape não encontrado'
sudo -n test -r "$DB" || fail DB_UNREADABLE "$DB"
for path in "$FAILED_7B" "$FAILED_7B0" "$FAILED_7B1" "$PASS_7B2"; do
  sudo -n test -d "$path" || fail PRIOR_EVIDENCE_MISSING "$path"
done

gh auth status > "$EVIDENCE_TMP/gh-auth-status.txt" 2>&1 ||
  fail GH_AUTH_FAILED 'gh auth status falhou'

TIMER_STATE="$(systemctl is-active "$TIMER_UNIT" 2>/dev/null || true)"
[[ "$TIMER_STATE" == 'inactive' ]] || fail TIMER_NOT_INACTIVE "$TIMER_STATE"
REFUSE_START="$(systemctl show "$TIMER_UNIT" -p RefuseManualStart --value 2>/dev/null || true)"
[[ "$REFUSE_START" == 'yes' ]] || fail TIMER_GUARD_NOT_ACTIVE "$REFUSE_START"
sudo -n test -f "$GUARD_FILE" || fail GUARD_FILE_MISSING "$GUARD_FILE"
sudo -n test ! -e "$ALLOW_PATH" || fail ALLOW_PATH_PRESENT "$ALLOW_PATH"
SERVICE_STATE="$(systemctl is-active "$SERVICE_UNIT" 2>/dev/null || true)"
[[ "$SERVICE_STATE" != 'active' && "$SERVICE_STATE" != 'activating' ]] ||
  fail RECONCILE_SERVICE_ACTIVE "$SERVICE_STATE"

gh pr view "$PR19" --repo "$GH_REPO" \
  --json state,isDraft,mergeable,headRefOid,baseRefName \
  > "$EVIDENCE_TMP/pr19.json"

python3 - "$EVIDENCE_TMP/pr19.json" "$PR19_HEAD" <<'PY'
import json
import sys
obj = json.load(open(sys.argv[1], encoding="utf-8"))
assert obj.get("state") == "OPEN", obj
assert obj.get("isDraft") is True, obj
assert obj.get("mergeable") == "MERGEABLE", obj
assert obj.get("headRefOid") == sys.argv[2], obj
assert obj.get("baseRefName") == "main", obj
PY

MAIN_REMOTE="$(gh api "repos/$GH_REPO/commits/main" --jq '.sha')"
[[ "$MAIN_REMOTE" == "$MAIN_EXPECTED" ]] || fail MAIN_CHANGED "$MAIN_REMOTE"

JOB_UNIT="$(systemd-escape --template=zoe-coder-job@.service "$JOB_ID")"
WAKE_UNIT="$(systemd-escape --template=zoe-coder-wake@.service "$JOB_ID")"
JOB_UNIT_STATE="$(systemctl is-active "$JOB_UNIT" 2>/dev/null || true)"
WAKE_UNIT_STATE="$(systemctl is-active "$WAKE_UNIT" 2>/dev/null || true)"
systemctl status "$JOB_UNIT" --no-pager -l > "$EVIDENCE_TMP/job-unit-status.txt" 2>&1 || true
systemctl status "$WAKE_UNIT" --no-pager -l > "$EVIDENCE_TMP/wake-unit-status.txt" 2>&1 || true
sudo -n journalctl -u "$JOB_UNIT" -u "$WAKE_UNIT" \
  --since '2026-07-31 13:45:00 UTC' --no-pager -o short-iso-precise \
  > "$EVIDENCE_TMP/job-units-journal.txt" 2>&1 || true

sudo -n -u ubuntu -g zoe-coders -H -- \
python3 - "$DB" "$EVIDENCE_TMP/job.json" "$EVIDENCE_TMP/classification.txt" \
  "$JOB_ID" "$JOB_PROJECT" "$JOB_STATUS" "$JOB_MODE" "$JOB_CODER" \
  "$STAGE7A_AT" "$FIRST_7B_FAILURE_AT" "$STAGE7B1_FAILURE_AT" \
  "$JOB_UNIT_STATE" "$WAKE_UNIT_STATE" <<'PY'
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys

(
    db_path, json_path, classification_path,
    expected_id, expected_project, expected_status, expected_mode, expected_coder,
    stage7a_at, first_7b_failure_at, stage7b1_failure_at,
    job_unit_state, wake_unit_state,
) = sys.argv[1:]

def parse_time(value):
    if not value:
        return None
    value = str(value).replace("Z", "+00:00")
    parsed = dt.datetime.fromisoformat(value)
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.timezone.utc)

def process_alive(pid, expected_ticks):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        raw = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8").strip()
        current_ticks = raw.rsplit(")", 1)[1].split()[19]
        if expected_ticks not in (None, "") and str(expected_ticks) != current_ticks:
            return False
        os.kill(pid, 0)
        return True
    except (OSError, IndexError, ValueError):
        return False

def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def git_output(repo, *args):
    try:
        return subprocess.check_output(
            ["git", "-C", repo, *args],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=10,
        ).strip()
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None

conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
conn.row_factory = sqlite3.Row
row = conn.execute("SELECT * FROM jobs WHERE id=?", (expected_id,)).fetchone()
if row is None:
    raise SystemExit("EXPECTED_JOB_MISSING")
job = dict(row)

active_rows = conn.execute(
    """
    SELECT id,status,project,mode,selected_coder,pid,pid_start_ticks
      FROM jobs
     WHERE status IN ('awaiting_capacity_plan','queued','dispatching','running')
     ORDER BY priority DESC,created_at ASC
    """
).fetchall()
if len(active_rows) != 1 or active_rows[0]["id"] != expected_id:
    raise SystemExit(
        "ACTIVE_SET_CHANGED:" + json.dumps([dict(r) for r in active_rows], ensure_ascii=False)
    )

assert job.get("project") == expected_project, job
assert job.get("status") == expected_status, job
assert job.get("mode") == expected_mode, job
assert job.get("selected_coder") == expected_coder, job

events = [
    dict(event)
    for event in conn.execute(
        """
        SELECT id,event_type,actor,payload,created_at
          FROM events
         WHERE job_id=?
         ORDER BY id ASC
        """,
        (expected_id,),
    ).fetchall()
]
conn.close()

pid_alive = process_alive(job.get("pid"), job.get("pid_start_ticks"))
prompt_path = job.get("prompt_path")
prompt_exists = bool(prompt_path and Path(prompt_path).is_file())
prompt_hash = sha256_file(prompt_path) if prompt_exists else None
prompt_hash_matches = bool(
    prompt_hash
    and job.get("prompt_sha256")
    and prompt_hash == job.get("prompt_sha256")
)

workspace = job.get("worktree") or job.get("repo_path")
workspace_exists = bool(workspace and Path(workspace).is_dir())
git_branch = git_output(workspace, "branch", "--show-current") if workspace_exists else None
git_head = git_output(workspace, "rev-parse", "HEAD") if workspace_exists else None
git_status = git_output(workspace, "status", "--porcelain=v1", "--untracked-files=all") if workspace_exists else None
git_clean = git_status == "" if git_status is not None else None
git_remote = git_output(workspace, "remote", "get-url", "origin") if workspace_exists else None

created_at = parse_time(job.get("created_at"))
stage7a = parse_time(stage7a_at)
first_fail = parse_time(first_7b_failure_at)
stage7b1_fail = parse_time(stage7b1_failure_at)
created_after_7a = bool(created_at and created_at >= stage7a)
created_during_timer_window = bool(
    created_at and first_fail <= created_at <= stage7b1_fail
)

event_text = json.dumps(events, ensure_ascii=False).lower()
origin_reconcile_signal = any(
    token in event_text
    for token in (
        "reconcile", "scheduler", "capacity_plan", "capacity-plan",
        "factory_scheduler", "factory-scheduler", "dispatcher",
    )
)
operator_signal = any(
    str(event.get("actor", "")).lower() in {"operator", "human", "lucaspprates", "ubuntu"}
    for event in events
)

ownership_fields = {
    "mission_id": job.get("mission_id"),
    "kanban_task_id": job.get("kanban_task_id"),
    "issue": job.get("issue"),
    "branch": job.get("branch"),
    "idempotency_key": job.get("idempotency_key"),
}
ownership_signal_count = sum(bool(value) for value in ownership_fields.values())

undispatched = (
    job.get("status") == "queued"
    and not pid_alive
    and job_unit_state not in {"active", "activating"}
    and wake_unit_state not in {"active", "activating"}
    and not job.get("started_at")
    and not job.get("heartbeat_at")
    and not job.get("process_heartbeat_at")
)
safe_runtime = undispatched and prompt_hash_matches

if not undispatched:
    classification = "PENDING_JOB_RUNTIME_CHANGED"
    next_action = "STOP_AND_REDIAGNOSE_JOB_RUNTIME"
elif created_during_timer_window and origin_reconcile_signal and not operator_signal and safe_runtime:
    classification = "STRAY_TIMER_WINDOW_ADMISSION"
    next_action = "PREPARE_EXACT_QUEUED_JOB_CAS_CANCELLATION"
elif ownership_signal_count >= 2:
    classification = "OWNED_PENDING_JOB"
    next_action = "PRESERVE_JOB_AND_DECIDE_MERGE_WINDOW_WITH_OWNER"
elif created_during_timer_window and safe_runtime:
    classification = "UNATTRIBUTED_TIMER_WINDOW_ADMISSION"
    next_action = "REVIEW_FIRST_EVENT_BEFORE_EXACT_CANCELLATION"
else:
    classification = "PENDING_JOB_OWNERSHIP_UNRESOLVED"
    next_action = "STOP_AND_REVIEW_JOB_EVIDENCE"

first_event = events[0] if events else {}
payload = {
    "captured_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    "job": job,
    "events": events,
    "runtime": {
        "pid_alive": pid_alive,
        "job_unit_state": job_unit_state,
        "wake_unit_state": wake_unit_state,
        "undispatched": undispatched,
    },
    "prompt": {
        "exists": prompt_exists,
        "sha256_actual": prompt_hash,
        "sha256_matches_ledger": prompt_hash_matches,
    },
    "workspace": {
        "path": workspace,
        "exists": workspace_exists,
        "git_branch": git_branch,
        "git_head": git_head,
        "git_clean": git_clean,
        "git_remote": git_remote,
    },
    "ownership": {
        **ownership_fields,
        "signal_count": ownership_signal_count,
        "created_after_stage7a": created_after_7a,
        "created_during_unexpected_timer_window": created_during_timer_window,
        "origin_reconcile_signal": origin_reconcile_signal,
        "operator_signal": operator_signal,
        "first_event_type": first_event.get("event_type"),
        "first_event_actor": first_event.get("actor"),
        "first_event_created_at": first_event.get("created_at"),
    },
    "classification": classification,
    "next": next_action,
}
with open(json_path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, ensure_ascii=False, sort_keys=True)
    fh.write("\n")

def emit(key, value):
    if value is None:
        value = ""
    text = str(value).replace("\n", " ").replace("\r", " ")[:1000]
    print(f"{key}={text}")

with open(classification_path, "w", encoding="utf-8") as fh:
    old_stdout = sys.stdout
    sys.stdout = fh
    emit("JOB_ID", job.get("id"))
    emit("JOB_STATUS", job.get("status"))
    emit("JOB_PROJECT", job.get("project"))
    emit("JOB_MODE", job.get("mode"))
    emit("JOB_CODER", job.get("selected_coder"))
    emit("MISSION_ID", job.get("mission_id"))
    emit("KANBAN_TASK_ID", job.get("kanban_task_id"))
    emit("ISSUE", job.get("issue"))
    emit("BRANCH", job.get("branch"))
    emit("CREATED_AT", job.get("created_at"))
    emit("STARTED_AT", job.get("started_at"))
    emit("PID", job.get("pid"))
    emit("PROCESS_ALIVE", str(pid_alive).lower())
    emit("JOB_UNIT_STATE", job_unit_state)
    emit("WAKE_UNIT_STATE", wake_unit_state)
    emit("PROMPT_EXISTS", str(prompt_exists).lower())
    emit("PROMPT_SHA_MATCHES", str(prompt_hash_matches).lower())
    emit("WORKSPACE_EXISTS", str(workspace_exists).lower())
    emit("WORKSPACE_GIT_BRANCH", git_branch)
    emit("WORKSPACE_GIT_HEAD", git_head)
    emit("WORKSPACE_GIT_CLEAN", "" if git_clean is None else str(git_clean).lower())
    emit("FIRST_EVENT_TYPE", first_event.get("event_type"))
    emit("FIRST_EVENT_ACTOR", first_event.get("actor"))
    emit("FIRST_EVENT_CREATED_AT", first_event.get("created_at"))
    emit("OWNERSHIP_SIGNAL_COUNT", ownership_signal_count)
    emit("CREATED_AFTER_STAGE7A", str(created_after_7a).lower())
    emit("CREATED_DURING_TIMER_WINDOW", str(created_during_timer_window).lower())
    emit("ORIGIN_RECONCILE_SIGNAL", str(origin_reconcile_signal).lower())
    emit("OPERATOR_SIGNAL", str(operator_signal).lower())
    emit("RUNTIME_UNDISPATCHED", str(undispatched).lower())
    emit("CLASSIFICATION", classification)
    emit("NEXT", next_action)
    sys.stdout = old_stdout
PY

cat "$EVIDENCE_TMP/classification.txt"

FINAL_TIMER="$(systemctl is-active "$TIMER_UNIT" 2>/dev/null || true)"
FINAL_SERVICE="$(systemctl is-active "$SERVICE_UNIT" 2>/dev/null || true)"
FINAL_REFUSE="$(systemctl show "$TIMER_UNIT" -p RefuseManualStart --value 2>/dev/null || true)"
[[ "$FINAL_TIMER" == 'inactive' ]] || fail TIMER_CHANGED_AFTER_DIAGNOSIS "$FINAL_TIMER"
[[ "$FINAL_SERVICE" != 'active' && "$FINAL_SERVICE" != 'activating' ]] ||
  fail SERVICE_CHANGED_AFTER_DIAGNOSIS "$FINAL_SERVICE"
[[ "$FINAL_REFUSE" == 'yes' ]] || fail TIMER_GUARD_LOST "$FINAL_REFUSE"

{
  echo 'MANUAL_ETAPA_7B3: PASS'
  echo "TIMER=$FINAL_TIMER"
  echo "REFUSE_MANUAL_START=$FINAL_REFUSE"
  echo "RECONCILE_SERVICE=$FINAL_SERVICE"
  echo 'PR19_UNCHANGED=true'
  echo "PR19_HEAD=$PR19_HEAD"
  echo "MAIN=$MAIN_REMOTE"
  echo 'LEDGER_MUTATED=false'
} | tee "$EVIDENCE_TMP/RESULT.txt"

persist_evidence PASS

echo
echo 'MANUAL_ETAPA_7B3_READBACK: PASS'
echo "EVIDENCE=$PERSISTED"
