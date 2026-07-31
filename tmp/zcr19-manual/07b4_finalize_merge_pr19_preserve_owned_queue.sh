#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

SOURCE_URL='https://raw.githubusercontent.com/lucaspprates/AmizadeChain/7355455e1a0c6764a65bc3857c532cfd4e5295bd/tmp/zcr19-manual/07b_finalize_merge_pr19.sh'
SOURCE_SHA256='38faef97054fb2545175c283ffb7cec1cd6f6ad8361a38b78dd245e14b1a3ffe'
SOURCE_BLOB='bebf28181844c74bddf5c1489e2d03384633cab1'
SOURCE='/tmp/07b_finalize_merge_pr19.original.sh'
PATCHED='/tmp/07b_finalize_merge_pr19.preserve-owned-queue.sh'

curl -fsSL "$SOURCE_URL" -o "$SOURCE"
printf '%s  %s\n' "$SOURCE_SHA256" "$SOURCE" | sha256sum -c -
test "$(git hash-object "$SOURCE")" = "$SOURCE_BLOB"
bash -n "$SOURCE"

python3 - "$SOURCE" "$PATCHED" <<'PY_PATCHER'
from pathlib import Path
import re
import sys

source_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
text = source_path.read_text(encoding="utf-8")

def replace_exact(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"PATCH_SOURCE_MISMATCH:{label}:occurrences={count}")
    text = text.replace(old, new, 1)

constants_old = '''FINAL_GATE_JOB='3276baad-1855-4f3d-9eb8-0f8ce0d3b81f'
'''
constants_new = '''FINAL_GATE_JOB='3276baad-1855-4f3d-9eb8-0f8ce0d3b81f'

PRESERVED_JOB_ID='fc91a851-81b8-4b55-8557-60a2ca9b69bd'
PRESERVED_JOB_MISSION='INFRAOPSAI220_DDD_FOUNDATIONS_2F290E4'
PRESERVED_JOB_PROJECT='infraops-ai'
PRESERVED_JOB_ISSUE='220'
PRESERVED_JOB_BRANCH='type/220-ddd-foundations'
PRESERVED_JOB_MODE='write'
PRESERVED_JOB_CODER='codex_terra_high'
PRESERVED_JOB_WORKTREE_HEAD='2f290e437130274b59d7282877c18610592b924d'
STAGE7B2_EVIDENCE="$OPS/ETAPA-7B2-ACTIVE-JOB-DIAGNOSIS-20260731T151134Z-PASS"
STAGE7B3_EVIDENCE="$OPS/ETAPA-7B3-PENDING-JOB-OWNERSHIP-20260731T152441Z-PASS"
TIMER_GUARD_FILE='/run/systemd/system/zoe-coder-reconcile.timer.d/99-zcr-manual-merge-freeze.conf'
TIMER_ALLOW_PATH='/run/zoe-coder-router/ALLOW_RECONCILE_TIMER_STAGE8'
'''
replace_exact(constants_old, constants_new, "constants")

