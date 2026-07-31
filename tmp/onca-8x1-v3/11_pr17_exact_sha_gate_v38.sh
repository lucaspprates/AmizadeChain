#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

RUNTIME="/usr/local/lib/zoe-coder-router/zoe_coder_router.py"
CONFIG="/etc/zoe-coder-router/config.toml"
DB="/var/lib/zoe-coder-router/runtime.db"
BRIDGE="/usr/local/bin/onca-codex-remote"
SOURCE_WORKTREE="/home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler"
TARGET_BRANCH="fix/16-opencode-result-provenance"
BASE_SHA="b705b03cdcc04bdd0d43df0f514f196f9a012430"
TARGET_SHA="31b2a8811cf931a5b4e155b30a3cb79927e1111c"
GATE="codex_terra_remote_gate"
EXPECTED_RUNTIME_SHA256="f181fd627dceff10d46d23598eb54d8cfb5a15b070231aa34b4c09e907fc7d85"
EXPECTED_CONFIG_SHA256="3af46a9069e406a75b8e3e66368fa3a2c688711616bc86a5df12d9e4135595e4"
EXPECTED_BRIDGE_SHA256="4d37ed3baba38dc5d35ac9e11928dd0969dd5e7fbdf3c0f4c3e4af2acafdd4b6"
WORKER_HOST="201.23.86.157"
WORKER_USER="ubuntu"
SSH_KEY="/home/ubuntu/.ssh/ssh-key-2026-06-03.key"
KNOWN_HOSTS="/home/ubuntu/.ssh/known_hosts_onca_8x1"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="/tmp/evidence/zcr17-exact-sha-gate-${STAMP}"
BACKUP="/var/backups/zoe-coder-router/zcr17-exact-sha-gate-${STAMP}"
TEMP_WORKTREE="/tmp/onca-zcr17-gate-worktree-${STAMP}"
TEMP_BRANCH="onca/zcr17-gate-${STAMP}"
PROMPT_ROOT="/var/lib/zoe-coder-router/prompts/ZCR17"
GATE_PROMPT="$PROMPT_ROOT/gate-${STAMP}.md"
GATE_JOB_ID=""
mkdir -p "$EVIDENCE"

