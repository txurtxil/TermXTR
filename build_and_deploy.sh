#!/bin/bash

# Colores para la salida
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}Iniciando compilación de la APK en modo release...${NC}"

# 1. Compilar la APK
flutter build apk --release --android-skip-build-dependency-validation --android-skip-build-dependency-validation --android-skip-build-dependency-validation --android-skip-build-dependency-validation

# Verificar si la compilación fue exitosa
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Compilación exitosa.${NC}"
    
    # 2. Copiar la APK al servidor de descargas
    TARGET_DIR="/home/txurtxil/shared_linuxcontainer/"
    APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
    
    echo "Copiando APK a $TARGET_DIR..."
    cp "$APK_PATH" "$TARGET_DIR"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}APK copiada con éxito a $TARGET_DIR${NC}"
    else
        echo "❌ Error al copiar la APK."
        exit 1
    fi
else
    echo "❌ Error durante la compilación de Flutter."
    exit 1
fi

# ── Servidor web APK (puerto 8091) ───────────────────────────
SERVE_DIR="$HOME/shared_linuxcontainer"
PORT=8091
APK_FINAL="$SERVE_DIR/app-release.apk"

cp -f "$TARGET_DIR/app-release.apk" "$APK_FINAL" 2>/dev/null || true

# Arrancar servidor si no está corriendo
if ! fuser ${PORT}/tcp > /dev/null 2>&1; then
    IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')
    echo ""
    echo "========================================"
    echo "  APK disponible en:"
    echo "  http://${IP}:${PORT}/app-release.apk"
    echo "========================================"
    cd "$SERVE_DIR"
    nohup python3 -m http.server $PORT > /tmp/apk_server.log 2>&1 &
    echo "Servidor iniciado (PID $!) — log: /tmp/apk_server.log"
    cd - > /dev/null
else
    IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')
    echo ""
    echo "APK actualizada en http://${IP}:${PORT}/app-release.apk"
fi
