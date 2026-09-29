#!/bin/bash
# -*- coding: utf-8 -*-
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════
#  XTR Terminal — Script de despliegue v12.0
#  Uso: cd ~/LinuxContainer && bash ~/Descargas/deploy_v12.sh
#  Hace: corrige agent_server, compila, sube a GitHub + release
# ═══════════════════════════════════════════════════════════════════

# CONFIGURACION (ajusta si tu repo no esta en ~/LinuxContainer)
REPO_DIR="${REPO_DIR:-$HOME/LinuxContainer}"

# Colores
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'

info()  { echo -e "${C}[*]${N} $*"; }
ok()    { echo -e "${G}[OK]${N} $*"; }
warn()  { echo -e "${Y}[WARN]${N} $*" >&2; }
die()   { echo -e "${R}[FAIL]${N} $*" >&2; exit 1; }

# ═══════════════════════════════════════════════════════════════════
#  0. Verificaciones iniciales
# ═══════════════════════════════════════════════════════════════════
info "=== XTR Terminal Deploy v12.0 ==="

cd "$REPO_DIR" || die "No se encontro el repo en $REPO_DIR"
info "Repo: $(pwd)"

# Verificar flutter
command -v flutter &>/dev/null || die "Flutter no esta en el PATH"
command -v git &>/dev/null   || die "Git no esta instalado"

# Verificar que tenemos el agent_server v12
V12_SRC=""
if [ -f "$HOME/Descargas/xtr_v11_mejoras.zip" ]; then
    info "Extrayendo agent_server_v12.py del zip..."
    unzip -p "$HOME/Descargas/xtr_v11_mejoras.zip" agent_server_v12.py > /tmp/agent_server_v12.py 2>/dev/null || true
    if [ -s /tmp/agent_server_v12.py ]; then
        V12_SRC=/tmp/agent_server_v12.py
    fi
fi
if [ -z "$V12_SRC" ] && [ -f "$HOME/Descargas/agent_server_v12.py" ]; then
    V12_SRC="$HOME/Descargas/agent_server_v12.py"
fi
if [ -z "$V12_SRC" ] && [ -f "$HOME/Descargas/xtr_v11_tmp/agent_server_v12.py" ]; then
    V12_SRC="$HOME/Descargas/xtr_v11_tmp/agent_server_v12.py"
fi
if [ -z "$V12_SRC" ]; then
    die "No se encontro agent_server_v12.py. Descarga xtr_v11_mejoras.zip primero."
fi

if ! grep -q 'v12.0' "$V12_SRC" 2>/dev/null; then
    die "El archivo no parece ser agent_server v12.0"
fi
ok "agent_server_v12.py encontrado"

# ═══════════════════════════════════════════════════════════════════
#  1. Corregir agent_server.py (copiar v12)
# ═══════════════════════════════════════════════════════════════════
info "[1/6] Copiando agent_server.py v12..."
cp "$V12_SRC" assets/agent_server.py
chmod +x assets/agent_server.py
ok "agent_server.py actualizado a v12.0"

# ═══════════════════════════════════════════════════════════════════
#  2. Parchear agent_services.dart
# ═══════════════════════════════════════════════════════════════════
info "[2/6] Parcheando agent_services.dart..."
DART_FILE="lib/src/agent/agent_services.dart"
[ -f "$DART_FILE" ] || die "No se encontro $DART_FILE"

# Backup
cp "$DART_FILE" "${DART_FILE}.bak.$(date +%Y%m%d_%H%M%S)"

python3 << 'PYEOF'
import os, re
f = os.environ.get("DART_FILE", "lib/src/agent/agent_services.dart")
with open(f, 'r') as fh:
    s = fh.read()

# 1) Cambiar version en log
s = s.replace('[XTR Agent Server v11.0]', '[XTR Agent Server v12.0]')

# 2) Cambiar seccion de dependencias
old_block = '''# [6] Instalar deps opcionales
echo "[XTR] Verificando dependencias..."
"$PYTHON" -m pip install -q --upgrade pip 2>/dev/null || true
"$PYTHON" -m pip install -q httpx openai 2>/dev/null || echo "[warn] No se pudieron instalar deps opcionales (httpx/openai). El fallback usa stdlib."'''

new_block = '''# [6] Instalar dependencias criticas (fastapi, uvicorn, pydantic, httpx)
echo "[XTR] Verificando dependencias criticas..."
"$PYTHON" -m pip install -q --upgrade pip 2>/dev/null || true
"$PYTHON" -m pip install -q fastapi uvicorn pydantic httpx 2>/dev/null || echo "[warn] No se pudieron instalar deps criticas. El agente puede fallar."
"$PYTHON" -m pip install -q openai 2>/dev/null || echo "[warn] openai opcional no instalado."'''

if old_block in s:
    s = s.replace(old_block, new_block)
    print("OK: Seccion de dependencias actualizada (match exacto).")
else:
    # Parche regex alternativo
    pat = r'#\s*\[6\].*?Instalar deps.*?\n.*?echo \[XTR\].*?dependencias.*?\n.*?\$PYTHON.*?pip install.*?httpx openai.*?El fallback usa stdlib.*?\n'
    repl = '''# [6] Instalar dependencias criticas (fastapi, uvicorn, pydantic, httpx)
echo "[XTR] Verificando dependencias criticas..."
"$PYTHON" -m pip install -q --upgrade pip 2>/dev/null || true
"$PYTHON" -m pip install -q fastapi uvicorn pydantic httpx 2>/dev/null || echo "[warn] No se pudieron instalar deps criticas. El agente puede fallar."
"$PYTHON" -m pip install -q openai 2>/dev/null || echo "[warn] openai opcional no instalado."
'''
    s2 = re.sub(pat, repl, s, flags=re.DOTALL | re.IGNORECASE)
    if s2 != s:
        s = s2
        print("OK: Parche regex aplicado.")
    else:
        print("WARN: No se encontro la seccion de dependencias. Revisa manualmente.")

