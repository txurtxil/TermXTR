#!/usr/bin/env python3
# apply_v2.17.3_selection.py — TermXTR v2.17.3
# 1) Overlay: asas/barra dibujadas desde anclas VIVAS (fin de la deriva).
# 2) TerminalView padding: EdgeInsets.zero (sin insets de MediaQuery).
# 3) Unico camino de pegado con feedback + bracketed paste + rescate.
# Idempotente. Verificado contra el contenido real de main.
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
        print(f'[FALLO] {name}: ancla x{n} (esperado 1).')
        sys.exit(1)
    p.write_text(s.replace(old, new), encoding='utf-8')
    print(f'[ok] {name}')

TV = 'lib/src/terminal/terminal_view.dart'
OV = 'lib/src/terminal/selection_overlay_termux.dart'

# ── 1) overlay: anclas vivas ──────────────────────────────────────────────
patch(OV,
"""  Offset? _cellToOverlay(CellOffset cell) {
""",
"""  // v2.17.3: anclas VIVAS en cada build. Las anclas de xterm siguen al
  // contenido ante scrolls y recortes del buffer; cachear CellOffsets
  // (_selStart/_selEnd) para DIBUJAR era la causa de la deriva de las
  // asas: el pintor resuelve las anclas en vivo y las asas no, asi que
  // el resaltado iba bien y las gotas se quedaban abajo "desgastandose".
  BufferRange? get _liveSel => widget.controller.selection?.normalized;

  Offset? _cellToOverlay(CellOffset? cell) {
""", 'overlay: getter _liveSel + firma nullable')

patch(OV,
"""  CellOffset _lastSelectedCell() {
    final end = _selEnd!;
    final start = _selStart!;
    if (end.x > 0) return CellOffset(end.x - 1, end.y);
    final prevY = math.max(end.y - 1, start.y);
    return CellOffset(widget.terminal.viewWidth - 1, prevY);
  }
""",
"""  CellOffset? _lastSelectedCell() {
    final sel = _liveSel;
    if (sel == null) return null;
    final end = sel.end;
    final start = sel.begin;
    if (end.x > 0) return CellOffset(end.x - 1, end.y);
    final prevY = math.max(end.y - 1, start.y);
    return CellOffset(widget.terminal.viewWidth - 1, prevY);
  }
""", 'overlay: _lastSelectedCell con ancla viva')

patch(OV,
"""  List<Widget> _buildHandles(Color color) {
    final startPos = _cellToOverlay(_selStart!);
    final endCellPos = _cellToOverlay(_lastSelectedCell());
""",
"""  List<Widget> _buildHandles(Color color) {
    final sel = _liveSel;
    if (sel == null) return const [];
    final startPos = _cellToOverlay(sel.begin);
    final endCellPos = _cellToOverlay(_lastSelectedCell());
""", 'overlay: _buildHandles con anclas vivas')

patch(OV,
"""    double top = 8;
    final startPos = _cellToOverlay(_selStart!);
    final endPos = _cellToOverlay(_lastSelectedCell());
""",
"""    double top = 8;
    final liveSel = _liveSel;
    final startPos = _cellToOverlay(liveSel?.begin);
    final endPos = _cellToOverlay(_lastSelectedCell());
""", 'overlay: _buildActionBar con anclas vivas')

# ── 2) terminal_view: padding cero, pegado unificado ─────────────────────
patch(TV,
"""              _scriptTile(ctx, s, 'Pegar', '', icon: Icons.paste, customAction: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (ctx.mounted) Navigator.pop(ctx);
                if (data?.text != null && data!.text!.isNotEmpty) {
                  s.terminal.textInput(data.text!);
                }
              }),
""",
"""              // v2.17.3: mismo camino de pegado que la barra de seleccion
              // y el keybar (feedback + bracketed paste + rescate).
              _scriptTile(ctx, s, 'Pegar', '', icon: Icons.paste, customAction: () { Navigator.pop(ctx); _pasteInto(s); }),
""", 'tv: Utilidades Pegar unificado')

