#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

REPO='/home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler'
OPS='/var/backups/zoe-coder-router/manual-8-etapas-20260731T104654Z'
DB='/var/lib/zoe-coder-router/runtime.db'
GH_REPO='lucaspprates/Zoe-Coder-Router'

PR17='17'
PR19='19'
MAIN_BEFORE='b705b03cdcc04bdd0d43df0f514f196f9a012430'
PR17_HEAD='0d935aa174850fa2581538c952d9fcbc832c6e80'
PR19_HEAD='7148c751257832c7953c59a17578985b7bf6e52e'
PR17_BRANCH='fix/16-opencode-result-provenance'
PR19_BRANCH='type/18-factory-scheduler-maintenance'
FINAL_GATE_EVIDENCE="$OPS/ETAPA-6C-FINAL-EXACT-SHA-GATE-$PR19_HEAD-PASS"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_TMP="$(mktemp -d /tmp/zcr19-stage7a.XXXXXX)"
EVIDENCE_FINAL="$OPS/ETAPA-7A-MERGE-PR17-RETARGET-PR19-$STAMP"
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
    echo 'MANUAL_ETAPA_7A: FAIL'
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

verify_pr_json() {
  local json_path="$1"
  local expected_state="$2"
  local expected_draft="$3"
  local expected_head="$4"
  local expected_base="$5"
  local expected_mergeable="$6"
  python3 - "$json_path" "$expected_state" "$expected_draft" "$expected_head" "$expected_base" "$expected_mergeable" <<'PY'
import json
import sys

path, state, draft, head, base, mergeable = sys.argv[1:]
obj = json.load(open(path, encoding='utf-8'))
assert obj.get('state') == state, obj
assert obj.get('isDraft') is (draft == 'true'), obj
assert obj.get('headRefOid') == head, obj
assert obj.get('baseRefName') == base, obj
if mergeable != 'ANY':
    assert obj.get('mergeable') == mergeable, obj
PY
}

[[ "$(id -un)" == 'ubuntu' ]] || fail USER_MISMATCH 'execute como ubuntu'
[[ "$(hostname -s)" == 'zoe-infranetwork-com-br' ]] || fail HOST_MISMATCH "$(hostname -s)"
sudo -n true >/dev/null 2>&1 || fail SUDO_UNAVAILABLE 'sudo NOPASSWD obrigatório'
command -v gh >/dev/null 2>&1 || fail GH_MISSING 'gh CLI não encontrado'
[[ -d "$REPO" ]] || fail REPO_MISSING "$REPO"
sudo -n test -d "$OPS" || fail OPS_MISSING "$OPS"
sudo -n test -r "$DB" || fail DB_UNREADABLE "$DB"
sudo -n test -d "$FINAL_GATE_EVIDENCE" || fail FINAL_GATE_EVIDENCE_MISSING "$FINAL_GATE_EVIDENCE"

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

gh auth status > "$EVIDENCE_TMP/gh-auth-status.txt" 2>&1 || fail GH_AUTH_FAILED 'gh auth status falhou'

git -C "$REPO" fetch -q origin main "$PR17_BRANCH" "$PR19_BRANCH"

[[ "$(git -C "$REPO" branch --show-current)" == "$PR19_BRANCH" ]] ||
  fail LOCAL_BRANCH_MISMATCH "$(git -C "$REPO" branch --show-current)"
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$PR19_HEAD" ]] ||
  fail LOCAL_HEAD_MISMATCH "$(git -C "$REPO" rev-parse HEAD)"
