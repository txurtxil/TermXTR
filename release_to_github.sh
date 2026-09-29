#!/usr/bin/env bash
# release_to_github.sh — Crea la Release en GitHub y sube la APK.
#
# Sustituye a deploy_to_github.sh, que tenía VERSION hardcodeada a v13.2,
# hacía `git add .` a ciegas y recompilaba siempre.
#
# Uso:
#   ./release_to_github.sh v1.11.0
#   ./release_to_github.sh v1.11.0 --build          # recompila antes
#   ./release_to_github.sh v1.11.0 --notes "texto"  # cuerpo de la release
#
# NO commitea ni pushea codigo. Eso lo haces tu antes, a mano.
# El tag debe existir ya en el remoto.

set -uo pipefail

REPO="txurtxil/LinuxContainer"
TOKEN_FILE="$HOME/githubToken"
APK_PATH="build/app/outputs/flutter-apk/app-release.apk"

C_RESET='\e[0m'; C_B='\e[1m'; C_DIM='\e[2m'
C_GRN='\e[1;32m'; C_YEL='\e[1;33m'; C_RED='\e[1;31m'; C_CYN='\e[1;36m'
ok()   { echo -e "${C_GRN}✓${C_RESET} $1"; }
warn() { echo -e "${C_YEL}!${C_RESET} $1"; }
die()  { echo -e "${C_RED}✗${C_RESET} $1"; exit 1; }
info() { echo -e "  ${C_DIM}$1${C_RESET}"; }

VERSION="${1:-}"
[ -z "$VERSION" ] && die "Falta la version.  Uso: $0 v1.11.0 [--build] [--notes \"...\"]"
[[ "$VERSION" == v* ]] || die "La version debe empezar por 'v': $VERSION"

DO_BUILD=0
NOTES=""
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --build) DO_BUILD=1 ;;
    --notes) shift; NOTES="${1:-}" ;;
    *) die "Flag desconocido: $1" ;;
  esac
  shift
done
[ -z "$NOTES" ] && NOTES="Release $VERSION"

echo -e "${C_CYN}${C_B}▸ Release $VERSION → $REPO${C_RESET}"
echo ""

# ── Token ─────────────────────────────────────────────────────
[ -f "$TOKEN_FILE" ] || die "Token no encontrado en $TOKEN_FILE"
TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
[ -n "$TOKEN" ] || die "$TOKEN_FILE esta vacio."
ok "token cargado"

api() {  # api <metodo> <url> [datos]
  local method="$1" url="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -sS -X "$method" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -d "$data" "$url"
  else
    curl -sS -X "$method" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" "$url"
  fi
}

# ── El tag tiene que existir en el remoto ─────────────────────
if ! git ls-remote --tags origin "refs/tags/$VERSION" 2>/dev/null | grep -q "$VERSION"; then
  die "El tag $VERSION no esta en el remoto.

  Primero:
    git tag -a $VERSION -m \"...\"
    git push origin $VERSION"
fi
ok "tag $VERSION existe en el remoto"

# ── Build opcional ────────────────────────────────────────────
if [ "$DO_BUILD" = "1" ]; then
  echo ""
  echo -e "${C_CYN}▸ flutter build apk --release${C_RESET}"
  flutter build apk --release || die "La compilacion fallo."
  ok "compilado"
fi

[ -f "$APK_PATH" ] || die "No hay APK en $APK_PATH  (usa --build)"

APK_BYTES=$(stat -c%s "$APK_PATH")
APK_MB=$((APK_BYTES / 1024 / 1024))
APK_AGE=$(( ($(date +%s) - $(stat -c%Y "$APK_PATH")) / 60 ))
ok "APK: ${APK_MB} MB, compilada hace ${APK_AGE} min"

if [ "$APK_BYTES" -gt 2147483648 ]; then
  die "La APK pesa ${APK_MB} MB. GitHub corta los assets en 2 GB."
fi
if [ "$APK_MB" -gt 500 ]; then
  warn "${APK_MB} MB es mucho para una APK. La subida ira lenta."
