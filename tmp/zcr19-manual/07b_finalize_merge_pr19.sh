#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

REPO='/home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler'
OPS='/var/backups/zoe-coder-router/manual-8-etapas-20260731T104654Z'
DB='/var/lib/zoe-coder-router/runtime.db'
GH_REPO='lucaspprates/Zoe-Coder-Router'

PR19='19'
MAIN_BEFORE='ad9cb37f37ceb1353f58a4c2c24de50ce50b9c4a'
PR19_HEAD='7148c751257832c7953c59a17578985b7bf6e52e'
PR19_BRANCH='type/18-factory-scheduler-maintenance'
FINAL_GATE_JOB='3276baad-1855-4f3d-9eb8-0f8ce0d3b81f'
FINAL_GATE_EVIDENCE="$OPS/ETAPA-6C-FINAL-EXACT-SHA-GATE-$PR19_HEAD-PASS"
STAGE7A_EVIDENCE="$OPS/ETAPA-7A-MERGE-PR17-RETARGET-PR19-20260731T135123Z-PASS"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_TMP="$(mktemp -d /tmp/zcr19-stage7b.XXXXXX)"
EVIDENCE_FINAL="$OPS/ETAPA-7B-FINAL-MERGE-PR19-$STAMP"
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
    echo 'MANUAL_ETAPA_7B: FAIL'
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
obj = json.load(open(path, encoding="utf-8"))
assert obj.get("state") == state, obj
assert obj.get("isDraft") is (draft == "true"), obj
assert obj.get("headRefOid") == head, obj
assert obj.get("baseRefName") == base, obj
if mergeable != "ANY":
    assert obj.get("mergeable") == mergeable, obj
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
sudo -n test -d "$STAGE7A_EVIDENCE" || fail STAGE7A_EVIDENCE_MISSING "$STAGE7A_EVIDENCE"

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

git -C "$REPO" fetch -q origin main "$PR19_BRANCH"

[[ "$(git -C "$REPO" branch --show-current)" == "$PR19_BRANCH" ]] ||
  fail LOCAL_BRANCH_MISMATCH "$(git -C "$REPO" branch --show-current)"
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$PR19_HEAD" ]] ||
  fail LOCAL_HEAD_MISMATCH "$(git -C "$REPO" rev-parse HEAD)"
[[ "$(git -C "$REPO" rev-parse "origin/$PR19_BRANCH")" == "$PR19_HEAD" ]] ||
  fail ORIGIN_HEAD_MISMATCH "$(git -C "$REPO" rev-parse "origin/$PR19_BRANCH")"
[[ "$(git -C "$REPO" rev-parse origin/main)" == "$MAIN_BEFORE" ]] ||
  fail MAIN_CHANGED "$(git -C "$REPO" rev-parse origin/main)"