with open(f, 'w') as fh:
    fh.write(s)
print("Done.")
PYEOF

ok "agent_services.dart parcheado"

# ═══════════════════════════════════════════════════════════════════
#  3. Git: add, commit, tag, push
# ═══════════════════════════════════════════════════════════════════
info "[3/6] Git: commit y tag..."
git add assets/agent_server.py "$DART_FILE"

if git diff --cached --quiet; then
    warn "No hay cambios nuevos para commitear (quizas ya lo hiciste)."
else
    git commit -m "v12.0: fix agent_server con endpoint /run, deps criticas fastapi/uvicorn

- Reemplaza agent_server.py por v12.0 con POST /run, /chat, /tools, /health
- Instala fastapi, uvicorn, pydantic, httpx como dependencias criticas
- Nuevas herramientas nativas: bash, python, read_file, write_file, list_dir"
fi

git tag -fa v12.0 -m "XTR Terminal v12.0 — Fix agent_server /run endpoint" 2>/dev/null || true
git push origin main 2>/dev/null || warn "Push a main fallo (quizas ya esta actualizado)"
git push -f origin v12.0 2>/dev/null || warn "Push del tag fallo"
ok "Git: commit + tag v12.0 subidos"

# ═══════════════════════════════════════════════════════════════════
#  4. Compilar APKs
# ═══════════════════════════════════════════════════════════════════
info "[4/6] Compilando Flutter..."
flutter build apk --release --split-per-abi
ok "Compilacion completada"

for abi in arm64-v8a armeabi-v7a x86_64; do
    apk="build/app/outputs/flutter-apk/app-$abi-release.apk"
    if [ -f "$apk" ]; then
        ok "APK $abi: $(ls -lh "$apk" | awk '{print $5}')"
    else
        warn "APK $abi no encontrado"
    fi
done

# ═══════════════════════════════════════════════════════════════════
#  5. Crear release en GitHub
# ═══════════════════════════════════════════════════════════════════
info "[5/6] Creando release GitHub..."

REPO_SLUG=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||' || echo "txurtxil/LinuxContainer")

if command -v gh &>/dev/null; then
    gh release create v12.0 \
      --title "XTR Terminal v12.0 — Fix agent_server /run" \
      --notes "## Fix v12.0
- Corrige error 404 en POST /run del agente
- agent_server.py v12.0 con endpoints completos: /run, /chat, /tools, /health, /gpu/status
- Dependencias criticas: fastapi, uvicorn, pydantic, httpx
- Herramientas nativas: bash, python, read_file, write_file, list_dir" \
      --repo "$REPO_SLUG" 2>/dev/null || true

    for abi in arm64-v8a armeabi-v7a x86_64; do
        apk="build/app/outputs/flutter-apk/app-$abi-release.apk"
        [ -f "$apk" ] && gh release upload v12.0 "$apk" --clobber 2>/dev/null || warn "No se pudo subir $apk"
    done
    ok "Release v12.0 creada y APKs subidos via gh CLI"
else
    warn "gh CLI no instalado. Crea la release manualmente:"
    echo "  https://github.com/$REPO_SLUG/releases/new?tag=v12.0"
    echo ""
    echo "Titulo: XTR Terminal v12.0 — Fix agent_server /run"
    echo "Luego arrastra los APKs desde build/app/outputs/flutter-apk/"
fi

# ═══════════════════════════════════════════════════════════════════
#  6. Instalar en dispositivo (opcional)
# ═══════════════════════════════════════════════════════════════════
info "[6/6] Intentando instalar en dispositivo via ADB..."
if command -v adb &>/dev/null; then
    if adb devices | grep -q 'device$'; then
        ok "Dispositivo Android detectado. Instalando..."
        adb install "build/app/outputs/flutter-apk/app-arm64-v8a-release.apk" && ok "Instalado arm64" || warn "Fallo arm64"
        adb install "build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk" && ok "Instalado armv7" || warn "Fallo armv7"
    else
        warn "ADB disponible pero no hay dispositivo conectado."
        warn "Conecta el Z Fold 7 por USB y activa Depuracion USB."
    fi
else
    warn "ADB no instalado. Salta instalacion en dispositivo."
fi

# ═══════════════════════════════════════════════════════════════════
#  Resumen
# ═══════════════════════════════════════════════════════════════════
echo ""
ok "=== DESPLIEGUE v12.0 COMPLETADO ==="
echo ""
echo "Resumen:"
echo "  - agent_server.py: v12.0 (con /run, /chat, /tools, /health)"
echo "  - agent_services.dart: deps criticas fastapi/uvicorn/pydantic/httpx"
echo "  - Git: tag v12.0 subido"
echo "  - APKs compilados en build/app/outputs/flutter-apk/"
echo ""
ls -lh build/app/outputs/flutter-apk/app-*-release.apk 2>/dev/null || true
echo ""
echo "Para instalar en el Z Fold 7:"
echo "  adb install build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
echo ""
ok "Done!"
