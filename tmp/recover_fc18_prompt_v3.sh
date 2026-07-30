#!/usr/bin/env bash
set -Eeuo pipefail

JOB='cfba0aa7-4a93-417a-ab5c-735d02e70992'
REPO='lucaspprates/infranetwork-factory-console'
ISSUE='18'
PR='19'
CONFIG='/etc/zoe-coder-router/config.toml'
ROUTER='/usr/local/bin/zoe-coder'
TIMER='zoe-coder-reconcile.timer'
JOB_UNIT="zoe-coder-job@${JOB}.service"
WAKE_UNIT="zoe-coder-wake@${JOB}.service"
PROMPT_DIR='/var/lib/zoe-coder-router/prompts'
PROMPT_PATH="${PROMPT_DIR}/fc18-router-proof-authority-v1-recovery.md"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMPROOT="$(mktemp -d /tmp/fc18-prompt-v3.XXXXXX)"
ISSUE_JSON="${TMPROOT}/issue.json"
PR_JSON="${TMPROOT}/pr.json"
PROMPT_TMP="${TMPROOT}/prompt.md"
TIMER_WAS_ACTIVE=0

cleanup() {
  local rc=$?
  if (( TIMER_WAS_ACTIVE == 1 )); then
    systemctl start "$TIMER" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMPROOT"
  return "$rc"
}
trap cleanup EXIT

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || die 'run with sudo bash'
[[ -x "$ROUTER" ]] || die "router not executable: $ROUTER"
for cmd in gh jq python3 git sha256sum systemctl; do
  command -v "$cmd" >/dev/null || die "missing command: $cmd"
done

echo '======================================================'
echo ' FACTORY CONSOLE #18 - DURABLE PROMPT RECOVERY V3'
echo '======================================================'

echo '[1/10] Pausing reconciler and neutralizing old units...'
if systemctl is-active --quiet "$TIMER"; then
  TIMER_WAS_ACTIVE=1
fi
systemctl stop "$TIMER" 2>/dev/null || true
systemctl stop "$JOB_UNIT" 2>/dev/null || true
systemctl stop "$WAKE_UNIT" 2>/dev/null || true
systemctl reset-failed "$JOB_UNIT" "$WAKE_UNIT" 2>/dev/null || true

echo '[2/10] Reading authoritative job state...'
JOB_JSON="$($ROUTER show "$JOB")"
echo "$JOB_JSON" | jq '{job:{id:.job.id,status:.job.status,error:.job.error,project:.job.project,issue:.job.issue,selected_coder:.job.selected_coder,prompt_path:.job.prompt_path,prompt_sha256:.job.prompt_sha256,worktree:.job.worktree,branch:.job.branch,pid:.job.pid,started_at:.job.started_at}}'

PROJECT="$(jq -r '.job.project' <<<"$JOB_JSON")"
JOB_ISSUE="$(jq -r '.job.issue' <<<"$JOB_JSON")"
CODER="$(jq -r '.job.selected_coder' <<<"$JOB_JSON")"
STATUS="$(jq -r '.job.status' <<<"$JOB_JSON")"
OLD_PROMPT="$(jq -r '.job.prompt_path' <<<"$JOB_JSON")"
OLD_SHA="$(jq -r '.job.prompt_sha256' <<<"$JOB_JSON")"
WORKTREE="$(jq -r '.job.worktree' <<<"$JOB_JSON")"
BRANCH="$(jq -r '.job.branch' <<<"$JOB_JSON")"
PID="$(jq -r '.job.pid // empty' <<<"$JOB_JSON")"
STARTED="$(jq -r '.job.started_at // empty' <<<"$JOB_JSON")"

[[ "$PROJECT" == 'factory-console' ]] || die "unexpected project: $PROJECT"
[[ "$JOB_ISSUE" == "$ISSUE" ]] || die "unexpected issue: $JOB_ISSUE"
[[ "$CODER" == 'opencode_glm52' ]] || die "unexpected coder: $CODER"
case "$STATUS" in
  dispatching|failed|blocked|queued) ;;
  *) die "status is not automatically recoverable: $STATUS" ;;
