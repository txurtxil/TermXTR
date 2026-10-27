#!/usr/bin/env python3
# apply_v2.17.4_own_geometry.py — TermXTR v2.17.4
# Sistema de geometria PROPIO del overlay: las posiciones de asas/barra y
# la conversion dedo->celda se calculan directamente en el espacio del
# overlay desde cellSize + scrollController.offset, sin getOffset(),
# sin localToGlobal/globalToLocal contra el RenderTerminal y sin
# getCellOffset() dinamico del paquete. Fin de las conversiones cruzadas
# entre objetos de render (la fuente real del "descuadre que no sigue
# los ejes"). Idempotente; verificado contra main.
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

OV = 'lib/src/terminal/selection_overlay_termux.dart'

patch(OV,
"""  Offset? _cellToOverlay(CellOffset? cell) {
    final rt = _rt;
    final box = context.findRenderObject() as RenderBox?;
    if (rt == null || box == null || !box.hasSize) return null;
    final Offset localInTerminal = rt.getOffset(cell) as Offset;
    final global = (rt as RenderBox).localToGlobal(localInTerminal);
    return box.globalToLocal(global);
  }
""",
"""  // v2.17.4: geometria PROPIA del overlay. Las posiciones se calculan
  // directamente en el espacio del overlay desde primitivas propias:
  // cellSize (constante) y scrollController.offset (el MISMO ScrollPosition
  // que usa el pintor del resaltado, asi que ambos no pueden
  // desincronizarse). Se eliminan getOffset(), localToGlobal/globalToLocal
  // contra el RenderTerminal y el getCellOffset() dinamico del paquete:
  // las conversiones cruzadas entre objetos de render eran la fuente del
  // "descuadre que no sigue los ejes x e y". padding ya es cero (v2.17.3),
  // asi que el origen del overlay coincide con el del RenderTerminal.
  Offset? _cellToOverlay(CellOffset? cell) {
    if (cell == null) return null;
    if (cell.y < 0 || cell.x < 0) return null;
    final sc = widget.scrollController;
    if (!sc.hasClients) return null;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final cw = _cellW, ch = _cellH;
    return Offset(cell.x * cw, cell.y * ch - sc.offset);
  }
""", 'overlay: _cellToOverlay con geometria propia')

patch(OV,
"""  void _extendSelectionTo(Offset global) {
    final rt = _rt;
    final fixed = _dragFixed;
    if (rt == null || fixed == null) return;
    final local = (rt as RenderBox).globalToLocal(global);
    // (rt as dynamic): el `as RenderBox` de la línea anterior promueve el
    // tipo estático de rt a partir de este punto y rompería el acceso
    // dinámico a getCellOffset (error de compilación visto en build linux).
    final cell = (rt as dynamic).getCellOffset(local) as CellOffset;
""",
"""  void _extendSelectionTo(Offset global) {
    final fixed = _dragFixed;
    final box = context.findRenderObject() as RenderBox?;
    final sc = widget.scrollController;
    if (fixed == null || box == null || !box.hasSize || !sc.hasClients) return;
    // v2.17.4: unica conversion respecto al PROPIO box del overlay y celda
    // con la formula inversa de _cellToOverlay (mismo sistema de coordenadas
    // que dibuja las asas: imposible que se descuadre con ellas).
    final local = box.globalToLocal(global);
    final cw = _cellW, ch = _cellH;
    var col = (local.dx / cw).floor();
    var row = ((local.dy + sc.offset) / ch).floor();
    if (col < 0) col = 0;
    if (col > widget.terminal.viewWidth - 1) col = widget.terminal.viewWidth - 1;
    if (row < 0) row = 0;
    final maxRow = widget.terminal.buffer.lines.length - 1;
    if (row > maxRow) row = maxRow;
    final cell = CellOffset(col, row);
""", 'overlay: _extendSelectionTo con geometria propia')

patch(OV,
"""  void _updateAutoScroll(Offset fingerGlobal) {
    final rt = _rt;
    if (rt == null) return;
    final box = rt as RenderBox;
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
""",
"""  void _updateAutoScroll(Offset fingerGlobal) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
""", 'overlay: auto-scroll sin RenderTerminal')

patch('pubspec.yaml', 'version: 2.17.3+48', 'version: 2.17.4+49', 'pubspec: version')

patch('CHANGELOG.md', '# Changelog\n',
"""# Changelog

## v2.17.4 (2026-10-27)

### Seleccion: geometria propia (otro sistema)
- El overlay calcula las posiciones de asas/barra y la conversion
  dedo->celda DIRECTAMENTE en su propio espacio, desde cellSize +
  scrollController.offset (el mismo ScrollPosition que usa el pintor del
  resaltado). Eliminados getOffset(), localToGlobal/globalToLocal contra
  el RenderTerminal y getCellOffset() dinamico del paquete: las
  conversiones cruzadas entre objetos de render eran la fuente del
  descuadre "que no sigue los ejes x e y" y del desgaste progresivo.

""", 'CHANGELOG: v2.17.4')

print('OK: parche v2.17.4 aplicado.')
