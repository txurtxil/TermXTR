#!/bin/bash
# ============================================================
# XTR — Aplica correcciones y recompila
# Ejecutar desde: ~/linux_container_build/
# ============================================================
set -e
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
log() { echo -e "${CYAN}[FIX]${NC} $1"; }
ok()  { echo -e "${GREEN}[OK]${NC} $1"; }
err() { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

cd ~/linux_container_build

# ── Fix 1: terminal_view.dart — escapar $() en strings bash ──
log "Fix 1: terminal_view.dart — escapar \$() en strings bash..."
python3 << 'PYEOF'
import re, sys
path = 'lib/src/terminal/terminal_view.dart'
with open(path) as f:
    content = f.read()

# Escapar $( que aparezca dentro de strings Dart single-quote
# Solo en las líneas del comando bash de versiones
old_block = """        {'command':
          'echo \"Python: $(python3 --version)\" && '
          'echo \"smolagents: $(/root/agent-env/bin/pip show smolagents 2>/dev/null | grep Version || echo N/A)\" && '
          'echo \"FastAPI: $(/root/agent-env/bin/pip show fastapi 2>/dev/null | grep Version || echo N/A)\"'
        },"""

new_block = """        {'command':
          'echo "Python: \\$(python3 --version)" && '
          'echo "smolagents: \\$(/root/agent-env/bin/pip show smolagents 2>/dev/null | grep Version || echo N/A)" && '
          'echo "FastAPI: \\$(/root/agent-env/bin/pip show fastapi 2>/dev/null | grep Version || echo N/A)"'
        },"""

if old_block in content:
    content = content.replace(old_block, new_block)
    print("OK: terminal_view.dart parcheado")
else:
    # Ya parcheado o diferente formato — buscar cualquier $( sin escapar en esas líneas
    import re
    # Reemplazar $( por \$( solo dentro de strings que contengan python3 o pip show
    def escape_bash_subshell(m):
        line = m.group(0)
        if 'python3 --version' in line or 'pip show' in line:
            return line.replace('$(', r'\$(')
        return line
    new_content = re.sub(r"'[^']*\$\([^']*'", escape_bash_subshell, content)
    if new_content != content:
        content = new_content
        print("OK: terminal_view.dart parcheado (método alternativo)")
    else:
        print("SKIP: terminal_view.dart ya estaba correcto o no encontrado")

with open(path, 'w') as f:
    f.write(content)
PYEOF
ok "Fix 1 aplicado"

# ── Fix 2: main.dart — quitar const de TerminalScreen() ──────
log "Fix 2: main.dart — quitar const de TerminalScreen()..."
if grep -q "const TerminalScreen()" lib/main.dart 2>/dev/null; then
    sed -i 's/home: const TerminalScreen()/home: TerminalScreen()/g' lib/main.dart
    ok "main.dart: 'const TerminalScreen()' → 'TerminalScreen()'"
else
    ok "main.dart: sin cambios necesarios"
fi

# ── Fix 3: copiar terminal_view.dart actualizado si existe ────
DOCS_TV="$HOME/Documentos/terminal_view.dart"
if [ -f "$DOCS_TV" ]; then
    log "Copiando terminal_view.dart desde Documentos..."
    cp -f "$DOCS_TV" lib/src/terminal/terminal_view.dart
    ok "terminal_view.dart actualizado desde Documentos"
fi

# ── Analizar antes de compilar ────────────────────────────────
log "Analizando Flutter..."
export PATH="$HOME/flutter/bin:$PATH"
flutter analyze lib/ 2>&1 | tail -8 || {
    echo "Errores de análisis — revisar antes de continuar"
    exit 1
}
ok "Análisis OK"

# ── Compilar ──────────────────────────────────────────────────
log "Compilando APK release..."
flutter build apk --release

APK="build/app/outputs/flutter-apk/app-release.apk"
DEST="$HOME/Documentos/app-release.apk"
cp "$APK" "$DEST"
ok "APK copiada a $DEST"

SIZE=$(du -sh "$APK" | cut -f1)
echo ""
ok "══════════════════════════════════"
ok "  Build completado ✓  ($SIZE)"
ok "══════════════════════════════════"
