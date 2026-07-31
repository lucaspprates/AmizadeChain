#!/usr/bin/env bash
set -Eeuo pipefail
umask 0077

COMMIT='df07b3b5ec850e87cb1dee17025e32eec34bc194'
BASE="https://raw.githubusercontent.com/lucaspprates/AmizadeChain/${COMMIT}/tmp/onca-8x1-v2"
DL='/tmp/onca-8x1-v2-download'
STAGE='/tmp/onca-8x1-v2-extract'
PKG='/tmp/ONCA_8X1_V2'
ARCHIVE="$DL/ONCA_8X1_V2.tar.xz"

EXPECTED=(
  'e558b2d9310e4b501e5abb074eacb2538e9fd714'
  '3d2a1916a715c26cfee7742a7b2cc53a5dfe423d'
  'ffe6a18a2b8a22383ce1b50e63d0b548d7fa14b4'
  'ec667655acb50ddb08d82b772fb7542e69d725f8'
)

fail() {
  echo "ERRO: $*" >&2
  echo 'ONCA_8X1_V2_INSTALL: BLOCKED'
  echo "FAILURE_CODE=${1:-UNKNOWN}"
  exit 1
}

[[ "$(id -un)" == 'ubuntu' ]] || fail USER_MISMATCH
[[ "$(hostname -s)" == 'zoe-infranetwork-com-br' ]] || fail HOST_MISMATCH
[[ "$(systemctl is-active zoe-coder-reconcile.timer 2>/dev/null || true)" == 'inactive' ]] || fail TIMER_NOT_INACTIVE

ACTIVE="$(
  systemctl list-units \
    'zoe-coder-job@*.service' \
    'zoe-coder-wake@*.service' \
    --state=active,activating \
    --no-legend --no-pager 2>/dev/null |
  wc -l
)"
[[ "$ACTIVE" -eq 0 ]] || fail ACTIVE_UNITS_PRESENT

command -v curl >/dev/null || fail CURL_MISSING
command -v git >/dev/null || fail GIT_MISSING
command -v python3 >/dev/null || fail PYTHON3_MISSING
command -v xz >/dev/null || fail XZ_MISSING
command -v tar >/dev/null || fail TAR_MISSING

rm -rf "$DL" "$STAGE" "$PKG"
mkdir -p "$DL" "$STAGE"

echo '===== 1. DOWNLOAD IMUTÁVEL ====='
for INDEX in 0 1 2 3; do
  PART="$(printf '%02d' "$INDEX")"
  FILE="$DL/part-$PART.txt"
  curl -fsSL "$BASE/package/part-$PART.txt" -o "$FILE"
  ACTUAL="$(git hash-object "$FILE")"
  WANT="${EXPECTED[$INDEX]}"
  echo "part-$PART esperado=$WANT"
  echo "part-$PART baixado=$ACTUAL"
  [[ "$ACTUAL" == "$WANT" ]] || fail "PART_${PART}_HASH_MISMATCH"
done

echo
echo '===== 2. RECONSTRUÇÃO ATÔMICA ====='
python3 - "$DL" "$ARCHIVE" <<'PY'
import base64
import binascii
import os
from pathlib import Path
import sys

dl = Path(sys.argv[1])
out = Path(sys.argv[2])
parts = [dl / f"part-{i:02d}.txt" for i in range(4)]
chunks = []
for path in parts:
    raw = path.read_bytes()
    compact = b"".join(raw.split())
    if not compact:
        raise SystemExit(f"empty part: {path}")
    chunks.append(compact)
encoded = b"".join(chunks)
if len(encoded) % 4:
    raise SystemExit(f"invalid base64 length: {len(encoded)}")
try:
    decoded = base64.b64decode(encoded, validate=True)
except binascii.Error as exc:
    raise SystemExit(f"invalid base64: {exc}") from exc
if not decoded.startswith(b"\xfd7zXZ\x00"):
    raise SystemExit("decoded payload is not XZ")
tmp = out.with_suffix(out.suffix + ".tmp")
with tmp.open("wb") as fh:
    fh.write(decoded)
    fh.flush()
    os.fsync(fh.fileno())
tmp.replace(out)
print(f"encoded_bytes={len(encoded)}")
print(f"archive_bytes={len(decoded)}")
PY

xz -t "$ARCHIVE" || fail XZ_INTEGRITY_FAILED
tar -tJf "$ARCHIVE" >/dev/null || fail TAR_INTEGRITY_FAILED

echo "archive_sha256=$(sha256sum "$ARCHIVE" | awk '{print $1}')"
echo "archive_bytes=$(stat -c '%s' "$ARCHIVE")"

echo
echo '===== 3. EXTRAÇÃO E VALIDAÇÃO ====='
tar -xJf "$ARCHIVE" -C "$STAGE"
ENTRY="$(find "$STAGE" -maxdepth 5 -type f -name 'onca-8x1-v2.sh' -print -quit)"
[[ -n "$ENTRY" ]] || fail ENTRYPOINT_MISSING
SOURCE_ROOT="$(dirname "$ENTRY")"
mkdir -p "$PKG"
cp -a "$SOURCE_ROOT/." "$PKG/"

REQUIRED=(
  "$PKG/onca-8x1-v2.sh"
  "$PKG/control-plane/onca_remote_bridge.sh"
  "$PKG/worker/remote_job_runner.py"
  "$PKG/worker/ONCA_WORKER_POLICY.md"
  "$PKG/worker/AGENTS.md"
  "$PKG/README.md"
  "$PKG/MANIFEST.json"
)
for FILE in "${REQUIRED[@]}"; do
  [[ -f "$FILE" ]] || fail "REQUIRED_FILE_MISSING:$FILE"
done

chmod 700 "$PKG/onca-8x1-v2.sh" "$PKG/control-plane/onca_remote_bridge.sh"
bash -n "$PKG/onca-8x1-v2.sh"
bash -n "$PKG/control-plane/onca_remote_bridge.sh"
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile "$PKG/worker/remote_job_runner.py"

find "$PKG" -type d -exec chmod go-w {} +
find "$PKG" -type f -exec chmod go-w {} +

echo
echo 'ONCA_8X1_V2_INSTALLED: PASS'
echo "PACKAGE_COMMIT=$COMMIT"
echo "PACKAGE_DIR=$PKG"
echo "ARCHIVE_SHA256=$(sha256sum "$ARCHIVE" | awk '{print $1}')"
echo 'PRODUCTION_CHANGED=false'
echo 'TIMER_CHANGED=false'
