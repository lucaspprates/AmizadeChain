#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

CONFIG="/etc/zoe-coder-router/config.toml"
RUNTIME="/usr/local/lib/zoe-coder-router/zoe_coder_router.py"
DB="/var/lib/zoe-coder-router/runtime.db"
BRIDGE="/usr/local/bin/onca-codex-remote"
BRIDGE_CONF="/etc/zoe-coder-router/onca-worker.conf"

EXPECTED_RUNTIME_SHA256="f181fd627dceff10d46d23598eb54d8cfb5a15b070231aa34b4c09e907fc7d85"
EXPECTED_CONFIG_SHA256="8f2e0632474bc12b62dea0e5539131ceb05f99631bf970ff06a1058bbef20ddf"
EXPECTED_DB_SHA256="b0ab9b08edc54cf6ba3d1f60aaef9ae93fea3392d01f55a40275776e7b119374"
EXPECTED_BRIDGE_SHA256="4d37ed3baba38dc5d35ac9e11928dd0969dd5e7fbdf3c0f4c3e4af2acafdd4b6"

WRITER="codex_terra_remote_writer_yolo"
GATE="codex_terra_remote_gate"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="/tmp/evidence/onca-router-route-admission-${STAMP}"
BACKUP="/var/backups/zoe-coder-router/onca-route-admission-${STAMP}"
STAGED="${EVIDENCE}/config.toml.staged"
CONFIG_CHANGED=0

restore_if_needed() {
  if [[ "$CONFIG_CHANGED" -eq 1 && -f "$BACKUP/config.toml.before" ]]; then
    sudo cp -a "$BACKUP/config.toml.before" "$CONFIG"
    CONFIG_CHANGED=0
    echo "ROLLBACK_CONFIG=PASS" >&2
  fi
}

fail() {
  restore_if_needed
  trap - ERR
  echo "ERRO: $*" >&2
  echo "OPERACAO_ONCA_ROUTER_ROUTE_ADMISSION: BLOCKED"
  echo "EVIDENCE_DIR=$EVIDENCE"
  exit 1
}

active_units() {
  systemctl list-units \
    'zoe-coder-job@*.service' \
    'zoe-coder-wake@*.service' \
    --state=active,activating \
    --no-legend --no-pager 2>/dev/null |
    wc -l
}

rollback() {
  local rc=$?
  restore_if_needed
  trap - ERR
  echo "OPERACAO_ONCA_ROUTER_ROUTE_ADMISSION: BLOCKED" >&2
  echo "FAILURE_CODE=UNEXPECTED_ERROR_RC_${rc}" >&2
  echo "EVIDENCE_DIR=$EVIDENCE" >&2
  exit "$rc"
}
trap rollback ERR

[[ "$(id -un)" == "ubuntu" ]] || fail "USER_MISMATCH"
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail "HOST_MISMATCH"
sudo -v
mkdir -p "$EVIDENCE"
sudo install -d -m 0700 -o root -g root "$BACKUP"

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail "TIMER_NOT_INACTIVE"
[[ "$(active_units)" -eq 0 ]] || fail "ACTIVE_UNITS_PRESENT"

