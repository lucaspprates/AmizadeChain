#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

RUNTIME="/usr/local/lib/zoe-coder-router/zoe_coder_router.py"
CONFIG="/etc/zoe-coder-router/config.toml"
DB="/var/lib/zoe-coder-router/runtime.db"
BRIDGE="/usr/local/bin/onca-codex-remote"
BRIDGE_CONF="/etc/zoe-coder-router/onca-worker.conf"
WORKTREE="/home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler"
BRANCH="type/18-factory-scheduler-maintenance"
BASE_SHA="d80ed678333dc70d1b92479a821bf2d1467c4424"
START_SHA="fc2329960d2dffb301b9ad1bde9f7ea5b4789795"
WRITER="codex_terra_remote_writer_yolo"
GATE="codex_terra_remote_gate"
EXPECTED_RUNTIME_SHA256="f181fd627dceff10d46d23598eb54d8cfb5a15b070231aa34b4c09e907fc7d85"
EXPECTED_CONFIG_SHA256="3af46a9069e406a75b8e3e66368fa3a2c688711616bc86a5df12d9e4135595e4"
EXPECTED_BRIDGE_SHA256="4d37ed3baba38dc5d35ac9e11928dd0969dd5e7fbdf3c0f4c3e4af2acafdd4b6"
WORKER_HOST="201.23.86.157"
WORKER_USER="ubuntu"
SSH_KEY="/home/ubuntu/.ssh/ssh-key-2026-06-03.key"
KNOWN_HOSTS="/home/ubuntu/.ssh/known_hosts_onca_8x1"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="/tmp/evidence/zcr19-symlink-fix-gate-${STAMP}"
BACKUP="/var/backups/zoe-coder-router/zcr19-symlink-fix-gate-${STAMP}"
PROMPT_ROOT="/var/lib/zoe-coder-router/prompts/ZCR19"
WRITER_PROMPT="$PROMPT_ROOT/symlink-fix-writer-${STAMP}.md"
GATE_PROMPT="$PROMPT_ROOT/symlink-fix-gate-${STAMP}.md"
mkdir -p "$EVIDENCE"

