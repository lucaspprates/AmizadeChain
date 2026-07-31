#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

SCRIPT="/tmp/ONCA_8X1_V3/onca-8x1-v3.sh"
EXPECTED_BEFORE_SHA256="0483060d64b3543681760133d0cd0c3900d70acc39af8361c9a933c917ef763b"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="/tmp/evidence/onca-v3-hotfix-return-traps-${STAMP}"
BACKUP="$EVIDENCE/onca-8x1-v3.sh.before"

fail() {
  echo "ERRO: $*" >&2
  echo "ONCA_V3_HOTFIX_RETURN_TRAPS: BLOCKED"
  echo "EVIDENCE_DIR=$EVIDENCE"
  exit 1
}

[[ "$(id -un)" == "ubuntu" ]] || fail "execute como ubuntu"
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail "execute na Zoe de produção"
[[ -f "$SCRIPT" ]] || fail "script V3 ausente: $SCRIPT"
[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] || fail "timer não está inactive"
[[ -x /usr/local/bin/onca-codex-remote ]] || fail "bridge ausente"

mkdir -p "$EVIDENCE"
cp -a "$SCRIPT" "$BACKUP"

BEFORE_SHA="$(sha256sum "$SCRIPT" | awk '{print $1}')"
[[ "$BEFORE_SHA" == "$EXPECTED_BEFORE_SHA256" ]] || fail "SHA inesperado antes do patch: $BEFORE_SHA"

python3 - "$SCRIPT" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = "trap 'rm -rf \"$tmp\"' RETURN"
new = "trap 'rm -rf -- \"${tmp:-}\"; trap - RETURN' RETURN"
count = text.count(old)
if count != 2:
    raise SystemExit(f"expected exactly 2 unsafe RETURN traps, found {count}")
text = text.replace(old, new)
path.write_text(text, encoding="utf-8")
PY

chmod 700 "$SCRIPT"
bash -n "$SCRIPT" || {
  cp -a "$BACKUP" "$SCRIPT"
  fail "bash -n falhou; backup restaurado"
}

UNSAFE_COUNT="$(grep -Fxc "  trap 'rm -rf \"\$tmp\"' RETURN" "$SCRIPT" || true)"
SAFE_COUNT="$(grep -Fc "trap 'rm -rf -- \"\${tmp:-}\"; trap - RETURN' RETURN" "$SCRIPT" || true)"
[[ "$UNSAFE_COUNT" -eq 0 ]] || {
  cp -a "$BACKUP" "$SCRIPT"
  fail "trap inseguro ainda presente"
}
[[ "$SAFE_COUNT" -eq 2 ]] || {
  cp -a "$BACKUP" "$SCRIPT"
  fail "quantidade de traps seguros divergente: $SAFE_COUNT"
}

AFTER_SHA="$(sha256sum "$SCRIPT" | awk '{print $1}')"
nl -ba "$SCRIPT" | sed -n '108,116p;149,156p' | tee "$EVIDENCE/context-after.txt"
printf '%s  %s\n' "$BEFORE_SHA" "onca-8x1-v3.sh.before" > "$EVIDENCE/SHA256SUMS"
printf '%s  %s\n' "$AFTER_SHA" "onca-8x1-v3.sh.after" >> "$EVIDENCE/SHA256SUMS"

cat <<EOF
ONCA_V3_HOTFIX_RETURN_TRAPS: PASS
PATCHED_TRAPS=2
BEFORE_SHA256=$BEFORE_SHA
AFTER_SHA256=$AFTER_SHA
BRIDGE=/usr/local/bin/onca-codex-remote
TIMER=inactive
ROUTER_CONFIG_CHANGED=false
WORKER_CHANGED=false
PREPARE_RERUN_REQUIRED=false
EVIDENCE_DIR=$EVIDENCE
NEXT_PHASE=ROUTER_ROUTE_ADMISSION
EOF