fi
if [ "$APK_AGE" -gt 60 ]; then
  warn "La APK tiene ${APK_AGE} min. ¿Seguro que incluye los ultimos cambios?"
  read -rp "$(echo -e "  ¿Subir esta? ${C_YEL}[s/N]${C_RESET} ")" c
  [[ "$c" != "s" && "$c" != "S" ]] && { echo "Cancelado. Relanza con --build."; exit 0; }
fi

# ── Aviso si hay codigo sin pushear ───────────────────────────
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  warn "Hay cambios sin commitear — no iran en esta release."
fi

# ── ¿Existe ya la release? ────────────────────────────────────
echo ""

# El JSON de GitHub no se parsea con grep sin acabar mal. python3 esta
# garantizado aqui, asi que lo usamos.
jget() {  # jget <expresion python sobre 'd'>  — lee el JSON de stdin
  python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
try:
    r = $1
    print(r if r is not None else '')
except Exception:
    pass
" 2>/dev/null
}

EXISTING="$(api GET "https://api.github.com/repos/$REPO/releases/tags/$VERSION")"
RELEASE_ID="$(echo "$EXISTING" | jget "d.get('id')")"

if [ -n "$RELEASE_ID" ]; then
  warn "La release $VERSION ya existe (id $RELEASE_ID)"

  # ¿Hay ya un asset con ese nombre? Hay que borrarlo antes de subir.
  ASSET_ID="$(echo "$EXISTING" | jget "next((a['id'] for a in d.get('assets', []) if a['name'] == 'app-release.apk'), None)")"

  if [ -n "$ASSET_ID" ]; then
    ASSET_MB="$(echo "$EXISTING" | jget "next((a['size'] // 1048576 for a in d.get('assets', []) if a['name'] == 'app-release.apk'), None)")"
    warn "Ya hay una app-release.apk subida (${ASSET_MB} MB, id $ASSET_ID)"
    read -rp "$(echo -e "  ¿Reemplazarla por la nueva? ${C_YEL}[s/N]${C_RESET} ")" c
    [[ "$c" != "s" && "$c" != "S" ]] && { echo "Cancelado."; exit 0; }
    DEL="$(api DELETE "https://api.github.com/repos/$REPO/releases/assets/$ASSET_ID")"
    # Un DELETE correcto devuelve 204 sin cuerpo.
    if [ -n "$DEL" ] && echo "$DEL" | grep -q '"message"'; then
      echo "$DEL" | head -5
      die "No se pudo borrar el asset anterior."
    fi
    ok "asset anterior borrado"
    sleep 2   # GitHub tarda un instante en liberar el nombre
  fi
else
  info "creando release..."
  BODY="$(printf '{"tag_name":"%s","name":"%s","body":"%s","draft":false,"prerelease":false}' \
    "$VERSION" "$VERSION" "$(echo "$NOTES" | sed 's/"/\\"/g')")"
  RESP="$(api POST "https://api.github.com/repos/$REPO/releases" "$BODY")"
  RELEASE_ID="$(echo "$RESP" | jget "d.get('id')")"
  if [ -z "$RELEASE_ID" ]; then
    echo "$RESP" | head -20
    die "No se pudo crear la release. Mira el error de arriba."
  fi
  ok "release creada (id $RELEASE_ID)"
fi

# ── Subir la APK ──────────────────────────────────────────────
echo ""
echo -e "${C_CYN}▸ Subiendo ${APK_MB} MB...${C_RESET}"
info "esto tarda; no cierres la terminal"

UP="$(curl -sS -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/vnd.android.package-archive" \
  --progress-bar \
  --data-binary @"$APK_PATH" \
  "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=app-release.apk")"

UP_STATE="$(echo "$UP" | jget "d.get('state')")"
if [ "$UP_STATE" = "uploaded" ]; then
  URL="$(echo "$UP" | jget "d.get('browser_download_url')")"
  echo ""
  ok "═══ SUBIDA OK ═══"
  echo ""
  echo -e "  ${C_B}$URL${C_RESET}"
  echo ""
  info "Release: https://github.com/$REPO/releases/tag/$VERSION"
else
  echo ""
  echo "$UP" | head -20
  die "La subida fallo. Mira el error de arriba."
fi
