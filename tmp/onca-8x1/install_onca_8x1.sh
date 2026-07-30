#!/usr/bin/env bash
set -Eeuo pipefail

PACKAGE_COMMIT="a222819559336661a403b2357bdc9ad755f3de56"
PACKAGE_ROOT="tmp/onca-8x1"
TARGET="/tmp/ONCA_8X1"
B64="/tmp/ONCA_8X1.tar.xz.b64"
ARCHIVE="/tmp/ONCA_8X1.tar.xz"

PARTS=(
  "ONCA_8X1.part.00"
  "ONCA_8X1.part.01"
  "ONCA_8X1.part.02"
  "ONCA_8X1.part.03"
)
PART_SHA256=(
  "16b4ce9f97c4c2fda057b28c37c935c38d45d77445a1decaf0882ef0d8002139"
  "404e53366ab4676a8f8f402c63cbfcc749a7a816a7e4da54445ed7ae898d5877"
  "6ea6a4861d0c1f8432d243e87d0b8b93a05f324ffe6d96f31107f0abb4a61e1d"
  "90e4e3bcb3083c87d7616224196ed65cf6bac18e4d0bf46fd05ba056615a75b9"
)
B64_SHA256="69f4522fa07b4a51d58737bbd781c2727f130b01d161d39865d2802f5c0c2f6d"
ARCHIVE_SHA256="a49de39600bdef6caebd3f846529f90598ea2c49c7751f8a6fe22f48112dcd9a"

[[ "$(id -u)" -ne 0 ]] || { echo "ERRO: execute como ubuntu, sem sudo" >&2; exit 2; }
[[ "${BASH_SOURCE[0]}" == "$0" ]] || { echo "ERRO: não use source" >&2; return 2; }
command -v curl >/dev/null
command -v sha256sum >/dev/null
command -v base64 >/dev/null
command -v tar >/dev/null
command -v python3 >/dev/null

TMP_DIR="$(mktemp -d /tmp/onca-8x1-installer.XXXXXX)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "[1/6] Baixando quatro blocos imutáveis..."
for i in "${!PARTS[@]}"; do
  part="${PARTS[$i]}"
  url="https://raw.githubusercontent.com/lucaspprates/AmizadeChain/${PACKAGE_COMMIT}/${PACKAGE_ROOT}/${part}"
  curl -fsSL "$url" -o "$TMP_DIR/$part"
  printf '%s  %s\n' "${PART_SHA256[$i]}" "$TMP_DIR/$part" | sha256sum -c -
done

echo "[2/6] Reconstruindo Base64..."
: > "$B64"
for part in "${PARTS[@]}"; do
  cat "$TMP_DIR/$part" >> "$B64"
done
printf '%s  %s\n' "$B64_SHA256" "$B64" | sha256sum -c -

echo "[3/6] Reconstruindo arquivo..."
base64 -d "$B64" > "$ARCHIVE"
printf '%s  %s\n' "$ARCHIVE_SHA256" "$ARCHIVE" | sha256sum -c -

echo "[4/6] Testando integridade..."
tar -tJf "$ARCHIVE" >/dev/null

echo "[5/6] Extraindo pacote..."
rm -rf "$TARGET" /tmp/onca-8x1
tar -xJf "$ARCHIVE" -C /tmp
mv /tmp/onca-8x1 "$TARGET"
find "$TARGET" -type f -name '*.sh' -exec chmod 700 {} +
find "$TARGET" -type f -name '*.py' -exec chmod 700 {} +

echo "[6/6] Validando executáveis..."
for required in \
  run_onca_8x1.sh \
  teardown_worker.sh \
  scripts/worker_bootstrap.sh \
  scripts/codex_remote_bridge.sh \
  scripts/remote_run_codex_job.py \
  scripts/patch_router_config.py \
  scripts/deploy_runtime_candidate.sh \
  prompts/zcr19-writer.md \
  prompts/zcr19-gate.md \
  prompts/scheduler-integration.md \
  prompts/scheduler-gate.md; do
  [[ -f "$TARGET/$required" ]] || { echo "ERRO: arquivo ausente: $required" >&2; exit 3; }
done

bash -n "$TARGET/run_onca_8x1.sh"
bash -n "$TARGET/teardown_worker.sh"
bash -n "$TARGET/scripts/worker_bootstrap.sh"
bash -n "$TARGET/scripts/codex_remote_bridge.sh"
bash -n "$TARGET/scripts/deploy_runtime_candidate.sh"
python3 -m py_compile \
  "$TARGET/scripts/remote_run_codex_job.py" \
  "$TARGET/scripts/patch_router_config.py"
rm -rf "$TARGET/scripts/__pycache__"

cat <<OUT

ONCA_8X1_INSTALLED: PASS
PACKAGE_DIR=$TARGET
PACKAGE_COMMIT=$PACKAGE_COMMIT
PACKAGE_BASE64_SHA256=$B64_SHA256
ARCHIVE_SHA256=$ARCHIVE_SHA256
PRODUCTION_CHANGED=false
TIMER_CHANGED=false

PRÓXIMO COMANDO:
cd "$TARGET" && ./run_onca_8x1.sh
OUT