esac
[[ -z "$PID" ]] || die "job has pid: $PID"
[[ -z "$STARTED" ]] || die "job actually started at $STARTED"
[[ -d "$WORKTREE/.git" || -f "$WORKTREE/.git" ]] || die "invalid worktree: $WORKTREE"

DB_PATH="$(python3 - "$CONFIG" <<'PY'
import sys, tomllib
from pathlib import Path
with open(sys.argv[1], 'rb') as f:
    cfg = tomllib.load(f)
rt = cfg['runtime']
print(rt.get('db_path', str(Path(rt.get('state_dir', '/var/lib/zoe-coder-router')) / 'runtime.db')))
PY
)"
[[ -f "$DB_PATH" ]] || die "database not found: $DB_PATH"
DB_BACKUP="${DB_PATH}.${STAMP}-pre-fc18-prompt-v3"
python3 - "$DB_PATH" "$DB_BACKUP" <<'PY'
import sqlite3, sys
src = sqlite3.connect(sys.argv[1])
dst = sqlite3.connect(sys.argv[2])
with dst:
    src.backup(dst)
src.close()
dst.close()
PY
echo "DB backup: $DB_BACKUP"
echo "DB SHA:    $(sha256sum "$DB_BACKUP" | awk '{print $1}')"

echo '[3/10] Reading canonical GitHub sources...'
sudo -u ubuntu -H gh issue view "$ISSUE" --repo "$REPO" \
  --json number,title,body,state,url,updatedAt > "$ISSUE_JSON"
sudo -u ubuntu -H gh pr view "$PR" --repo "$REPO" \
  --json number,title,state,isDraft,url,headRefName,headRefOid,baseRefName,mergeStateStatus > "$PR_JSON"
PR_BASE_SHA="$(sudo -u ubuntu -H gh api "repos/$REPO/pulls/$PR" --jq '.base.sha')"

ISSUE_STATE="$(jq -r '.state' "$ISSUE_JSON")"
PR_STATE="$(jq -r '.state' "$PR_JSON")"
PR_DRAFT="$(jq -r '.isDraft' "$PR_JSON")"
PR_HEAD_BRANCH="$(jq -r '.headRefName' "$PR_JSON")"
PR_HEAD_SHA="$(jq -r '.headRefOid' "$PR_JSON")"
PR_BASE_BRANCH="$(jq -r '.baseRefName' "$PR_JSON")"