[[ -z "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail SOURCE_WORKTREE_DIRTY 'source worktree is not clean'

REMOTE_MAIN_BEFORE="$(git -C "$REPO" ls-remote origin refs/heads/main | awk '{print $1}')"
REMOTE_PR17="$(git -C "$REPO" ls-remote origin "refs/heads/$PR17_BRANCH" | awk '{print $1}')"
REMOTE_PR19="$(git -C "$REPO" ls-remote origin "refs/heads/$PR19_BRANCH" | awk '{print $1}')"

[[ "$REMOTE_MAIN_BEFORE" == "$MAIN_BEFORE" ]] || fail MAIN_CHANGED "$REMOTE_MAIN_BEFORE"
[[ "$REMOTE_PR17" == "$PR17_HEAD" ]] || fail PR17_HEAD_CHANGED "$REMOTE_PR17"
[[ "$REMOTE_PR19" == "$PR19_HEAD" ]] || fail PR19_HEAD_CHANGED "$REMOTE_PR19"

git -C "$REPO" merge-base --is-ancestor "$MAIN_BEFORE" "$PR17_HEAD" ||
  fail MAIN_NOT_ANCESTOR_OF_PR17 "$MAIN_BEFORE"
git -C "$REPO" merge-base --is-ancestor "$PR17_HEAD" "$PR19_HEAD" ||
  fail PR17_NOT_ANCESTOR_OF_PR19 "$PR17_HEAD"
[[ "$(git -C "$REPO" rev-list --count "$PR17_HEAD..$PR19_HEAD")" == '5' ]] ||
  fail PR19_UNIQUE_COMMIT_COUNT_MISMATCH "$(git -C "$REPO" rev-list --count "$PR17_HEAD..$PR19_HEAD")"

EXPECTED_DIFF="$(
  printf '%s\n' \
    'README.md' \
    'config/config.example.toml' \
    'src/zoe_coder_router/zoe_coder_router.py' \
    'tests/fixtures/config-schema.json' \
    'tests/test_factory_scheduler_maintenance.py' \
    'tests/test_opencode_terminal_result_smoke.py' |
  sort
)"
ACTUAL_DIFF="$(git -C "$REPO" diff --name-only "$PR17_HEAD" "$PR19_HEAD" | sort)"
[[ "$ACTUAL_DIFF" == "$EXPECTED_DIFF" ]] || fail PR19_DIFF_SCOPE_MISMATCH "$ACTUAL_DIFF"

gh pr view "$PR17" --repo "$GH_REPO" \
  --json state,isDraft,mergeable,headRefOid,baseRefName > "$EVIDENCE_TMP/pr17-before.json"
gh pr view "$PR19" --repo "$GH_REPO" \
  --json state,isDraft,mergeable,headRefOid,baseRefName > "$EVIDENCE_TMP/pr19-before.json"

verify_pr_json "$EVIDENCE_TMP/pr17-before.json" OPEN true "$PR17_HEAD" main MERGEABLE ||
  fail PR17_PRECONDITION_FAILED 'PR17 não está open/draft/mergeable no SHA esperado'
verify_pr_json "$EVIDENCE_TMP/pr19-before.json" OPEN true "$PR19_HEAD" "$PR17_BRANCH" MERGEABLE ||
  fail PR19_PRECONDITION_FAILED 'PR19 não está open/draft/mergeable na base esperada'

{
  echo '===== ETAPA 7A PRE-MERGE ====='
  echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "main_before=$MAIN_BEFORE"
  echo "pr17_head=$PR17_HEAD"
  echo "pr19_head=$PR19_HEAD"
  echo "active_jobs=$ACTIVE_JOBS"
  echo "active_units=$ACTIVE_UNITS"
  echo "timer=$TIMER"
  echo "final_gate_evidence=$FINAL_GATE_EVIDENCE"
  echo 'strategy=merge PR17, retarget PR19, stop before PR19 merge'
} | tee "$EVIDENCE_TMP/PRE-MERGE.txt"

gh pr ready "$PR17" --repo "$GH_REPO" > "$EVIDENCE_TMP/pr17-ready.txt" 2>&1 ||
  fail PR17_READY_FAILED 'não foi possível marcar PR17 ready'

gh pr view "$PR17" --repo "$GH_REPO" \
  --json state,isDraft,mergeable,headRefOid,baseRefName > "$EVIDENCE_TMP/pr17-ready.json"
verify_pr_json "$EVIDENCE_TMP/pr17-ready.json" OPEN false "$PR17_HEAD" main MERGEABLE ||
  fail PR17_READY_READBACK_FAILED 'PR17 ready readback divergente'

set +e
gh api --method PUT "repos/$GH_REPO/pulls/$PR17/merge" \
  -f merge_method=merge \
  -f sha="$PR17_HEAD" \
  > "$EVIDENCE_TMP/pr17-merge-response.json" \
  2> "$EVIDENCE_TMP/pr17-merge-response.stderr"
MERGE17_RC=$?
set -e
[[ "$MERGE17_RC" == '0' ]] || fail PR17_MERGE_API_FAILED "rc=$MERGE17_RC"

PR17_MERGE_SHA="$(
  python3 - "$EVIDENCE_TMP/pr17-merge-response.json" <<'PY'
import json
import sys
obj=json.load(open(sys.argv[1],encoding='utf-8'))
assert obj.get('merged') is True, obj
sha=obj.get('sha')
assert isinstance(sha,str) and len(sha)==40, obj
print(sha)
PY
)" || fail PR17_MERGE_RESPONSE_INVALID 'merge response inválida'

git -C "$REPO" fetch -q origin main
MAIN_AFTER_PR17="$(git -C "$REPO" rev-parse origin/main)"
[[ "$MAIN_AFTER_PR17" == "$PR17_MERGE_SHA" ]] || fail MAIN_PR17_READBACK_MISMATCH "$MAIN_AFTER_PR17"
git -C "$REPO" merge-base --is-ancestor "$MAIN_BEFORE" "$MAIN_AFTER_PR17" ||
  fail MAIN_HISTORY_INVALID_AFTER_PR17 "$MAIN_AFTER_PR17"
git -C "$REPO" merge-base --is-ancestor "$PR17_HEAD" "$MAIN_AFTER_PR17" ||
  fail PR17_HEAD_NOT_IN_MAIN "$MAIN_AFTER_PR17"
[[ "$(git -C "$REPO" rev-parse "$MAIN_AFTER_PR17^{tree}")" == "$(git -C "$REPO" rev-parse "$PR17_HEAD^{tree}")" ]] ||
  fail PR17_MERGE_TREE_MISMATCH "$MAIN_AFTER_PR17"

