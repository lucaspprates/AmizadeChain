#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

RUN_EVIDENCE="/tmp/evidence/zcr19-remote-writer-gate-20260731T015111Z"
WORKTREE="/home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler"
DB="/var/lib/zoe-coder-router/runtime.db"
RUNTIME="/usr/local/lib/zoe-coder-router/zoe_coder_router.py"
CONFIG="/etc/zoe-coder-router/config.toml"
BRANCH="type/18-factory-scheduler-maintenance"
START_SHA="d80ed678333dc70d1b92479a821bf2d1467c4424"
EXPECTED_NEW_SHA="fc2329960d2dffb301b9ad1bde9f7ea5b4789795"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/tmp/evidence/zcr19-gate-failure-diagnostic-${STAMP}"
mkdir -p "$OUT"

fail() {
  echo "ERRO: $*" >&2
  echo "ZCR19_GATE_FAILURE_DIAGNOSTIC: BLOCKED"
  echo "EVIDENCE_DIR=$OUT"
  exit 1
}

[[ "$(id -un)" == "ubuntu" ]] || fail "execute como ubuntu"
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail "host inesperado"
[[ -d "$RUN_EVIDENCE" ]] || fail "evidência original ausente: $RUN_EVIDENCE"
[[ -f "$RUN_EVIDENCE/writer-job-id.txt" ]] || fail "writer-job-id ausente"
[[ -f "$RUN_EVIDENCE/gate-job-id.txt" ]] || fail "gate-job-id ausente"
[[ -f "$RUN_EVIDENCE/writer-show.json" ]] || fail "writer-show ausente"
[[ -f "$RUN_EVIDENCE/gate-show.json" ]] || fail "gate-show ausente"

WRITER_JOB_ID="$(tr -d '\r\n' < "$RUN_EVIDENCE/writer-job-id.txt")"
GATE_JOB_ID="$(tr -d '\r\n' < "$RUN_EVIDENCE/gate-job-id.txt")"
[[ "$WRITER_JOB_ID" =~ ^[0-9a-f-]{36}$ ]] || fail "writer job id inválido"
[[ "$GATE_JOB_ID" =~ ^[0-9a-f-]{36}$ ]] || fail "gate job id inválido"

{
  echo "===== CONTROL PLANE ====="
  echo "timer=$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
  echo "active_units=$(systemctl list-units 'zoe-coder-job@*.service' 'zoe-coder-wake@*.service' --state=active,activating --no-legend --no-pager 2>/dev/null | wc -l)"
  sha256sum "$RUNTIME"
  sudo sha256sum "$CONFIG" "$DB"
  echo
  echo "===== GIT / PR HEAD ====="
  echo "worktree=$WORKTREE"
  echo "branch=$(git -C "$WORKTREE" branch --show-current)"
  echo "head=$(git -C "$WORKTREE" rev-parse HEAD)"
  echo "clean=$([[ -z "$(git -C "$WORKTREE" status --porcelain=v1 --untracked-files=all)" ]] && echo true || echo false)"
  echo "commit_count=$(git -C "$WORKTREE" rev-list --count "$START_SHA..HEAD")"
  echo "origin_head=$(git ls-remote --heads "$(git -C "$WORKTREE" remote get-url origin)" "refs/heads/$BRANCH" | awk '{print $1}')"
  git -C "$WORKTREE" log -2 --oneline --decorate
  git -C "$WORKTREE" diff --stat "$START_SHA..HEAD"
  echo
  echo "===== JOB IDS ====="
  echo "writer_job_id=$WRITER_JOB_ID"
  echo "gate_job_id=$GATE_JOB_ID"
} | tee "$OUT/control-and-git.txt"

python3 - "$RUN_EVIDENCE/writer-show.json" "$RUN_EVIDENCE/gate-show.json" <<'PY' | tee "$OUT/router-job-summary.json"
import json, sys
out = {}
for label, path in (("writer", sys.argv[1]), ("gate", sys.argv[2])):
    data = json.load(open(path, encoding="utf-8"))
    job = data.get("job", {})
    out[label] = {
        "id": job.get("id"),
        "execution_id": job.get("execution_id"),
        "status": job.get("status"),
        "selected_coder": job.get("selected_coder"),
        "mode": job.get("mode"),
        "branch": job.get("branch"),
        "exit_code": job.get("exit_code"),
        "error": job.get("error"),
        "result_path": job.get("result_path"),
        "stdout_path": job.get("stdout_path"),
        "stderr_path": job.get("stderr_path"),
        "completed_at": job.get("completed_at"),
        "events": [
            {
                "id": e.get("id"),
                "type": e.get("event_type"),
                "actor": e.get("actor"),
                "payload": e.get("payload"),
                "created_at": e.get("created_at"),
            }
            for e in data.get("events", [])
        ],
    }
print(json.dumps(out, indent=2, ensure_ascii=False, sort_keys=True))
PY

