#!/usr/bin/env bash
set -Eeuo pipefail

WT="/home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler"
BRANCH="type/18-factory-scheduler-maintenance"
EXPECTED_HEAD="d80ed678333dc70d1b92479a821bf2d1467c4424"

echo "===== SHELL RECOVERY CHECK ====="
echo "timer=$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)"
echo "branch=$(git -C "$WT" branch --show-current)"
echo "head=$(git -C "$WT" rev-parse HEAD)"
echo
echo "===== WORKTREE STATUS ====="
git -C "$WT" status --short
echo
echo "===== RUNNING ROUTER UNITS ====="
systemctl list-units 'zoe-coder-job@*.service' 'zoe-coder-wake@*.service' \
  --state=active,activating --no-pager || true

[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]]
[[ "$(git -C "$WT" branch --show-current)" == "$BRANCH" ]]
[[ "$(git -C "$WT" rev-parse HEAD)" == "$EXPECTED_HEAD" ]]

echo
echo "ZCR19_SHELL_RECOVERY_CHECK: PASS"
