#!/usr/bin/env bash
# tools/gen_prompt_estado.sh
#
# Regenera docs/estado/PROMPT_ESTADO.md (contexto para retomar el proyecto
# en un chat nuevo) y lo publica CIFRADO en docs/estado/PROMPT_ESTADO.7z
# (7z AES-256 con cabeceras cifradas; el repo es publico).
#
# Uso (en cada hito/release):
#   PROMPT_PASS='la-clave' ./tools/gen_prompt_estado.sh
#
# El contenido NUNCA debe incluir contrasenas ni claves: la seccion de
# acceso referencia "gestor de credenciales del equipo".

set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="docs/estado"
MD="$OUT_DIR/PROMPT_ESTADO.md"
SEVENZ="$OUT_DIR/PROMPT_ESTADO.7z"
PASS="${PROMPT_PASS:?Falta PROMPT_PASS}"

mkdir -p "$OUT_DIR"

VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}')
DATE=$(date +%Y-%m-%d)

# Ultima entrada del changelog (primer bloque "## v")
LAST_CHANGELOG=$(awk '/^## v/{n++} n==1{print} n==2{exit}' CHANGELOG.md)

{
  echo "# TermXTR - Prompt de estado (GENERADO: no editar a mano)"
  echo "# Fecha: $DATE · Version: $VERSION"
  echo "# Regenerar: PROMPT_PASS=... ./tools/gen_prompt_estado.sh"
  echo "# Descifrar:  7z x -p'...' docs/estado/PROMPT_ESTADO.7z"
  echo ""
  echo "Eres el ingeniero senior de **TermXTR**: app Flutter de terminal"
  echo "SSH/SFTP para Android y Windows (desktop). Lee el changelog mas"
  echo "abajo para el ultimo hito y la lista de pendientes antes de"
  echo "proponer nada."
  echo ""
  echo "## Identidad y acceso (SIN SECRETOS)"
  echo "- Repo VIVO: github.com/txurtxil/TermXTR (rama main). LinuxContainer"
  echo "  esta ARCHIVADO (lineage Debian/proot/IA; solo historico)."
  echo "- Build machine **z1** (Ubuntu x86_64): ssh -p 6022"
  echo "  txurtxil@www.mundaka.net. Contrasena y claves: en el GESTOR DE"
  echo "  CREDENCIALES del equipo del usuario, NUNCA en este documento."
  echo "- Flutter en ~/flutter/bin (NO en PATH de shells no interactivos)."
  echo "  gh autenticado (txurtxil)."
  echo "- Desde sandbox sin sshpass: paramiko por el puerto 6022; subir/"
  echo "  bajar ficheros en BASE64 por canal exec (SFTP directo se cuelga)."
  echo "  El sandbox solo sale por 443."
  echo ""
  echo "## Como compilar"
  echo "- Android: export PATH=\"\$HOME/flutter/bin:\$PATH\" && flutter build apk --release"
  echo "  (APK unico app-release.apk, no split-per-abi)."
  echo "- Windows: el workflow .github/workflows/windows_build.yml se dispara"
  echo "  con tags v*; genera termxtr-windows-<tag>.zip e incluye el VC++"
  echo "  runtime. Trasladar un tag convierte la release en DRAFT: republicar"
  echo "  con gh release edit <tag> --draft=false."
  echo ""
  echo "## Arquitectura (estado actual)"
  echo "- SSH/SFTP 100% dartssh2 3.3.1 (sin binario ssh, sin proot)."
  echo "- SshHost: credenciales, jumpHost, macAddress, group (v2.10),"
  echo "  audit (v2.11: gateway/lanIp/arp/services del 'Auditar servicios')."
  echo "- SshHostsService: lista + colores de grupo en ssh_groups.json."
  echo "- known_hosts en JSON (accept-new; huella cambiada = rechazo con"
  echo "  mensaje claro; se gestiona en Hosts > Hosts conocidos)."
  echo "- Almacen propio AppPaths (<appSupport>/xtr): ssh_hosts.json,"
  echo "  snippets, clipboard, known_hosts, sessions, keys."
  echo "- Widgets de escritorio y KeepAliveService: Android-only (guards"
  echo "  Platform.isAndroid)."
  echo "- xterm.dart 4.0.0 + overlay de seleccion estilo Termux."
  echo ""
  echo "## Reglas de oro"
  echo "- Nunca editar a ciegas: leer el fichero real primero."
  echo "- Un solo edit por fichero y por mensaje; verificar con grep."
  echo "- Versiones/tags ASCENDENTES, nunca reutilizadas."
  echo "- Compilar no es funcionar: declarar pruebas pendientes en device."
  echo ""
  echo "## Ultimo hito (changelog)"
  echo "$LAST_CHANGELOG"
  echo ""
  echo "## Pendientes (docs/estado/PENDIENTES.md)"
  cat "$OUT_DIR/PENDIENTES.md"
} > "$MD"

rm -f "$SEVENZ"
7z a -t7z -p"$PASS" -mhe=on "$SEVENZ" "$MD" >/dev/null
rm -f "$MD"

git add "$SEVENZ" "$OUT_DIR/PENDIENTES.md" CHANGELOG.md pubspec.yaml 2>/dev/null || git add "$SEVENZ"
if git diff --cached --quiet; then
  echo "Sin cambios que commitear."
else
  git -c user.name='txurtxil' -c user.email='txurtxil@users.noreply.github.com' \
    commit -m "estado: prompt cifrado actualizado ($VERSION)"
  echo "Prompt cifrado actualizado y commiteado ($VERSION)."
fi
