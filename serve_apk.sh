#!/bin/bash
# ============================================================
# XTR — Servidor web local para descargar la APK
# Puerto: 8091 | Ruta: ~/shared_linuxcontainer/
# Cada compilación copia la APK aquí automáticamente.
# ============================================================
APK_SRC="$HOME/linux_container_build/build/app/outputs/flutter-apk/app-release.apk"
SERVE_DIR="$HOME/shared_linuxcontainer"
PORT=8091

mkdir -p "$SERVE_DIR"

# Copiar APK si existe y es más nueva
if [ -f "$APK_SRC" ]; then
    cp -f "$APK_SRC" "$SERVE_DIR/app-release.apk"
    SIZE=$(du -sh "$SERVE_DIR/app-release.apk" | cut -f1)
    echo "APK lista: $SERVE_DIR/app-release.apk ($SIZE)"
fi

# Matar servidor previo en ese puerto si lo hay
fuser -k ${PORT}/tcp 2>/dev/null || true
sleep 0.5

# Obtener IP local
IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')

echo ""
echo "========================================"
echo "  Servidor APK en http://${IP}:${PORT}"
echo "  Descarga: http://${IP}:${PORT}/app-release.apk"
echo "  Ctrl+C para detener"
echo "========================================"
echo ""

cd "$SERVE_DIR"
python3 -m http.server $PORT
