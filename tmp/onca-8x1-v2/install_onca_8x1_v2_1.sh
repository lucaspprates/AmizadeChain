#!/usr/bin/env bash
set -Eeuo pipefail

PACKAGE_COMMIT="c32c62afffccfc8bc9058fa99229c6757b8e9d09"
PACKAGE_PATH="tmp/onca-8x1-v2/package-v2.1"
BASE_URL_DEFAULT="https://raw.githubusercontent.com/lucaspprates/AmizadeChain/${PACKAGE_COMMIT}/${PACKAGE_PATH}"
BASE_URL="${ONCA_PACKAGE_BASE_URL:-$BASE_URL_DEFAULT}"

TARGET="/tmp/ONCA_8X1_V2"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d "/tmp/onca-8x1-v2-installer-${STAMP}.XXXXXX")"
EXTRACT_ROOT="$WORK/extracted"
PAYLOAD="$WORK/ONCA_8X1_V2.tar.xz.b64"
ARCHIVE="$WORK/ONCA_8X1_V2.tar.xz"
BACKUP=""
INSTALLED=false

EXPECTED_PAYLOAD_SIZE="22208"
EXPECTED_PAYLOAD_SHA256="64736e16ded49dfe0f0fb097eb542a7e87064e6c5f2471731d4d1accccb45e75"
EXPECTED_ARCHIVE_SIZE="16656"
EXPECTED_ARCHIVE_SHA256="f314322067e44ac8329da535d6fdbdf6a3ae505f5934cd856ec38b2014f462fc"

PART_HASHES=(
  "8e2ad3f7816d4fd8c1bc04e3eaedbb141c21301dcd2a6cae69af4efeab097fb0"
  "92e8850bc1c548db9fba934f4abbe877f0c40545e13d1096039c7b46e5fd5119"
  "9fc84ea4f7dd136171db284a0cde0d4550eb465f4b17e3292126f23085f15206"
  "53b9a9a56a75aacd7e6711d1fa172b8618a49a7ebe76b1c5d5a7f5cdec9468e0"
  "3f50c3b7e418f20fec7fbde1882cabf12d68d0d342d2d73df69ee38ac4cabde5"
  "cc94ebd69d55e470d4ade64c95b6549ca4d11d274088b779e9e795dbff7cb38f"
  "4ed1e4e8b8a10bc06dddf77b47d708de5b46d92360a69f57bab50e5d0fd0ad30"
)
PART_SIZES=(3500 3500 3500 3500 3500 3500 1208)

fail() {
  echo "ERRO: $*" >&2
  exit 1
}

finish() {
  local rc=$?
  trap - EXIT
  set +e

  if [[ "$rc" -ne 0 && "$INSTALLED" == true ]]; then
    echo
    echo "===== ROLLBACK DO PACOTE ====="
    rm -rf "$TARGET"
    if [[ -n "$BACKUP" && -d "$BACKUP" ]]; then
      mv "$BACKUP" "$TARGET"
      echo "PACKAGE_ROLLBACK: PASS"
    else
      echo "PACKAGE_ROLLBACK: target removido; não havia versão anterior"
    fi
  fi

  rm -rf "$WORK"
  exit "$rc"
}
trap finish EXIT

[[ -n "${BASH_VERSION:-}" ]] || fail "execute com Bash"
[[ "${BASH_SOURCE[0]}" == "$0" ]] || fail "não use source; execute o arquivo"
[[ "$(id -u)" -ne 0 ]] || fail "execute como ubuntu, sem sudo/root"
[[ "$(hostname -s)" == "zoe-infranetwork-com-br" ]] || fail "este instalador roda somente na Zoe de produção"

for command in curl sha256sum stat base64 tar python3 git; do
  command -v "$command" >/dev/null 2>&1 || fail "comando ausente: $command"
done

mkdir -p "$EXTRACT_ROOT" "$WORK/parts"

echo "===== 1. DOWNLOAD IMUTÁVEL ====="
echo "package_commit=$PACKAGE_COMMIT"
echo "base_url=$BASE_URL"

for index in 0 1 2 3 4 5 6; do
  part="$(printf '%02d' "$index")"
  file="$WORK/parts/part-${part}.txt"
  url="$BASE_URL/part-${part}.txt"
  curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 15 "$url" -o "$file"

  actual_size="$(stat -c '%s' "$file")"
  actual_sha="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$actual_size" == "${PART_SIZES[$index]}" ]] || fail "part-${part}: tamanho divergente: $actual_size"
  [[ "$actual_sha" == "${PART_HASHES[$index]}" ]] || fail "part-${part}: SHA256 divergente: $actual_sha"
  printf 'part-%s: PASS size=%s sha256=%s\n' "$part" "$actual_size" "$actual_sha"
done

cat "$WORK"/parts/part-{00..06}.txt > "$PAYLOAD"

payload_size="$(stat -c '%s' "$PAYLOAD")"
payload_sha="$(sha256sum "$PAYLOAD" | awk '{print $1}')"
[[ "$payload_size" == "$EXPECTED_PAYLOAD_SIZE" ]] || fail "payload size divergente: $payload_size"
[[ "$payload_sha" == "$EXPECTED_PAYLOAD_SHA256" ]] || fail "payload SHA divergente: $payload_sha"
echo "payload: PASS size=$payload_size sha256=$payload_sha"

