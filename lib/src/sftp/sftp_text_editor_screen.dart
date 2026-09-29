// lib/src/sftp/sftp_text_editor_screen.dart
//
// Editor de texto plano para ficheros remotos SFTP (generico: tambien lo
// usa el picker de ficheros locales). v2.1.0: buscar/reemplazar, ir a
// linea, auto-indent, undo/redo, barra de estado, seleccionar todo/copiar.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class _C {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const border = Color(0xFF3A3A3C);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const accent = Color(0xFF5E9BD6);
  static const err = Color(0xFFFF453A);
  static const ok = Color(0xFF34C759);
}

class SftpTextEditorScreen extends StatefulWidget {
  final String fileName;
  final Future<Uint8List> Function() loader;
  final Future<void> Function(Uint8List bytes) saver;
  final int sizeLimitBytes;

  const SftpTextEditorScreen({
    super.key,
    required this.fileName,
    required this.loader,
    required this.saver,
    this.sizeLimitBytes = 1024 * 1024,
  });

  @override
  State<SftpTextEditorScreen> createState() => _SftpTextEditorScreenState();
}

class _SftpTextEditorScreenState extends State<SftpTextEditorScreen> {
  final _controller = TextEditingController();
  final _searchCtrl = TextEditingController();
  final _replaceCtrl = TextEditingController();

  bool _loading = true;
  bool _loaded = false;
  bool _saving = false;
  bool _dirty = false;
  String? _error;
  String _encoding = '';
  int _size = 0;

