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
import 'package:flutter/gestures.dart';
import 'package:xterm/xterm.dart';

import 'clipboard_vault.dart';

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

  // NOTA v14.22: el doble-toque -> TAB se eliminó. El GestureDetector del
  // panel (terminal_view) abre el menú de Utilidades con ese mismo gesto,
  // así que cada apertura del menú inyectaba un TAB en la shell. El
  // autocompletado sigue a un toque: primera opción del menú Utilidades
  // y tecla Tab del keybar.

  // v2.17.6: nuestra limpieza del controller (tras capturar el long-press)
  // dispara _onController con selection==null; sin esta bandera se
  // interpretaria como un dismiss del usuario y nos borraria la seleccion.
  bool _ownClearing = false;

  bool get _hasSelection => _selStart != null && _selEnd != null;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
    widget.scrollController.addListener(_onViewportChange);
    widget.terminal.addListener(_onViewportChange);
  }

  @override
  void dispose() {
    _stopAutoScroll();
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
      if (_hasSelection && !_ownClearing) {
        // Clear externo (tap fuera o boton X del paquete): dismiss real.
        setState(() {
          _selStart = null;
          _selEnd = null;
        });
      }
      _ownClearing = false;
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
        // v2.17.6: el paquete ya aporto la palabra inicial; le quitamos la
        // seleccion para que sus anclas no mueran con el buffer (eso era lo
        // que congelaba la seleccion tras el auto-scroll) y para que su
        // pintor no dibuje un segundo highlight.
        _ownClearing = true;
        widget.controller.clearSelection();
      }
    }
  }

  // Scroll manual u output nuevo con selección activa: las asas siguen
  // al texto (los anchors se mueven con el buffer).
  void _onViewportChange() {
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
  // (v2.17.6) _liveSel eliminado: la seleccion es propia (_selStart/_selEnd).

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
    final s0 = _selStart, e0 = _selEnd;
    if (s0 == null || e0 == null) return null;
    final sel = s0.isBefore(e0) ? BufferRangeLine(s0, e0) : BufferRangeLine(e0, s0);
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
    // v2.17.7: compensacion de agarre — el punto que se agarra (la punta
    // del asa) sigue al dedo desde el primer instante. Sin esto, el "aim"
    // (dedo -56px) hacia saltar la seleccion ~4 filas al empezar a
    // arrastrar: era el "punto de seleccion roto". Se conserva el lift
    // como offset fijo dedo->punta, capturado en el agarre.
    final grabbed = isStartHandle ? _selStart : _selEnd;
    final aimed = _cellFromGlobal(_aimOf(d.globalPosition));
    _grabDelta = (grabbed != null && aimed != null)
        ? CellOffset(grabbed.x - aimed.x, grabbed.y - aimed.y)
        : const CellOffset(0, 0);
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

  // v2.17.7: offset de agarre (celda) para que la punta agarrada siga al
  // dedo sin saltos desde el primer movimiento.
  CellOffset _grabDelta = const CellOffset(0, 0);

  // Celda (col, fila absoluta) bajo un punto global, con la geometria
  // propia del overlay (formula inversa de _cellToOverlay).
  CellOffset? _cellFromGlobal(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    final sc = widget.scrollController;
    if (box == null || !box.hasSize || !sc.hasClients) return null;
    final local = box.globalToLocal(global);
    final cw = _cellW, ch = _cellH;
    var col = (local.dx / cw).floor();
    var row = ((local.dy + sc.offset) / ch).floor();
    if (col < 0) col = 0;
    if (col > widget.terminal.viewWidth - 1) col = widget.terminal.viewWidth - 1;
    if (row < 0) row = 0;
    final maxRow = widget.terminal.buffer.lines.length - 1;
    if (row > maxRow) row = maxRow;
    return CellOffset(col, row);
  }

  // Long-press propio (v2.17.7): selecciona la palabra bajo el dedo usando
  // la geometria propia — el paquete seleccionaba una palabra distinta a
  // donde se pulsaba. Si la linea no tiene caracter de palabra, selecciona
  // la linea entera (como hace Termux).
  void _selectWordAt(CellOffset cell) {
    final buffer = widget.terminal.buffer;
    if (cell.y >= buffer.lines.length) return;
    final line = buffer.lines[cell.y];
    final text = line.getText(0, line.getTrimmedLength());
    if (text.isEmpty) {
      setState(() {
        _selStart = CellOffset(0, cell.y);
        _selEnd = CellOffset(widget.terminal.viewWidth, cell.y + 1);
      });
      HapticFeedback.mediumImpact();
      return;
    }
    var x = cell.x;
    if (x >= text.length) x = text.length - 1;
    if (x < 0) x = 0;
    bool isWordChar(int i) =>
        RegExp(r'[A-Za-z0-9_/\.~:@%+,=-]').hasMatch(text[i]);
    if (!isWordChar(x)) {
      var l = x - 1;
      var r = x + 1;
      var found = -1;
      while (l >= 0 || r < text.length) {
        if (r < text.length && isWordChar(r)) {
          found = r;
          break;
        }
        if (l >= 0 && isWordChar(l)) {
          found = l;
          break;
        }
        l--;
        r++;
      }
      if (found < 0) {
        setState(() {
          _selStart = CellOffset(0, cell.y);
          _selEnd = CellOffset(widget.terminal.viewWidth, cell.y + 1);
        });
        HapticFeedback.mediumImpact();
        return;
      }
      x = found;
    }
    var a = x;
    while (a > 0 && isWordChar(a - 1)) a--;
    var b = x;
    while (b < text.length && isWordChar(b)) b++;
    setState(() {
      _selStart = CellOffset(a, cell.y);
      _selEnd = CellOffset(b, cell.y);
    });
    HapticFeedback.mediumImpact();
  }

  void _endDrag(DragEndDetails d) => _finishDrag();
  void _cancelDrag() => _finishDrag();

  void _finishDrag() {
    setState(() {
      _dragging = false;
      _dragFixed = null;
    });
    // v2.17.6: sin _onController() — la seleccion es propia y ese resync
    // veria el controller vacio y borraria la seleccion al soltar.
  }

  void _extendSelectionTo(Offset global) {
    final fixed = _dragFixed;
    if (fixed == null) return;
    final base = _cellFromGlobal(global);
    if (base == null) return;
    // v2.17.7: compensacion de agarre — la punta agarrada sigue al dedo con
    // el offset capturado al empezar (sin salto inicial del aim).
    var cx = base.x + _grabDelta.x;
    var cy = base.y + _grabDelta.y;
    if (cx < 0) cx = 0;
    if (cx > widget.terminal.viewWidth - 1) cx = widget.terminal.viewWidth - 1;
    if (cy < 0) cy = 0;
    final maxRow = widget.terminal.buffer.lines.length - 1;
    if (cy > maxRow) cy = maxRow;
    final cell = CellOffset(cx, cy);
    // v2.17.6: seleccion PROPIA en CellOffset (end-exclusive como el
    // paquete: +1 en x al avanzar hacia adelante). NADA de anclas: las
    // CellAnchor de xterm viven en las lineas del buffer y se invalidan
    // con scrolls/reciclados, congelando la seleccion (ver v2.17.5).
    final moving =
        fixed.isBeforeOrSame(cell) ? CellOffset(cell.x + 1, cell.y) : cell;
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
    // v2.17.6: copia desde la seleccion PROPIA leyendo el buffer, sin
    // depender de las anclas del paquete. ClipboardVault.copy graba en el
    // historial interno y en el portapapeles del sistema.
    final s = _selStart, e = _selEnd;
    if (s == null || e == null) return;
    final first = s.isBefore(e) ? s : e;
    final last = s.isBefore(e) ? e : s;
    final text = widget.terminal.buffer
        .getText(BufferRangeLine(first, last));
    if (text.isEmpty) return;
    ClipboardVault.instance.copy(text, label: 'seleccion');
    HapticFeedback.selectionClick();
    _toast(context, 'Copiado (${text.length} caracteres)');
    _close();
  }

  void _toast(BuildContext context, String msg) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ));
  }

  void _selectAll() {
    // v2.17.6: select-all propio (sin anclas del paquete).
    final lastY = widget.terminal.buffer.lines.length - 1;
    if (lastY < 0) return;
    setState(() {
      _selStart = const CellOffset(0, 0);
      _selEnd = CellOffset(widget.terminal.viewWidth, lastY);
    });
  }

  void _close() => widget.controller.clearSelection();

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final color = widget.handleColor ?? Colors.greenAccent.shade400;

    return Stack(
      children: [
        // v2.17.7: long-press PROPIO. El detector del paquete vive mas
        // profundo en el arbol y ganaba el empate de la arena; este
        // reconocedor acepta antes (380 ms vs 500 ms) y se lleva el gesto.
        RawGestureDetector(
          behavior: HitTestBehavior.translucent,
          gestures: <Type, GestureRecognizerFactory>{
            _FastLongPressRecognizer:
                GestureRecognizerFactoryWithHandlers<_FastLongPressRecognizer>(
              () => _FastLongPressRecognizer(debugOwner: this),
              (recognizer) {
                recognizer.onLongPressStart = (details) {
                  final cell = _cellFromGlobal(details.globalPosition);
                  if (cell != null) _selectWordAt(cell);
                };
              },
            ),
          },
          child: widget.child,
        ),
        if (_hasSelection) _buildHighlight(),
        if (_hasSelection) ..._buildHandles(color),
        if (_hasSelection) _buildActionBar(context),
      ],
    );
  }


  // Highlight propio (v2.17.6): rectangulos por fila con la geometria
  // propia (celda + sc.offset), mismos valores que usan las asas, asi que
  // no puede desincronizarse con ellas ni con la posicion del texto.
  Widget _buildHighlight() {
    final s = _selStart, e = _selEnd;
    if (s == null || e == null) return const SizedBox.shrink();
    final first = s.isBefore(e) ? s : e;
    final last = s.isBefore(e) ? e : s;
    final sc = widget.scrollController;
    if (!sc.hasClients) return const SizedBox.shrink();
    final cw = _cellW, ch = _cellH;
    final vw = widget.terminal.viewWidth * cw;
    final maxRow = widget.terminal.buffer.lines.length - 1;
    final rects = <Rect>[];
    for (var r = first.y; r <= last.y && r <= maxRow; r++) {
      final x0 = r == first.y ? first.x * cw : 0.0;
      final x1 = r == last.y ? (last.x + 1) * cw : vw;
      if (x1 <= x0) continue;
      rects.add(Rect.fromLTWH(x0, r * ch - sc.offset, x1 - x0, ch));
    }
    if (rects.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(size: Size.infinite, painter: _HighlightPainter(rects)),
      ),
    );
  }

  List<Widget> _buildHandles(Color color) {
    final sel = _selStart == null || _selEnd == null
        ? null
        : (_selStart!.isBefore(_selEnd!)
            ? BufferRangeLine(_selStart!, _selEnd!)
            : BufferRangeLine(_selEnd!, _selStart!));
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
    final s0 = _selStart, e0 = _selEnd;
    final liveSel = s0 != null && e0 != null
        ? (s0.isBefore(e0) ? BufferRangeLine(s0, e0) : BufferRangeLine(e0, s0))
        : null;
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
// Reconocedor de long-press con deadline mas corto que el del paquete
// xterm (500 ms): aceptando a los 380 ms gana la arena de gestos y es este
// overlay quien decide la palabra inicial, con la geometria propia.
class _FastLongPressRecognizer extends LongPressGestureRecognizer {
  _FastLongPressRecognizer({Object? debugOwner})
      : super(
          debugOwner: debugOwner,
          duration: const Duration(milliseconds: 380),
        );
}

class _HighlightPainter extends CustomPainter {
  _HighlightPainter(this.rects);
  final List<Rect> rects;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withOpacity(0.22);
    for (final r in rects) {
      canvas.drawRect(r, paint);
    }
  }

  @override
  bool shouldRepaint(_HighlightPainter old) => true;
}

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
