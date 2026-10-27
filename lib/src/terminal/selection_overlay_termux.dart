// lib/src/terminal/selection_overlay_termux.dart
//
// Selección de texto estilo Termux para xterm.dart 4.0.0.
//
// Sustituye a selection_handles.dart (asas por calibración). Ese enfoque
// dependía de TerminalView.onTapUp(details, CellOffset), que en xterm 4.0.0
// está MUERTO: TerminalGestureDetector._handleTapUp solo llama a
// onSingleTapUp, así que ningún tap reporta jamás su celda y la calibración
// nunca recibía datos. Por eso solo funcionaba la barra inferior.
//
// Este overlay no calibra nada: la geometría celda<->píxel la da el propio
// paquete via renderTerminal.getOffset(CellOffset) / getCellOffset(Offset),
// que ya descuentan el padding y el scroll internos.
//
// Flujo (igual que Termux):
//  - Long-press: xterm selecciona la palabra (nativo) -> aparecen asas +
//    barra contextual COPIAR / PEGAR / TODO / cerrar.
//  - Arrastrar un asa mueve ese extremo carácter a carácter; durante el
//    arrastre el asa se eleva sobre el dedo para no tapar el texto.
//  - Dedo cerca del borde superior/inferior -> auto-scroll del terminal.
//  - Tocar fuera limpia la selección (nativo: _onTapDown -> clearSelection)
//    y este overlay reacciona ocultándose.
//
// NOTA TÉCNICA DELIBERADA: RenderTerminal no está exportado por el paquete
// (ui.dart no exporta render.dart), pero TerminalViewState.renderTerminal es
// un getter público. Accedemos a getOffset/getCellOffset/cellSize por vía
// dinámica; los tres existen en 4.0.0 (verificado en la fuente del paquete,
// sha256 168dfedca77cba33fdb6f52e2cd001e9fde216e398e89335c19b524bb22da3a2
// = el tarball exacto de pub.dev que usa el proyecto).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

class TermuxSelectionOverlay extends StatefulWidget {
  const TermuxSelectionOverlay({
    super.key,
    required this.child,
    required this.terminal,
    required this.controller,
    required this.terminalViewKey,
    required this.scrollController,
    this.onCopy,
    this.onPaste,
    this.onSelectAll,
    this.handleColor,
  });

  /// El TerminalView envuelto.
  final Widget child;

  final Terminal terminal;
  final TerminalController controller;

  /// GlobalKey colocada en el TerminalView: da acceso a renderTerminal,
  /// la geometría real celda <-> píxel.
  final GlobalKey<TerminalViewState> terminalViewKey;

  /// La MISMA instancia pasada a TerminalView.scrollController
  /// (vive en TerminalSession); si no, el auto-scroll no movería el
  /// contenido.
  final ScrollController scrollController;

  /// Acciones de la barra. Si no se pasan, el overlay usa su lógica interna.
  final VoidCallback? onCopy;
  final VoidCallback? onPaste;
  final VoidCallback? onSelectAll;

  final Color? handleColor;

  @override
  State<TermuxSelectionOverlay> createState() => TermuxSelectionOverlayState();
}

class TermuxSelectionOverlayState extends State<TermuxSelectionOverlay> {
  static const double _handleSize = 48;
  static const double _dragLift = 56; // elevación del asa sobre el dedo
  static const double _edgeMarginCells = 2.0;
  static const double _scrollCellsPerTick = 0.6;
  static const Duration _scrollTick = Duration(milliseconds: 50);

  // Extremos de selección normalizados (start <= end) para pintar.
  CellOffset? _selStart;
  CellOffset? _selEnd;

  // Estado de arrastre de un asa.
  bool _dragging = false;
  bool _draggingStartHandle = false;
  CellOffset? _dragFixed; // extremo que NO se mueve durante el arrastre
  Offset? _lastFingerGlobal;

  Timer? _autoScrollTimer;
  int _autoScrollDir = 0; // -1 arriba, 0 parado, 1 abajo

  // --- Diagnóstico v2.17.5: panel en pantalla + registro de eventos ------
  final List<String> _dbg = [];
  double _dbgLastOffset = -1;
  CellOffset? _dbgLastCell;
  bool _dbgDirty = false;
  Timer? _dbgTimer;

