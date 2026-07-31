#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

RUNTIME="/usr/local/lib/zoe-coder-router/zoe_coder_router.py"
CONFIG="/etc/zoe-coder-router/config.toml"
PROD_DB="/var/lib/zoe-coder-router/runtime.db"
BRIDGE="/usr/local/bin/onca-codex-remote"
BRIDGE_CONF="/etc/zoe-coder-router/onca-worker.conf"

EXPECTED_RUNTIME_SHA256="f181fd627dceff10d46d23598eb54d8cfb5a15b070231aa34b4c09e907fc7d85"
EXPECTED_CONFIG_SHA256="3af46a9069e406a75b8e3e66368fa3a2c688711616bc86a5df12d9e4135595e4"
EXPECTED_PROD_DB_SHA256="b0ab9b08edc54cf6ba3d1f60aaef9ae93fea3392d01f55a40275776e7b119374"
EXPECTED_BRIDGE_SHA256="4d37ed3baba38dc5d35ac9e11928dd0969dd5e7fbdf3c0f4c3e4af2acafdd4b6"

WRITER="codex_terra_remote_writer_yolo"
GATE="codex_terra_remote_gate"
PROJECT="infranetwork"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
MISSION="ONCA_ROUTER_CANARY_${STAMP}"
ISSUE="ONCA-CANARY-${STAMP}"
BRANCH="onca/router-writer-gate-${STAMP}"
EVIDENCE="/tmp/evidence/onca-router-writer-gate-${STAMP}"
CANARY_CONFIG="$EVIDENCE/config.canary.toml"
CANARY_STATE="$EVIDENCE/state"
CANARY_LOGS="$EVIDENCE/router-logs"
CANARY_DB="$CANARY_STATE/runtime.db"
ORIGIN="$EVIDENCE/origin.git"
REPO="$EVIDENCE/repo"
WRITER_PROMPT="$EVIDENCE/writer.prompt.md"
GATE_PROMPT="$EVIDENCE/gate.prompt.md"

active_units() {
  systemctl list-units \
    'zoe-coder-job@*.service' \
    'zoe-coder-wake@*.service' \
    --state=active,activating \
    --no-legend --no-pager 2>/dev/null |
    wc -l
}

fail() {
  local code="$1"
  shift
  trap - ERR
  echo "ERRO: $*" >&2
  echo "OPERACAO_ONCA_ROUTER_WRITER_GATE_CANARY: BLOCKED"
  echo "FAILURE_CODE=$code"
  echo "EVIDENCE_DIR=$EVIDENCE"
  exit 1
}

unexpected_error() {
  local rc=$?
  trap - ERR
  echo "OPERACAO_ONCA_ROUTER_WRITER_GATE_CANARY: BLOCKED" >&2
  echo "FAILURE_CODE=UNEXPECTED_ERROR_RC_${rc}" >&2
  echo "EVIDENCE_DIR=$EVIDENCE" >&2
  exit "$rc"
}
trap unexpected_error ERR