[[ "$ISSUE_STATE" == 'OPEN' ]] || die "issue is not OPEN: $ISSUE_STATE"
[[ "$PR_STATE" == 'OPEN' ]] || die "PR is not OPEN: $PR_STATE"
[[ "$PR_DRAFT" == 'true' ]] || die 'PR is not Draft'
[[ "$PR_HEAD_BRANCH" == "$BRANCH" ]] || die "branch mismatch: job=$BRANCH pr=$PR_HEAD_BRANCH"
[[ "$PR_HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || die "invalid head SHA: $PR_HEAD_SHA"
[[ "$PR_BASE_SHA" =~ ^[0-9a-f]{40}$ ]] || die "invalid base SHA: $PR_BASE_SHA"

echo '[4/10] Validating exact clean worktree...'
WT_BRANCH="$(git -C "$WORKTREE" branch --show-current)"
WT_HEAD="$(git -C "$WORKTREE" rev-parse HEAD)"
DIRTY="$(git -C "$WORKTREE" status --porcelain=v1 --untracked-files=all)"
[[ "$WT_BRANCH" == "$BRANCH" ]] || die "worktree branch mismatch: $WT_BRANCH"
[[ "$WT_HEAD" == "$PR_HEAD_SHA" ]] || die "worktree head mismatch: wt=$WT_HEAD pr=$PR_HEAD_SHA"
[[ -z "$DIRTY" ]] || { echo "$DIRTY" >&2; die 'worktree is dirty'; }
echo "Branch: $WT_BRANCH"
echo "HEAD:   $WT_HEAD"

echo '[5/10] Validating exclusive GLM route...'
ROUTE_JSON="$($ROUTER route --project factory-console --task-type implementation --mode write --available)"
echo "$ROUTE_JSON" | jq .
[[ "$(jq -c '.route' <<<"$ROUTE_JSON")" == '["opencode_glm52"]' ]] || die 'unexpected route'

echo '[6/10] Building durable prompt...'
python3 - "$ISSUE_JSON" "$PR_JSON" "$PR_BASE_SHA" "$WORKTREE" "$OLD_PROMPT" "$PROMPT_TMP" <<'PY'
import json, sys
issue_path, pr_path, base_sha, worktree, old_prompt, output = sys.argv[1:]
with open(issue_path, encoding='utf-8') as f:
    issue = json.load(f)
with open(pr_path, encoding='utf-8') as f:
    pr = json.load(f)
text = f"""# ROUTER_PROOF_AUTHORITY_V1_RECOVERY

You are the exclusive `opencode_glm52` writer for Factory Console Issue #18.

## Canonical sources

- Issue: {issue['url']}
- Issue title: {issue['title']}
- Existing Draft PR: {pr['url']}
- PR title: {pr['title']}
- Branch: `{pr['headRefName']}`
- Exact starting head: `{pr['headRefOid']}`
- Base: `{pr['baseRefName']}` at `{base_sha}`
- Observed merge state: `{pr['mergeStateStatus']}`
- Exclusive worktree: `{worktree}`

## Canonical Issue #18 body

{issue['body']}

## Recovery instructions

This is a continuation of the existing mission, not a parallel implementation.
The previous ephemeral prompt `{old_prompt}` disappeared before the executor started.
Do not claim to reproduce the old prompt byte for byte.

1. Work only in the worktree and branch above.
2. Read Issue #18, Draft PR #19, the full diff and branch history.
3. Preserve all material work already delivered; do not blindly reimplement it.
4. Determine which acceptance criteria are still actually incomplete.
5. Make only the material delta required to complete Router Proof Authority v1.
6. Run focused validation and the isolated local canary required by the issue.
7. Do not alter FC-005 PR #10. Do not mark Ready, merge, deploy, activate production, mutate secrets or expand capacity/policy.
8. Do not invoke Codex or Claude and do not use another coder.
9. If a valid material change is needed, commit and push only to `{pr['headRefName']}`.
10. Report initial SHA, final SHA, changed files, tests/canaries, commit/push, resolved model, fallback used and any reproducible remaining blocker.
11. If implementation is already complete and only independent gates remain, do not fabricate changes; validate and return exact evidence.

Terminal criterion: Draft PR #19 preserved, reproducible evidence, and no action outside scope.
"""
with open(output, 'w', encoding='utf-8', newline='\n') as f:
    f.write(text)
PY
NEW_SHA="$(sha256sum "$PROMPT_TMP" | awk '{print $1}')"
install -d -o root -g zoe-coders -m 0750 "$PROMPT_DIR"
install -o root -g zoe-coders -m 0640 "$PROMPT_TMP" "$PROMPT_PATH"
sudo -u ubuntu test -r "$PROMPT_PATH" || die 'ubuntu cannot read durable prompt'
[[ "$(sha256sum "$PROMPT_PATH" | awk '{print $1}')" == "$NEW_SHA" ]] || die 'installed prompt SHA mismatch'
echo "Prompt: $PROMPT_PATH"
echo "SHA:    $NEW_SHA"

echo '[7/10] Requeueing the same job with compare-and-set...'
python3 - "$CONFIG" "$JOB" "$STATUS" "$OLD_PROMPT" "$OLD_SHA" "$PROMPT_PATH" "$NEW_SHA" "$DB_BACKUP" <<'PY'
import datetime as dt
import json
import sqlite3
import sys
import tomllib
from pathlib import Path
config, job_id, expected_status, old_path, old_sha, new_path, new_sha, backup = sys.argv[1:]
with open(config, 'rb') as f:
    cfg = tomllib.load(f)
rt = cfg['runtime']
db = rt.get('db_path', str(Path(rt.get('state_dir', '/var/lib/zoe-coder-router')) / 'runtime.db'))
now = dt.datetime.now(dt.timezone.utc).isoformat()
conn = sqlite3.connect(db, timeout=15)
conn.execute('PRAGMA journal_mode=WAL')
conn.execute('PRAGMA busy_timeout=10000')
row = conn.execute(
    'SELECT status,pid,started_at,selected_coder,project,issue,prompt_path,prompt_sha256 FROM jobs WHERE id=?',
    (job_id,),
).fetchone()
if row is None:
    raise SystemExit('job not found')
status, pid, started_at, coder, project, issue, current_path, current_sha = row
if status != expected_status:
    raise SystemExit(f'CAS refused: status changed from {expected_status} to {status}')
if pid is not None or started_at is not None:
    raise SystemExit(f'CAS refused: job started pid={pid} started_at={started_at}')
if (coder, project, str(issue)) != ('opencode_glm52', 'factory-console', '18'):
    raise SystemExit(f'CAS refused: unexpected identity {(coder, project, issue)}')
if current_path != old_path or current_sha != old_sha:
    raise SystemExit('CAS refused: prompt coordinates changed')
cur = conn.execute(
    """
    UPDATE jobs SET
      status='queued', prompt_path=?, prompt_sha256=?, error=NULL,
      pid=NULL, pid_start_ticks=NULL, started_at=NULL, heartbeat_at=NULL,
      last_output_at=NULL, completed_at=NULL, exit_code=NULL,
      result_path=NULL, stdout_path=NULL, stderr_path=NULL,
      wake_pending=0, wake_status=NULL, wake_attempts=0,
      process_heartbeat_at=NULL, progress_heartbeat_at=NULL,
      progress_sequence=0, last_progress_kind=NULL, last_progress_summary=NULL,
      last_stdout_offset=0, last_workspace_marker=NULL, last_tool_call_at=NULL,
      provider_request_started_at=NULL, provider_request_id=NULL,
      stall_detected_at=NULL, recovery_attempt=0, watchdog_state=NULL,
      resolved_model_id=NULL, updated_at=?
    WHERE id=? AND status=? AND pid IS NULL AND started_at IS NULL
    """,
    (new_path, new_sha, now, job_id, expected_status),
)
if cur.rowcount != 1:
    conn.rollback()
    raise SystemExit('CAS refused: no row updated')
payload = {
    'previous_status': expected_status,
    'old_prompt_path': old_path,
    'old_prompt_sha256': old_sha,
    'new_prompt_path': new_path,
    'new_prompt_sha256': new_sha,
    'db_backup': backup,
    'reason': 'ephemeral_prompt_missing_before_executor_start',
    'recovery_contract': 'canonical_issue_18_and_exact_pr_19_snapshot',
}
conn.execute(
    'INSERT INTO events(job_id,event_type,actor,payload,created_at) VALUES(?,?,?,?,?)',
    (job_id, 'JOB_REQUEUED_AFTER_DURABLE_PROMPT_RECOVERY', 'operator', json.dumps(payload, ensure_ascii=False, separators=(',', ':')), now),
)
conn.commit()
conn.close()
print(json.dumps({'job': job_id, 'status': 'queued', 'prompt': new_path, 'sha256': new_sha}, indent=2))
PY

echo '[8/10] Restoring timer and reconciling immediately...'
systemctl start "$TIMER"
TIMER_WAS_ACTIVE=0
$ROUTER reconcile
sleep 2

echo '[9/10] Dispatch evidence...'
$ROUTER show "$JOB" | jq '{job:{id:.job.id,status:.job.status,selected_coder:.job.selected_coder,prompt_path:.job.prompt_path,prompt_sha256:.job.prompt_sha256,pid:.job.pid,started_at:.job.started_at,error:.job.error},events:[.events[]|select(.event_type=="JOB_REQUEUED_AFTER_DURABLE_PROMPT_RECOVERY" or .event_type=="JOB_DISPATCHING" or .event_type=="JOB_STARTED" or .event_type=="JOB_FAILED")][-12:]}'

echo '[10/10] Unit and process evidence...'
systemctl status "$JOB_UNIT" --no-pager -l || true
pgrep -af 'opencode|zoe-coder execute' || true

echo '======================================================'
echo ' DURABLE PROMPT RECOVERY V3 COMPLETED'
echo '======================================================'
echo "Prompt:    $PROMPT_PATH"
echo "PromptSHA: $NEW_SHA"
echo "DB backup: $DB_BACKUP"
echo "Job:       $JOB"
