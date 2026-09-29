#!/bin/bash

# Configuración
REPO="txurtxil/LinuxContainer"
TOKEN_FILE="/home/txurtxil/githubToken"
APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
VERSION="v$(date +%Y%m%d.%H%M)"

if [ ! -f "$TOKEN_FILE" ]; then
    echo "❌ Error: Token de GitHub no encontrado en $TOKEN_FILE"
    exit 1
fi

TOKEN=$(cat "$TOKEN_FILE" | tr -d '\n')

echo "🚀 Iniciando despliegue de $VERSION..."

# 1. Commits de código
git config user.email "txurtxil@users.noreply.github.com"
git config user.name "txurtxil"
git add .
git commit -m "Build $VERSION: Actualización de agente y herramientas"
git push https://txurtxil:${TOKEN}@github.com/${REPO}.git main

# 2. Crear Release en GitHub
echo "📦 Creando Release en GitHub..."
RELEASE_JSON=$(printf '{"tag_name": "%s", "name": "Build %s", "body": "Despliegue automático de la versión %s", "draft": false, "prerelease": false}' "$VERSION" "$VERSION" "$VERSION")

RELEASE_ID=$(curl -s -H "Authorization: token $TOKEN" \
    -d "$RELEASE_JSON" \
    https://api.github.com/repos/${REPO}/releases | grep -o '"id": [0-9]*' | head -1 | awk '{print $2}')

if [ -z "$RELEASE_ID" ]; then
    echo "❌ Error al crear release."
    exit 1
fi

# 3. Subir APK
echo "⬆️ Subiendo APK a Release ID: $RELEASE_ID..."
curl -s -X POST \
    -H "Authorization: token $TOKEN" \
    -H "Content-Type: application/vnd.android.package-archive" \
    --data-binary @"$APK_PATH" \
    "https://uploads.github.com/repos/${REPO}/releases/${RELEASE_ID}/assets?name=app-release.apk"

echo "✅ Despliegue completado con éxito: $VERSION"
