#!/bin/bash
# ============================================================
# XTR Terminal — Bootstrap completo desde 0 en bc-250
# Ejecutar: bash 00_bootstrap_bc250.sh
# ============================================================
set -e
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${CYAN}[XTR]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

REPO_URL="https://github.com/txurtxil/LinuxContainer.git"
PROJECT_DIR="$HOME/linux_container_build"
TOKEN_FILE="$HOME/githubToken"
DOCS_DIR="$HOME/Documentos"

# ── 1. Dependencias del sistema ──────────────────────────────
log "Instalando dependencias del sistema..."
sudo apt update -q
sudo apt install -y \
  git curl wget unzip tar \
  openjdk-17-jdk \
  lib32stdc++6 lib32z1 \
  python3 python3-pip python3-venv \
  proot \
  2>/dev/null

# qemu-user-static es virtual en Ubuntu 26.04 — instalar el paquete real
sudo apt install -y qemu-user-binfmt 2>/dev/null || \
sudo apt install -y qemu-user-static 2>/dev/null || \
warn "qemu-user no instalado — solo necesario para preparar rootfs con debootstrap"
ok "Dependencias del sistema instaladas"

# ── 2. Android SDK ───────────────────────────────────────────
ANDROID_HOME="$HOME/Android/Sdk"
if [ ! -d "$ANDROID_HOME" ]; then
  log "Descargando Android command-line tools..."
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  CMDTOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
  wget -q --show-progress "$CMDTOOLS_URL" -O /tmp/cmdtools.zip
  unzip -q /tmp/cmdtools.zip -d /tmp/cmdtools_extract
  mv /tmp/cmdtools_extract/cmdline-tools "$ANDROID_HOME/cmdline-tools/latest"
  rm -f /tmp/cmdtools.zip
  ok "Android cmdline-tools instalado"
else
  ok "Android SDK ya existe en $ANDROID_HOME"
fi

export ANDROID_HOME
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

# Aceptar licencias e instalar plataformas
log "Instalando plataformas Android (API 35, NDK 27, build-tools 35)..."
yes | sdkmanager --licenses > /dev/null 2>&1 || true
sdkmanager \
  "platforms;android-35" \
  "build-tools;35.0.0" \
  "ndk;27.0.12077973" \
  "platform-tools" \
  > /dev/null 2>&1
ok "Android SDK configurado"

# ── 3. Flutter ───────────────────────────────────────────────
FLUTTER_DIR="$HOME/flutter"
if [ ! -d "$FLUTTER_DIR" ]; then
  log "Instalando Flutter stable..."
  git clone -q --depth 1 -b stable https://github.com/flutter/flutter.git "$FLUTTER_DIR"
  ok "Flutter clonado"
else
  ok "Flutter ya existe"
fi

export PATH="$FLUTTER_DIR/bin:$PATH"
flutter config --android-sdk "$ANDROID_HOME" --no-analytics > /dev/null 2>&1
flutter precache --android > /dev/null 2>&1
ok "Flutter configurado"

# ── 4. Añadir variables al .bashrc si no están ──────────────
grep -q "ANDROID_HOME" "$HOME/.bashrc" || cat >> "$HOME/.bashrc" << 'BASHRC'

# ── XTR Terminal SDK ────────────────────────────────────────
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
export PATH="$HOME/flutter/bin:$PATH"
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
# Alias
alias build='cd ~/linux_container_build && ./build_and_deploy.sh'
alias sync='~/sync_from_bc250.sh 2>/dev/null || true'
BASHRC
ok "Variables de entorno configuradas en .bashrc"

# ── 5. Clonar repositorio ────────────────────────────────────
if [ ! -d "$PROJECT_DIR/.git" ]; then
  log "Clonando repositorio desde GitHub..."
  if [ -f "$TOKEN_FILE" ]; then
    TOKEN=$(cat "$TOKEN_FILE" | tr -d '[:space:]')
    REPO_AUTH=$(echo "$REPO_URL" | sed "s|https://|https://${TOKEN}@|")
    git clone "$REPO_AUTH" "$PROJECT_DIR"
  else
    warn "No se encontró token en $TOKEN_FILE — clonando sin auth (read-only)"
    git clone "$REPO_URL" "$PROJECT_DIR"
  fi
  ok "Repositorio clonado en $PROJECT_DIR"
else
  log "Repositorio ya existe, haciendo pull..."
  cd "$PROJECT_DIR"
  git pull
  ok "Repositorio actualizado"
fi

# ── 6. Crear directorios necesarios ──────────────────────────
mkdir -p "$DOCS_DIR"
mkdir -p "$PROJECT_DIR/android/app/src/main/assets"
ok "Directorios creados"

# ── 7. Generar local.properties ─────────────────────────────
cat > "$PROJECT_DIR/android/local.properties" << EOF
sdk.dir=$ANDROID_HOME
flutter.sdk=$FLUTTER_DIR
ndk.dir=$ANDROID_HOME/ndk/27.0.12077973
EOF
ok "local.properties generado"

# ── 8. Script de build ───────────────────────────────────────
cat > "$PROJECT_DIR/build_and_deploy.sh" << 'BUILDSCP'
#!/bin/bash
set -e
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${CYAN}[BUILD]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }

cd "$(dirname "$0")"
source "$HOME/.bashrc" 2>/dev/null || true
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$HOME/flutter/bin:$PATH"
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"

log "Analizando código Flutter..."
flutter analyze lib/ || { echo "Errores de análisis — corrige antes de compilar"; exit 1; }

log "Compilando APK release..."
flutter build apk --release

APK="build/app/outputs/flutter-apk/app-release.apk"
DEST="$HOME/Documentos/app-release.apk"
cp "$APK" "$DEST"
ok "APK copiada a $DEST"

# Push a GitHub
TOKEN_FILE="$HOME/githubToken"
if [ -f "$TOKEN_FILE" ]; then
  TOKEN=$(cat "$TOKEN_FILE" | tr -d '[:space:]')
  git remote set-url origin "$(git remote get-url origin | sed "s|https://[^@]*@|https://$TOKEN@|; s|https://github.com|https://$TOKEN@github.com|")"
  git add -A
  git diff --cached --quiet && { echo "Sin cambios que commitear"; } || {
    git commit -m "build: $(date '+%Y-%m-%d %H:%M')"
    git push
    ok "Código subido a GitHub"
  }
fi
BUILDSCP
chmod +x "$PROJECT_DIR/build_and_deploy.sh"
ok "build_and_deploy.sh creado"

# ── 9. Verificación final ────────────────────────────────────
echo ""
log "=== Verificación del entorno ==="
java -version 2>&1 | head -1
"$FLUTTER_DIR/bin/flutter" --version 2>/dev/null | head -1
echo "Android SDK: $ANDROID_HOME"
echo "Proyecto: $PROJECT_DIR"
echo ""
ok "Bootstrap completado. Ejecuta: source ~/.bashrc && cd $PROJECT_DIR"
