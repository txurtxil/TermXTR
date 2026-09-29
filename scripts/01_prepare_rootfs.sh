#!/bin/bash
# ============================================================
# XTR Terminal — Preparar rootfs Debian arm64
# RESULTADO: android/app/src/main/assets/rootfs.tar.gz
# ============================================================
set -euo pipefail
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${CYAN}[ROOTFS]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOTFS_DIR="/tmp/xtr_rootfs_build"
ASSETS_DIR="$PROJECT_DIR/android/app/src/main/assets"
OUTPUT="$ASSETS_DIR/rootfs.tar.gz"

log "Proyecto: $PROJECT_DIR"
log "Output:   $OUTPUT"
echo ""

# ── 1. Instalar debootstrap ───────────────────────────────────
log "Paso 1/7 — Instalando debootstrap..."
sudo apt-get install -y debootstrap || err "No se pudo instalar debootstrap"
ok "debootstrap: $(debootstrap --version 2>/dev/null | head -1)"

# ── Localizar qemu-aarch64 (little-endian, sin _be) ──────────
log "Localizando qemu-aarch64..."
QEMU_BIN=""
for candidate in \
    /usr/bin/qemu-aarch64-static \
    /usr/bin/qemu-aarch64; do
  if [ -f "$candidate" ] && [[ "$candidate" != *"_be"* ]]; then
    QEMU_BIN="$candidate"
    break
  fi
done

[ -n "$QEMU_BIN" ] || err "No se encontró qemu-aarch64. Instala: sudo apt install qemu-user"
ok "qemu encontrado: $QEMU_BIN"

# Dentro del rootfs siempre debe llamarse qemu-aarch64-static
QEMU_DEST_NAME="qemu-aarch64-static"

# ── 2. Limpiar directorio previo ─────────────────────────────
if [ -d "$ROOTFS_DIR" ]; then
  warn "Limpiando rootfs anterior..."
  sudo rm -rf "$ROOTFS_DIR"
fi
sudo mkdir -p "$ROOTFS_DIR"

# ── 3. Debootstrap fase 1 ────────────────────────────────────
log "Paso 2/7 — debootstrap fase 1 (3-5 min)..."
sudo debootstrap \
  --arch=arm64 \
  --foreign \
  --include=apt,apt-utils,curl,wget,ca-certificates \
  bookworm \
  "$ROOTFS_DIR" \
  http://deb.debian.org/debian/
ok "Fase 1 completada"

# ── 4. Copiar qemu al rootfs ─────────────────────────────────
log "Paso 3/7 — Copiando qemu al rootfs..."
sudo mkdir -p "$ROOTFS_DIR/usr/bin"
sudo cp "$QEMU_BIN" "$ROOTFS_DIR/usr/bin/$QEMU_DEST_NAME"
sudo chmod +x "$ROOTFS_DIR/usr/bin/$QEMU_DEST_NAME"
ok "Copiado como /usr/bin/$QEMU_DEST_NAME"

# Registrar el intérprete con binfmt_misc si es posible
sudo update-binfmts --enable qemu-aarch64 2>/dev/null || true

# ── 5. Debootstrap fase 2 ────────────────────────────────────
log "Paso 4/7 — debootstrap fase 2 (3-5 min)..."
sudo chroot "$ROOTFS_DIR" "/usr/bin/$QEMU_DEST_NAME" \
  /bin/bash /debootstrap/debootstrap --second-stage
ok "Fase 2 completada — Debian Bookworm arm64 base lista"

# ── 6. Configurar rootfs ─────────────────────────────────────
log "Paso 5/7 — Configurando sistema base..."

sudo tee "$ROOTFS_DIR/etc/apt/sources.list" > /dev/null << 'SRCLIST'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
SRCLIST

echo "xtr-terminal" | sudo tee "$ROOTFS_DIR/etc/hostname" > /dev/null
sudo tee "$ROOTFS_DIR/etc/resolv.conf" > /dev/null << 'RESOLV'
nameserver 8.8.8.8
nameserver 1.1.1.1
RESOLV

log "Instalando Python y herramientas (5-8 min)..."
sudo chroot "$ROOTFS_DIR" "/usr/bin/$QEMU_DEST_NAME" /bin/bash << 'CHROOT'
set -e
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
echo "--- apt update ---"
apt-get update -q
echo "--- Instalando paquetes ---"
apt-get install -y --no-install-recommends \
  python3 python3-pip python3-venv python3-dev \
  git curl wget ca-certificates \
  build-essential nano procps locales
echo "--- Locale ---"
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "--- Limpiando cache ---"
apt-get clean
rm -rf /var/lib/apt/lists/*
echo "--- OK ---"
CHROOT
ok "Paquetes base instalados"

# ── 7. Instalar smolagents ────────────────────────────────────
log "Paso 6/7 — Instalando smolagents (5-10 min)..."
sudo chroot "$ROOTFS_DIR" "/usr/bin/$QEMU_DEST_NAME" /bin/bash << 'CHROOT'
set -e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cd /root
echo "--- Creando venv ---"
python3 -m venv agent-env
echo "--- pip install ---"
agent-env/bin/pip install --upgrade pip --quiet
agent-env/bin/pip install \
  smolagents "fastapi>=0.111.0" "uvicorn[standard]" \
  httpx openai requests --quiet
echo "--- smolagents: $(agent-env/bin/pip show smolagents | grep Version) ---"
CHROOT
ok "smolagents instalado"

# Copiar ficheros al rootfs
for f in agent_server.py xtr_setup.sh; do
  SRC="$PROJECT_DIR/assets/$f"
  if [ -f "$SRC" ]; then
    sudo cp "$SRC" "$ROOTFS_DIR/root/$f"
    sudo chmod +x "$ROOTFS_DIR/root/$f" 2>/dev/null || true
    ok "Copiado: $f"
  else
    warn "$f no encontrado en assets/ — se instalará desde Setup Inicial"
  fi
done

sudo tee "$ROOTFS_DIR/root/start_agent.sh" > /dev/null << 'STARTSH'
#!/bin/bash
source /root/agent-env/bin/activate
cd /root
exec uvicorn agent_server:app --host 127.0.0.1 --port 8765 --workers 1
STARTSH
sudo chmod +x "$ROOTFS_DIR/root/start_agent.sh"

# Eliminar qemu del rootfs final (el ARM real no lo necesita)
sudo rm -f "$ROOTFS_DIR/usr/bin/$QEMU_DEST_NAME"

# ── 8. Comprimir ─────────────────────────────────────────────
log "Paso 7/7 — Comprimiendo rootfs (2-5 min)..."
mkdir -p "$ASSETS_DIR"
sudo tar czf "$OUTPUT" \
  --exclude="./proc" \
  --exclude="./sys" \
  --exclude="./dev" \
  --exclude="./run" \
  --exclude="./tmp" \
  -C "$ROOTFS_DIR" .

sudo chown "$(whoami):$(whoami)" "$OUTPUT"
sudo rm -rf "$ROOTFS_DIR"

SIZE=$(du -sh "$OUTPUT" | cut -f1)
echo ""
ok "══════════════════════════════════════"
ok "  rootfs.tar.gz generado: $SIZE"
ok "  $OUTPUT"
ok "══════════════════════════════════════"
echo ""
log "Siguiente: cd $PROJECT_DIR && ./build_and_deploy.sh"
