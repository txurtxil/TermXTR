#!/usr/bin/env python3
# apply_v2.17.1_clipboard_reset.py — TermXTR v2.17.1
# Rescate del portapapeles: cuando Clipboard.getData se queda bloqueado o
# devuelve vacio, ya no hace falta cerrar la sesion: 'Reiniciar portapapeles'
# en el menu de ajustes repara empujando la ultima entrada de ClipboardVault
# al sistema, y si tampoco responde el pegado pasa a usar el historial
# interno de la app. Idempotente: ejecutable dos veces sin romper nada.
import sys, pathlib

REPO = pathlib.Path(__file__).resolve().parent  # copiar al raiz del repo

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

# ── 1) lib/src/terminal/terminal_view.dart ────────────────────────────────
TV = 'lib/src/terminal/terminal_view.dart'

patch(TV,
"""  Future<void> _pasteClipboard() async {
    // v2.10.2: feedback al pegar y aviso si el portapapeles esta vacio
    // (antes pegaba en silencio y parecia que no pasaba nada).
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      _active.terminal.textInput(text);
      _toast('Pegado (${text.length} caracteres)');
    } else {
      _toast('Portapapeles vacio');
    }
  }
""",
"""  // v2.17.1: rescate del portapapeles. Cuando el portapapeles del sistema
  // se queda bloqueado (otro proceso lo mantiene abierto: gestores de
  // portapapeles, CLIPBRD_E_CANT_OPEN en Windows...), Clipboard.getData
  // puede NO VOLVER NUNCA y la unica salida era cerrar la sesion y entrar
  // de nuevo. _resetClipboard() lo rescata: lectura con timeout corto,
  // reparacion empujando la ultima entrada de ClipboardVault al sistema y,
  // si tampoco responde, pegado directo desde el historial interno.
  bool _clipboardFallback = false;

  Future<void> _resetClipboard() async {
    String? sys;
    try {
      final data = await Future.any<ClipboardData?>([
        Clipboard.getData(Clipboard.kTextPlain),
        Future<ClipboardData?>.delayed(const Duration(seconds: 2), () => null),
      ]);
      sys = data?.text;
    } catch (_) {}

    if (sys != null && sys.isNotEmpty) {
      _clipboardFallback = false;
      _toast('Portapapeles responde (${sys.length} caracteres)');
      return;
    }

    final vault = ClipboardVault.instance;
    final entry = vault.history.isEmpty ? null : vault.history.first;
    if (entry == null) {
      _toast('Sin historial interno que rescatar');
      return;
    }
    final repaired = await vault.forceSystemClipboard(entry);
    if (repaired) {
      _clipboardFallback = false;
      _toast('Portapapeles reiniciado desde el historial (${entry.bytes} B)');
    } else {
      _clipboardFallback = true;
      _toast('Sistema no responde; pegando desde el historial interno');
    }
  }

  Future<void> _pasteClipboard() async {
    // v2.17.1: con el rescate activo se pega directo desde el historial
    // interno (el portapapeles del sistema no responde).
    if (_clipboardFallback) {
      final vault = ClipboardVault.instance;
      final entry = vault.history.isEmpty ? null : vault.history.first;
      if (entry == null) {
        _toast('Historial interno vacio');
        return;
      }
      _active.terminal.textInput(entry.text);
      _toast('Pegado desde historial (${entry.text.length} caracteres)');
      return;
    }
    // v2.10.2: feedback al pegar y aviso si el portapapeles esta vacio
    // (antes pegaba en silencio y parecia que no pasaba nada).
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      _active.terminal.textInput(text);
      _toast('Pegado (${text.length} caracteres)');
    } else if (ClipboardVault.instance.history.isNotEmpty) {
      // v2.17.1: vacio/imposible de leer pero hay historial interno: se
      // activa el rescate solo, sin obligar a resetear a mano.
      _clipboardFallback = true;
      _toast('Portapapeles del sistema fallo; usando historial interno');
    } else {
      _toast('Portapapeles vacio');
    }
  }
""", 'terminal_view.dart: _resetClipboard + _pasteClipboard robusto')

patch(TV,
"""                ListTile(leading: const Icon(Icons.content_paste_go, color: Colors.greenAccent), title: const Text('Portapapeles e historial', style: TextStyle(color: Colors.white)), subtitle: const Text('Clips guardados y texto de la sesión', style: TextStyle(color: Colors.white54)), onTap: () { Navigator.pop(ctx); _openClipboardVault(_active); }),
""",
"""                ListTile(leading: const Icon(Icons.content_paste_go, color: Colors.greenAccent), title: const Text('Portapapeles e historial', style: TextStyle(color: Colors.white)), subtitle: const Text('Clips guardados y texto de la sesion', style: TextStyle(color: Colors.white54)), onTap: () { Navigator.pop(ctx); _openClipboardVault(_active); }),
                ListTile(leading: const Icon(Icons.restart_alt, color: Colors.orangeAccent), title: const Text('Reiniciar portapapeles', style: TextStyle(color: Colors.white)), subtitle: const Text('Rescata el pegado si el sistema no responde', style: TextStyle(color: Colors.white54)), onTap: () { Navigator.pop(ctx); _resetClipboard(); }),
""", 'terminal_view.dart: tile Reiniciar portapapeles')

# ── 2) pubspec.yaml: version ──────────────────────────────────────────────
patch('pubspec.yaml', 'version: 2.17.0+45', 'version: 2.17.1+46', 'pubspec.yaml: version')

# ── 3) CHANGELOG.md: entrada v2.17.1 ──────────────────────────────────────
patch('CHANGELOG.md', '# Changelog\n',
"""# Changelog

## v2.17.1 (2026-10-27)

### Rescate del portapapeles + zip Windows ordenado
- Nuevo "Reiniciar portapapeles" (menu de ajustes de la terminal): cuando
  Clipboard.getData se queda colgado o devuelve vacio (portapapeles
  bloqueado por otro proceso, CLIPBRD_E_CANT_OPEN en Windows...), ya no
  hace falta cerrar la sesion y entrar de nuevo. La accion prueba el
  sistema con timeout de 2 s; si no responde, repara empujando la ultima
  entrada de ClipboardVault al portapapeles del sistema, y si tampoco
  cuela activa el pegado directo desde el historial interno de la app.
- Pegado robusto automatico: si al pegar el sistema devuelve vacio pero
  hay historial interno, el rescate se activa solo (avisa con toast).
- Zip portable de Windows con estructura ordenada: TermXTR.exe + LEEME.txt
  + runtime de Visual C++ en la raiz, lib/ (flutter_windows.dll cargado
  por delay-load, registrado por el exe con AddDllDirectory), data/ y
  log/. El workflow tambien acepta workflow_dispatch para probar la build
  sin etiquetar (sube el zip como artifact, no toca releases).

""", 'CHANGELOG.md: entrada v2.17.1')

print('OK: parche v2.17.1 aplicado. Siguiente: dart analyze + build.')