[[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$EXPECTED_RUNTIME_SHA256" ]] ||
  fail "RUNTIME_SHA_MISMATCH"
[[ "$(sudo sha256sum "$CONFIG" | awk '{print $1}')" == "$EXPECTED_CONFIG_SHA256" ]] ||
  fail "CONFIG_SHA_MISMATCH"
[[ "$(sudo sha256sum "$DB" | awk '{print $1}')" == "$EXPECTED_DB_SHA256" ]] ||
  fail "DB_SHA_MISMATCH"
[[ "$(sha256sum "$BRIDGE" | awk '{print $1}')" == "$EXPECTED_BRIDGE_SHA256" ]] ||
  fail "BRIDGE_SHA_MISMATCH"
bash -n "$BRIDGE"
sudo -u ubuntu -g zoe-coders test -r "$BRIDGE_CONF" || fail "BRIDGE_CONFIG_UNREADABLE"

sudo cp -a "$CONFIG" "$BACKUP/config.toml.before"
sudo cp "$CONFIG" "$STAGED"
sudo chown ubuntu:ubuntu "$STAGED"
chmod 0600 "$STAGED"

python3 - "$STAGED" "$WRITER" "$GATE" <<'PY'
from __future__ import annotations

import json
import re
import sys
import tomllib
from copy import deepcopy
from pathlib import Path

path = Path(sys.argv[1])
writer = sys.argv[2]
gate = sys.argv[3]
active_projects = ["infraflow", "infraops-ai", "infranetwork", "zoe-coder-router"]

text = path.read_text(encoding="utf-8")
before = tomllib.loads(text)
if writer in before["coders"] or gate in before["coders"]:
    raise SystemExit("remote profiles already exist; expected pristine config")

for project in active_projects:
    if project not in before["projects"]:
        raise SystemExit(f"missing project: {project}")

lines = text.splitlines(keepends=True)
header_re = re.compile(r"^\s*\[([^\]]+)\]\s*(?:#.*)?$")


def section_bounds(section: str) -> tuple[int, int]:
    start = None
    for index, line in enumerate(lines):
        match = header_re.match(line.rstrip("\n"))
        if match and match.group(1).strip() == section:
            start = index
            break
    if start is None:
        raise SystemExit(f"section not found: [{section}]")
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if header_re.match(lines[index].rstrip("\n")):
            end = index
            break
    return start, end


def assignment_span(section: str, key: str) -> tuple[int, int, str]:
    start, end = section_bounds(section)
    key_re = re.compile(rf"^(\s*){re.escape(key)}\s*=")
    for index in range(start + 1, end):
        match = key_re.match(lines[index])
        if not match:
            continue
        depth = 0
        seen_array = False
        in_double = False
        in_single = False
        escaped = False
        for current in range(index, end):
            for char in lines[current]:
                if in_double:
                    if escaped:
                        escaped = False
                    elif char == "\\":
                        escaped = True
                    elif char == '"':
                        in_double = False
                    continue
                if in_single:
                    if char == "'":
                        in_single = False
                    continue
                if char == '"':
                    in_double = True
                elif char == "'":
                    in_single = True
                elif char == "[":
                    depth += 1
                    seen_array = True
                elif char == "]":
                    depth -= 1
            if seen_array and depth == 0 and not in_double and not in_single:
                return index, current + 1, match.group(1)
        raise SystemExit(f"unterminated array: [{section}] {key}")
    raise SystemExit(f"key not found: [{section}] {key}")


def append_to_array(section: str, key: str, value: str) -> None:
    current = list(before["projects"][section.split(".", 1)[1]].get(key, []))
    if value not in current:
        current.append(value)
    begin, end, indent = assignment_span(section, key)
    replacement = f"{indent}{key} = {json.dumps(current, ensure_ascii=False)}\n"
    lines[begin:end] = [replacement]


for project in reversed(active_projects):
    append_to_array(f"projects.{project}", "allowed_read", gate)
    append_to_array(f"projects.{project}", "allowed_write", writer)

coder_block = f"""
# ONCA-8X1 remote worker profiles. Defaults and existing routes remain unchanged.
[coders.{writer}]
adapter = "custom"
binary = "/usr/local/bin/onca-codex-remote"
command = ["/usr/local/bin/onca-codex-remote", "{{prompt}}"]
mode = "write"
model = "gpt-5.6-terra"
reasoning = "high"
enabled = true
max_concurrency = 4
allowed_projects = ["infraflow", "infraops-ai", "infranetwork", "zoe-coder-router"]
denied_projects = ["factory-console"]
allowed_write_paths = ["*"]

[coders.{gate}]
adapter = "custom"
binary = "/usr/local/bin/onca-codex-remote"
command = ["/usr/local/bin/onca-codex-remote", "{{prompt}}"]
mode = "read_only"
model = "gpt-5.6-terra"
reasoning = "high"
enabled = true
max_concurrency = 2
allowed_projects = ["infraflow", "infraops-ai", "infranetwork", "zoe-coder-router"]
denied_projects = ["factory-console"]
"""

patched = "".join(lines)
if not patched.endswith("\n"):
    patched += "\n"
patched += coder_block.lstrip("\n")
after = tomllib.loads(patched)

expected_writer = {
    "adapter": "custom",
    "binary": "/usr/local/bin/onca-codex-remote",
    "command": ["/usr/local/bin/onca-codex-remote", "{prompt}"],
    "mode": "write",
    "model": "gpt-5.6-terra",
    "reasoning": "high",
    "enabled": True,
    "max_concurrency": 4,
    "allowed_projects": active_projects,
    "denied_projects": ["factory-console"],
    "allowed_write_paths": ["*"],
}
expected_gate = {
    "adapter": "custom",
    "binary": "/usr/local/bin/onca-codex-remote",
    "command": ["/usr/local/bin/onca-codex-remote", "{prompt}"],
    "mode": "read_only",
    "model": "gpt-5.6-terra",
    "reasoning": "high",
    "enabled": True,
    "max_concurrency": 2,
    "allowed_projects": active_projects,
    "denied_projects": ["factory-console"],
}
assert after["coders"][writer] == expected_writer
assert after["coders"][gate] == expected_gate

for name, coder in before["coders"].items():
    assert after["coders"][name] == coder, name

for name, project_before in before["projects"].items():
    project_after = deepcopy(after["projects"][name])
    expected = deepcopy(project_before)
    if name in active_projects:
        expected.setdefault("allowed_write", [])
        expected.setdefault("allowed_read", [])
        if writer not in expected["allowed_write"]:
            expected["allowed_write"].append(writer)
        if gate not in expected["allowed_read"]:
            expected["allowed_read"].append(gate)
    assert project_after == expected, name

assert after["runtime"] == before["runtime"]
path.write_text(patched, encoding="utf-8")
print(json.dumps({
    "status": "PASS",
    "writer": writer,
    "gate": gate,
    "projects": active_projects,
    "defaults_changed": False,
    "routes_changed": False,
    "runtime_changed": False,
}, indent=2))
PY

PYTHONDONTWRITEBYTECODE=1 python3 - "$RUNTIME" "$STAGED" "$WRITER" "$GATE" <<'PY'
from __future__ import annotations

import importlib.util
import sqlite3
import sys
from pathlib import Path

runtime_path, config_path, writer, gate = sys.argv[1:]
spec = importlib.util.spec_from_file_location("onca_route_validation", runtime_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
cfg = module.load_config(Path(config_path))

conn = sqlite3.connect(":memory:")
conn.row_factory = sqlite3.Row
conn.execute("CREATE TABLE provider_capacity (coder TEXT PRIMARY KEY, state TEXT NOT NULL, reason TEXT NOT NULL, blocked_at TEXT NOT NULL)")

for project in ("infraflow", "infraops-ai", "infranetwork", "zoe-coder-router"):
    write_route = module.route_candidates(
        cfg, conn, project, "onca_remote_canary", "write",
        requested=writer, require_available=True,
    )
    read_route = module.route_candidates(
        cfg, conn, project, "onca_remote_gate", "read_only",
        requested=gate, require_available=True,
    )
    assert write_route == [writer], (project, write_route)
    assert read_route == [gate], (project, read_route)

assert cfg["runtime"]["max_global_workers"] == 8
print("DEPLOYED_RUNTIME_ROUTE_VALIDATION=PASS")
print("GLOBAL_MAX_WORKERS=8_UNCHANGED")
PY

sudo install -m 0640 -o root -g zoe-coders "$STAGED" "${CONFIG}.onca-new-${STAMP}"
sudo mv "${CONFIG}.onca-new-${STAMP}" "$CONFIG"
CONFIG_CHANGED=1

sudo -u ubuntu -g zoe-coders PYTHONDONTWRITEBYTECODE=1 python3 - "$CONFIG" "$WRITER" "$GATE" <<'PY'
import sys
import tomllib
from pathlib import Path

path, writer, gate = sys.argv[1:]
with Path(path).open("rb") as fh:
    cfg = tomllib.load(fh)
assert cfg["coders"][writer]["mode"] == "write"
assert cfg["coders"][writer]["max_concurrency"] == 4
assert cfg["coders"][gate]["mode"] == "read_only"
assert cfg["coders"][gate]["max_concurrency"] == 2
for project in ("infraflow", "infraops-ai", "infranetwork", "zoe-coder-router"):
    assert writer in cfg["projects"][project]["allowed_write"]
    assert gate in cfg["projects"][project]["allowed_read"]
print("INSTALLED_CONFIG_READBACK=PASS")
PY

[[ "$(sha256sum "$RUNTIME" | awk '{print $1}')" == "$EXPECTED_RUNTIME_SHA256" ]] ||
  fail "RUNTIME_CHANGED_AFTER_ADMISSION"
[[ "$(sudo sha256sum "$DB" | awk '{print $1}')" == "$EXPECTED_DB_SHA256" ]] ||
  fail "DB_CHANGED_AFTER_ADMISSION"
[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] ||
  fail "TIMER_CHANGED_AFTER_ADMISSION"
[[ "$(active_units)" -eq 0 ]] || fail "ACTIVE_UNITS_AFTER_ADMISSION"

NEW_CONFIG_SHA256="$(sudo sha256sum "$CONFIG" | awk '{print $1}')"
sudo cp -a "$CONFIG" "$BACKUP/config.toml.after"
printf '%s  %s\n' "$EXPECTED_CONFIG_SHA256" "config.toml.before" >"$EVIDENCE/SHA256SUMS"
printf '%s  %s\n' "$NEW_CONFIG_SHA256" "config.toml.after" >>"$EVIDENCE/SHA256SUMS"

CONFIG_CHANGED=0
trap - ERR

cat <<EOF
OPERACAO_ONCA_ROUTER_ROUTE_ADMISSION: PASS
WRITER_PROFILE=$WRITER
WRITER_CONCURRENCY=4
GATE_PROFILE=$GATE
GATE_CONCURRENCY=2
ADMITTED_PROJECTS=infraflow,infraops-ai,infranetwork,zoe-coder-router
DEFAULTS_CHANGED=false
ROUTES_CHANGED=false
GLOBAL_MAX_WORKERS=8_UNCHANGED
TIMER=inactive
ACTIVE_UNITS=0
RUNTIME_SHA256=$EXPECTED_RUNTIME_SHA256
CONFIG_SHA256_BEFORE=$EXPECTED_CONFIG_SHA256
CONFIG_SHA256_AFTER=$NEW_CONFIG_SHA256
DB_SHA256=$EXPECTED_DB_SHA256
BACKUP=$BACKUP
EVIDENCE_DIR=$EVIDENCE
NEXT_PHASE=ROUTER_WRITER_GATE_CANARY
EOF
