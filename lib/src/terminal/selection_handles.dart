// lib/src/terminal/selection_handles.dart
//
// Asas de seleccion arrastrables + barra flotante Copiar/Pegar/Todo.
//
// v7 - CAMBIO DE ENFOQUE. Las seis versiones anteriores intentaban DEDUCIR
// donde cae cada celda en pantalla: primero desde el cursor parpadeante,
// luego dividiendo el tamano del widget, luego midiendo offsets entre
// widgets... Todas fallaron porque TerminalView contiene un Scrollable
// interno CON PADDING PROPIO (documentado: "Padding around the inner
// Scrollable widget"), y ni el padding ni el desplazamiento del scroll son
// visibles desde fuera. Por eso el desfase parecia distinto cada vez.
//
// Enfoque nuevo: NO deducir nada. El paquete expone onTapUp(details,
// CellOffset) -- te dice exactamente en que celda tocaste. Cada vez que el
// usuario toca la terminal tenemos un par (posicion en pixeles, celda
// real). Con dos toques en celdas distintas se despeja la relacion exacta:
// tamano de celda Y origen, incluyendo el padding y el scroll que no
// podemos ver. Eso se llama calibracion, y sustituye a seis intentos de
// adivinar.
//
// Mientras no haya calibracion, las asas NO se dibujan (no se inventan
// posiciones), pero la barra Copiar/Pegar/Todo SI aparece, anclada abajo
// en un sitio fijo -- util desde el primer segundo, sin depender de
// ninguna geometria.

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

/// Relacion medida entre pixeles y celdas. Se rellena con los toques
/// reales del usuario, no se calcula a ciegas.
class TerminalCalibration {
  double? cellW;
  double? cellH;
  double? originX;
  double? originY;

  // Ultimo par observado (pixel local, celda) para poder despejar con el
  // siguiente toque en una celda distinta.
  Offset? _lastPixel;
  CellOffset? _lastCell;

  bool get isReady =>
      cellW != null && cellH != null && originX != null && originY != null;

  /// Registra un toque: posicion LOCAL dentro del TerminalView + la celda
  /// que el propio paquete dice que corresponde.
  void observe(Offset localPixel, CellOffset cell) {
    final prevPixel = _lastPixel;
    final prevCell = _lastCell;
    _lastPixel = localPixel;
    _lastCell = cell;

    if (prevPixel == null || prevCell == null) return;

    // Necesitamos dos toques en columnas distintas para despejar cellW,
    // y en filas distintas para cellH. Se acumula: cada eje se resuelve
    // por separado en cuanto hay datos suficientes.
    final dxCells = cell.x - prevCell.x;
    if (dxCells != 0) {
      final w = (localPixel.dx - prevPixel.dx) / dxCells;
      if (w > 1 && w < 200) {
        cellW = w;
        originX = localPixel.dx - (cell.x * w);
      }
    }

    final dyCells = cell.y - prevCell.y;
    if (dyCells != 0) {
      final h = (localPixel.dy - prevPixel.dy) / dyCells;
      if (h > 1 && h < 200) {
        cellH = h;
        originY = localPixel.dy - (cell.y * h);
      }
    }
  }

  void reset() {
    cellW = null;
    cellH = null;
    originX = null;
    originY = null;
    _lastPixel = null;
    _lastCell = null;
  }
}

class SelectionHandlesOverlay extends StatefulWidget {
  final Terminal terminal;
  final TerminalController controller;
  final GlobalKey<TerminalViewState> viewKey;
  final TerminalCalibration calibration;
  final VoidCallback onCopy;
  final VoidCallback onPaste;
  final VoidCallback onSelectAll;

  const SelectionHandlesOverlay({
    super.key,
    required this.terminal,
    required this.controller,
    required this.viewKey,
    required this.calibration,
    required this.onCopy,
    required this.onPaste,
    required this.onSelectAll,
  });

  @override
  State<SelectionHandlesOverlay> createState() => _SelectionHandlesOverlayState();
}