gh pr view "$PR17" --repo "$GH_REPO" \
  --json state,isDraft,headRefOid,baseRefName,mergedAt,mergeCommit > "$EVIDENCE_TMP/pr17-after.json"
python3 - "$EVIDENCE_TMP/pr17-after.json" "$PR17_HEAD" "$PR17_MERGE_SHA" <<'PY' ||
  fail PR17_MERGED_READBACK_FAILED 'PR17 merged readback divergente'
import json
import sys
obj=json.load(open(sys.argv[1],encoding='utf-8'))
assert obj.get('state') == 'MERGED', obj
assert obj.get('headRefOid') == sys.argv[2], obj
assert obj.get('baseRefName') == 'main', obj
assert obj.get('mergedAt'), obj
merge=obj.get('mergeCommit') or {}
assert merge.get('oid') == sys.argv[3], obj
PY

set +e
gh api --method PATCH "repos/$GH_REPO/pulls/$PR19" \
  -f base=main \
  > "$EVIDENCE_TMP/pr19-retarget-response.json" \
  2> "$EVIDENCE_TMP/pr19-retarget-response.stderr"
RETARGET_RC=$?
set -e
[[ "$RETARGET_RC" == '0' ]] || fail PR19_RETARGET_FAILED "rc=$RETARGET_RC"

MERGEABLE19='UNKNOWN'
for attempt in $(seq 1 12); do
  gh pr view "$PR19" --repo "$GH_REPO" \
    --json state,isDraft,mergeable,headRefOid,baseRefName > "$EVIDENCE_TMP/pr19-after.json"
  MERGEABLE19="$(python3 - "$EVIDENCE_TMP/pr19-after.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding='utf-8')).get('mergeable','UNKNOWN'))
PY
)"
  [[ "$MERGEABLE19" != 'UNKNOWN' ]] && break
  sleep 2
done

verify_pr_json "$EVIDENCE_TMP/pr19-after.json" OPEN true "$PR19_HEAD" main MERGEABLE ||
  fail PR19_RETARGET_READBACK_FAILED "mergeable=$MERGEABLE19"

git -C "$REPO" fetch -q origin main "$PR19_BRANCH"
[[ "$(git -C "$REPO" rev-parse "origin/$PR19_BRANCH")" == "$PR19_HEAD" ]] ||
  fail PR19_HEAD_CHANGED_AFTER_RETARGET "$(git -C "$REPO" rev-parse "origin/$PR19_BRANCH")"
[[ "$(git -C "$REPO" merge-base origin/main "$PR19_HEAD")" == "$PR17_HEAD" ]] ||
  fail PR19_MERGE_BASE_UNEXPECTED "$(git -C "$REPO" merge-base origin/main "$PR19_HEAD")"
[[ "$(git -C "$REPO" rev-parse "origin/main^{tree}")" == "$(git -C "$REPO" rev-parse "$PR17_HEAD^{tree}")" ]] ||
  fail MAIN_TREE_NOT_EQUAL_PR17_TREE 'retarget base tree divergiu'

RETARGET_DIFF="$(git -C "$REPO" diff --name-only origin/main "$PR19_HEAD" | sort)"
[[ "$RETARGET_DIFF" == "$EXPECTED_DIFF" ]] || fail RETARGET_DIFF_SCOPE_MISMATCH "$RETARGET_DIFF"
git -C "$REPO" diff --check origin/main "$PR19_HEAD"

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == 'inactive' ]] ||
  fail TIMER_CHANGED_AFTER_INTEGRATION 'timer changed'
[[ "$(active_jobs)" == '0' ]] || fail ACTIVE_JOBS_AFTER_INTEGRATION "$(active_jobs)"
[[ -z "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail SOURCE_WORKTREE_DIRTY_AFTER_INTEGRATION 'source worktree dirty'

{
  echo 'MANUAL_ETAPA_7A: PASS'
  echo "PR17_MERGED=true"
  echo "PR17_HEAD=$PR17_HEAD"
  echo "PR17_MERGE_SHA=$PR17_MERGE_SHA"
  echo "MAIN_AFTER_PR17=$MAIN_AFTER_PR17"
  echo "PR19_RETARGETED=true"
  echo 'PR19_BASE=main'
  echo "PR19_HEAD=$PR19_HEAD"
  echo "PR19_MERGEABLE=$MERGEABLE19"
  echo 'PR19_DRAFT=true'
  echo 'PR19_CHANGED_FILES=6'
  echo 'ACTIVE_JOBS=0'
  echo 'ACTIVE_UNITS=0'
  echo 'TIMER=inactive'
  echo 'NEXT=MERGE_PR19_AFTER_RETARGET_READBACK'
} | tee "$EVIDENCE_TMP/RESULT.txt"

persist_evidence PASS

echo
echo 'MANUAL_ETAPA_7A_READBACK: PASS'
echo "EVIDENCE=$PERSISTED"