patch(TV,
"""  Future<void> _pasteClipboard() async {
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
""",
"""  Future<void> _pasteClipboard() async {
    // v2.17.3: unica implementacion en _pasteInto (antes esta funcion y
    // la barra de seleccion/Utilidades pegaban por caminos distintos).
    await _pasteInto(_active);
  }

  // v2.17.3: UNICO camino de pegado (barra de seleccion, keybar y
  // Utilidades): timeout de 2 s al portapapeles del sistema (puede
  // quedarse colgado para siempre), bracketed paste via Terminal.paste
  // (multilinea sin ejecutar a medias, con fallback a textInput) y
  // rescate al historial interno si el sistema falla.
  Future<void> _pasteInto(TerminalSession s) async {
    if (_clipboardFallback) {
      final vault = ClipboardVault.instance;
      final entry = vault.history.isEmpty ? null : vault.history.first;
      if (entry == null) {
        _toast('Historial interno vacio');
        return;
      }
      _pasteText(s, entry.text);
      _toast('Pegado desde historial (${entry.text.length} caracteres)');
      return;
    }
    String? text;
    try {
      final data = await Future.any<ClipboardData?>([
        Clipboard.getData(Clipboard.kTextPlain),
        Future<ClipboardData?>.delayed(const Duration(seconds: 2), () => null),
      ]);
      text = data?.text;
    } catch (_) {}
    if (text != null && text.isNotEmpty) {
      _pasteText(s, text);
      _toast('Pegado (${text.length} caracteres)');
    } else if (ClipboardVault.instance.history.isNotEmpty) {
      _clipboardFallback = true;
      _toast('Portapapeles del sistema fallo; usando historial interno');
    } else {
      _toast('Portapapeles vacio');
    }
  }

  void _pasteText(TerminalSession s, String text) {
    try {
      s.terminal.paste(text);
    } catch (_) {
      s.terminal.textInput(text);
    }
  }
""", 'tv: _pasteClipboard delega + _pasteInto/_pasteText')

patch(TV,
"""                  onCopy: _copySelection, onPaste: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    if (data?.text != null && data!.text!.isNotEmpty) s.terminal.textInput(data.text!);
                  }, onSelectAll: _selectAll,
""",
"""                  onCopy: _copySelection, onPaste: () => _pasteInto(s), onSelectAll: _selectAll,
""", 'tv: overlay onPaste unificado')

patch(TV,
"""                  scrollController: s.scrollController, textStyle: TerminalStyle(fontSize: _fontSize, fontFamily: 'monospace')),
""",
"""                  padding: EdgeInsets.zero, // v2.17.3: sin insets de MediaQuery en el mapeo celdas/pixeles (teclado/nav bar ya no desplazan la seleccion)
                  scrollController: s.scrollController, textStyle: TerminalStyle(fontSize: _fontSize, fontFamily: 'monospace')),
""", 'tv: TerminalView padding cero')

patch('pubspec.yaml', 'version: 2.17.2+47', 'version: 2.17.3+48', 'pubspec: version')

patch('CHANGELOG.md', '# Changelog\n',
"""# Changelog

## v2.17.3 (2026-10-27)

### Seleccion sin deriva + pegado unificado
- Fix seleccion "se va desgastando": las asas y la barra se dibujaban
  desde CellOffsets cacheadas; ahora se resuelven las anclas VIVAS de
  xterm en cada build, igual que el pintor del resaltado. Con scrolls y
  recortes del buffer el resaltado iba bien y las gotas se quedaban
  abajo seleccionando zona vacia.
- TerminalView con padding: EdgeInsets.zero: el paquete usaba por
  defecto MediaQuery.of(context).padding (status bar, nav bar, teclado
  abierto/cerrado) dentro del mapeo celdas<->pixeles, fuente de desplazamientos.
- UNICO camino de pegado (barra de seleccion, keybar y Utilidades):
  timeout de 2 s al sistema, bracketed paste via Terminal.paste
  (multilinea sin ejecutar a medias) con fallback a textInput, feedback
  siempre y rescate al historial interno si el portapapeles falla.

""", 'CHANGELOG: v2.17.3')

print('OK: parche v2.17.3 aplicado.')
