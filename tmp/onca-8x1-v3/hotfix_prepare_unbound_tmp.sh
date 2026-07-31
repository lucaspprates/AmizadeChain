#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

SCRIPT="/tmp/ONCA_8X1_V3/onca-8x1-v3.sh"
LINE_NO=225
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="/tmp/evidence/onca-v3-hotfix-unbound-tmp-${STAMP}"
BACKUP="$EVIDENCE/onca-8x1-v3.sh.before"
CONTEXT="$EVIDENCE/context-before.txt"

fail() {
  echo "ERRO: $*" >&2
  echo "ONCA_V3_HOTFIX_UNBOUND_TMP: BLOCKED"
  echo "EVIDENCE_DIR=$EVIDENCE"
  exit 1
}

[[ "$(id -un)" == "ubuntu" ]] || fail "execute como ubuntu"
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail "execute na Zoe de produção"
[[ -f "$SCRIPT" ]] || fail "script V3 ausente: $SCRIPT"
[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == "inactive" ]] || fail "timer não está inactive"

mkdir -p "$EVIDENCE"
cp -a "$SCRIPT" "$BACKUP"
nl -ba "$SCRIPT" | sed -n '215,232p' | tee "$CONTEXT"

ORIGINAL="$(sed -n "${LINE_NO}p" "$SCRIPT")"
printf 'line_%s_original=%q\n' "$LINE_NO" "$ORIGINAL" | tee "$EVIDENCE/original-line.txt"

[[ "$ORIGINAL" == *'$tmp'* || "$ORIGINAL" == *'${tmp}'* ]] ||
  fail "linha $LINE_NO não contém referência explícita a tmp; recusei patch"

grep -q 'OPERACAO_ONCA_8X1_V3_PREPARE: PASS' "$SCRIPT" ||
  fail "marcador PREPARE PASS ausente"
grep -q 'NEXT_PHASE=ROUTER_ROUTE_ADMISSION' "$SCRIPT" ||
  fail "marcador de próxima fase ausente"

python3 - "$SCRIPT" "$LINE_NO" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
line_no = int(sys.argv[2])
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
if len(lines) < line_no:
    raise SystemExit(f"script has only {len(lines)} lines")
newline = "\n" if lines[line_no - 1].endswith("\n") else ""
lines[line_no - 1] = ": # HOTFIX ONCA V3: post-PASS reference to unbound tmp removed" + newline
path.write_text("".join(lines), encoding="utf-8")
PY

chmod 700 "$SCRIPT"
bash -n "$SCRIPT" || {
  cp -a "$BACKUP" "$SCRIPT"
  fail "bash -n falhou; backup restaurado"
}

[[ -x /usr/local/bin/onca-codex-remote ]] || {
  cp -a "$BACKUP" "$SCRIPT"
  fail "bridge ausente ou não executável; backup restaurado"
}

AFTER_SHA="$(sha256sum "$SCRIPT" | awk '{print $1}')"
BEFORE_SHA="$(sha256sum "$BACKUP" | awk '{print $1}')"

nl -ba "$SCRIPT" | sed -n '220,228p' > "$EVIDENCE/context-after.txt"
printf '%s  %s\n' "$BEFORE_SHA" "onca-8x1-v3.sh.before" > "$EVIDENCE/SHA256SUMS"
printf '%s  %s\n' "$AFTER_SHA" "onca-8x1-v3.sh.after" >> "$EVIDENCE/SHA256SUMS"

cat <<EOF
ONCA_V3_HOTFIX_UNBOUND_TMP: PASS
PATCHED_LINE=$LINE_NO
ORIGINAL_LINE=$ORIGINAL
BEFORE_SHA256=$BEFORE_SHA
AFTER_SHA256=$AFTER_SHA
BRIDGE=/usr/local/bin/onca-codex-remote
TIMER=inactive
ROUTER_CONFIG_CHANGED=false
WORKER_CHANGED=false
EVIDENCE_DIR=$EVIDENCE
NEXT_PHASE=ROUTER_ROUTE_ADMISSION
EOF