[[ -z "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail SOURCE_WORKTREE_DIRTY 'source worktree is not clean'

REMOTE_MAIN="$(git -C "$REPO" ls-remote origin refs/heads/main | awk '{print $1}')"
REMOTE_PR19="$(git -C "$REPO" ls-remote origin "refs/heads/$PR19_BRANCH" | awk '{print $1}')"
[[ "$REMOTE_MAIN" == "$MAIN_BEFORE" ]] || fail REMOTE_MAIN_CHANGED "$REMOTE_MAIN"
[[ "$REMOTE_PR19" == "$PR19_HEAD" ]] || fail REMOTE_PR19_CHANGED "$REMOTE_PR19"

STACK_BASE='0d935aa174850fa2581538c952d9fcbc832c6e80'
MERGE_BASE="$(git -C "$REPO" merge-base "$MAIN_BEFORE" "$PR19_HEAD")"
[[ "$MERGE_BASE" == "$STACK_BASE" ]] ||
  fail UNEXPECTED_STACK_MERGE_BASE "$MERGE_BASE"
[[ "$(git -C "$REPO" rev-parse "$MAIN_BEFORE^{tree}")" == "$(git -C "$REPO" rev-parse "$STACK_BASE^{tree}")" ]] ||
  fail MAIN_TREE_NOT_EQUAL_STACK_BASE 'main merge tree differs from PR17 head tree'

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
ACTUAL_DIFF="$(git -C "$REPO" diff --name-only "$MAIN_BEFORE" "$PR19_HEAD" | sort)"
[[ "$ACTUAL_DIFF" == "$EXPECTED_DIFF" ]] || fail PR19_DIFF_SCOPE_MISMATCH "$ACTUAL_DIFF"
git -C "$REPO" diff --check "$MAIN_BEFORE" "$PR19_HEAD"

gh pr view "$PR19" --repo "$GH_REPO" \
  --json state,isDraft,mergeable,headRefOid,baseRefName,body > "$EVIDENCE_TMP/pr19-before.json"

if ! verify_pr_json "$EVIDENCE_TMP/pr19-before.json" OPEN true "$PR19_HEAD" main MERGEABLE; then
  fail PR19_PRECONDITION_FAILED 'PR19 não está open/draft/mergeable no SHA e base esperados'
fi

cat > "$EVIDENCE_TMP/pr19-final-body.md" <<EOF_BODY
Closes #18

## What changed

- dispatches Zoe wakes asynchronously without blocking reconciliation;
- enforces one global wake lease with stale/orphan recovery;
- restores six factory slots: four writers and two independent gates;
- separates writer, gate, QA and release-validation accounting;
- requires durable prompts and supports atomic prompt import;
- adds compare-and-set requeue with SQLite backup;
- validates every capacity-plan reservation before admission;
- requires project, task route, coder profile, no-fallback, exact-SHA and clean-worktree proof;
- makes the final reservation-to-queued transition all-or-none;
- adds deterministic negative-path and admission-race regression coverage.

## Stack

- PR #17 merged into \`main\` as \`$MAIN_BEFORE\`;
- this PR is based on \`main\` and has exact head \`$PR19_HEAD\`;
- changed-file scope after retarget: six files.

## Validation

- capacity-plan regressions: 27 passed;
- scheduler-maintenance suite: 38 passed;
- provenance and terminal smoke: 47 passed;
- full suite: 120 passed;
- Python compileall: PASS;
- git diff --check: PASS;
- final worktree: clean.

## Independent Gate

- prior Gate on \`c3db2c39e58326c932e1a9276b1da9b4cecd45bb\` correctly rejected incomplete negative-path coverage;
- test-only correction SHA: \`$PR19_HEAD\`;
- final exact-SHA Gate job: \`$FINAL_GATE_JOB\`;
- final Gate profile: \`codex_terra_remote_gate\`;
- mode: \`read_only\`;
- terminal: \`gate_status=PASS\`;
- start SHA = end SHA = \`$PR19_HEAD\`;
- Gate changed paths: none.

## Safety

No runtime deployment, timer activation, production configuration mutation, credential mutation or worker teardown is included in this merge. The reconciler timer remained inactive and the Router ledger had zero active jobs throughout integration.
EOF_BODY

gh pr edit "$PR19" --repo "$GH_REPO" \
  --body-file "$EVIDENCE_TMP/pr19-final-body.md" \
  > "$EVIDENCE_TMP/pr19-body-update.txt" 2>&1 ||
  fail PR19_BODY_UPDATE_FAILED 'não foi possível atualizar o corpo da PR19'

gh pr view "$PR19" --repo "$GH_REPO" --json body --jq '.body' \
  > "$EVIDENCE_TMP/pr19-body-readback.md"
grep -Fq "$PR19_HEAD" "$EVIDENCE_TMP/pr19-body-readback.md" ||
  fail PR19_BODY_SHA_MISSING 'head SHA não apareceu no corpo atualizado'
grep -Fq "$FINAL_GATE_JOB" "$EVIDENCE_TMP/pr19-body-readback.md" ||
  fail PR19_BODY_GATE_JOB_MISSING 'Gate job não apareceu no corpo atualizado'
grep -Fq 'full suite: 120 passed' "$EVIDENCE_TMP/pr19-body-readback.md" ||
  fail PR19_BODY_TEST_EVIDENCE_MISSING 'evidência de testes ausente'

{
  echo '===== ETAPA 7B PRE-MERGE ====='
  echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "main_before=$MAIN_BEFORE"
  echo "pr19_head=$PR19_HEAD"
  echo "final_gate_job=$FINAL_GATE_JOB"
  echo "final_gate_evidence=$FINAL_GATE_EVIDENCE"
  echo "stage7a_evidence=$STAGE7A_EVIDENCE"
  echo "active_jobs=$ACTIVE_JOBS"
  echo "active_units=$ACTIVE_UNITS"
  echo "timer=$TIMER"
  echo 'merge_method=merge'
  echo 'merge_sha_guard=enabled'
} | tee "$EVIDENCE_TMP/PRE-MERGE.txt"

gh pr ready "$PR19" --repo "$GH_REPO" > "$EVIDENCE_TMP/pr19-ready.txt" 2>&1 ||
  fail PR19_READY_FAILED 'não foi possível marcar PR19 ready'

MERGEABLE19='UNKNOWN'
for attempt in $(seq 1 12); do
  gh pr view "$PR19" --repo "$GH_REPO" \
    --json state,isDraft,mergeable,headRefOid,baseRefName > "$EVIDENCE_TMP/pr19-ready.json"
  MERGEABLE19="$(
    python3 - "$EVIDENCE_TMP/pr19-ready.json" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8")).get("mergeable", "UNKNOWN"))
PY
  )"
  [[ "$MERGEABLE19" != 'UNKNOWN' ]] && break
  sleep 2
done

if ! verify_pr_json "$EVIDENCE_TMP/pr19-ready.json" OPEN false "$PR19_HEAD" main MERGEABLE; then
  fail PR19_READY_READBACK_FAILED "mergeable=$MERGEABLE19"
fi

set +e
gh api --method PUT "repos/$GH_REPO/pulls/$PR19/merge" \
  -f merge_method=merge \
  -f sha="$PR19_HEAD" \
  > "$EVIDENCE_TMP/pr19-merge-response.json" \
  2> "$EVIDENCE_TMP/pr19-merge-response.stderr"
MERGE_RC=$?
set -e
[[ "$MERGE_RC" == '0' ]] || fail PR19_MERGE_API_FAILED "rc=$MERGE_RC"

set +e
PR19_MERGE_SHA="$(
  python3 - "$EVIDENCE_TMP/pr19-merge-response.json" <<'PY'
import json
import sys

obj = json.load(open(sys.argv[1], encoding="utf-8"))
assert obj.get("merged") is True, obj
sha = obj.get("sha")
assert isinstance(sha, str) and len(sha) == 40, obj
print(sha)
PY
)"
PARSE_RC=$?
set -e
[[ "$PARSE_RC" == '0' ]] || fail PR19_MERGE_RESPONSE_INVALID 'merge response inválida'

git -C "$REPO" fetch -q origin main "$PR19_BRANCH"
MAIN_FINAL="$(git -C "$REPO" rev-parse origin/main)"
[[ "$MAIN_FINAL" == "$PR19_MERGE_SHA" ]] || fail MAIN_FINAL_READBACK_MISMATCH "$MAIN_FINAL"
git -C "$REPO" merge-base --is-ancestor "$MAIN_BEFORE" "$MAIN_FINAL" ||
  fail MAIN_HISTORY_INVALID "$MAIN_FINAL"
git -C "$REPO" merge-base --is-ancestor "$PR19_HEAD" "$MAIN_FINAL" ||
  fail PR19_HEAD_NOT_IN_MAIN "$MAIN_FINAL"
[[ "$(git -C "$REPO" rev-parse "$MAIN_FINAL^{tree}")" == "$(git -C "$REPO" rev-parse "$PR19_HEAD^{tree}")" ]] ||
  fail PR19_MERGE_TREE_MISMATCH "$MAIN_FINAL"

gh pr view "$PR19" --repo "$GH_REPO" \
  --json state,isDraft,headRefOid,baseRefName,mergedAt,mergeCommit,body \
  > "$EVIDENCE_TMP/pr19-after.json"

set +e
python3 - "$EVIDENCE_TMP/pr19-after.json" "$PR19_HEAD" "$PR19_MERGE_SHA" <<'PY'
import json
import sys

obj = json.load(open(sys.argv[1], encoding="utf-8"))
assert obj.get("state") == "MERGED", obj
assert obj.get("isDraft") is False, obj
assert obj.get("headRefOid") == sys.argv[2], obj
assert obj.get("baseRefName") == "main", obj
assert obj.get("mergedAt"), obj
merge = obj.get("mergeCommit") or {}
assert merge.get("oid") == sys.argv[3], obj
body = obj.get("body") or ""
assert sys.argv[2] in body, obj
PY
READBACK_RC=$?
set -e
[[ "$READBACK_RC" == '0' ]] || fail PR19_MERGED_READBACK_FAILED 'PR19 merged readback divergente'

FINAL_TIMER="$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
FINAL_UNITS="$(
  systemctl list-units \
    'zoe-coder-job@*.service' \
    'zoe-coder-wake@*.service' \
    --state=active,activating \
    --no-legend \
    --no-pager 2>/dev/null |
  awk 'NF{n++} END{print n+0}'
)"
FINAL_JOBS="$(active_jobs)"

[[ "$FINAL_TIMER" == 'inactive' ]] || fail TIMER_CHANGED_AFTER_MERGE "$FINAL_TIMER"
[[ "$FINAL_UNITS" == '0' ]] || fail ACTIVE_UNITS_AFTER_MERGE "$FINAL_UNITS"
[[ "$FINAL_JOBS" == '0' ]] || fail ACTIVE_JOBS_AFTER_MERGE "$FINAL_JOBS"
[[ -z "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail SOURCE_WORKTREE_DIRTY_AFTER_MERGE 'source worktree dirty'
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$PR19_HEAD" ]] ||
  fail LOCAL_HEAD_CHANGED_AFTER_MERGE "$(git -C "$REPO" rev-parse HEAD)"

{
  echo 'MANUAL_ETAPA_7B: PASS'
  echo 'PR19_MERGED=true'
  echo "PR19_HEAD=$PR19_HEAD"
  echo "PR19_MERGE_SHA=$PR19_MERGE_SHA"
  echo "MAIN_FINAL=$MAIN_FINAL"
  echo 'MAIN_TREE_EQUALS_PR19=true'
  echo 'PR19_BODY_UPDATED=true'
  echo "FINAL_GATE_JOB=$FINAL_GATE_JOB"
  echo "ACTIVE_JOBS=$FINAL_JOBS"
  echo "ACTIVE_UNITS=$FINAL_UNITS"
  echo "TIMER=$FINAL_TIMER"
  echo 'NEXT=DEPLOY_CANARY_ACTIVATION_AND_ONCA_TEARDOWN'
} | tee "$EVIDENCE_TMP/RESULT.txt"

persist_evidence PASS

echo
echo 'MANUAL_ETAPA_7B_READBACK: PASS'
echo "EVIDENCE=$PERSISTED"
