#!/bin/bash
# ============================================================
# XTR Terminal — Deploy completo a GitHub
# Copia todos los ficheros al proyecto y hace push
# ============================================================
set -e
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${CYAN}[DEPLOY]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

PROJECT_DIR="$HOME/linux_container_build"
TOKEN_FILE="$HOME/githubToken"
DOCS_DIR="$HOME/Documentos"

# ── Verificaciones previas ───────────────────────────────────
[ -f "$TOKEN_FILE" ] || err "Token GitHub no encontrado en $TOKEN_FILE"
TOKEN=$(cat "$TOKEN_FILE" | tr -d '[:space:]')

# ── Clonar si no existe ──────────────────────────────────────
if [ ! -d "$PROJECT_DIR/.git" ]; then
  log "Clonando repositorio LinuxContainer..."
  git clone "https://${TOKEN}@github.com/txurtxil/LinuxContainer.git" "$PROJECT_DIR"
  ok "Repositorio clonado en $PROJECT_DIR"
fi

cd "$PROJECT_DIR"

# ── Remote con token ─────────────────────────────────────────
git remote set-url origin "https://${TOKEN}@github.com/txurtxil/LinuxContainer.git"
log "Remote configurado"

# ── Pull ─────────────────────────────────────────────────────
log "Actualizando desde GitHub..."
git pull --rebase 2>/dev/null || warn "Pull con conflictos — continúa manualmente"

# ── Crear estructura ─────────────────────────────────────────
log "Creando estructura de directorios..."
mkdir -p android/app/src/main/kotlin/com/example/linux_container
mkdir -p android/app/src/main/assets
mkdir -p assets
mkdir -p lib/src/terminal
mkdir -p lib/src/agent
mkdir -p scripts
ok "Directorios creados"

# ── Copiar ficheros desde Documentos ─────────────────────────
copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [ -f "$src" ]; then
    cp -f "$src" "$dst"
    ok "$(basename "$src") → $dst"
  else
    warn "No encontrado: $src"
  fi
}

log "Copiando ficheros..."

copy_if_exists "$DOCS_DIR/MainActivity.kt" \
  "android/app/src/main/kotlin/com/example/linux_container/MainActivity.kt"

copy_if_exists "$DOCS_DIR/terminal_view.dart"  "lib/src/terminal/terminal_view.dart"
copy_if_exists "$DOCS_DIR/agent_services.dart" "lib/src/agent/agent_services.dart"
copy_if_exists "$DOCS_DIR/agent_server.py"     "assets/agent_server.py"
copy_if_exists "$DOCS_DIR/xtr_setup.sh"        "assets/xtr_setup.sh"

copy_if_exists "$DOCS_DIR/00_bootstrap_bc250.sh"  "scripts/00_bootstrap_bc250.sh"
copy_if_exists "$DOCS_DIR/01_prepare_rootfs.sh"   "scripts/01_prepare_rootfs.sh"
copy_if_exists "$DOCS_DIR/02_deploy_to_github.sh" "scripts/02_deploy_to_github.sh"

# ── Parche build.gradle.kts ──────────────────────────────────
GRADLE_FILE="android/app/build.gradle.kts"
if [ -f "$GRADLE_FILE" ] && ! grep -q "noCompress" "$GRADLE_FILE"; then
  log "Parcheando build.gradle.kts con noCompress..."
  python3 - << PYEOF
import re
path = "$GRADLE_FILE"
with open(path) as f:
    content = f.read()
patch = '''
    aaptOptions {
        noCompress += listOf("gz", "tar", "task")
    }
'''
if 'aaptOptions' not in content:
    content = re.sub(r'(buildTypes\s*\{)', patch + r'\1', content, count=1)
    with open(path, 'w') as f:
        f.write(content)
    print("build.gradle.kts parcheado")
else:
    print("build.gradle.kts ya tiene aaptOptions")
PYEOF
fi

# ── README ───────────────────────────────────────────────────
cat > README.md << 'READMEEOF'
# XTR Terminal

App Android con agente IA autónomo **100% local y privado**.

- **Plataforma:** Samsung Z Fold7 (Snapdragon 8 Elite)
- **Sistema:** Debian Bookworm arm64 vía proot (sin root)
- **GPU:** MediaPipe LLM API — Adreno GPU (55+ tok/s)
- **Package:** `com.example.linux_container`

## Setup desde 0 en bc-250

```bash
# 1. Bootstrap (instala SDK, Flutter, Java)
bash scripts/00_bootstrap_bc250.sh
source ~/.bashrc

# 2. Preparar rootfs Debian (~15 min, una sola vez)
bash scripts/01_prepare_rootfs.sh

# 3. Build APK
cd ~/linux_container_build
./build_and_deploy.sh
```

## Primera ejecución en el dispositivo

1. Instalar APK
2. La app extrae Debian automáticamente (~500 MB, 1-3 min)
3. Menú ☰ → **Setup Inicial** (instala smolagents)
4. Modelos GPU: pantalla "Prueba GPU" → Importar .task
READMEEOF
ok "README.md actualizado"

# ── Flutter analyze ──────────────────────────────────────────
FLUTTER_BIN="$HOME/flutter/bin/flutter"
if [ -f "$FLUTTER_BIN" ] && [ -d "lib" ]; then
  log "Analizando Flutter..."
  export PATH="$HOME/flutter/bin:$HOME/Android/Sdk/cmdline-tools/latest/bin:$PATH"
  export ANDROID_HOME="$HOME/Android/Sdk"
  "$FLUTTER_BIN" analyze lib/ 2>&1 | tail -5 || warn "Advertencias en flutter analyze"
fi

# ── Git commit y push ────────────────────────────────────────
log "Preparando commit..."
git add -A

CHANGED=$(git diff --cached --name-only | wc -l)
if [ "$CHANGED" -eq 0 ]; then
  warn "Sin cambios que commitear"
else
  git commit -m "feat: setup inicial, rootfs bundleado, Gemini 3.5-flash, GPU-only

- MainActivity: extracción automática de rootfs.tar.gz en primer arranque
- terminal_view: menú Setup Inicial con apt update + smolagents
- agent_services: Gemini 3.5-flash, GPU Local dedicado, sin CPU
- agent_server: GPU-only via MediaPipe :8090, sin llama.cpp
- scripts: bootstrap, rootfs, deploy"

  git push origin main
  ok "Push a GitHub completado"
fi

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}  Deploy completado ✓${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo ""
echo "Próximos pasos:"
echo "  1. bash ~/linux_container_build/scripts/01_prepare_rootfs.sh"
echo "  2. cd ~/linux_container_build && ./build_and_deploy.sh"