copy_job_artifacts() {
  local label="$1" show="$2"
  python3 - "$show" <<'PY' > "$OUT/${label}-paths.txt"
import json, sys
job=json.load(open(sys.argv[1],encoding='utf-8')).get('job',{})
for key in ('stdout_path','stderr_path','result_path'):
    value=job.get(key)
    if value:
        print(f"{key}={value}")
PY
  while IFS='=' read -r key path; do
    [[ -n "${path:-}" ]] || continue
    if sudo test -f "$path"; then
      sudo cp "$path" "$OUT/${label}-${key}"
      sudo chown ubuntu:ubuntu "$OUT/${label}-${key}"
      chmod 0600 "$OUT/${label}-${key}"
    else
      printf 'MISSING %s=%s\n' "$key" "$path" >> "$OUT/${label}-missing-artifacts.txt"
    fi
  done < "$OUT/${label}-paths.txt"
}

copy_job_artifacts writer "$RUN_EVIDENCE/writer-show.json"
copy_job_artifacts gate "$RUN_EVIDENCE/gate-show.json"

if sudo test -d "/var/log/zoe-coder-router/remote/$GATE_JOB_ID"; then
  sudo tar -C "/var/log/zoe-coder-router/remote/$GATE_JOB_ID" -czf "$OUT/gate-bridge-evidence.tar.gz" .
  sudo chown ubuntu:ubuntu "$OUT/gate-bridge-evidence.tar.gz"
fi

sudo -u ubuntu -g zoe-coders -H -- python3 - "$DB" "$WRITER_JOB_ID" "$GATE_JOB_ID" <<'PY' | tee "$OUT/db-jobs-events.json"
import json, sqlite3, sys
conn=sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
conn.row_factory=sqlite3.Row
result={}
for label, job_id in (("writer",sys.argv[2]),("gate",sys.argv[3])):
    job=conn.execute("SELECT * FROM jobs WHERE id=?",(job_id,)).fetchone()
    events=conn.execute("SELECT id,event_type,actor,payload,created_at FROM events WHERE job_id=? ORDER BY id",(job_id,)).fetchall()
    result[label]={"job":dict(job) if job else None,"events":[dict(x) for x in events]}
print(json.dumps(result,indent=2,ensure_ascii=False,sort_keys=True))
PY

{
  echo "===== ORIGINAL GATE EXECUTE STDOUT ====="
  tail -n 120 "$RUN_EVIDENCE/gate-execute.stdout.log" 2>/dev/null || true
  echo
  echo "===== ORIGINAL GATE EXECUTE STDERR ====="
  tail -n 160 "$RUN_EVIDENCE/gate-execute.stderr.log" 2>/dev/null || true
  echo
  echo "===== ROUTER GATE STDOUT ====="
  tail -n 160 "$OUT/gate-stdout_path" 2>/dev/null || true
  echo
  echo "===== ROUTER GATE STDERR ====="
  tail -n 200 "$OUT/gate-stderr_path" 2>/dev/null || true
  echo
  echo "===== ROUTER GATE RESULT ====="
  if [[ -f "$OUT/gate-result_path" ]]; then
    python3 -m json.tool "$OUT/gate-result_path" 2>/dev/null || cat "$OUT/gate-result_path"
  fi
  echo
  echo "===== BRIDGE RESULT.JSON ====="
  if [[ -f "$OUT/gate-bridge-evidence.tar.gz" ]]; then
    tar -tzf "$OUT/gate-bridge-evidence.tar.gz" | sed -n '1,120p'
    tar -xOzf "$OUT/gate-bridge-evidence.tar.gz" ./result.json 2>/dev/null | python3 -m json.tool 2>/dev/null || true
  fi
} | tee "$OUT/gate-readable-diagnostic.txt"

HEAD="$(git -C "$WORKTREE" rev-parse HEAD)"
[[ "$HEAD" == "$EXPECTED_NEW_SHA" ]] || fail "HEAD divergente: $HEAD"
[[ "$(git -C "$WORKTREE" branch --show-current)" == "$BRANCH" ]] || fail "branch divergente"
[[ -z "$(git -C "$WORKTREE" status --porcelain=v1 --untracked-files=all)" ]] || fail "worktree não está limpa"
[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] || fail "timer mudou"

(
  cd "$OUT"
  find . -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)

cat <<EOF
ZCR19_GATE_FAILURE_DIAGNOSTIC: PASS
WRITER_JOB_ID=$WRITER_JOB_ID
GATE_JOB_ID=$GATE_JOB_ID
START_SHA=$START_SHA
NEW_SHA=$HEAD
WRITER_PUBLISHED=true
WORKTREE_CLEAN=true
TIMER=inactive
EVIDENCE_DIR=$OUT
READABLE_REPORT=$OUT/gate-readable-diagnostic.txt
NEXT_PHASE=CLASSIFY_GATE_FAILURE
EOF
