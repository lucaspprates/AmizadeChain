#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

JOB_ID='0e965769-bb00-4a02-9784-6d4c4c86911c'
SOURCE_EVIDENCE='/tmp/zcr19-gate-evidence.DjPkGE'
OPS='/var/backups/zoe-coder-router/manual-8-etapas-20260731T104654Z'
DB='/var/lib/zoe-coder-router/runtime.db'
RUNTIME='/usr/local/lib/zoe-coder-router/zoe_coder_router.py'
CONFIG='/etc/zoe-coder-router/config.toml'
REPO='/home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler'
TARGET_SHA='c3db2c39e58326c932e1a9276b1da9b4cecd45bb'

STAGE="$(mktemp -d /tmp/zcr19-gate-diagnosis.XXXXXX)"
FINAL="$OPS/ETAPA-6-FAILED-GATE-DIAGNOSIS-$JOB_ID"

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

fail() {
  echo 'ETAPA_6_GATE_DIAGNOSIS: FAIL' >&2
  echo "DETAIL=$*" >&2
  exit 1
}

router() {
  sudo -n -u ubuntu -g zoe-coders -H -- \
    python3 "$RUNTIME" --config "$CONFIG" "$@"
}

[[ "$(id -un)" == 'ubuntu' ]] || fail 'user must be ubuntu'
[[ "$(hostname -s)" == 'zoe-infranetwork-com-br' ]] || fail 'unexpected host'
sudo -n true >/dev/null 2>&1 || fail 'passwordless sudo unavailable'
sudo -n test -d "$OPS" || fail 'operation directory unavailable'
sudo -n test -r "$DB" || fail 'runtime database unavailable'
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$TARGET_SHA" ]] || fail 'local HEAD changed'
[[ -z "$(git -C "$REPO" status --porcelain=v1 --untracked-files=all)" ]] || fail 'source worktree dirty'

TIMER="$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
ACTIVE_UNITS="$(systemctl list-units 'zoe-coder-job@*.service' 'zoe-coder-wake@*.service' --state=active,activating --no-legend --no-pager 2>/dev/null | awk 'NF{n++} END{print n+0}')"

router show "$JOB_ID" > "$STAGE/gate-show.json"

python3 - "$STAGE/gate-show.json" "$STAGE/job-paths.env" <<'PY'
import json, shlex, sys
obj=json.load(open(sys.argv[1],encoding='utf-8'))['job']
keys=['status','exit_code','mode','selected_coder','branch','stdout_path','stderr_path','result_path','completed_at']
with open(sys.argv[2],'w',encoding='utf-8') as fh:
    for key in keys:
        value=obj.get(key)
        fh.write(f"{key.upper()}={shlex.quote('' if value is None else str(value))}\n")
PY
# shellcheck disable=SC1090
source "$STAGE/job-paths.env"

for pair in \
  "$STDOUT_PATH:router-stdout.jsonl" \
  "$STDERR_PATH:router-stderr.log" \
  "$RESULT_PATH:router-result.json"; do
  src="${pair%%:*}"
  dst="${pair#*:}"
  if [[ -n "$src" ]] && sudo -n test -f "$src"; then
    sudo -n cp "$src" "$STAGE/$dst"
    sudo -n chown ubuntu:ubuntu "$STAGE/$dst"
    chmod 0600 "$STAGE/$dst"
  fi
done

BRIDGE_DIR="/var/log/zoe-coder-router/remote/$JOB_ID"
if sudo -n test -d "$BRIDGE_DIR"; then
  sudo -n cp -a "$BRIDGE_DIR" "$STAGE/bridge-remote"
  sudo -n chown -R ubuntu:ubuntu "$STAGE/bridge-remote"
  chmod -R u+rwX,go-rwx "$STAGE/bridge-remote"
fi

if [[ -d "$SOURCE_EVIDENCE" ]]; then
  cp -a "$SOURCE_EVIDENCE" "$STAGE/original-script-evidence"
fi