  void _dbgT(String ev) {
    if (!mounted) return;
    final t = DateTime.now();
    final ts =
        '${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';
    _dbg.insert(0, '$ts $ev');
    if (_dbg.length > 30) _dbg.removeLast();
    _dbgDirty = true; // el timer refresca el panel (seguro: nunca en build)
  }

  // NOTA v14.22: el doble-toque -> TAB se eliminó. El GestureDetector del
  // panel (terminal_view) abre el menú de Utilidades con ese mismo gesto,
  // así que cada apertura del menú inyectaba un TAB en la shell. El
  // autocompletado sigue a un toque: primera opción del menú Utilidades
  // y tecla Tab del keybar.

  bool get _hasSelection => _selStart != null && _selEnd != null;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
    widget.scrollController.addListener(_onViewportChange);
    widget.terminal.addListener(_onViewportChange);
    _dbgTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!mounted) return;
      if (_dbgDirty) {
        _dbgDirty = false;
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _stopAutoScroll();
    _dbgTimer?.cancel();
    widget.controller.removeListener(_onController);
    widget.scrollController.removeListener(_onViewportChange);
    widget.terminal.removeListener(_onViewportChange);
    super.dispose();
  }

  // --- Sincronización con la selección del terminal ------------------------

  void _onController() {
    if (_dragging) return; // durante el arrastre mandan las asas
    final sel = widget.controller.selection;
    if (sel == null) {
      if (_hasSelection) {
        setState(() {
          _selStart = null;
          _selEnd = null;
        });
      }
      return;
    }
    final n = sel.normalized;
    final appeared = !_hasSelection;
    if (_selStart != n.begin || _selEnd != n.end) {
      setState(() {
        _selStart = n.begin;
        _selEnd = n.end;
      });
      if (appeared) {
        HapticFeedback.mediumImpact();
        _dbgT('SEL ${n.begin} -> ${n.end}');
      }
    }
  }

  // Scroll manual u output nuevo con selección activa: las asas siguen
  // al texto (los anchors se mueven con el buffer).
  void _onViewportChange() {
    final sc = widget.scrollController;
    final off = sc.hasClients ? sc.offset : -1.0;
    if ((off - _dbgLastOffset).abs() > 0.5) {
      _dbgLastOffset = off;
      _dbgT('scroll ${off.toStringAsFixed(1)}');
    }
    if (_hasSelection && mounted && !_dragging) {
      setState(() {});
    }
  }

  // --- Geometría (celda <-> píxel) -----------------------------------------

  /// RenderTerminal del TerminalView (acceso dinámico, ver cabecera).
  dynamic get _rt {
    final s = widget.terminalViewKey.currentState;
    if (s == null) return null;
    final rt = s.renderTerminal;
    return (rt as RenderObject).attached ? rt : null;
  }

  /// Top-left de [cell] en coordenadas de ESTE overlay.
  // v2.17.3: anclas VIVAS en cada build. Las anclas de xterm siguen al
  // contenido ante scrolls y recortes del buffer; cachear CellOffsets
  // (_selStart/_selEnd) para DIBUJAR era la causa de la deriva de las
  // asas: el pintor resuelve las anclas en vivo y las asas no, asi que
  // el resaltado iba bien y las gotas se quedaban abajo "desgastandose".
  BufferRange? get _liveSel => widget.controller.selection?.normalized;

  // v2.17.4: geometria PROPIA del overlay. Las posiciones se calculan
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

  double get _cellW {
    final rt = _rt;
    if (rt == null) return 8;
    return (rt.cellSize as Size).width;
  }

  double get _cellH {
    final rt = _rt;
    if (rt == null) return 16;
    return (rt.cellSize as Size).height;
  }

  /// Última celda seleccionada (la selección de xterm es end-exclusive).
  CellOffset? _lastSelectedCell() {
    final sel = _liveSel;
    if (sel == null) return null;
    final end = sel.end;
    final start = sel.begin;
    if (end.x > 0) return CellOffset(end.x - 1, end.y);
    final prevY = math.max(end.y - 1, start.y);
    return CellOffset(widget.terminal.viewWidth - 1, prevY);
  }

  // --- Arrastre de asas -----------------------------------------------------

  void _startDrag(bool isStartHandle, DragStartDetails d) {
    // setState OBLIGATORIO: en v14.22 se cambiaba _dragging sin setState;
    // al soltar el dedo _onController() solo reconstruye si la seleccion
    // cambio (y durante el arrastre ya se sincronizo), asi que la barra
    // quedaba oculta para siempre hasta que llegaba output al terminal.
    setState(() {
      _dragging = true;
      _draggingStartHandle = isStartHandle;
      _dragFixed = isStartHandle ? _selEnd : _selStart;
    });
    _lastFingerGlobal = d.globalPosition;
    _dbgT('DRAG ${isStartHandle ? 'INI' : 'FIN'} fijo=$_dragFixed dedo=${d.globalPosition.dx.toStringAsFixed(0)},${d.globalPosition.dy.toStringAsFixed(0)}');
  }

  void _updateDrag(DragUpdateDetails d) {
    _lastFingerGlobal = d.globalPosition;
    _extendSelectionTo(_aimOf(d.globalPosition));
    _updateAutoScroll(d.globalPosition);
  }

  /// Punto de mira: durante el arrastre el asa se dibuja _dragLift px por
  /// ENCIMA del dedo para no tapar el texto; la selección debe terminar
  /// donde apunta la PUNTA del asa, no donde está el dedo. Antes se usaba
  /// la posición del dedo y asa e highlight iban ~3 líneas desincronizados.
  Offset _aimOf(Offset fingerGlobal) =>
      fingerGlobal - const Offset(0, _dragLift);

  void _endDrag(DragEndDetails d) => _finishDrag();
  void _cancelDrag() => _finishDrag();

  void _finishDrag() {
    _dbgT('DRAG fin');
    _stopAutoScroll();
    setState(() {
      _dragging = false;
      _dragFixed = null;
    });
    _onController(); // resincroniza con la selección final
  }

  void _extendSelectionTo(Offset global) {
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
    final buffer = widget.terminal.buffer;
    // La selección de xterm es end-exclusive: por eso selectCharacters del
    // paquete hace +1 en x al arrastrar hacia adelante. Al arrastrar el asa
    // de FIN hay que hacer lo mismo o la celda bajo la punta queda fuera
    // del highlight (otra fuente de desincronización asa<->texto).
    if (cell != _dbgLastCell) {
      _dbgLastCell = cell;
      _dbgT('arrastre->$cell (dedo=${global.dx.toStringAsFixed(0)},${global.dy.toStringAsFixed(0)})');
    }
    final moving =
        fixed.isBeforeOrSame(cell) ? CellOffset(cell.x + 1, cell.y) : cell;
    widget.controller.setSelection(
      buffer.createAnchorFromOffset(fixed),
      buffer.createAnchorFromOffset(moving),
    );
    // BufferRangeLine normaliza al pintar/copiar; aquí guardamos ordenado.
    setState(() {
      if (fixed.isBeforeOrSame(moving)) {
        _selStart = fixed;
        _selEnd = moving;
      } else {
        _selStart = moving;
        _selEnd = fixed;
      }
    });
  }

  // --- Auto-scroll cerca de los bordes --------------------------------------

  void _updateAutoScroll(Offset fingerGlobal) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    final margin = _cellH * _edgeMarginCells;

    final dir = fingerGlobal.dy < top + margin
        ? -1
        : fingerGlobal.dy > bottom - margin
            ? 1
            : 0;

    if (dir == _autoScrollDir) return;
    _autoScrollDir = dir;
    _stopTimerOnly();
    if (dir != 0) {
      _autoScrollTimer = Timer.periodic(_scrollTick, (_) => _autoScrollStep());
    }
  }

  void _autoScrollStep() {
    final sc = widget.scrollController;
    if (!sc.hasClients) return;
    final pos = sc.position;
    if (!pos.hasContentDimensions) return;
    if (!pos.minScrollExtent.isFinite || !pos.maxScrollExtent.isFinite) return;

    final target = (sc.offset + _autoScrollDir * _cellH * _scrollCellsPerTick)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent)
        .toDouble();
    if (target != sc.offset) {
      sc.jumpTo(target);
      final finger = _lastFingerGlobal;
      if (finger != null) _extendSelectionTo(_aimOf(finger));
    }
  }

  void _stopTimerOnly() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  void _stopAutoScroll() {
    _stopTimerOnly();
    _autoScrollDir = 0;
  }

  // --- Acciones de la barra --------------------------------------------------

  void _copySelection() {
    if (widget.onCopy != null) {
      widget.onCopy!.call();
      return;
    }
    final sel = widget.controller.selection;
    if (sel != null) {
      final text = widget.terminal.buffer.getText(sel);
      if (text.isNotEmpty) {
        Clipboard.setData(ClipboardData(text: text));
      }
    }
    widget.controller.clearSelection();
  }

  void _selectAll() {
    if (widget.onSelectAll != null) {
      widget.onSelectAll!.call();
      return;
    }
    final buffer = widget.terminal.buffer;
    final lastY = buffer.lines.length - 1;
    if (lastY < 0) return;
    widget.controller.setSelection(
      buffer.createAnchor(0, 0),
      buffer.createAnchor(widget.terminal.viewWidth - 1, lastY),
    );
  }

  void _close() => widget.controller.clearSelection();

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final color = widget.handleColor ?? Colors.greenAccent.shade400;

    return Stack(
      children: [
        widget.child,
        if (_hasSelection) ..._buildHandles(color),
        if (_hasSelection) _buildActionBar(context),
        // v2.17.5: panel de diagnostico (build de pruebas).
        _buildDbgPanel(),
      ],
    );
  }

  Widget _buildDbgPanel() {
    if (_dbg.isEmpty) return const SizedBox.shrink();
    final sc = widget.scrollController;
    final sel = _liveSel;
    final box = context.findRenderObject() as RenderBox?;
    final sp = sel == null ? null : _cellToOverlay(sel.begin);
    final ep = _cellToOverlay(_lastSelectedCell());
    final rt = _rt;
    String f(double v) => v.toStringAsFixed(1);
    final lines = <String>[
      'SEL  ${sel?.begin} -> ${sel?.end}',
      'cache ${_selStart} -> ${_selEnd}',
      'sc ${sc.hasClients ? f(sc.offset) : '-'}px | celda ${f(_cellW)}x${f(_cellH)} | rt ${rt == null ? 'NULL' : 'ok'}',
      'box ${box != null && box.hasSize ? '${box.size.width.toStringAsFixed(0)}x${box.size.height.toStringAsFixed(0)}' : '-'}',
      'pos  ${sp == null ? '-' : '${sp.dx.toStringAsFixed(0)},${sp.dy.toStringAsFixed(0)}'} -> ${ep == null ? '-' : '${ep.dx.toStringAsFixed(0)},${ep.dy.toStringAsFixed(0)}'}',
      ..._dbg.take(7),
    ];
    return Positioned(
      left: 4,
      top: 4,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.all(6),
          color: Colors.black.withOpacity(0.75),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final l in lines)
                Text(l,
                    style: const TextStyle(
                        color: Colors.yellowAccent,
                        fontSize: 9,
                        fontFamily: 'monospace',
                        height: 1.2)),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildHandles(Color color) {
    final sel = _liveSel;
    if (sel == null) return const [];
    final startPos = _cellToOverlay(sel.begin);
    final endCellPos = _cellToOverlay(_lastSelectedCell());
    if (startPos == null || endCellPos == null) return const [];

    final box = context.findRenderObject() as RenderBox?;
    final maxW = box?.hasSize == true ? box!.size.width : double.infinity;
    final maxH = box?.hasSize == true ? box!.size.height : double.infinity;

    // Asa de inicio: punta en la esquina inferior-izquierda de la 1ª celda.
    var startTip = startPos + Offset(0, _cellH);
    // Asa de fin: punta en la esquina inferior-derecha del último carácter.
    var endTip = endCellPos + Offset(_cellW, _cellH);

    // Durante el arrastre el asa va elevada sobre el dedo (como Termux).
    if (_dragging && _lastFingerGlobal != null && box != null && box.hasSize) {
      final finger = box.globalToLocal(_lastFingerGlobal!);
      final lifted = finger + const Offset(0, -_dragLift);
      if (_draggingStartHandle) {
        startTip = lifted;
      } else {
        endTip = lifted;
      }
    }

    Offset clampTip(Offset p) => Offset(
          p.dx.clamp(0.0, math.max(0.0, maxW - _handleSize)).toDouble(),
          p.dy.clamp(0.0, math.max(0.0, maxH - _handleSize)).toDouble(),
        );

    return [
      _buildHandle(color, clampTip(startTip), true),
      _buildHandle(color, clampTip(endTip), false),
    ];
  }

  Widget _buildHandle(Color color, Offset tip, bool isStart) {
    // La punta de la lágrima está en (24, 4) dentro del box de 48x48.
    return Positioned(
      left: tip.dx - 24,
      top: tip.dy - 4,
      width: _handleSize,
      height: _handleSize,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) => _startDrag(isStart, d),
        onPanUpdate: _updateDrag,
        onPanEnd: _endDrag,
        onPanCancel: _cancelDrag,
        child: CustomPaint(
          painter: _TeardropPainter(color: color),
        ),
      ),
    );
  }

  /// Barra contextual flotante JUNTO a la selección (como Termux/Android),
  /// no clavada siempre arriba: si la selección estaba en las primeras
  /// líneas, la barra fija en top:8 tapaba el texto seleccionado y el asa
  /// de inicio. Ahora va ENCIMA de la 1ª línea seleccionada; si no cabe,
  /// DEBAJO de la última; y si tampoco (selección a pantalla completa),
  /// se ancla arriba como último recurso. Mientras se arrastra un asa se
  /// oculta para no estorbar al dedo.
  Widget _buildActionBar(BuildContext context) {
    if (_dragging) return const SizedBox.shrink();

    const double barH = 44;
    final box = context.findRenderObject() as RenderBox?;
    final maxH = box?.hasSize == true ? box!.size.height : double.infinity;

    double top = 8;
    final liveSel = _liveSel;
    final startPos = _cellToOverlay(liveSel?.begin);
    final endPos = _cellToOverlay(_lastSelectedCell());
    if (startPos != null && endPos != null) {
      final firstTop = math.min(startPos.dy, endPos.dy);
      final lastBottom = math.max(startPos.dy, endPos.dy) + _cellH;
      final above = firstTop - barH - 6;
      if (above >= 4) {
        top = above;
      } else {
        final below = lastBottom + 10;
        top = (maxH.isFinite && below + barH > maxH - 4) ? 8.0 : below;
      }
    }
    // CLAMP obligatorio (v14.23): en una sesion con output activo la
    // seleccion se desplaza con el buffer y firstTop/lastBottom salen del
    // viewport; sin clamp la barra se posicionaba FUERA de pantalla y
    // "desaparecia" aunque la seleccion siguiera viva.
    if (maxH.isFinite) {
      top = top.clamp(4.0, math.max(4.0, maxH - barH - 4)).toDouble();
    } else if (top < 4) {
      top = 4;
    }

    return Positioned(
      top: top,
      left: 0,
      right: 0,
      child: Center(
        child: Material(
          color: const Color(0xFF3A3A3C),
          borderRadius: BorderRadius.circular(10),
          elevation: 8,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _toolbarButton('Copiar', Icons.copy, _copySelection),
              Container(width: 1, height: 22, color: Colors.white24),
              if (widget.onPaste != null) ...[
                _toolbarButton('Pegar', Icons.content_paste, widget.onPaste!),
                Container(width: 1, height: 22, color: Colors.white24),
              ],
              _toolbarButton('Todo', Icons.select_all, _selectAll),
              Container(width: 1, height: 22, color: Colors.white24),
              InkWell(
                onTap: _close,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Icon(Icons.close, size: 16, color: Colors.white70),
                ),
              ),
            ],
          ),
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
            Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

/// Lágrima tipo asa de selección de Android/Termux: punta arriba en el
/// centro (24, 4) del box de 48x48, bola debajo.
class _TeardropPainter extends CustomPainter {
  const _TeardropPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final shadow = Paint()
      ..color = Colors.black54
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);

    const tip = Offset(24, 4);
    const center = Offset(24, 22);
    const radius = 9.0;

    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(center.dx - radius * 0.75, center.dy - radius * 0.5)
      ..arcToPoint(
        Offset(center.dx + radius * 0.75, center.dy - radius * 0.5),
        radius: const Radius.circular(radius),
        clockwise: false,
        largeArc: true,
      )
      ..close();

    canvas.drawPath(path.shift(const Offset(0, 1.5)), shadow);
    canvas.drawPath(path, paint);
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(_TeardropPainter old) => old.color != color;
}
