#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "ERRO: execute este arquivo com Bash." >&2
  exit 2
fi

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "ERRO: não use source. Execute o arquivo diretamente." >&2
  return 2 2>/dev/null || exit 2
fi

if [[ "$(id -u)" -eq 0 ]]; then
  echo "ERRO: execute como usuário normal, sem sudo." >&2
  exit 2
fi

DEST="${1:-/tmp}"
DIR="$DEST/FABRICA_ZOE_URGENTE_V2"
B64="$DEST/FABRICA_ZOE_URGENTE_V2.tar.xz.b64"
ARCHIVE="$DEST/FABRICA_ZOE_URGENTE_V2.tar.xz"
PACKAGE_COMMIT="a7049a4a86de4ae6bb0be97db92036e1d34ec462"
PACKAGE_URL="https://raw.githubusercontent.com/lucaspprates/AmizadeChain/${PACKAGE_COMMIT}/tmp/fabrica-zoe-urgente-v2/FABRICA_ZOE_URGENTE_V2.tar.xz.b64"
EXPECTED_B64_SHA="3d5b8e43db219120342d6cface553d4b72bae6a299593da0817a6b6f9e66ad47"
EXPECTED_ARCHIVE_SHA="fa20bf38a105210bc8aa6afae6452782daee6115f0387b705feb478fa71debe3"

for cmd in curl base64 sha256sum tar; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERRO: comando ausente: $cmd" >&2
    exit 3
  }
done

mkdir -p "$DEST"

echo "[1/5] Baixando pacote V2..."
curl -fsSL "$PACKAGE_URL" -o "$B64"

echo "[2/5] Validando Base64..."
echo "$EXPECTED_B64_SHA  $B64" | sha256sum -c -

echo "[3/5] Reconstruindo arquivo..."
base64 -d "$B64" > "$ARCHIVE"
echo "$EXPECTED_ARCHIVE_SHA  $ARCHIVE" | sha256sum -c -

echo "[4/5] Testando integridade..."
tar -tJf "$ARCHIVE" >/dev/null

echo "[5/5] Extraindo pacote..."
rm -rf "$DIR"
tar -xJf "$ARCHIVE" -C "$DEST"

for required in \
  "$DIR/00_LEIA_PRIMEIRO_SEGURANCA.md" \
  "$DIR/00_COMECE_AQUI.md" \
  "$DIR/09_PROMPT_MESTRE_ZOE.md" \
  "$DIR/MANIFEST.json" \
  "$DIR/scripts/00_preflight_control_plane.sh"
do
  [[ -f "$required" ]] || {
    echo "ERRO: arquivo obrigatório ausente: $required" >&2
    exit 4
  }
done

chmod 700 "$DIR"/scripts/*.sh

cat <<EOF

FABRICA_ZOE_URGENTE_V2_INSTALLED: PASS
PACKAGE_DIR=$DIR
PACKAGE_COMMIT=$PACKAGE_COMMIT
PACKAGE_ARCHIVE_SHA256=$EXPECTED_ARCHIVE_SHA
FACTORY_CONSOLE_IN_SCOPE=false
PRODUCTION_CHANGED=false
TIMER_CHANGED=false

PRÓXIMO COMANDO SEGURO E SOMENTE LEITURA:
cd "$DIR" && ./scripts/00_preflight_control_plane.sh
EOF