pattern = re.compile(
    r"active_jobs\(\) \{\n.*?\n\}\n\nverify_pr_json\(\)",
    re.DOTALL,
)
replacement = r"""blocking_active_jobs() {
  sudo -n -u ubuntu -g zoe-coders -H -- \
  python3 - "$DB" "$PRESERVED_JOB_ID" <<'PY'
import sqlite3
import sys

db_path, preserved_id = sys.argv[1:3]
conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
count = conn.execute(
    '''
    SELECT COUNT(*)
      FROM jobs
     WHERE status IN (
       'awaiting_capacity_plan',
       'queued',
       'dispatching',
       'running'
     )
       AND id <> ?
    ''',
    (preserved_id,),
).fetchone()[0]
conn.close()
print(count)
PY
}

verify_preserved_job() {
  local json_path="$1"
  local phase="$2"

  sudo -n -u ubuntu -g zoe-coders -H -- \
  python3 - \
    "$DB" \
    "$json_path" \
    "$phase" \
    "$PRESERVED_JOB_ID" \
    "$PRESERVED_JOB_MISSION" \
    "$PRESERVED_JOB_PROJECT" \
    "$PRESERVED_JOB_ISSUE" \
    "$PRESERVED_JOB_BRANCH" \
    "$PRESERVED_JOB_MODE" \
    "$PRESERVED_JOB_CODER" \
    "$PRESERVED_JOB_WORKTREE_HEAD" <<'PY'
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys

(
    db_path,
    json_path,
    phase,
    expected_id,
    expected_mission,
    expected_project,
    expected_issue,
    expected_branch,
    expected_mode,
    expected_coder,
    expected_worktree_head,
) = sys.argv[1:]

conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
conn.row_factory = sqlite3.Row
active = [
    dict(row)
    for row in conn.execute(
        '''
        SELECT *
          FROM jobs
         WHERE status IN (
           'awaiting_capacity_plan',
           'queued',
           'dispatching',
           'running'
         )
         ORDER BY priority DESC, created_at ASC
        '''
    ).fetchall()
]
assert len(active) == 1, active
job = active[0]
assert job.get("id") == expected_id, job
assert job.get("status") == "queued", job
assert job.get("mission_id") == expected_mission, job
assert job.get("project") == expected_project, job
assert str(job.get("issue") or "") == expected_issue, job
assert job.get("branch") == expected_branch, job
assert job.get("mode") == expected_mode, job
assert job.get("selected_coder") == expected_coder, job
assert job.get("pid") in (None, 0), job
assert not job.get("started_at"), job
assert not job.get("heartbeat_at"), job
assert not job.get("process_heartbeat_at"), job

events = [
    dict(row)
    for row in conn.execute(
        '''
        SELECT id,event_type,actor,payload,created_at
          FROM events
         WHERE job_id=?
         ORDER BY id ASC
        ''',
        (expected_id,),
    ).fetchall()
]
conn.close()
assert events, job
assert events[0].get("event_type") == "JOB_QUEUED", events[0]
assert events[0].get("actor") == "zoe-coder", events[0]

prompt_path = Path(str(job.get("prompt_path") or ""))
assert prompt_path.is_file(), prompt_path
digest = hashlib.sha256(prompt_path.read_bytes()).hexdigest()
assert digest == job.get("prompt_sha256"), (digest, job.get("prompt_sha256"))

workspace = Path(str(job.get("worktree") or job.get("repo_path") or ""))
assert workspace.is_dir(), workspace

def git(*args):
    return subprocess.check_output(
        ["git", "-C", str(workspace), *args],
        text=True,
        stderr=subprocess.DEVNULL,
        timeout=15,
    ).strip()

branch = git("branch", "--show-current")
head = git("rev-parse", "HEAD")
status = git("status", "--porcelain=v1", "--untracked-files=all")
assert branch == expected_branch, branch
assert head == expected_worktree_head, head
assert status == "", status

payload = {
    "phase": phase,
    "preserved": True,
    "job_id": expected_id,
    "mission_id": expected_mission,
    "project": expected_project,
    "issue": expected_issue,
    "branch": expected_branch,
    "status": "queued",
    "mode": expected_mode,
    "selected_coder": expected_coder,
    "pid": job.get("pid"),
    "started_at": job.get("started_at"),
    "heartbeat_at": job.get("heartbeat_at"),
    "prompt_sha256": digest,
    "worktree": str(workspace),
    "worktree_head": head,
    "worktree_clean": True,
    "first_event": events[0],
    "active_job_count": len(active),
}
Path(json_path).write_text(
    json.dumps(payload, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

verify_pr_json()"""
text, count = pattern.subn(lambda _match: replacement, text, count=1)
if count != 1:
    raise SystemExit(f"PATCH_SOURCE_MISMATCH:active_jobs_function:occurrences={count}")

evidence_old = '''sudo -n test -d "$STAGE7A_EVIDENCE" || fail STAGE7A_EVIDENCE_MISSING "$STAGE7A_EVIDENCE"
'''
evidence_new = '''sudo -n test -d "$STAGE7A_EVIDENCE" || fail STAGE7A_EVIDENCE_MISSING "$STAGE7A_EVIDENCE"
sudo -n test -d "$STAGE7B2_EVIDENCE" || fail STAGE7B2_EVIDENCE_MISSING "$STAGE7B2_EVIDENCE"
sudo -n test -d "$STAGE7B3_EVIDENCE" || fail STAGE7B3_EVIDENCE_MISSING "$STAGE7B3_EVIDENCE"
sudo -n test -f "$TIMER_GUARD_FILE" || fail TIMER_GUARD_MISSING "$TIMER_GUARD_FILE"
sudo -n test ! -e "$TIMER_ALLOW_PATH" || fail TIMER_ALLOW_PATH_PRESENT "$TIMER_ALLOW_PATH"
REFUSE_START="$(systemctl show zoe-coder-reconcile.timer -p RefuseManualStart --value 2>/dev/null || true)"
[[ "$REFUSE_START" == 'yes' ]] || fail TIMER_GUARD_NOT_ENFORCED "$REFUSE_START"
'''
replace_exact(evidence_old, evidence_new, "evidence_and_guard")

