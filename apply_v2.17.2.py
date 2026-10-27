#!/usr/bin/env python3
# apply_v2.17.2_quickscripts_reset.py — TermXTR v2.17.2
# "Reiniciar portapapeles" tambien en Utilidades -> seccion Portapapeles
# (el menu rapido de la terminal), no solo en ajustes. Idempotente.
import sys, pathlib

REPO = pathlib.Path(__file__).resolve().parent

def patch(path, old, new, name):
    p = REPO / path
    s = p.read_text(encoding='utf-8')
    if new in s:
        print(f'[skip] {name}: ya aplicado')
        return
    n = s.count(old)
    if n != 1:
        print(f'[FALLO] {name}: el ancla aparece {n} veces (esperado 1). NO se escribio nada.')
        sys.exit(1)
    p.write_text(s.replace(old, new), encoding='utf-8')
    print(f'[ok] {name}')

patch('lib/src/terminal/terminal_view.dart',
"""              _scriptTile(ctx, s, 'Portapapeles guardados', '', icon: Icons.content_paste_go, customAction: () { Navigator.pop(ctx); _openClipboardVault(s); }),
""",
"""              _scriptTile(ctx, s, 'Portapapeles guardados', '', icon: Icons.content_paste_go, customAction: () { Navigator.pop(ctx); _openClipboardVault(s); }),
              // v2.17.2: el rescate del portapapeles tambien en el menu rapido
              // de Utilidades (antes solo en ajustes); mismo _resetClipboard.
              _scriptTile(ctx, s, 'Reiniciar portapapeles', '', icon: Icons.restart_alt, customAction: () { Navigator.pop(ctx); _resetClipboard(); }),
""", 'terminal_view.dart: tile en Utilidades')

patch('pubspec.yaml', 'version: 2.17.1+46', 'version: 2.17.2+47', 'pubspec.yaml: version')

patch('CHANGELOG.md', '# Changelog\n',
"""# Changelog

## v2.17.2 (2026-10-27)

### Reiniciar portapapeles en el menu rapido
- "Reiniciar portapapeles" tambien en Utilidades -> seccion Portapapeles
  (antes solo en el menu de ajustes). Mismo rescate: timeout 2 s al sistema,
  reparacion desde el historial interno, pegado directo si no responde.

""", 'CHANGELOG.md: entrada v2.17.2')

print('OK: parche v2.17.2 aplicado.')