  // v2.1.0
  bool _wrap = true;
  bool _showSearch = false;
  bool _caseSensitive = false;
  final _undo = <String>[];
  final _redo = <String>[];
  String _lastText = '';
  DateTime _lastSnapshot = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _statusDebounce;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onEdit);
    _load();
  }

  @override
  void dispose() {
    _statusDebounce?.cancel();
    _controller.dispose();
    _searchCtrl.dispose();
    _replaceCtrl.dispose();
    super.dispose();
  }

  // ---------- carga / guardado ----------

  static bool _looksBinary(Uint8List head) {
    final n = head.length > 8192 ? 8192 : head.length;
    for (var i = 0; i < n; i++) {
      if (head[i] == 0) return true;
    }
    return false;
  }

  static String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _loaded = false;
      _dirty = false;
    });
    try {
      final bytes = await widget.loader();
      if (!mounted) return;
      _size = bytes.length;
      if (bytes.length > widget.sizeLimitBytes) {
        setState(() {
          _loading = false;
          _error = 'Fichero demasiado grande: ${_fmtBytes(bytes.length)} '
              '(limite ${_fmtBytes(widget.sizeLimitBytes)}).\n'
              'Descargalo y editalo localmente.';
        });
        return;
      }
      if (_looksBinary(bytes)) {
        setState(() {
          _loading = false;
          _error = 'El fichero parece binario (contiene bytes nulos en su '
              'cabecera) y no es seguro editarlo como texto.';
        });
        return;
      }
      String text;
      try {
        text = utf8.decode(bytes);
        _encoding = 'UTF-8';
      } on FormatException {
        text = latin1.decode(bytes);
        _encoding = 'Latin-1';
      }
      _controller.text = text;
      _lastText = text;
      _undo
        ..clear()
        ..add(text);
      _redo.clear();
      _scheduleStatus();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loaded = true;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No se pudo abrir el fichero: $err';
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final bytes = Uint8List.fromList(utf8.encode(_controller.text));
      await widget.saver(bytes);
      if (!mounted) return;
      _size = bytes.length;
      setState(() {
        _saving = false;
        _dirty = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${widget.fileName} guardado (${_fmtBytes(bytes.length)})'),
        backgroundColor: _C.ok,
      ));
    } catch (err) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error al guardar: $err'),
        backgroundColor: _C.err,
      ));
    }
  }

  // ---------- edicion: undo/redo, auto-indent, estado ----------

  void _onEdit() {
    if (!_loaded) return;
    _autoIndent();
    final now = DateTime.now();
    if (now.difference(_lastSnapshot).inMilliseconds > 800) {
      _undo.add(_lastText);
      if (_undo.length > 200) _undo.removeAt(0);
      _redo.clear();
      _lastSnapshot = now;
    }
    _lastText = _controller.text;
    if (!_dirty) setState(() => _dirty = true);
    _scheduleStatus();
  }

  /// Tras pulsar Intro, hereda la indentacion (espacios/tabs) de la linea
  /// anterior. Sin recursion: la reentrada no cumple la condicion de diff.
  void _autoIndent() {
    final text = _controller.text;
    if (text.length != _lastText.length + 1) return;
    final sel = _controller.selection;
    if (!sel.isValid || sel.baseOffset != sel.extentOffset) return;
    final pos = sel.baseOffset;
    if (pos < 1 || text[pos - 1] != '\n') return;
    final before = text.substring(0, pos - 1);
    final lineStart = before.lastIndexOf('\n') + 1;
    final prevLine = before.substring(lineStart);
    final indent = RegExp(r'^[ \t]*').firstMatch(prevLine)?.group(0) ?? '';
    if (indent.isEmpty) return;
    _lastText = text; // evita reentrada
    _controller.value = TextEditingValue(
      text: text.substring(0, pos) + indent + text.substring(pos),
      selection: TextSelection.collapsed(offset: pos + indent.length),
    );
  }

  void _scheduleStatus() {
    _statusDebounce?.cancel();
    _statusDebounce = Timer(const Duration(milliseconds: 300), _updateStatus);
  }

  void _updateStatus() {
    if (!mounted) return;
    final sel = _controller.selection;
    final text = _controller.text;
    var line = 1, col = 1;
    if (sel.isValid && sel.baseOffset <= text.length) {
      final upto = sel.baseOffset;
      line = '\n'.allMatches(text.substring(0, upto)).length + 1;
      final ls = text.lastIndexOf('\n', upto - 1 < 0 ? 0 : upto - 1);
      col = upto - (ls < 0 ? 0 : ls);
    }
    var selLen = 0;
    if (sel.isValid && sel.baseOffset != sel.extentOffset) {
      selLen = (sel.extentOffset - sel.baseOffset).abs();
    }
    final words =
        text.isEmpty ? 0 : text.trim().split(RegExp(r'\s+')).length;
    setState(() {
      _status = 'Ln $line, Col $col'
          '${selLen > 0 ? ' · sel $selLen' : ''}'
          ' · $words palabras · ${_fmtBytes(text.length)}'
          ' · $_encoding${_dirty ? ' · modificado' : ''}';
    });
  }

  void _undoIt() {
    if (_undo.isEmpty) return;
    _redo.add(_controller.text);
    _applyHistory(_undo.removeLast());
  }

  void _redoIt() {
    if (_redo.isEmpty) return;
    _undo.add(_controller.text);
    _applyHistory(_redo.removeLast());
  }

  void _applyHistory(String text) {
    _lastText = text;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _scheduleStatus();
    setState(() {});
  }

  // ---------- buscar / reemplazar ----------

  bool _matchAt(String text, int i, String q) {
    if (i < 0 || i + q.length > text.length) return false;
    final slice = text.substring(i, i + q.length);
    return _caseSensitive ? slice == q : slice.toLowerCase() == q.toLowerCase();
  }

  int _findFrom(String text, String q, int start) {
    if (q.isEmpty) return -1;
    if (_caseSensitive) {
      final i = text.indexOf(q, start);
      return i >= 0 ? i : text.indexOf(q); // wrap-around
    }
    final lower = text.toLowerCase();
    final ql = q.toLowerCase();
    final i = lower.indexOf(ql, start);
    return i >= 0 ? i : lower.indexOf(ql);
  }

  void _findNext() {
    final q = _searchCtrl.text;
    if (q.isEmpty) return;
    final text = _controller.text;
    final sel = _controller.selection;
    final start = sel.isValid && sel.baseOffset >= 0 ? sel.baseOffset : 0;
    final i = _findFrom(text, q, start);
    if (i < 0) {
      _toast('Sin resultados');
      return;
    }
    _select(i, q.length);
  }

  void _select(int i, int len) {
    _controller.selection = TextSelection(baseOffset: i, extentOffset: i + len);
    _scheduleStatus();
  }

  void _replaceOne() {
    final q = _searchCtrl.text;
    if (q.isEmpty) return;
    final text = _controller.text;
    final sel = _controller.selection;
    if (sel.isValid &&
        sel.baseOffset != sel.extentOffset &&
        _matchAt(text, sel.baseOffset, q)) {
      final repl = _replaceCtrl.text;
      final newText = text.replaceRange(sel.baseOffset, sel.baseOffset + q.length, repl);
      final newPos = sel.baseOffset + repl.length;
      _lastText = newText;
      _controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newPos),
      );
      if (!_dirty) setState(() => _dirty = true);
      _scheduleStatus();
    }
    _findNext();
  }

  void _replaceAll() {
    final q = _searchCtrl.text;
    if (q.isEmpty) return;
    final text = _controller.text;
    final repl = _replaceCtrl.text;
    final newText = _caseSensitive
        ? text.replaceAll(q, repl)
        : text.replaceAll(RegExp(RegExp.escape(q), caseSensitive: false), repl);
    if (newText == text) {
      _toast('Sin resultados');
      return;
    }
    _lastText = newText;
    _controller.value = TextEditingValue(
      text: newText,
      selection: const TextSelection.collapsed(offset: 0),
    );
    if (!_dirty) setState(() => _dirty = true);
    _scheduleStatus();
    _toast('Reemplazado');
  }

  // ---------- ir a linea ----------

  Future<void> _goToLine() async {
    final c = TextEditingController();
    final line = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('Ir a linea', style: TextStyle(color: _C.textHi)),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: _C.textHi),
          decoration: const InputDecoration(
            hintText: 'Numero de linea',
            hintStyle: TextStyle(color: _C.textLo),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, int.tryParse(c.text.trim())),
              child: const Text('Ir')),
        ],
      ),
    );
    if (line == null || line < 1) return;
    final text = _controller.text;
    var offset = 0;
    var current = 1;
    while (current < line) {
      final next = text.indexOf('\n', offset);
      if (next < 0) break;
      offset = next + 1;
      current++;
    }
    _controller.selection = TextSelection.collapsed(offset: offset);
    _scheduleStatus();
  }

  // ---------- seleccion ----------

  void _selectAll() {
    final text = _controller.text;
    _controller.selection =
        TextSelection(baseOffset: 0, extentOffset: text.length);
    _scheduleStatus();
  }

  void _copySelection() {
    final sel = _controller.selection;
    final text = _controller.text;
    if (!sel.isValid || sel.baseOffset == sel.extentOffset) return;
    final a = sel.baseOffset < sel.extentOffset ? sel.baseOffset : sel.extentOffset;
    final b = sel.baseOffset < sel.extentOffset ? sel.extentOffset : sel.baseOffset;
    Clipboard.setData(ClipboardData(text: text.substring(a, b)));
    _toast('Copiado');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 1)));
  }

  Future<bool> _confirmExit() async {
    if (!_dirty || !_loaded) return true;
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('Cambios sin guardar',
            style: TextStyle(color: _C.textHi)),
        content: const Text('¿Guardar antes de salir?',
            style: TextStyle(color: _C.textLo)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'discard'),
              child: const Text('Descartar',
                  style: TextStyle(color: _C.err))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('Seguir editando')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('Guardar')),
        ],
      ),
    );
    if (r == 'discard') return true;
    if (r == 'save') {
      await _save();
      return !_dirty;
    }
    return false;
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _confirmExit,
      child: Scaffold(
        backgroundColor: _C.bg,
        appBar: AppBar(
          backgroundColor: _C.bg,
          elevation: 0,
          iconTheme: const IconThemeData(color: _C.textHi),
          title: Text(widget.fileName,
              style: const TextStyle(color: _C.textHi, fontSize: 15)),
          actions: [
            IconButton(
              tooltip: 'Seleccionar todo',
              icon: const Icon(Icons.select_all, color: _C.textLo),
              onPressed: _loaded ? _selectAll : null,
            ),
            IconButton(
              tooltip: 'Copiar seleccion',
              icon: const Icon(Icons.copy, color: _C.textLo),
              onPressed: _loaded ? _copySelection : null,
            ),
            IconButton(
              tooltip: 'Buscar y reemplazar',
              icon: const Icon(Icons.search, color: _C.textLo),
              onPressed: _loaded
                  ? () => setState(() => _showSearch = !_showSearch)
                  : null,
            ),
            IconButton(
              tooltip: 'Ir a linea',
              icon: const Icon(Icons.format_list_numbered, color: _C.textLo),
              onPressed: _loaded ? _goToLine : null,
            ),
            IconButton(
              tooltip: 'Ajuste de linea',
              icon: Icon(_wrap ? Icons.wrap_text : Icons.notes,
                  color: _C.textLo),
              onPressed: _loaded
                  ? () => setState(() => _wrap = !_wrap)
                  : null,
            ),
            IconButton(
              tooltip: 'Deshacer',
              icon: const Icon(Icons.undo, color: _C.textLo),
              onPressed: _undo.isEmpty ? null : _undoIt,
            ),
            IconButton(
              tooltip: 'Rehacer',
              icon: const Icon(Icons.redo, color: _C.textLo),
              onPressed: _redo.isEmpty ? null : _redoIt,
            ),
            IconButton(
              tooltip: 'Guardar',
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save, color: _C.textLo),
              onPressed: _loaded && !_saving ? _save : null,
            ),
          ],
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildSearchPanel() {
    return Container(
      color: _C.card,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  autofocus: true,
                  style: const TextStyle(color: _C.textHi, fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: 'Buscar...',
                    hintStyle: TextStyle(color: _C.textLo),
                    border: InputBorder.none,
                    isDense: true,
                    prefixIcon: Icon(Icons.search,
                        size: 18, color: _C.textLo),
                  ),
                  onSubmitted: (_) => _findNext(),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_return,
                    size: 18, color: _C.accent),
                tooltip: 'Siguiente',
                onPressed: _findNext,
              ),
              IconButton(
                icon: Icon(
                    _caseSensitive ? Icons.abc : Icons.abc_outlined,
                    size: 18,
                    color: _caseSensitive ? _C.accent : _C.textLo),
                tooltip: 'Mayusculas/minusculas',
                onPressed: () =>
                    setState(() => _caseSensitive = !_caseSensitive),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _replaceCtrl,
                  style: const TextStyle(color: _C.textHi, fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: 'Reemplazar con...',
                    hintStyle: TextStyle(color: _C.textLo),
                    border: InputBorder.none,
                    isDense: true,
                    prefixIcon: Icon(Icons.find_replace,
                        size: 18, color: _C.textLo),
                  ),
                ),
              ),
              TextButton(
                onPressed: _replaceOne,
                child: const Text('Uno', style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                onPressed: _replaceAll,
                child: const Text('Todos', style: TextStyle(fontSize: 12)),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18, color: _C.textLo),
                tooltip: 'Cerrar',
                onPressed: () => setState(() => _showSearch = false),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: _C.accent));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _C.err)),
        ),
      );
    }
    return Column(
      children: [
        if (_showSearch) _buildSearchPanel(),
        Expanded(
          child: Container(
            color: _C.bg,
            child: TextField(
              controller: _controller,
              maxLines: _wrap ? null : 1,
              expands: _wrap,
              scrollPadding: const EdgeInsets.all(20),
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.none,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(
                color: _C.textHi,
                fontSize: 13,
                height: 1.35,
                fontFamily: 'monospace',
                fontFamilyFallback: ['Courier'],
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.all(12),
              ),
            ),
          ),
        ),
        Container(
          width: double.infinity,
          color: _C.card,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text(
            _status.isEmpty
                ? (_loaded ? 'Listo' : '')
                : _status,
            style: const TextStyle(color: _C.textLo, fontSize: 10),
          ),
        ),
      ],
    );
  }
}
