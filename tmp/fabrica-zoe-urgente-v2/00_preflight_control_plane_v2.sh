#!/usr/bin/env bash
set -Eeuo pipefail

TIMER="zoe-coder-reconcile.timer"
SNAPSHOT="/var/backups/zoe-coder-router/maintenance-20260730T152024Z"
RUNTIME="/usr/local/lib/zoe-coder-router/zoe_coder_router.py"
EXPECTED_RUNTIME_SHA="fb715130494523c5720982bfd0bd6093744881b4f1a33fdff8209c234b2bb362"

PR21_WT="/home/ubuntu/worktrees/zoe-coder-router-zcr19-contract"
PR21_BRANCH="fix/20-zcr19-runner-semantic-contract"
PR21_HEAD="66ea771be8a231b955d719417d2242c3bca2407d"

ZCR19_WT="/home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler"
ZCR19_BRANCH="type/18-factory-scheduler-maintenance"
ZCR19_HEAD="d80ed678333dc70d1b92479a821bf2d1467c4424"

bool() {
  [[ "$1" == "true" ]] && printf true || printf false
}

safe_git_read() {
  local repo="$1" op="$2"
  case "$op" in
    branch) git -C "$repo" branch --show-current 2>/dev/null || true ;;
    head) git -C "$repo" rev-parse HEAD 2>/dev/null || true ;;
    clean) [[ -d "$repo" && -z "$(git -C "$repo" status --porcelain=v1 2>/dev/null || printf ERROR)" ]] ;;
  esac
}

timer="$(systemctl is-active "$TIMER" 2>/dev/null || true)"
active_units="$(
  systemctl list-units 'zoe-coder-job@*.service' 'zoe-coder-wake@*.service' \
    --state=active,activating --no-legend --no-pager 2>/dev/null | wc -l
)"
runtime_sha="$(sha256sum "$RUNTIME" 2>/dev/null | awk '{print $1}' || true)"

snapshot_present=false
snapshot_manifest_valid=false
snapshot_check_method="none"

if [[ -d "$SNAPSHOT" ]]; then
  snapshot_present=true
  snapshot_check_method="direct"
  if (cd "$SNAPSHOT" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
    snapshot_manifest_valid=true
  fi
elif sudo -n test -d "$SNAPSHOT" 2>/dev/null; then
  snapshot_present=true
  snapshot_check_method="sudo-read-only"
  if sudo -n bash -c 'cd "$1" && sha256sum -c SHA256SUMS >/dev/null' _ "$SNAPSHOT" 2>/dev/null; then
    snapshot_manifest_valid=true
  fi
fi

pr21_branch="$(safe_git_read "$PR21_WT" branch)"
pr21_head="$(safe_git_read "$PR21_WT" head)"
pr21_clean=false
if safe_git_read "$PR21_WT" clean; then pr21_clean=true; fi

zcr19_branch="$(safe_git_read "$ZCR19_WT" branch)"
zcr19_head="$(safe_git_read "$ZCR19_WT" head)"
zcr19_clean=false
if safe_git_read "$ZCR19_WT" clean; then zcr19_clean=true; fi

safe=true
[[ "$timer" == "inactive" ]] || safe=false
[[ "$active_units" -eq 0 ]] || safe=false
[[ "$runtime_sha" == "$EXPECTED_RUNTIME_SHA" ]] || safe=false
[[ "$snapshot_present" == true ]] || safe=false
[[ "$snapshot_manifest_valid" == true ]] || safe=false
[[ "$pr21_branch" == "$PR21_BRANCH" ]] || safe=false
[[ "$pr21_head" == "$PR21_HEAD" ]] || safe=false
[[ "$pr21_clean" == true ]] || safe=false
[[ "$zcr19_branch" == "$ZCR19_BRANCH" ]] || safe=false
[[ "$zcr19_head" == "$ZCR19_HEAD" ]] || safe=false
[[ "$zcr19_clean" == true ]] || safe=false

cat <<EOF
{
  "timer": "$timer",
  "active_job_or_wake_units": $active_units,
  "runtime_sha256": "$runtime_sha",
  "runtime_matches_known_hotfix": $([[ "$runtime_sha" == "$EXPECTED_RUNTIME_SHA" ]] && echo true || echo false),
  "snapshot_present": $snapshot_present,
  "snapshot_manifest_valid": $snapshot_manifest_valid,
  "snapshot_check_method": "$snapshot_check_method",
  "pr21": {
    "branch": "$pr21_branch",
    "head": "$pr21_head",
    "clean": $pr21_clean
  },
  "zcr19": {
    "branch": "$zcr19_branch",
    "head": "$zcr19_head",
    "clean": $zcr19_clean
  },
  "safe_maintenance_state": $safe
}
EOF

if [[ "$safe" == true ]]; then
  echo "CONTROL_PLANE_PREFLIGHT_V2: PASS"
else
  echo "CONTROL_PLANE_PREFLIGHT_V2: FAIL" >&2
  exit 1
fi