pre_jobs_old = '''ACTIVE_JOBS="$(active_jobs)"
[[ "$ACTIVE_JOBS" == '0' ]] || fail ACTIVE_JOBS_PRESENT "$ACTIVE_JOBS"
'''
pre_jobs_new = '''BLOCKING_ACTIVE_JOBS="$(blocking_active_jobs)"
[[ "$BLOCKING_ACTIVE_JOBS" == '0' ]] ||
  fail BLOCKING_ACTIVE_JOBS_PRESENT "$BLOCKING_ACTIVE_JOBS"
if ! verify_preserved_job "$EVIDENCE_TMP/preserved-job-before.json" before_merge; then
  fail PRESERVED_JOB_PRECONDITION_FAILED "$PRESERVED_JOB_ID"
fi
'''
replace_exact(pre_jobs_old, pre_jobs_new, "pre_merge_active_jobs")

replace_exact(
    'The reconciler timer remained inactive and the Router ledger had zero active jobs throughout integration.',
    'The reconciler timer remained runtime-frozen; the owned InfraOps AI issue #220 job remained queued, undispatched and unchanged throughout integration, with zero blocking jobs.',
    "pr_body_safety",
)

replace_exact(
    '## Safety\n',
    '''## Preserved queued mission

- job: `$PRESERVED_JOB_ID`;
- mission: `$PRESERVED_JOB_MISSION`;
- project/issue: `infraops-ai#220`;
- branch/head: `$PRESERVED_JOB_BRANCH` at `$PRESERVED_JOB_WORKTREE_HEAD`;
- state during merge: queued, undispatched, clean worktree and prompt digest preserved.

## Safety
''',
    "pr_body_preserved_section",
)

pre_output_old = '''  echo "active_jobs=$ACTIVE_JOBS"
  echo "active_units=$ACTIVE_UNITS"
'''
pre_output_new = '''  echo "blocking_active_jobs=$BLOCKING_ACTIVE_JOBS"
  echo 'preserved_queued_jobs=1'
  echo "preserved_job_id=$PRESERVED_JOB_ID"
  echo "preserved_job_mission=$PRESERVED_JOB_MISSION"
  echo "preserved_job_issue=$PRESERVED_JOB_ISSUE"
  echo "preserved_job_branch=$PRESERVED_JOB_BRANCH"
  echo "stage7b2_evidence=$STAGE7B2_EVIDENCE"
  echo "stage7b3_evidence=$STAGE7B3_EVIDENCE"
  echo "active_units=$ACTIVE_UNITS"
'''
replace_exact(pre_output_old, pre_output_new, "pre_merge_output")

replace_exact(
    'FINAL_JOBS="$(active_jobs)"\n',
    '''FINAL_BLOCKING_JOBS="$(blocking_active_jobs)"
if ! verify_preserved_job "$EVIDENCE_TMP/preserved-job-after.json" after_merge; then
  fail PRESERVED_JOB_CHANGED_AFTER_MERGE "$PRESERVED_JOB_ID"
fi
''',
    "post_merge_active_jobs_assignment",
)

replace_exact(
    '[[ "$FINAL_JOBS" == \'0\' ]] || fail ACTIVE_JOBS_AFTER_MERGE "$FINAL_JOBS"\n',
    '''[[ "$FINAL_BLOCKING_JOBS" == '0' ]] ||
  fail BLOCKING_ACTIVE_JOBS_AFTER_MERGE "$FINAL_BLOCKING_JOBS"
''',
    "post_merge_active_jobs_assertion",
)

replace_exact(
    '  echo "ACTIVE_JOBS=$FINAL_JOBS"\n',
    '''  echo "BLOCKING_ACTIVE_JOBS=$FINAL_BLOCKING_JOBS"
  echo 'PRESERVED_QUEUED_JOBS=1'
  echo 'OWNED_JOB_PRESERVED=true'
  echo "PRESERVED_JOB_ID=$PRESERVED_JOB_ID"
  echo "PRESERVED_JOB_MISSION=$PRESERVED_JOB_MISSION"
  echo "PRESERVED_JOB_PROJECT=$PRESERVED_JOB_PROJECT"
  echo "PRESERVED_JOB_ISSUE=$PRESERVED_JOB_ISSUE"
  echo "PRESERVED_JOB_BRANCH=$PRESERVED_JOB_BRANCH"
  echo "PRESERVED_JOB_STATUS=queued"
''',
    "final_output_active_jobs",
)

target_path.write_text(text, encoding="utf-8")
target_path.chmod(0o700)
PY_PATCHER

bash -n "$PATCHED"
echo "PATCHED_SHA256=$(sha256sum "$PATCHED" | awk '{print $1}')"
echo "PATCHED_BLOB=$(git hash-object "$PATCHED")"
echo 'PRESERVED_OWNED_QUEUE_PATCH=PASS'
exec "$PATCHED"