fail() {
  local code="$1"
  shift
  echo "ERRO: $*" >&2
  echo "OPERACAO_ZCR19_SYMLINK_FIX_GATE: BLOCKED"
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

copy_router_artifact() {
  local source="$1" target="$2"
  sudo test -f "$source" || fail ROUTER_ARTIFACT_MISSING "$source"
  sudo cp "$source" "$target"
  sudo chown ubuntu:ubuntu "$target"
  chmod 0600 "$target"
}

extract_gate_terminal() {
  local bridge_result="$1" output="$2"
  python3 - "$bridge_result" "$output" <<'PY'
import json, sys
source, output = sys.argv[1:]
value = json.load(open(source, encoding="utf-8"))
terminal = value.get("terminal_object")
with open(output, "w", encoding="utf-8") as fh:
    json.dump(terminal, fh, indent=2, ensure_ascii=False, sort_keys=True)
    fh.write("\n")
print(json.dumps(terminal, ensure_ascii=False, sort_keys=True))
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
bash -n "$BRIDGE"
sudo -u ubuntu -g zoe-coders test -r "$BRIDGE_CONF" || fail BRIDGE_CONFIG_UNREADABLE "$BRIDGE_CONF"

[[ -d "$WORKTREE/.git" || -f "$WORKTREE/.git" ]] || fail WORKTREE_MISSING "$WORKTREE"
[[ "$(git -C "$WORKTREE" branch --show-current)" == "$BRANCH" ]] ||
  fail BRANCH_MISMATCH "$(git -C "$WORKTREE" branch --show-current)"
[[ "$(git -C "$WORKTREE" rev-parse HEAD)" == "$START_SHA" ]] ||
  fail START_SHA_MISMATCH "$(git -C "$WORKTREE" rev-parse HEAD)"
[[ -z "$(git -C "$WORKTREE" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail WORKTREE_NOT_CLEAN "worktree possui alterações"

git -C "$WORKTREE" fetch -q origin "$BRANCH"
[[ "$(git -C "$WORKTREE" rev-parse "origin/$BRANCH")" == "$START_SHA" ]] ||
  fail ORIGIN_SHA_MISMATCH "$(git -C "$WORKTREE" rev-parse "origin/$BRANCH")"

SSH=(ssh -i "$SSH_KEY" -o BatchMode=yes -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=20
  "${WORKER_USER}@${WORKER_HOST}")
set +e
"${SSH[@]}" "sudo -n -u onca-runner -H bash -s" <<'REMOTE' | tee "$EVIDENCE/worker-toolchain-readback.log"
set -Eeuo pipefail
cd /
python3 -m pytest --version
rg --version | head -1
codex --version
codex login status
REMOTE
WORKER_READBACK_RC=${PIPESTATUS[0]}
set -e
[[ "$WORKER_READBACK_RC" -eq 0 ]] || fail WORKER_TOOLCHAIN_READBACK_FAILED "rc=$WORKER_READBACK_RC"

grep -Fq 'pytest ' "$EVIDENCE/worker-toolchain-readback.log" || fail WORKER_PYTEST_UNAVAILABLE "pytest ausente"
grep -Fq 'ripgrep ' "$EVIDENCE/worker-toolchain-readback.log" || fail WORKER_RG_UNAVAILABLE "ripgrep ausente"
grep -Fq 'Logged in using ChatGPT' "$EVIDENCE/worker-toolchain-readback.log" || fail WORKER_CODEX_NOT_AUTHENTICATED "Codex sem login"

set +e
sudo -u ubuntu -g zoe-coders -H -- python3 - "$DB" <<'PY' > "$EVIDENCE/active-zcr19-jobs.json"
import json, sqlite3, sys
conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
conn.row_factory = sqlite3.Row
rows = conn.execute(
    """
    SELECT id,mission_id,status,selected_coder,mode
    FROM jobs
    WHERE (mission_id='ZCR19' OR mission_id LIKE 'ZCR19_%')
      AND status IN ('awaiting_receipt','awaiting_capacity_plan','queued','dispatching','running')
    ORDER BY created_at
    """
).fetchall()
print(json.dumps([dict(row) for row in rows], indent=2, ensure_ascii=False))
if rows:
    raise SystemExit(1)
PY
ACTIVE_ZCR19_RC=$?
set -e
[[ "$ACTIVE_ZCR19_RC" -eq 0 ]] || fail ACTIVE_ZCR19_JOB_PRESENT "consulte active-zcr19-jobs.json"

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
You are the admitted follow-up Writer for Zoe Coder Router issue #18 / draft PR #19.

Immutable execution context:
- repository: lucaspprates/Zoe-Coder-Router
- branch: $BRANCH
- current starting SHA: $START_SHA
- original scheduler baseline: $BASE_SHA
- reconciler timer must remain inactive
- work only in the supplied repository
- do not merge, rebase, reset, change branches, push, or touch production runtime/config/database/systemd
- finish with exactly one new commit on top of $START_SHA and a clean worktree

The previous independent Gate returned one material code finding:
"Durable prompt-root validation rejects only the final path, not symlinked parent components; configured prompt directories can still traverse a symlink."

Correction scope:
1. Make durable_prompt_root() reject the configured prompt_dir when any existing path component is a symbolic link, before resolving the path or creating directories through it.
2. Preserve support for a normal absolute or relative non-symlink path, including not-yet-created final components.
3. Reuse or safely reposition has_symlink_component(); do not leave duplicate helpers or broaden scope.
4. Add a focused regression test that constructs a real directory plus a symlinked parent component, configures runtime.prompt_dir through that symlink, proves RouterError mentioning symlink, and proves no prompt directory was created through the symlink.
5. Preserve the existing direct source-symlink test and all scheduler contracts.

Required validation before commit:
- PYTHONDONTWRITEBYTECODE=1 python3 -B -m pytest -q tests/test_factory_scheduler_maintenance.py
- PYTHONDONTWRITEBYTECODE=1 python3 -B -m pytest -q
- PYTHONDONTWRITEBYTECODE=1 python3 -B -m compileall -q src tests
- git diff --check

Create exactly one commit with a clear message. Do not push; the bridge will verify and push.

Your final non-empty output line must be one JSON object, without Markdown fences and with no output after it:
{"terminal_status":"complete","starting_sha":"$START_SHA","new_sha":"<exact 40-char commit SHA>","focused_tests":"<focused pytest PASS summary>","full_tests":"<full pytest PASS summary>","finding_fixed":"symlinked_prompt_dir_parent_component","timer":"inactive"}
EOF_WRITER
sudo install -m 0640 -o root -g zoe-coders "$EVIDENCE/writer-prompt.md" "$WRITER_PROMPT"
WRITER_PROMPT_SHA="$(sudo sha256sum "$WRITER_PROMPT" | awk '{print $1}')"

WRITER_JOB_ID="$(router submit \
  --project zoe-coder-router \
  --repo "$WORKTREE" \
  --worktree "$WORKTREE" \
  --branch "$BRANCH" \
  --issue 18 \
  --mission "ZCR19_SYMLINK_FIX_$START_SHA" \
  --task-type bugfix \
  --mode write \
  --prompt-file "$WRITER_PROMPT" \
  --coder "$WRITER" \
  --priority 100 \
  --max-attempts 1 \
  --no-fallback \
  --idempotency-key "ZCR19-SYMLINK-FIX-V37-$START_SHA-$WRITER_PROMPT_SHA")"
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
WRITER_STDERR="$(job_field "$EVIDENCE/writer-show.json" stderr_path)"
WRITER_RESULT="$(job_field "$EVIDENCE/writer-show.json" result_path)"
copy_router_artifact "$WRITER_STDOUT" "$EVIDENCE/writer-router-stdout.jsonl"
copy_router_artifact "$WRITER_STDERR" "$EVIDENCE/writer-router-stderr.log"
copy_router_artifact "$WRITER_RESULT" "$EVIDENCE/writer-router-result.json"

NEW_SHA="$(git -C "$WORKTREE" rev-parse HEAD)"
[[ "$NEW_SHA" =~ ^[0-9a-f]{40}$ && "$NEW_SHA" != "$START_SHA" ]] ||
  fail WRITER_SHA_INVALID "$NEW_SHA"
[[ "$(git -C "$WORKTREE" branch --show-current)" == "$BRANCH" ]] || fail WRITER_BRANCH_CHANGED "$BRANCH"
[[ -z "$(git -C "$WORKTREE" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail WRITER_WORKTREE_NOT_CLEAN "worktree suja"
[[ "$(git -C "$WORKTREE" rev-list --count "$START_SHA..$NEW_SHA")" -eq 1 ]] ||
  fail WRITER_COMMIT_COUNT_NOT_ONE "$(git -C "$WORKTREE" rev-list --count "$START_SHA..$NEW_SHA")"
git -C "$WORKTREE" merge-base --is-ancestor "$START_SHA" "$NEW_SHA" || fail WRITER_NOT_DESCENDANT "$NEW_SHA"
git -C "$WORKTREE" fetch -q origin "$BRANCH"
[[ "$(git -C "$WORKTREE" rev-parse "origin/$BRANCH")" == "$NEW_SHA" ]] ||
  fail WRITER_ORIGIN_NOT_PUBLISHED "origin divergiu"

git -C "$WORKTREE" diff --check "$START_SHA..$NEW_SHA"
git -C "$WORKTREE" diff --stat "$START_SHA..$NEW_SHA" | tee "$EVIDENCE/writer-diff-stat.txt"
git -C "$WORKTREE" diff --name-only "$START_SHA..$NEW_SHA" | tee "$EVIDENCE/writer-changed-paths.txt"

python3 - "$EVIDENCE/writer-router-stdout.jsonl" "$START_SHA" "$NEW_SHA" <<'PY' > "$EVIDENCE/writer-terminal-object.json"
import json, sys
lines=[line.strip() for line in open(sys.argv[1],encoding="utf-8",errors="replace") if line.strip()]
objects=[]
for line in lines:
    try:
        value=json.loads(line)
    except json.JSONDecodeError:
        continue
    if isinstance(value,dict) and value.get("terminal_status") == "complete":
        objects.append(value)
assert objects, "writer terminal object missing"
obj=objects[-1]
assert obj["starting_sha"] == sys.argv[2]
assert obj["new_sha"] == sys.argv[3]
assert obj["finding_fixed"] == "symlinked_prompt_dir_parent_component"
assert obj["timer"] == "inactive"
assert isinstance(obj.get("focused_tests"),str) and obj["focused_tests"].strip()
assert isinstance(obj.get("full_tests"),str) and obj["full_tests"].strip()
print(json.dumps(obj,indent=2,ensure_ascii=False,sort_keys=True))
PY

cat > "$EVIDENCE/gate-prompt.md" <<EOF_GATE
You are the independent read-only Gate for Zoe Coder Router issue #18 / draft PR #19.

Review the exact current commit:
- exact SHA: $NEW_SHA
- previous reviewed SHA: $START_SHA
- original scheduler baseline: $BASE_SHA

The prior Gate finding to verify is fixed:
- configured runtime.prompt_dir must be rejected when any parent component is a symlink, before resolve/mkdir traversal.

Mandatory rules:
- do not modify files, index, refs, branches, configuration, database or systemd
- do not commit, push, reset, checkout, merge or rebase
- verify the worktree is clean before and after review
- review the full diff $BASE_SHA..$NEW_SHA and the focused correction $START_SHA..$NEW_SHA
- independently run:
  PYTHONDONTWRITEBYTECODE=1 python3 -B -m pytest -q tests/test_factory_scheduler_maintenance.py
  PYTHONDONTWRITEBYTECODE=1 python3 -B -m pytest -q
  PYTHONDONTWRITEBYTECODE=1 python3 -B -m compileall -q src tests
  git diff --check $BASE_SHA..$NEW_SHA
- verify the parent-component symlink regression test is meaningful and fail-closed
- re-evaluate the 4+2 planner, plan-before-dispatch barrier, wake lease/orphan recovery, durable prompts, native CAS requeue, and independent exact-SHA gate contract
- confirm the reconciler timer remains inactive

Return PASS only with no material finding. When approved, your final non-empty output line must be exactly, with no Markdown fences and nothing after it:
{"gate_status":"PASS"}
If a finding remains, return one final JSON object with gate_status FAIL and concise findings; do not edit code.
EOF_GATE
sudo install -m 0640 -o root -g zoe-coders "$EVIDENCE/gate-prompt.md" "$GATE_PROMPT"
GATE_PROMPT_SHA="$(sudo sha256sum "$GATE_PROMPT" | awk '{print $1}')"

GATE_JOB_ID="$(router submit \
  --project zoe-coder-router \
  --repo "$WORKTREE" \
  --worktree "$WORKTREE" \
  --branch "$NEW_SHA" \
  --issue 18 \
  --mission "ZCR19_GATE_R2_$NEW_SHA" \
  --task-type gate \
  --mode read_only \
  --prompt-file "$GATE_PROMPT" \
  --coder "$GATE" \
  --priority 100 \
  --max-attempts 1 \
  --no-fallback \
  --idempotency-key "ZCR19-GATE-R2-V37-$NEW_SHA-$GATE_PROMPT_SHA")"
[[ "$GATE_JOB_ID" =~ ^[0-9a-f-]{36}$ ]] || fail GATE_SUBMIT_INVALID "$GATE_JOB_ID"
echo "$GATE_JOB_ID" > "$EVIDENCE/gate-job-id.txt"

set +e
router execute "$GATE_JOB_ID" > "$EVIDENCE/gate-execute.stdout.log" 2> "$EVIDENCE/gate-execute.stderr.log"
GATE_RC=$?
set -e
router show "$GATE_JOB_ID" > "$EVIDENCE/gate-show.json"

GATE_STDOUT="$(job_field "$EVIDENCE/gate-show.json" stdout_path)"
GATE_STDERR="$(job_field "$EVIDENCE/gate-show.json" stderr_path)"
GATE_RESULT="$(job_field "$EVIDENCE/gate-show.json" result_path)"
[[ -z "$GATE_STDOUT" ]] || copy_router_artifact "$GATE_STDOUT" "$EVIDENCE/gate-router-stdout.jsonl"
[[ -z "$GATE_STDERR" ]] || copy_router_artifact "$GATE_STDERR" "$EVIDENCE/gate-router-stderr.log"
[[ -z "$GATE_RESULT" ]] || copy_router_artifact "$GATE_RESULT" "$EVIDENCE/gate-router-result.json"

BRIDGE_GATE_DIR="/var/log/zoe-coder-router/remote/$GATE_JOB_ID"
if sudo test -f "$BRIDGE_GATE_DIR/result.json"; then
  sudo cp "$BRIDGE_GATE_DIR/result.json" "$EVIDENCE/gate-bridge-result.json"
  sudo chown ubuntu:ubuntu "$EVIDENCE/gate-bridge-result.json"
  chmod 0600 "$EVIDENCE/gate-bridge-result.json"
  GATE_TERMINAL="$(extract_gate_terminal "$EVIDENCE/gate-bridge-result.json" "$EVIDENCE/gate-terminal-object.json")"
else
  GATE_TERMINAL='null'
fi

if [[ "$GATE_RC" -ne 0 ]]; then
  echo "===== GATE TERMINAL OBJECT ====="
  printf '%s\n' "$GATE_TERMINAL" | python3 -m json.tool 2>/dev/null || printf '%s\n' "$GATE_TERMINAL"
  echo "===== GATE STDERR TAIL ====="
  tail -n 160 "$EVIDENCE/gate-router-stderr.log" 2>/dev/null || true
  fail GATE_REJECTED_OR_FAILED "rc=$GATE_RC terminal=$GATE_TERMINAL"
fi

[[ "$(job_field "$EVIDENCE/gate-show.json" status)" == "succeeded" ]] ||
  fail GATE_JOB_NOT_SUCCEEDED "status=$(job_field "$EVIDENCE/gate-show.json" status)"
[[ "$(job_field "$EVIDENCE/gate-show.json" selected_coder)" == "$GATE" ]] ||
  fail GATE_PROFILE_MISMATCH "$(job_field "$EVIDENCE/gate-show.json" selected_coder)"
python3 - "$EVIDENCE/gate-terminal-object.json" <<'PY'
import json, sys
obj=json.load(open(sys.argv[1],encoding="utf-8"))
assert obj == {"gate_status":"PASS"}, obj
PY

[[ "$(git -C "$WORKTREE" rev-parse HEAD)" == "$NEW_SHA" ]] || fail GATE_CHANGED_SHA "HEAD mudou"
[[ "$(git -C "$WORKTREE" branch --show-current)" == "$BRANCH" ]] || fail GATE_CHANGED_BRANCH "branch mudou"
[[ -z "$(git -C "$WORKTREE" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail GATE_READ_ONLY_VIOLATION "worktree alterada"
git -C "$WORKTREE" fetch -q origin "$BRANCH"
[[ "$(git -C "$WORKTREE" rev-parse "origin/$BRANCH")" == "$NEW_SHA" ]] ||
  fail GATE_ORIGIN_SHA_MISMATCH "origin divergiu"

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail TIMER_CHANGED "timer foi alterado"
[[ "$(active_units)" -eq 0 ]] || fail ACTIVE_UNITS_AFTER_RUN "há units ativas"
[[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$EXPECTED_RUNTIME_SHA256" ]] || fail RUNTIME_CHANGED "runtime alterado"
[[ "$(sudo sha256sum "$CONFIG" | awk '{print $1}')" == "$EXPECTED_CONFIG_SHA256" ]] || fail CONFIG_CHANGED "config alterada"
[[ "$(sha256sum "$BRIDGE" | awk '{print $1}')" == "$EXPECTED_BRIDGE_SHA256" ]] || fail BRIDGE_CHANGED "bridge alterado"
DB_SHA_AFTER="$(sudo sha256sum "$DB" | awk '{print $1}')"
printf '%s\n' "$DB_SHA_AFTER" > "$EVIDENCE/db-sha-after.txt"

(
  cd "$EVIDENCE"
  find . -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)

cat <<EOF_RESULT
OPERACAO_ZCR19_SYMLINK_FIX_GATE: PASS
WRITER_JOB_ID=$WRITER_JOB_ID
GATE_JOB_ID=$GATE_JOB_ID
BASE_SHA=$BASE_SHA
START_SHA=$START_SHA
NEW_SHA=$NEW_SHA
BRANCH=$BRANCH
WRITER_PROFILE=$WRITER
GATE_PROFILE=$GATE
WRITER_COMMIT_COUNT=1
WRITER_PUSH=PASS
FINDING_FIXED=symlinked_prompt_dir_parent_component
PYTEST_WORKER=PASS
GATE_EXACT_SHA=$NEW_SHA
GATE_READ_ONLY=PASS
GATE_STATUS=PASS
RUNTIME_CHANGED=false
CONFIG_CHANGED=false
BRIDGE_CHANGED=false
DB_SHA256_BEFORE=$DB_SHA_BEFORE
DB_SHA256_AFTER=$DB_SHA_AFTER
TIMER=inactive
ACTIVE_UNITS=0
DB_BACKUP=$BACKUP/runtime.db.before
EVIDENCE_DIR=$EVIDENCE
NEXT_PHASE=ZCR19_EXACT_SHA_GATE_EVIDENCE_AND_PR_UPDATE
EOF_RESULT
