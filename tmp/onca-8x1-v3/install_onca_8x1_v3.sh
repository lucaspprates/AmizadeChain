#!/usr/bin/env bash
set -Eeuo pipefail

PACKAGE="ONCA_8X1_V3"
PACKAGE_COMMIT="da505b1d8da2dda2623e3789637b856149fad9a6"
BASE_URL="${ONCA_PACKAGE_BASE_URL:-https://raw.githubusercontent.com/lucaspprates/AmizadeChain/$PACKAGE_COMMIT/tmp/onca-8x1-v3/package}"
DEST="${1:-/tmp}"
TARGET="$DEST/$PACKAGE"
DOWNLOAD="$(mktemp -d /tmp/onca-v3-download.XXXXXX)"
PAYLOAD="$DOWNLOAD/$PACKAGE.tar.xz.b64"
ARCHIVE="$DOWNLOAD/$PACKAGE.tar.xz"
EXPECTED_PAYLOAD_SIZE=17688
EXPECTED_PAYLOAD_SHA256="2d7988fa27b4e6d0709b6eb28a5f76d3da21284277f5ea9c1c23cf3ab0acb4b3"
EXPECTED_ARCHIVE_SIZE=13264
EXPECTED_ARCHIVE_SHA256="52a927fcfb97ad9a963a7f93e2ae52690554da841706dfeac5760b2b090949e1"
PART_HASHES=(
  6598313223022e37e3effece8ab573d7f9827e9817ec46f660ed4c7453617ad1
  db2d0d90027f137e4dd51fdff8a3685d7f373bcb494a0a9464b822f815d5e9f8
  876490393716ceee0b908e7b3cffe4445b98a11c858483ce451dd10a57c53667
  e19c38e6cb02fa48a37ccc84ab9d42abf4db693b39c583c482e0a317c4acd4e7
  c3cef41cee3c51fde0ecb39f6cc7151496339561457918ab43029d4dd00e4e35
  ef55fb4182bd3b3b67b71cc7037e2e8f55a8e4577ce2bc75a1f8ffd2772f3c36
)
cleanup() { rm -rf "$DOWNLOAD"; }
trap cleanup EXIT
fail() { echo "ERRO: $*" >&2; exit 1; }

[[ -n "${BASH_VERSION:-}" ]] || fail "execute com Bash"
[[ "${BASH_SOURCE[0]}" == "$0" ]] || fail "não use source"
[[ "$(id -u)" -ne 0 ]] || fail "execute como ubuntu, sem sudo"
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail "execute na Zoe de produção"
for cmd in curl sha256sum base64 tar python3 stat; do command -v "$cmd" >/dev/null || fail "$cmd ausente"; done

mkdir -p "$DEST"
for idx in 0 1 2 3 4 5; do
  part="$(printf '%02d' "$idx")"
  file="$DOWNLOAD/part-$part.txt"
  curl -fsSL --retry 3 --retry-delay 1 "$BASE_URL/part-$part.txt" -o "$file"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  expected="${PART_HASHES[$idx]}"
  echo "part-$part expected=$expected actual=$actual"
  [[ "$actual" == "$expected" ]] || fail "part-$part divergente"
done
cat "$DOWNLOAD"/part-{00..05}.txt > "$PAYLOAD"
[[ "$(stat -c %s "$PAYLOAD")" == "$EXPECTED_PAYLOAD_SIZE" ]] || fail "tamanho Base64 divergente"
[[ "$(sha256sum "$PAYLOAD" | awk '{print $1}')" == "$EXPECTED_PAYLOAD_SHA256" ]] || fail "SHA Base64 divergente"
base64 -d "$PAYLOAD" > "$ARCHIVE"
[[ "$(stat -c %s "$ARCHIVE")" == "$EXPECTED_ARCHIVE_SIZE" ]] || fail "tamanho do archive divergente"
[[ "$(sha256sum "$ARCHIVE" | awk '{print $1}')" == "$EXPECTED_ARCHIVE_SHA256" ]] || fail "SHA do archive divergente"
tar -tJf "$ARCHIVE" >/dev/null
rm -rf "$TARGET"
tar -xJf "$ARCHIVE" -C "$DEST"

python3 - "$TARGET" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]); manifest=json.loads((root/'MANIFEST.json').read_text())
assert manifest['package']=='ONCA_8X1_V3'
for item in manifest['files']:
    path=root/item['path']; assert path.is_file(),item
    actual=hashlib.sha256(path.read_bytes()).hexdigest(); assert actual==item['sha256'],(item,actual)
print(f"PACKAGE_MANIFEST: PASS files={len(manifest['files'])}")
PY
chmod 700 "$TARGET/onca-8x1-v3.sh" "$TARGET/control-plane/onca_remote_bridge.sh" "$TARGET/worker/remote_job_runner.py"
bash -n "$TARGET/onca-8x1-v3.sh"
bash -n "$TARGET/control-plane/onca_remote_bridge.sh"
python3 -m py_compile "$TARGET/worker/remote_job_runner.py"
rm -rf "$TARGET/worker/__pycache__"

cat <<EOF

ONCA_8X1_V3_INSTALLED: PASS
PACKAGE_DIR=$TARGET
PACKAGE_COMMIT=$PACKAGE_COMMIT
ARCHIVE_SHA256=$EXPECTED_ARCHIVE_SHA256
CONTROL_PLANE_CHANGED=false
WORKER_CHANGED=false

PRÓXIMO COMANDO:
cd "$TARGET" && ./onca-8x1-v3.sh prepare
EOF