base64 -d "$PAYLOAD" > "$ARCHIVE"
archive_size="$(stat -c '%s' "$ARCHIVE")"
archive_sha="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
[[ "$archive_size" == "$EXPECTED_ARCHIVE_SIZE" ]] || fail "archive size divergente: $archive_size"
[[ "$archive_sha" == "$EXPECTED_ARCHIVE_SHA256" ]] || fail "archive SHA divergente: $archive_sha"
tar -tJf "$ARCHIVE" >/dev/null
echo "archive: PASS size=$archive_size sha256=$archive_sha"

echo
echo "===== 2. EXTRAÇÃO E CONTRATO ====="
tar -xJf "$ARCHIVE" -C "$EXTRACT_ROOT"
CANDIDATE="$EXTRACT_ROOT/ONCA_8X1_V2"
[[ -d "$CANDIDATE" ]] || fail "diretório ONCA_8X1_V2 ausente no archive"

python3 - "$CANDIDATE" <<'PY'
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
manifest_path = root / "MANIFEST.json"
if not manifest_path.is_file():
    raise SystemExit("MANIFEST.json ausente")
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
assert manifest["package"] == "ONCA_8X1_V2"
assert manifest["version"] == "2.1.0"
assert manifest["codex"]["approval_policy"] == "never"
assert manifest["codex"]["sandbox_mode"] == "danger-full-access"
assert manifest["codex"]["cli_flag"] == "--dangerously-bypass-approvals-and-sandbox"
assert manifest["codex"]["run_as"] == "onca-runner"
assert manifest["codex"]["sudo"] is False
assert manifest["contracts"]["always_emit_result"] is True
assert manifest["contracts"]["collect_failure_evidence"] is True

for item in manifest["files"]:
    path = root / item["path"]
    if not path.is_file():
        raise SystemExit(f"arquivo ausente: {item['path']}")
    data = path.read_bytes()
    actual_sha = hashlib.sha256(data).hexdigest()
    if actual_sha != item["sha256"]:
        raise SystemExit(f"SHA divergente: {item['path']}: {actual_sha}")
    if len(data) != item["bytes"]:
        raise SystemExit(f"tamanho divergente: {item['path']}: {len(data)}")
    expected_mode = int(item["mode"], 8)
    actual_mode = stat.S_IMODE(path.stat().st_mode)
    if actual_mode != expected_mode:
        raise SystemExit(
            f"modo divergente: {item['path']}: {oct(actual_mode)} != {oct(expected_mode)}"
        )
print("manifest_and_modes=PASS")
PY

bash -n "$CANDIDATE/onca-8x1-v2.sh"
bash -n "$CANDIDATE/control-plane/onca_remote_bridge.sh"
python3 -m py_compile "$CANDIDATE/worker/remote_job_runner.py"

grep -q -- '--dangerously-bypass-approvals-and-sandbox' "$CANDIDATE/onca-8x1-v2.sh"
grep -q 'approval_policy = "never"' "$CANDIDATE/onca-8x1-v2.sh"
grep -q 'sandbox_mode = "danger-full-access"' "$CANDIDATE/onca-8x1-v2.sh"
grep -q 'onca-runner ALL=.*NOPASSWD' "$CANDIDATE/onca-8x1-v2.sh" && fail "onca-runner recebeu sudo"
grep -q 'result.json' "$CANDIDATE/worker/ONCA_WORKER_POLICY.md"
grep -q 'Não use sudo' "$CANDIDATE/worker/AGENTS.md"
grep -q 'always_emit_result' "$CANDIDATE/MANIFEST.json"

echo "package_contract=PASS"

echo
echo "===== 3. INSTALAÇÃO ATÔMICA EM /tmp ====="
if [[ -e "$TARGET" ]]; then
  BACKUP="${TARGET}.previous.${STAMP}"
  [[ ! -e "$BACKUP" ]] || fail "backup já existe: $BACKUP"
  mv "$TARGET" "$BACKUP"
  echo "previous_package=$BACKUP"
fi

mv "$CANDIDATE" "$TARGET"
INSTALLED=true

[[ -x "$TARGET/onca-8x1-v2.sh" ]] || fail "orquestrador instalado não executável"
[[ -x "$TARGET/control-plane/onca_remote_bridge.sh" ]] || fail "bridge instalado não executável"
[[ -x "$TARGET/worker/remote_job_runner.py" ]] || fail "runner instalado não executável"

installed_version="$(python3 - "$TARGET/MANIFEST.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding='utf-8'))['version'])
PY
)"
[[ "$installed_version" == "2.1.0" ]] || fail "versão instalada divergente: $installed_version"

cat <<EOF

ONCA_8X1_V2_INSTALL: PASS
PACKAGE_VERSION=$installed_version
PACKAGE_COMMIT=$PACKAGE_COMMIT
PACKAGE_ARCHIVE_SHA256=$archive_sha
PACKAGE_DIR=$TARGET
PREVIOUS_PACKAGE=${BACKUP:-none}
PRODUCTION_CHANGED=false
WORKER_CHANGED=false
TIMER_CHANGED=false

PRÓXIMO COMANDO:
cd "$TARGET" && ./onca-8x1-v2.sh prepare
EOF