[[ "$(id -un)" == "ubuntu" ]] || fail USER_MISMATCH "execute como ubuntu"
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail HOST_MISMATCH "execute na Zoe de produção"
sudo -v
mkdir -p "$EVIDENCE" "$CANARY_STATE" "$CANARY_LOGS"

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail TIMER_NOT_INACTIVE "reconciler não está congelado"
[[ "$(active_units)" -eq 0 ]] || fail ACTIVE_UNITS_PRESENT "há units de job/wake ativas"
[[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$EXPECTED_RUNTIME_SHA256" ]] ||
  fail RUNTIME_SHA_MISMATCH "runtime divergente"
[[ "$(sudo sha256sum "$CONFIG" | awk '{print $1}')" == "$EXPECTED_CONFIG_SHA256" ]] ||
  fail CONFIG_SHA_MISMATCH "config divergente"
[[ "$(sudo sha256sum "$PROD_DB" | awk '{print $1}')" == "$EXPECTED_PROD_DB_SHA256" ]] ||
  fail PROD_DB_SHA_MISMATCH "banco de produção divergente antes do canário"
[[ "$(sha256sum "$BRIDGE" | awk '{print $1}')" == "$EXPECTED_BRIDGE_SHA256" ]] ||
  fail BRIDGE_SHA_MISMATCH "bridge divergente"
bash -n "$BRIDGE"
sudo -u ubuntu -g zoe-coders test -r "$BRIDGE_CONF" ||
  fail BRIDGE_CONFIG_UNREADABLE "ubuntu/zoe-coders não lê onca-worker.conf"

python3 - "$CONFIG" "$WRITER" "$GATE" <<'PY'
import sys, tomllib
from pathlib import Path
path, writer, gate = sys.argv[1:]
with Path(path).open('rb') as fh:
    cfg = tomllib.load(fh)
assert cfg['coders'][writer]['adapter'] == 'custom'
assert cfg['coders'][writer]['binary'] == '/usr/local/bin/onca-codex-remote'
assert cfg['coders'][writer]['command'] == ['/usr/local/bin/onca-codex-remote', '{prompt}']
assert cfg['coders'][writer]['mode'] == 'write'
assert cfg['coders'][writer]['max_concurrency'] == 4
assert cfg['coders'][gate]['adapter'] == 'custom'
assert cfg['coders'][gate]['binary'] == '/usr/local/bin/onca-codex-remote'
assert cfg['coders'][gate]['command'] == ['/usr/local/bin/onca-codex-remote', '{prompt}']
assert cfg['coders'][gate]['mode'] == 'read_only'
assert cfg['coders'][gate]['max_concurrency'] == 2
assert writer in cfg['projects']['infranetwork']['allowed_write']
assert gate in cfg['projects']['infranetwork']['allowed_read']
print('REMOTE_PROFILE_READBACK=PASS')
PY

source "$BRIDGE_CONF"
SSH=(ssh -i "$ONCA_WORKER_KEY" -o BatchMode=yes -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$ONCA_WORKER_KNOWN_HOSTS"
  -o ConnectTimeout=15 "${ONCA_WORKER_USER}@${ONCA_WORKER_HOST}")
"${SSH[@]}" '
set -Eeuo pipefail
cd /
test "$(hostname -s)" = "win-codex-wak-01"
test "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns)" = "0"
id onca-runner
sudo -n -u onca-runner -H /usr/local/bin/codex --version
sudo -n -u onca-runner -H /usr/local/bin/codex login status
test -x /usr/local/lib/zoe-worker/remote_job_runner.py
echo WORKER_ROUTE_CANARY_READY=PASS
' | tee "$EVIDENCE/worker-readback.log"

sudo cat "$CONFIG" > "$CANARY_CONFIG"
chmod 0600 "$CANARY_CONFIG"
python3 - "$CANARY_CONFIG" "$CANARY_STATE" "$CANARY_LOGS" "$CANARY_DB" <<'PY'
from pathlib import Path
import json, re, sys, tomllib
path = Path(sys.argv[1])
values = {
    'state_dir': sys.argv[2],
    'log_dir': sys.argv[3],
    'db_path': sys.argv[4],
}
lines = path.read_text(encoding='utf-8').splitlines(keepends=True)
header = re.compile(r'^\s*\[([^\]]+)\]\s*(?:#.*)?$')
start = None
end = len(lines)
for i, line in enumerate(lines):
    m = header.match(line.rstrip('\n'))
    if m and m.group(1).strip() == 'runtime':
        start = i
        break
if start is None:
    raise SystemExit('[runtime] section missing')
for i in range(start + 1, len(lines)):
    if header.match(lines[i].rstrip('\n')):
        end = i
        break
for key, value in values.items():
    pattern = re.compile(rf'^\s*{re.escape(key)}\s*=')
    matches = [i for i in range(start + 1, end) if pattern.match(lines[i])]
    replacement = f'{key} = {json.dumps(value)}\n'
    if len(matches) > 1:
        raise SystemExit(f'duplicate runtime key: {key}')
    if matches:
        lines[matches[0]] = replacement
    else:
        lines.insert(start + 1, replacement)
        end += 1
path.write_text(''.join(lines), encoding='utf-8')
with path.open('rb') as fh:
    cfg = tomllib.load(fh)
assert cfg['runtime']['state_dir'] == values['state_dir']
assert cfg['runtime']['log_dir'] == values['log_dir']
assert cfg['runtime']['db_path'] == values['db_path']
print('ISOLATED_ROUTER_CONFIG=PASS')
PY

ROUTER=(python3 "$RUNTIME" --config "$CANARY_CONFIG")
"${ROUTER[@]}" init | tee "$EVIDENCE/router-init.log"

git init -q --bare "$ORIGIN"
git init -q -b "$BRANCH" "$REPO"
git -C "$REPO" config user.name 'ONCA Router Canary'
git -C "$REPO" config user.email 'onca-router-canary@invalid.local'
printf '# ONCA Router Writer/Gate Canary\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm 'test(onca): initialize router canary'
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q -u origin "$BRANCH"
START_SHA="$(git -C "$REPO" rev-parse HEAD)"

cat > "$WRITER_PROMPT" <<'PROMPT'
You are the admitted remote Writer for an isolated infrastructure canary.

Work only inside the current Git repository. Perform exactly these actions:
1. Create one file named ROUTER_CANARY.txt containing exactly the single line:
   ONCA_ROUTER_WRITER_OK
   The file must end with one newline.
2. Do not modify README.md or any other file.
3. If Git identity is not configured, set repository-local user.name to ONCA Remote Writer and user.email to onca-remote-writer@invalid.local.
4. Commit the change with exactly this commit message:
   test(onca): remote writer canary
5. Do not push manually. The bridge owns publishing.
6. Verify the worktree is clean after the commit and that exactly one path changed.

Your final response must be exactly this single JSON object on one line, with no markdown and no additional text:
{"terminal_status":"complete"}
PROMPT

WRITER_JOB="$("${ROUTER[@]}" submit \
  --project "$PROJECT" \
  --repo "$REPO" \
  --worktree "$REPO" \
  --branch "$BRANCH" \
  --issue "$ISSUE-WRITER" \
  --mission "$MISSION-WRITER" \
  --task-type onca_remote_canary \
  --mode write \
  --prompt-file "$WRITER_PROMPT" \
  --coder "$WRITER" \
  --priority 100 \
  --max-attempts 1 \
  --idempotency-key "$MISSION-WRITER" \
  --no-fallback)"
[[ "$WRITER_JOB" =~ ^[0-9a-f-]{36}$ ]] || fail WRITER_JOB_ID_INVALID "$WRITER_JOB"
printf '%s\n' "$WRITER_JOB" > "$EVIDENCE/writer-job-id.txt"

set +e
"${ROUTER[@]}" execute "$WRITER_JOB" \
  > >(tee "$EVIDENCE/writer-execute.stdout.log") \
  2> >(tee "$EVIDENCE/writer-execute.stderr.log" >&2)
WRITER_RC=$?
set -e
[[ "$WRITER_RC" -eq 0 ]] || fail WRITER_EXECUTE_FAILED "rc=$WRITER_RC job=$WRITER_JOB"
"${ROUTER[@]}" show "$WRITER_JOB" > "$EVIDENCE/writer-job.json"

python3 - "$EVIDENCE/writer-job.json" "$WRITER" <<'PY'
import json, sys
p, writer = sys.argv[1:]
data = json.load(open(p, encoding='utf-8'))
job = data['job']
assert job['status'] == 'succeeded', job
assert job['exit_code'] == 0, job
assert job['selected_coder'] == writer, job
assert job['mode'] == 'write', job
assert any(e['event_type'] == 'JOB_SUCCEEDED' for e in data['events'])
print('WRITER_ROUTER_RECEIPT=PASS')
PY

WRITER_SHA="$(git -C "$REPO" rev-parse HEAD)"
[[ "$WRITER_SHA" != "$START_SHA" ]] || fail WRITER_HEAD_UNCHANGED "writer não criou commit"
git -C "$REPO" merge-base --is-ancestor "$START_SHA" "$WRITER_SHA" ||
  fail WRITER_NON_DESCENDANT "$WRITER_SHA"
[[ "$(git -C "$REPO" rev-list --count "$START_SHA..$WRITER_SHA")" -eq 1 ]] ||
  fail WRITER_COMMIT_COUNT_INVALID "esperado um commit"
[[ "$(git -C "$REPO" diff --name-only "$START_SHA" "$WRITER_SHA")" == "ROUTER_CANARY.txt" ]] ||
  fail WRITER_CHANGED_PATHS_INVALID "$(git -C "$REPO" diff --name-only "$START_SHA" "$WRITER_SHA")"
printf 'ONCA_ROUTER_WRITER_OK\n' | cmp -s - "$REPO/ROUTER_CANARY.txt" ||
  fail WRITER_FILE_CONTENT_INVALID "bytes divergentes"
[[ "$(git -C "$REPO" log -1 --format=%s)" == "test(onca): remote writer canary" ]] ||
  fail WRITER_COMMIT_MESSAGE_INVALID "$(git -C "$REPO" log -1 --format=%s)"
[[ -z "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail WRITER_LOCAL_WORKTREE_DIRTY "após import"
[[ "$(git --git-dir="$ORIGIN" rev-parse "$BRANCH")" == "$WRITER_SHA" ]] ||
  fail WRITER_ORIGIN_NOT_PUBLISHED "origin divergente"

cat > "$GATE_PROMPT" <<PROMPT
You are the independent read-only Gate for an isolated Router canary.

Review the repository at the exact immutable HEAD below:
$WRITER_SHA

Prove all of the following without modifying any file, ref, index, branch, configuration, or commit:
1. HEAD is exactly $WRITER_SHA.
2. $START_SHA is its direct parent and there is exactly one commit in the range.
3. The only changed path is ROUTER_CANARY.txt.
4. ROUTER_CANARY.txt contains exactly ONCA_ROUTER_WRITER_OK followed by one newline.
5. README.md is unchanged from $START_SHA.
6. The worktree remains clean.

Run the necessary read-only Git and byte-level checks. If every assertion passes, your final response must be exactly this single JSON object on one line, with no markdown and no additional text:
{"gate_status":"PASS"}
PROMPT

GATE_JOB="$("${ROUTER[@]}" submit \
  --project "$PROJECT" \
  --repo "$REPO" \
  --worktree "$REPO" \
  --branch "$BRANCH" \
  --issue "$ISSUE-GATE" \
  --mission "$MISSION-GATE" \
  --task-type onca_remote_gate \
  --mode read_only \
  --prompt-file "$GATE_PROMPT" \
  --coder "$GATE" \
  --priority 100 \
  --max-attempts 1 \
  --idempotency-key "$MISSION-GATE" \
  --no-fallback)"
[[ "$GATE_JOB" =~ ^[0-9a-f-]{36}$ ]] || fail GATE_JOB_ID_INVALID "$GATE_JOB"
printf '%s\n' "$GATE_JOB" > "$EVIDENCE/gate-job-id.txt"

set +e
"${ROUTER[@]}" execute "$GATE_JOB" \
  > >(tee "$EVIDENCE/gate-execute.stdout.log") \
  2> >(tee "$EVIDENCE/gate-execute.stderr.log" >&2)
GATE_RC=$?
set -e
[[ "$GATE_RC" -eq 0 ]] || fail GATE_EXECUTE_FAILED "rc=$GATE_RC job=$GATE_JOB"
"${ROUTER[@]}" show "$GATE_JOB" > "$EVIDENCE/gate-job.json"

python3 - "$EVIDENCE/gate-job.json" "$GATE" <<'PY'
import json, sys
p, gate = sys.argv[1:]
data = json.load(open(p, encoding='utf-8'))
job = data['job']
assert job['status'] == 'succeeded', job
assert job['exit_code'] == 0, job
assert job['selected_coder'] == gate, job
assert job['mode'] == 'read_only', job
assert any(e['event_type'] == 'JOB_SUCCEEDED' for e in data['events'])
print('GATE_ROUTER_RECEIPT=PASS')
PY

[[ "$(git -C "$REPO" rev-parse HEAD)" == "$WRITER_SHA" ]] ||
  fail GATE_LOCAL_HEAD_CHANGED "gate alterou HEAD"
[[ -z "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)" ]] ||
  fail GATE_LOCAL_WORKTREE_DIRTY "gate deixou mudanças"
[[ "$(git --git-dir="$ORIGIN" rev-parse "$BRANCH")" == "$WRITER_SHA" ]] ||
  fail GATE_ORIGIN_CHANGED "gate alterou origin"
printf 'ONCA_ROUTER_WRITER_OK\n' | cmp -s - "$REPO/ROUTER_CANARY.txt" ||
  fail GATE_FILE_CONTENT_CHANGED "conteúdo mudou"

for job in "$WRITER_JOB" "$GATE_JOB"; do
  remote_evidence="/var/log/zoe-coder-router/remote/$job"
  [[ -f "$remote_evidence/result.json" ]] || fail BRIDGE_RESULT_MISSING "$job"
  cp -a "$remote_evidence/result.json" "$EVIDENCE/$job.bridge-result.json"
done

[[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$EXPECTED_RUNTIME_SHA256" ]] ||
  fail RUNTIME_CHANGED_AFTER_CANARY "runtime divergente"
[[ "$(sudo sha256sum "$CONFIG" | awk '{print $1}')" == "$EXPECTED_CONFIG_SHA256" ]] ||
  fail CONFIG_CHANGED_AFTER_CANARY "config divergente"
[[ "$(sudo sha256sum "$PROD_DB" | awk '{print $1}')" == "$EXPECTED_PROD_DB_SHA256" ]] ||
  fail PROD_DB_CHANGED_AFTER_CANARY "produção foi tocada"
[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail TIMER_CHANGED_AFTER_CANARY "timer foi alterado"
[[ "$(active_units)" -eq 0 ]] || fail ACTIVE_UNITS_AFTER_CANARY "units ativas"

CANARY_DB_SHA256="$(sha256sum "$CANARY_DB" | awk '{print $1}')"
(
  cd "$EVIDENCE"
  sha256sum \
    config.canary.toml \
    writer.prompt.md gate.prompt.md \
    writer-job.json gate-job.json \
    writer-execute.stdout.log writer-execute.stderr.log \
    gate-execute.stdout.log gate-execute.stderr.log \
    "$WRITER_JOB.bridge-result.json" "$GATE_JOB.bridge-result.json" \
    > SHA256SUMS
)

trap - ERR
cat <<EOF
OPERACAO_ONCA_ROUTER_WRITER_GATE_CANARY: PASS
WRITER_JOB_ID=$WRITER_JOB
GATE_JOB_ID=$GATE_JOB
START_SHA=$START_SHA
WRITER_SHA=$WRITER_SHA
WRITER_PROFILE=$WRITER
GATE_PROFILE=$GATE
WRITER_ROUTE=ROUTER_TO_REMOTE_WORKER_YOLO
GATE_ROUTE=ROUTER_TO_REMOTE_WORKER_READ_ONLY
WRITER_COMMIT_COUNT=1
WRITER_CHANGED_PATH=ROUTER_CANARY.txt
GATE_EXACT_SHA=$WRITER_SHA
GATE_READ_ONLY=PASS
ORIGIN_PUBLISHED=PASS
PRODUCTION_DB_CHANGED=false
CONFIG_CHANGED=false
RUNTIME_CHANGED=false
TIMER=inactive
ACTIVE_UNITS=0
CANARY_DB_SHA256=$CANARY_DB_SHA256
EVIDENCE_DIR=$EVIDENCE
NEXT_PHASE=ZCR19_REMOTE_WRITER_EXECUTION
EOF