sudo -n -u ubuntu -g zoe-coders -H -- python3 - "$DB" > "$STAGE/active-state.json" <<'PY'
import json, sqlite3, sys
conn=sqlite3.connect(f"file:{sys.argv[1]}?mode=ro",uri=True)
conn.row_factory=sqlite3.Row
rows=conn.execute("""
SELECT id,project,mission_id,mode,status,selected_coder
FROM jobs
WHERE status IN ('awaiting_capacity_plan','queued','dispatching','running')
ORDER BY created_at
""").fetchall()
print(json.dumps([dict(r) for r in rows],indent=2,ensure_ascii=False))
conn.close()
PY

python3 - "$STAGE" > "$STAGE/terminal-analysis.txt" <<'PY'
import json, pathlib, re, sys
root=pathlib.Path(sys.argv[1])
print('===== TERMINAL ANALYSIS =====')
stdout=root/'router-stdout.jsonl'
messages=[]
commands=[]
json_candidates=[]
if stdout.exists():
    for lineno,line in enumerate(stdout.read_text(encoding='utf-8',errors='replace').splitlines(),1):
        try: obj=json.loads(line)
        except Exception: continue
        item=obj.get('item') if isinstance(obj,dict) else None
        if isinstance(item,dict):
            if item.get('type')=='agent_message':
                text=str(item.get('text',''))
                messages.append((lineno,text))
                for candidate in re.findall(r'\{[^\n]*"gate_status"[^\n]*\}',text):
                    try: json_candidates.append(json.loads(candidate))
                    except Exception: pass
            elif item.get('type')=='command_execution' and obj.get('type')=='item.completed':
                commands.append((lineno,item.get('command'),item.get('exit_code'),item.get('status')))
print(f'agent_messages={len(messages)}')
for lineno,text in messages[-5:]:
    print(f'AGENT_MESSAGE_LINE={lineno}')
    print(text)
print(f'completed_commands={len(commands)}')
for row in commands[-12:]:
    print('COMMAND',json.dumps(row,ensure_ascii=False))
print('gate_json_candidates=')
print(json.dumps(json_candidates,indent=2,ensure_ascii=False,sort_keys=True))
for path in [root/'router-stderr.log', root/'bridge-remote'/'result.json', root/'bridge-remote'/'meta.json']:
    if path.exists():
        print(f'===== {path.relative_to(root)} =====')
        print(path.read_text(encoding='utf-8',errors='replace')[-12000:])
PY

{
  echo '===== GATE DIAGNOSIS SUMMARY ====='
  echo "job_id=$JOB_ID"
  echo "status=$STATUS"
  echo "exit_code=$EXIT_CODE"
  echo "mode=$MODE"
  echo "selected_coder=$SELECTED_CODER"
  echo "branch=$BRANCH"
  echo "completed_at=$COMPLETED_AT"
  echo "timer=$TIMER"
  echo "active_units=$ACTIVE_UNITS"
  echo "source_head=$(git -C "$REPO" rev-parse HEAD)"
  echo "source_clean=true"
  echo
  cat "$STAGE/active-state.json"
  echo
  cat "$STAGE/terminal-analysis.txt"
} | tee "$STAGE/SUMMARY.txt"

sudo -n rm -rf "$FINAL"
sudo -n install -d -m 0700 -o root -g root "$FINAL"
sudo -n cp -a "$STAGE/." "$FINAL/"
sudo -n chown -R root:root "$FINAL"
sudo -n chmod -R go-rwx "$FINAL"

echo
echo 'ETAPA_6_GATE_DIAGNOSIS: PASS'
echo "JOB_ID=$JOB_ID"
echo "JOB_STATUS=$STATUS"
echo "JOB_EXIT_CODE=$EXIT_CODE"
echo "ACTIVE_UNITS=$ACTIVE_UNITS"
echo "TIMER=$TIMER"
echo "EVIDENCE=$FINAL"
echo 'NEXT=CLASSIFICAR_GATE_SEM_REEXECUTAR'