class _SelectionHandlesOverlayState extends State<SelectionHandlesOverlay> {
  int? _fixedX;
  int? _fixedY;
  bool _draggingStart = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void didUpdateWidget(covariant SelectionHandlesOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
      _onChange();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// Convierte el origen medido (coordenadas locales del TerminalView) a
  /// coordenadas locales de ESTE overlay.
  Offset? _originInMyCoords() {
    final cal = widget.calibration;
    if (!cal.isReady) return null;

    final termCtx = widget.viewKey.currentContext;
    if (termCtx == null) return null;
    final termBox = termCtx.findRenderObject();
    if (termBox is! RenderBox || !termBox.hasSize) return null;

    final myBox = context.findRenderObject();
    if (myBox is! RenderBox || !myBox.hasSize) return null;

    final originGlobal =
        termBox.localToGlobal(Offset(cal.originX!, cal.originY!));
    return myBox.globalToLocal(originGlobal);
  }

  int _viewportTopAbsolute() {
    final buf = widget.terminal.buffer;
    return buf.height - buf.viewHeight - buf.scrollBack;
  }

  double? _localY(int absoluteRow, double cellH, double originY) {
    final viewportRow = absoluteRow - _viewportTopAbsolute();
    if (viewportRow < 0 || viewportRow >= widget.terminal.buffer.viewHeight) {
      return null;
    }
    return originY + viewportRow * cellH;
  }

  void _startDrag(bool isStartHandle) {
    final sel = widget.controller.selection;
    if (sel == null) return;
    final fixed = isStartHandle ? sel.end : sel.begin;
    _fixedX = fixed.x;
    _fixedY = fixed.y;
    _draggingStart = isStartHandle;
  }

  void _updateDrag(DragUpdateDetails details) {
    final cal = widget.calibration;
    if (!cal.isReady || _fixedX == null || _fixedY == null) return;

    final box = widget.viewKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    final local = box.globalToLocal(details.globalPosition);

    final col = ((local.dx - cal.originX!) / cal.cellW!)
        .round()
        .clamp(0, widget.terminal.buffer.viewWidth - 1)
        .toInt();
    final viewportRow = ((local.dy - cal.originY!) / cal.cellH!).round();
    final absoluteRow = (viewportRow + _viewportTopAbsolute())
        .clamp(0, widget.terminal.buffer.height - 1)
        .toInt();

    final buf = widget.terminal.buffer;
    final movingAnchor = buf.createAnchor(col, absoluteRow);
    final fixedAnchor = buf.createAnchor(_fixedX!, _fixedY!);

    if (_draggingStart) {
      widget.controller.setSelection(movingAnchor, fixedAnchor);
    } else {
      widget.controller.setSelection(fixedAnchor, movingAnchor);
    }
  }

  void _endDrag() {
    _fixedX = null;
    _fixedY = null;
  }

  Widget _handle({required bool isStart}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => _startDrag(isStart),
      onPanUpdate: _updateDrag,
      onPanEnd: (_) => _endDrag(),
      child: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        child: CustomPaint(
          size: const Size(20, 20),
          painter: const _HandlePainter(),
        ),
      ),
    );
  }

  Widget _toolbarButton(String label, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: Colors.white),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _toolbar() {
    return Material(
      color: const Color(0xFF3A3A3C),
      borderRadius: BorderRadius.circular(10),
      elevation: 8,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _toolbarButton('Copiar', Icons.copy, widget.onCopy),
          Container(width: 1, height: 22, color: Colors.white24),
          _toolbarButton('Pegar', Icons.content_paste, widget.onPaste),
          Container(width: 1, height: 22, color: Colors.white24),
          _toolbarButton('Todo', Icons.select_all, widget.onSelectAll),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: _buildChildren(),
    );
  }

  List<Widget> _buildChildren() {
    final sel = widget.controller.selection;
    if (sel == null) return const [];

    final children = <Widget>[];
    final cal = widget.calibration;
    final origin = _originInMyCoords();

    // Asas: SOLO si hay calibracion real. Sin ella no se dibujan -- antes
    // que inventar una posicion, no poner nada.
    if (origin != null && cal.isReady) {
      final startY = _localY(sel.begin.y, cal.cellH!, origin.dy);
      final endY = _localY(sel.end.y, cal.cellH!, origin.dy);

      if (startY != null) {
        children.add(Positioned(
          left: origin.dx + sel.begin.x * cal.cellW! - 16,
          top: startY - 32,
          child: _handle(isStart: true),
        ));
      }
      if (endY != null) {
        children.add(Positioned(
          left: origin.dx + (sel.end.x + 1) * cal.cellW! - 16,
          top: endY + cal.cellH!,
          child: _handle(isStart: false),
        ));
      }
    }

    // Barra: SIEMPRE que haya seleccion, en un sitio fijo y predecible.
    // No depende de ninguna geometria, asi que funciona desde el primer
    // segundo -- calibrado o no.
    children.add(Positioned(
      left: 0,
      right: 0,
      bottom: 12,
      child: Center(child: _toolbar()),
    ));

    return children;
  }
}

class _HandlePainter extends CustomPainter {
  const _HandlePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.greenAccent.shade400;
    final border = Paint()
      ..color = Colors.black54
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    canvas.drawCircle(c, r, paint);
    canvas.drawCircle(c, r, border);
  }

  @override
  bool shouldRepaint(covariant _HandlePainter oldDelegate) => false;
}
