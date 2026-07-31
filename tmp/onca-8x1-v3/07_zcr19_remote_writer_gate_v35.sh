#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

RUNTIME="/usr/local/lib/zoe-coder-router/zoe_coder_router.py"
CONFIG="/etc/zoe-coder-router/config.toml"
DB="/var/lib/zoe-coder-router/runtime.db"
BRIDGE="/usr/local/bin/onca-codex-remote"
WORKTREE="/home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler"
BRANCH="type/18-factory-scheduler-maintenance"
START_SHA="d80ed678333dc70d1b92479a821bf2d1467c4424"
WRITER="codex_terra_remote_writer_yolo"
GATE="codex_terra_remote_gate"
EXPECTED_RUNTIME_SHA256="f181fd627dceff10d46d23598eb54d8cfb5a15b070231aa34b4c09e907fc7d85"
EXPECTED_CONFIG_SHA256="3af46a9069e406a75b8e3e66368fa3a2c688711616bc86a5df12d9e4135595e4"
EXPECTED_BRIDGE_SHA256="4d37ed3baba38dc5d35ac9e11928dd0969dd5e7fbdf3c0f4c3e4af2acafdd4b6"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="/tmp/evidence/zcr19-remote-writer-gate-${STAMP}"
BACKUP="/var/backups/zoe-coder-router/zcr19-remote-writer-gate-${STAMP}"
PROMPT_ROOT="/var/lib/zoe-coder-router/prompts/ZCR19"
WRITER_PROMPT="$PROMPT_ROOT/writer-${STAMP}.md"
GATE_PROMPT="$PROMPT_ROOT/gate-${STAMP}.md"
mkdir -p "$EVIDENCE"

fail() {
  local code="$1"; shift
  echo "ERRO: $*" >&2
  echo "OPERACAO_ZCR19_REMOTE_WRITER_GATE: BLOCKED"
  echo "FAILURE_CODE=$code"
  echo "EVIDENCE_DIR=$EVIDENCE"
  exit 1
}

active_units() {
  systemctl list-units \
    'zoe-coder-job@*.service' \
    'zoe-coder-wake@*.service' \
    --state=active,activating \
    --no-legend --no-pager 2>/dev/null | wc -l
}

router() {
  sudo -u ubuntu -g zoe-coders -H -- \
    python3 "$RUNTIME" --config "$CONFIG" "$@"
}

copy_router_artifact() {
  local source="$1" target="$2"
  sudo test -f "$source" || fail ROUTER_ARTIFACT_MISSING "$source"
  sudo cp "$source" "$target"
  sudo chown ubuntu:ubuntu "$target"
  chmod 0600 "$target"
}

job_field() {
  local json="$1" field="$2"
  python3 - "$json" "$field" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))["job"]
for part in sys.argv[2].split('.'):
    value = value.get(part) if isinstance(value, dict) else None
print("" if value is None else value)
PY
}