fail() {
  local code="$1"; shift
  echo "ERRO: $*" >&2
  echo "OPERACAO_ZCR17_EXACT_SHA_GATE: BLOCKED"
  echo "FAILURE_CODE=$code"
  [[ -n "$GATE_JOB_ID" ]] && echo "GATE_JOB_ID=$GATE_JOB_ID"
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

cleanup_temp_worktree() {
  set +e
  if [[ -e "$TEMP_WORKTREE/.git" || -d "$TEMP_WORKTREE" ]]; then
    git -C "$SOURCE_WORKTREE" worktree remove --force "$TEMP_WORKTREE" >/dev/null 2>&1
  fi
  if git -C "$SOURCE_WORKTREE" show-ref --verify --quiet "refs/heads/$TEMP_BRANCH"; then
    git -C "$SOURCE_WORKTREE" branch -D "$TEMP_BRANCH" >/dev/null 2>&1
  fi
  set -e
}
trap cleanup_temp_worktree EXIT

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
[[ -d "$SOURCE_WORKTREE" ]] || fail SOURCE_WORKTREE_MISSING "$SOURCE_WORKTREE"
[[ -z "$(git -C "$SOURCE_WORKTREE" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail SOURCE_WORKTREE_NOT_CLEAN "PR19 worktree está suja"

SSH=(ssh -i "$SSH_KEY" -o BatchMode=yes -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=20
  "${WORKER_USER}@${WORKER_HOST}")

set +e
"${SSH[@]}" "sudo -n -u onca-runner -H bash -s" <<'REMOTE' 2>&1 | tee "$EVIDENCE/worker-preflight.log"
set -Eeuo pipefail
python3 -m pytest --version
rg --version | head -1
codex --version
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
git init -q
git config user.name onca-auth-check
git config user.email onca-auth-check@invalid.local
codex exec \
  --json \
  --ephemeral \
  --dangerously-bypass-approvals-and-sandbox \
  --skip-git-repo-check \
  --cd "$TMP" \
  --model gpt-5.6-terra \
  -c 'features.plugins=false' \
  -c 'model_reasoning_effort="high"' \
  'Do not create or modify files. Reply with exactly AUTH_OK.' \
  | tee "$TMP/auth.jsonl"
grep -Fq '"text":"AUTH_OK"' "$TMP/auth.jsonl"
echo WORKER_AUTH_INFERENCE=PASS
REMOTE
WORKER_PREFLIGHT_RC=${PIPESTATUS[0]}
set -e
[[ "$WORKER_PREFLIGHT_RC" -eq 0 ]] || fail WORKER_PREFLIGHT_FAILED "rc=$WORKER_PREFLIGHT_RC"
grep -Fq 'WORKER_AUTH_INFERENCE=PASS' "$EVIDENCE/worker-preflight.log" ||
  fail WORKER_AUTH_INFERENCE_MISSING "AUTH_OK não comprovado"

# Create a disposable local branch/worktree at PR17 exact SHA. No remote branch is created.
git -C "$SOURCE_WORKTREE" fetch -q origin "$TARGET_BRANCH"
REMOTE_TARGET_SHA="$(git -C "$SOURCE_WORKTREE" rev-parse "origin/$TARGET_BRANCH")"
[[ "$REMOTE_TARGET_SHA" == "$TARGET_SHA" ]] || fail ORIGIN_TARGET_SHA_MISMATCH "$REMOTE_TARGET_SHA"
git -C "$SOURCE_WORKTREE" cat-file -e "$BASE_SHA^{commit}" || fail BASE_SHA_MISSING "$BASE_SHA"
git -C "$SOURCE_WORKTREE" worktree add -q -b "$TEMP_BRANCH" "$TEMP_WORKTREE" "$TARGET_SHA"
[[ "$(git -C "$TEMP_WORKTREE" rev-parse HEAD)" == "$TARGET_SHA" ]] || fail TEMP_HEAD_MISMATCH
[[ "$(git -C "$TEMP_WORKTREE" branch --show-current)" == "$TEMP_BRANCH" ]] || fail TEMP_BRANCH_MISMATCH
[[ -z "$(git -C "$TEMP_WORKTREE" status --porcelain=v1 --untracked-files=all)" ]] || fail TEMP_WORKTREE_NOT_CLEAN

git -C "$TEMP_WORKTREE" merge-base --is-ancestor "$BASE_SHA" "$TARGET_SHA" ||
  fail TARGET_NOT_DESCENDANT_OF_BASE "$TARGET_SHA"

set +e
sudo -u ubuntu -g zoe-coders -H -- python3 - "$DB" <<'PY' > "$EVIDENCE/active-zcr17-jobs.json"
import json, sqlite3, sys
conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
conn.row_factory = sqlite3.Row
rows = conn.execute(
    """
    SELECT id,mission_id,status,selected_coder,mode
    FROM jobs
    WHERE (mission_id='ZCR17' OR mission_id LIKE 'ZCR17_%')
      AND status IN ('awaiting_receipt','awaiting_capacity_plan','queued','dispatching','running')
    ORDER BY created_at
    """
).fetchall()
print(json.dumps([dict(row) for row in rows], indent=2, ensure_ascii=False))
if rows:
    raise SystemExit(1)
PY
ACTIVE_RC=$?
set -e
[[ "$ACTIVE_RC" -eq 0 ]] || fail ACTIVE_ZCR17_JOB_PRESENT "consulte active-zcr17-jobs.json"

sudo python3 - "$DB" "$BACKUP/runtime.db.before" <<'PY'
import sqlite3, sys
source = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
target = sqlite3.connect(sys.argv[2])
source.backup(target)
target.close(); source.close()
PY
DB_SHA_BEFORE="$(sudo sha256sum "$DB" | awk '{print $1}')"

cat > "$EVIDENCE/gate-prompt.md" <<EOF_GATE
You are the independent read-only Gate for Zoe Coder Router issue #16 / draft PR #17.

Immutable review target:
- repository: lucaspprates/Zoe-Coder-Router
- base SHA: $BASE_SHA
- exact head SHA: $TARGET_SHA
- remote branch: $TARGET_BRANCH

Rules:
- do not modify files, index, refs, configuration, database, credentials or systemd
- do not commit, push, reset, checkout, merge or rebase
- verify HEAD is exactly $TARGET_SHA and the worktree is clean before and after review
- review the complete diff $BASE_SHA..$TARGET_SHA
- the production control plane already proved its reconciler timer is inactive; do not fail because this disposable worker has no production timer unit

Acceptance checks:
1. Provenance is observability only and does not alter routing, provider/model selection, fallback behavior or --no-fallback enforcement.
2. resolved_model_id is emitted only from exactly one sanitized structured identifier; absent, conflicting, malformed, unsafe or credential-like values fail closed.
3. fallback_used becomes true/false only from an explicit JSON boolean in the approved keys; textual markers, numeric values, configured preferences and exit code never prove fallback.
4. provenance_state is complete only when both model and explicit fallback evidence are present.
5. Result, events, terminal receipt, status and public-status surfaces expose only the intended sanitized/aggregated fields and never raw stdout, prompts, tokens or credentials.
6. SQLite migrations are additive and old ledgers remain readable through row_value compatibility.
7. Non-OpenCode adapters remain fail-closed and any behavior restriction is documented.
8. Tests cover valid, absent, conflicting, malformed, truncated, unsafe and credential-like evidence, plus no-fallback policy separation and terminal smoke behavior.

Run independently:
- PYTHONDONTWRITEBYTECODE=1 python3 -B -m pytest -q tests/test_opencode_result_provenance.py tests/test_opencode_terminal_result_smoke.py
- PYTHONDONTWRITEBYTECODE=1 python3 -B -m pytest -q
- PYTHONDONTWRITEBYTECODE=1 python3 -B -m compileall -q src tests
- git diff --check $BASE_SHA..$TARGET_SHA

Only return PASS if there are no material correctness, security, privacy, compatibility, test or contract findings. If any finding exists, return gate_status FAIL with concise findings. Do not edit the repository.

Your final non-empty output line must be one JSON object with no Markdown fences and no output after it:
{"gate_status":"PASS"}
EOF_GATE
sudo install -m 0640 -o root -g zoe-coders "$EVIDENCE/gate-prompt.md" "$GATE_PROMPT"
GATE_PROMPT_SHA="$(sudo sha256sum "$GATE_PROMPT" | awk '{print $1}')"

GATE_JOB_ID="$(router submit \
  --project zoe-coder-router \
  --repo "$TEMP_WORKTREE" \
  --worktree "$TEMP_WORKTREE" \
  --branch "$TARGET_SHA" \
  --issue 16 \
  --mission "ZCR17_GATE_$TARGET_SHA" \
  --task-type gate \
  --mode read_only \
  --prompt-file "$GATE_PROMPT" \
  --coder "$GATE" \
  --priority 100 \
  --max-attempts 1 \
  --no-fallback \
  --idempotency-key "ZCR17-EXACT-SHA-GATE-V38-$TARGET_SHA-$GATE_PROMPT_SHA")"
[[ "$GATE_JOB_ID" =~ ^[0-9a-f-]{36}$ ]] || fail GATE_SUBMIT_INVALID "$GATE_JOB_ID"
echo "$GATE_JOB_ID" > "$EVIDENCE/gate-job-id.txt"

set +e
router execute "$GATE_JOB_ID" > "$EVIDENCE/gate-execute.stdout.log" 2> "$EVIDENCE/gate-execute.stderr.log"
GATE_RC=$?
set -e
router show "$GATE_JOB_ID" > "$EVIDENCE/gate-show.json"

BRIDGE_RESULT="/var/log/zoe-coder-router/remote/$GATE_JOB_ID/result.json"
if sudo test -f "$BRIDGE_RESULT"; then
  sudo cp "$BRIDGE_RESULT" "$EVIDENCE/gate-bridge-result.json"
  sudo chown ubuntu:ubuntu "$EVIDENCE/gate-bridge-result.json"
  chmod 0600 "$EVIDENCE/gate-bridge-result.json"
fi

if [[ "$GATE_RC" -ne 0 ]]; then
  if [[ -f "$EVIDENCE/gate-bridge-result.json" ]]; then
    python3 - "$EVIDENCE/gate-bridge-result.json" <<'PY' | tee "$EVIDENCE/gate-terminal-readable.json"
import json, sys
value=json.load(open(sys.argv[1],encoding='utf-8'))
terminal=value.get('terminal_object')
print(json.dumps(terminal,indent=2,ensure_ascii=False,sort_keys=True))
if isinstance(terminal,dict) and terminal.get('gate_status') == 'FAIL':
    raise SystemExit(10)
raise SystemExit(11)
PY
    CLASSIFY_RC=${PIPESTATUS[0]}
    [[ "$CLASSIFY_RC" -ne 10 ]] || fail GATE_REJECTED "findings em gate-terminal-readable.json"
  fi
  fail GATE_EXECUTION_FAILED "rc=$GATE_RC"
fi

[[ "$(job_field "$EVIDENCE/gate-show.json" status)" == "succeeded" ]] ||
  fail GATE_JOB_NOT_SUCCEEDED "status=$(job_field "$EVIDENCE/gate-show.json" status)"
[[ "$(job_field "$EVIDENCE/gate-show.json" selected_coder)" == "$GATE" ]] ||
  fail GATE_PROFILE_MISMATCH "$(job_field "$EVIDENCE/gate-show.json" selected_coder)"

GATE_STDOUT="$(job_field "$EVIDENCE/gate-show.json" stdout_path)"
GATE_STDERR="$(job_field "$EVIDENCE/gate-show.json" stderr_path)"
GATE_RESULT="$(job_field "$EVIDENCE/gate-show.json" result_path)"
copy_router_artifact "$GATE_STDOUT" "$EVIDENCE/gate-router-stdout.jsonl"
copy_router_artifact "$GATE_STDERR" "$EVIDENCE/gate-router-stderr.log"
copy_router_artifact "$GATE_RESULT" "$EVIDENCE/gate-router-result.json"
[[ -f "$EVIDENCE/gate-bridge-result.json" ]] || fail BRIDGE_RESULT_MISSING "$BRIDGE_RESULT"

python3 - "$EVIDENCE/gate-bridge-result.json" <<'PY' > "$EVIDENCE/gate-terminal-object.json"
import json, sys
value=json.load(open(sys.argv[1],encoding='utf-8'))
terminal=value.get('terminal_object')
assert terminal == {'gate_status':'PASS'}, terminal
assert value.get('start_sha') == '31b2a8811cf931a5b4e155b30a3cb79927e1111c', value.get('start_sha')
assert value.get('head_sha') == '31b2a8811cf931a5b4e155b30a3cb79927e1111c', value.get('head_sha')
assert value.get('worktree_clean') is True
assert value.get('mode') == 'read_only'
print(json.dumps(terminal,indent=2,sort_keys=True))
PY

[[ "$(git -C "$TEMP_WORKTREE" rev-parse HEAD)" == "$TARGET_SHA" ]] || fail GATE_CHANGED_SHA
[[ -z "$(git -C "$TEMP_WORKTREE" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail GATE_READ_ONLY_VIOLATION "worktree temporária alterada"
[[ -z "$(git -C "$SOURCE_WORKTREE" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail SOURCE_WORKTREE_CHANGED "PR19 worktree alterada"
[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] || fail TIMER_CHANGED
[[ "$(active_units)" -eq 0 ]] || fail ACTIVE_UNITS_AFTER_GATE
[[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$EXPECTED_RUNTIME_SHA256" ]] || fail RUNTIME_CHANGED
[[ "$(sudo sha256sum "$CONFIG" | awk '{print $1}')" == "$EXPECTED_CONFIG_SHA256" ]] || fail CONFIG_CHANGED
[[ "$(sha256sum "$BRIDGE" | awk '{print $1}')" == "$EXPECTED_BRIDGE_SHA256" ]] || fail BRIDGE_CHANGED
DB_SHA_AFTER="$(sudo sha256sum "$DB" | awk '{print $1}')"

(
  cd "$EVIDENCE"
  sha256sum \
    worker-preflight.log gate-prompt.md gate-show.json \
    gate-router-stdout.jsonl gate-router-stderr.log gate-router-result.json \
    gate-bridge-result.json gate-terminal-object.json \
    > SHA256SUMS
)

cleanup_temp_worktree
trap - EXIT
[[ ! -e "$TEMP_WORKTREE" ]] || fail TEMP_WORKTREE_CLEANUP_FAILED "$TEMP_WORKTREE"
if git -C "$SOURCE_WORKTREE" show-ref --verify --quiet "refs/heads/$TEMP_BRANCH"; then
  fail TEMP_BRANCH_CLEANUP_FAILED "$TEMP_BRANCH"
fi

cat <<EOF
OPERACAO_ZCR17_EXACT_SHA_GATE: PASS
PR=17
BASE_SHA=$BASE_SHA
GATE_EXACT_SHA=$TARGET_SHA
GATE_JOB_ID=$GATE_JOB_ID
GATE_PROFILE=$GATE
GATE_STATUS=PASS
GATE_READ_ONLY=PASS
FOCUSED_PYTEST=PASS
FULL_PYTEST=PASS
WORKER_AUTH_INFERENCE=PASS
TEMP_WORKTREE_REMOVED=true
SOURCE_WORKTREE_CHANGED=false
RUNTIME_CHANGED=false
CONFIG_CHANGED=false
BRIDGE_CHANGED=false
DB_SHA256_BEFORE=$DB_SHA_BEFORE
DB_SHA256_AFTER=$DB_SHA_AFTER
TIMER=inactive
ACTIVE_UNITS=0
DB_BACKUP=$BACKUP/runtime.db.before
EVIDENCE_DIR=$EVIDENCE
NEXT_PHASE=PR17_EVIDENCE_AND_STACK_INTEGRATION
EOF