[[ "$(id -un)" == "ubuntu" ]] || fail USER_MISMATCH "execute como ubuntu"
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail HOST_MISMATCH "host atual=$(hostname -s)"
sudo -v
sudo install -d -m 0700 -o root -g root "$BACKUP"
sudo install -d -m 0770 -o root -g zoe-coders "$PROMPT_ROOT"

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail TIMER_NOT_INACTIVE "reconciler deve permanecer congelado"
[[ "$(active_units)" -eq 0 ]] || fail ACTIVE_UNITS_PRESENT "há units ativas"
[[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$EXPECTED_RUNTIME_SHA256" ]] ||
  fail RUNTIME_SHA_MISMATCH "runtime divergente"
[[ "$(sudo sha256sum "$CONFIG" | awk '{print $1}')" == "$EXPECTED_CONFIG_SHA256" ]] ||
  fail CONFIG_SHA_MISMATCH "config divergente"
[[ "$(sha256sum "$BRIDGE" | awk '{print $1}')" == "$EXPECTED_BRIDGE_SHA256" ]] ||
  fail BRIDGE_SHA_MISMATCH "bridge divergente"

[[ -d "$WORKTREE/.git" || -f "$WORKTREE/.git" ]] || fail WORKTREE_MISSING "$WORKTREE"
[[ "$(git -C "$WORKTREE" branch --show-current)" == "$BRANCH" ]] ||
  fail BRANCH_MISMATCH "$(git -C "$WORKTREE" branch --show-current)"
[[ "$(git -C "$WORKTREE" rev-parse HEAD)" == "$START_SHA" ]] ||
  fail START_SHA_MISMATCH "$(git -C "$WORKTREE" rev-parse HEAD)"
[[ -z "$(git -C "$WORKTREE" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail WORKTREE_NOT_CLEAN "worktree possui alterações"

git -C "$WORKTREE" fetch -q origin "$BRANCH"
REMOTE_START="$(git -C "$WORKTREE" rev-parse "origin/$BRANCH")"
[[ "$REMOTE_START" == "$START_SHA" ]] || fail ORIGIN_SHA_MISMATCH "$REMOTE_START"

if ! python3 - "$DB" <<'PY' > "$EVIDENCE/active-zcr19-jobs.json"
import json, sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.row_factory = sqlite3.Row
rows = conn.execute(
    "SELECT id,status,selected_coder,mode FROM jobs WHERE mission_id='ZCR19' AND status IN ('queued','dispatching','running')"
).fetchall()
print(json.dumps([dict(row) for row in rows], indent=2))
if rows:
    raise SystemExit(1)
PY
then
  fail ACTIVE_ZCR19_JOB_PRESENT "consulte active-zcr19-jobs.json"
fi

sudo python3 - "$DB" "$BACKUP/runtime.db.before" <<'PY'
import sqlite3, sys
source = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
target = sqlite3.connect(sys.argv[2])
source.backup(target)
target.close(); source.close()
PY
DB_SHA_BEFORE="$(sudo sha256sum "$DB" | awk '{print $1}')"
printf '%s\n' "$DB_SHA_BEFORE" > "$EVIDENCE/db-sha-before.txt"

cat > "$EVIDENCE/writer-prompt.md" <<EOF_WRITER
You are the admitted Writer for Zoe Coder Router issue #18 / draft PR #19.

Immutable execution context:
- repository: lucaspprates/Zoe-Coder-Router
- branch: $BRANCH
- starting SHA: $START_SHA
- mission: ZCR19
- reconciler timer must remain inactive
- do not change branches, merge, rebase, reset to another commit, push, or touch production runtime/config/database/systemd
- work only inside the supplied repository
- finish with exactly one new commit on top of the starting SHA and a clean worktree

Objective:
Complete the scheduler/control-plane repair required by issue #18 and correct the current PR implementation. Inspect the full diff and tests before editing. Keep the work strictly in scope.

Mandatory corrections and proofs:
1. Admission barrier: wake-created or successor jobs must never become dispatchable before the structured GLOBAL_CAPACITY_PLAN has been validated against current ledger state and reservations.
2. 4+2 planner: enforce total capacity 6, up to 4 writers and 2 independent read-only gates; blocked writers must not suppress gates; reject duplicate jobs, over-capacity plans, role mixing, and unjustified idle slots.
3. Native requeue/retry: compare-and-set only from eligible states, preserve mission/worktree/branch/prompt identity, reject live processes or conflicting active lanes, reset only required fields, create an online SQLite backup, and emit durable audit evidence.
4. Async wake lease: use non-blocking systemd dispatch, never hold reconciliation lock while Hermes runs, enforce one global lease, and deterministically recover stale/orphaned leases without duplicate orchestration or timeout loops.
5. Durable prompts: configured durable root, reject /tmp and symlink/ephemeral sources, atomic import, SHA verification, file fsync plus parent-directory fsync, immutable/readable execution contract, and explicit recovery reuse.
6. Independent gate contract: exact-SHA read-only/no-fallback verifier admission must be distinct from writer identity for Zoe Coder Router and Factory Console examples, without adding credentials or activating unrelated production routes.
7. Terminal GLOBAL_CAPACITY_PLAN validation must be ledger-backed and fail closed; a textual success marker alone is never sufficient.

Validation required before commit:
- focused scheduler/wake/capacity/prompt/requeue/gate tests
- full pytest suite
- python3 -m compileall -q src tests
- git diff --check
- an isolated canary covering terminal job -> async wake -> continued reconcile ticks -> independently justified writer/gate plan

Create one final commit with a clear message. Do not push; the control-plane bridge performs the push after verifying the result.

Your final non-empty output line must be one JSON object, without Markdown fences and with no output after it:
{"terminal_status":"complete","mission":"ZCR19","terminal_marker":"ZCR19_PRE_GATE_CORRECTIONS_COMPLETE","starting_sha":"$START_SHA","new_sha":"<exact 40-char commit SHA>","tests_passed":<positive integer total>,"focused_tests":"<exact focused commands and PASS summary>","diff_stat":"<git diff --stat $START_SHA..HEAD summary>","timer":"inactive","push_required":true}
EOF_WRITER
sudo install -m 0640 -o root -g zoe-coders "$EVIDENCE/writer-prompt.md" "$WRITER_PROMPT"
WRITER_PROMPT_SHA="$(sudo sha256sum "$WRITER_PROMPT" | awk '{print $1}')"

WRITER_JOB_ID="$(router submit \
  --project zoe-coder-router \
  --repo "$WORKTREE" \
  --worktree "$WORKTREE" \
  --branch "$BRANCH" \
  --issue 18 \
  --mission ZCR19 \
  --task-type implementation \
  --mode write \
  --prompt-file "$WRITER_PROMPT" \
  --coder "$WRITER" \
  --priority 100 \
  --max-attempts 1 \
  --no-fallback \
  --idempotency-key "ZCR19-REMOTE-WRITER-V35-$START_SHA-$WRITER_PROMPT_SHA")"
[[ "$WRITER_JOB_ID" =~ ^[0-9a-f-]{36}$ ]] || fail WRITER_SUBMIT_INVALID "$WRITER_JOB_ID"
echo "$WRITER_JOB_ID" > "$EVIDENCE/writer-job-id.txt"

set +e
router execute "$WRITER_JOB_ID" > "$EVIDENCE/writer-execute.stdout.log" 2> "$EVIDENCE/writer-execute.stderr.log"
WRITER_RC=$?
set -e
router show "$WRITER_JOB_ID" > "$EVIDENCE/writer-show.json"
[[ "$WRITER_RC" -eq 0 ]] || fail WRITER_EXECUTION_FAILED "rc=$WRITER_RC"
[[ "$(job_field "$EVIDENCE/writer-show.json" status)" == "succeeded" ]] ||
  fail WRITER_JOB_NOT_SUCCEEDED "status=$(job_field "$EVIDENCE/writer-show.json" status)"
[[ "$(job_field "$EVIDENCE/writer-show.json" selected_coder)" == "$WRITER" ]] ||
  fail WRITER_PROFILE_MISMATCH "$(job_field "$EVIDENCE/writer-show.json" selected_coder)"

WRITER_STDOUT="$(job_field "$EVIDENCE/writer-show.json" stdout_path)"
WRITER_RESULT="$(job_field "$EVIDENCE/writer-show.json" result_path)"
copy_router_artifact "$WRITER_STDOUT" "$EVIDENCE/writer-router-stdout.jsonl"
copy_router_artifact "$WRITER_RESULT" "$EVIDENCE/writer-router-result.json"

NEW_SHA="$(git -C "$WORKTREE" rev-parse HEAD)"
[[ "$NEW_SHA" =~ ^[0-9a-f]{40}$ && "$NEW_SHA" != "$START_SHA" ]] ||
  fail WRITER_SHA_INVALID "$NEW_SHA"
[[ "$(git -C "$WORKTREE" branch --show-current)" == "$BRANCH" ]] || fail WRITER_BRANCH_CHANGED "$BRANCH"
[[ -z "$(git -C "$WORKTREE" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail WRITER_WORKTREE_NOT_CLEAN "worktree suja"
[[ "$(git -C "$WORKTREE" rev-list --count "$START_SHA..$NEW_SHA")" -eq 1 ]] ||
  fail WRITER_COMMIT_COUNT_NOT_ONE "$(git -C "$WORKTREE" rev-list --count "$START_SHA..$NEW_SHA")"
git -C "$WORKTREE" merge-base --is-ancestor "$START_SHA" "$NEW_SHA" ||
  fail WRITER_NOT_DESCENDANT "$NEW_SHA"
git -C "$WORKTREE" fetch -q origin "$BRANCH"
[[ "$(git -C "$WORKTREE" rev-parse "origin/$BRANCH")" == "$NEW_SHA" ]] ||
  fail WRITER_ORIGIN_NOT_PUBLISHED "origin divergiu"

python3 - "$EVIDENCE/writer-router-stdout.jsonl" "$START_SHA" "$NEW_SHA" <<'PY' > "$EVIDENCE/writer-terminal-object.json"
import json, sys
lines=[line.strip() for line in open(sys.argv[1], encoding="utf-8", errors="replace") if line.strip()]
obj=json.loads(lines[-1])
assert obj["terminal_status"] == "complete"
assert obj["mission"] == "ZCR19"
assert obj["terminal_marker"] == "ZCR19_PRE_GATE_CORRECTIONS_COMPLETE"
assert obj["starting_sha"] == sys.argv[2]
assert obj["new_sha"] == sys.argv[3]
assert isinstance(obj["tests_passed"], int) and not isinstance(obj["tests_passed"], bool) and obj["tests_passed"] > 0
assert isinstance(obj["focused_tests"], str) and obj["focused_tests"].strip()
assert isinstance(obj["diff_stat"], str) and obj["diff_stat"].strip()
assert obj["timer"] == "inactive"
assert obj["push_required"] is True
print(json.dumps(obj, indent=2, ensure_ascii=False, sort_keys=True))
PY

cat > "$EVIDENCE/gate-prompt.md" <<EOF_GATE
You are the independent read-only Gate for Zoe Coder Router issue #18 / draft PR #19.

Review the exact branch and SHA currently checked out:
- branch: $BRANCH
- exact SHA: $NEW_SHA
- baseline: $START_SHA

Mandatory rules:
- do not modify any file, index, ref, branch, configuration, database or systemd state
- do not commit, push, reset, checkout, merge or rebase
- verify the worktree is clean before and after review
- review the complete diff $START_SHA..$NEW_SHA against every acceptance criterion in issue #18
- independently run focused tests, the full pytest suite, compileall, git diff --check, and inspect the isolated scheduler canary coverage
- verify the 4+2 planner, plan-before-dispatch barrier, global wake lease/orphan recovery, durable prompt fsync/symlink rejection, native CAS requeue backup/audit, and exact-SHA independent gate contract
- confirm the reconciler timer remains inactive

Only return PASS when there are no material correctness, concurrency, durability, security, test, or contract findings. If any finding exists, return a JSON object with gate_status FAIL and concise findings; do not edit the code.

Your final non-empty output line must be exactly this JSON object when approved, with no Markdown fences and nothing after it:
{"gate_status":"PASS"}
EOF_GATE
sudo install -m 0640 -o root -g zoe-coders "$EVIDENCE/gate-prompt.md" "$GATE_PROMPT"
GATE_PROMPT_SHA="$(sudo sha256sum "$GATE_PROMPT" | awk '{print $1}')"

GATE_JOB_ID="$(router submit \
  --project zoe-coder-router \
  --repo "$WORKTREE" \
  --worktree "$WORKTREE" \
  --branch "$BRANCH" \
  --issue 18 \
  --mission "ZCR19_GATE_$NEW_SHA" \
  --task-type gate \
  --mode read_only \
  --prompt-file "$GATE_PROMPT" \
  --coder "$GATE" \
  --priority 100 \
  --max-attempts 1 \
  --no-fallback \
  --idempotency-key "ZCR19-REMOTE-GATE-V35-$NEW_SHA-$GATE_PROMPT_SHA")"
[[ "$GATE_JOB_ID" =~ ^[0-9a-f-]{36}$ ]] || fail GATE_SUBMIT_INVALID "$GATE_JOB_ID"
echo "$GATE_JOB_ID" > "$EVIDENCE/gate-job-id.txt"

set +e
router execute "$GATE_JOB_ID" > "$EVIDENCE/gate-execute.stdout.log" 2> "$EVIDENCE/gate-execute.stderr.log"
GATE_RC=$?
set -e
router show "$GATE_JOB_ID" > "$EVIDENCE/gate-show.json"
[[ "$GATE_RC" -eq 0 ]] || fail GATE_EXECUTION_FAILED "rc=$GATE_RC"
[[ "$(job_field "$EVIDENCE/gate-show.json" status)" == "succeeded" ]] ||
  fail GATE_JOB_NOT_SUCCEEDED "status=$(job_field "$EVIDENCE/gate-show.json" status)"
[[ "$(job_field "$EVIDENCE/gate-show.json" selected_coder)" == "$GATE" ]] ||
  fail GATE_PROFILE_MISMATCH "$(job_field "$EVIDENCE/gate-show.json" selected_coder)"

GATE_STDOUT="$(job_field "$EVIDENCE/gate-show.json" stdout_path)"
GATE_RESULT="$(job_field "$EVIDENCE/gate-show.json" result_path)"
copy_router_artifact "$GATE_STDOUT" "$EVIDENCE/gate-router-stdout.jsonl"
copy_router_artifact "$GATE_RESULT" "$EVIDENCE/gate-router-result.json"
python3 - "$EVIDENCE/gate-router-stdout.jsonl" <<'PY' > "$EVIDENCE/gate-terminal-object.json"
import json, sys
lines=[line.strip() for line in open(sys.argv[1], encoding="utf-8", errors="replace") if line.strip()]
obj=json.loads(lines[-1])
assert obj == {"gate_status":"PASS"}, obj
print(json.dumps(obj, indent=2, sort_keys=True))
PY

[[ "$(git -C "$WORKTREE" rev-parse HEAD)" == "$NEW_SHA" ]] || fail GATE_CHANGED_SHA "HEAD mudou"
[[ -z "$(git -C "$WORKTREE" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail GATE_READ_ONLY_VIOLATION "worktree alterada"
git -C "$WORKTREE" fetch -q origin "$BRANCH"
[[ "$(git -C "$WORKTREE" rev-parse "origin/$BRANCH")" == "$NEW_SHA" ]] ||
  fail GATE_ORIGIN_SHA_MISMATCH "origin divergiu"

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail TIMER_CHANGED "timer foi alterado"
[[ "$(active_units)" -eq 0 ]] || fail ACTIVE_UNITS_AFTER_RUN "há units ativas"
[[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$EXPECTED_RUNTIME_SHA256" ]] ||
  fail RUNTIME_CHANGED "runtime alterado"
[[ "$(sudo sha256sum "$CONFIG" | awk '{print $1}')" == "$EXPECTED_CONFIG_SHA256" ]] ||
  fail CONFIG_CHANGED "config alterada"
DB_SHA_AFTER="$(sudo sha256sum "$DB" | awk '{print $1}')"
printf '%s\n' "$DB_SHA_AFTER" > "$EVIDENCE/db-sha-after.txt"

(
  cd "$EVIDENCE"
  sha256sum \
    writer-prompt.md gate-prompt.md \
    writer-show.json gate-show.json \
    writer-router-stdout.jsonl writer-router-result.json writer-terminal-object.json \
    gate-router-stdout.jsonl gate-router-result.json gate-terminal-object.json \
    > SHA256SUMS
)

cat <<EOF_RESULT
OPERACAO_ZCR19_REMOTE_WRITER_GATE: PASS
WRITER_JOB_ID=$WRITER_JOB_ID
GATE_JOB_ID=$GATE_JOB_ID
START_SHA=$START_SHA
NEW_SHA=$NEW_SHA
BRANCH=$BRANCH
WRITER_PROFILE=$WRITER
GATE_PROFILE=$GATE
WRITER_COMMIT_COUNT=1
WRITER_PUSH=PASS
GATE_EXACT_SHA=$NEW_SHA
GATE_READ_ONLY=PASS
RUNTIME_CHANGED=false
CONFIG_CHANGED=false
DB_SHA256_BEFORE=$DB_SHA_BEFORE
DB_SHA256_AFTER=$DB_SHA_AFTER
TIMER=inactive
ACTIVE_UNITS=0
DB_BACKUP=$BACKUP/runtime.db.before
EVIDENCE_DIR=$EVIDENCE
NEXT_PHASE=ZCR19_GATE_EVIDENCE_AND_PR_UPDATE
EOF_RESULT
