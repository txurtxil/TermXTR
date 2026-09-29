// lib/src/sftp/sftp_text_editor_screen.dart
//
// Editor de texto plano para ficheros remotos SFTP: abre el fichero en
// memoria, permite editarlo y guardarlo de vuelta por el mismo canal SFTP.
// Sin dependencias nuevas: TextField multilinea con fuente monospace.
//
// Protecciones:
//  - Limite de tamano (1 MB por defecto): un .log de gigas no se edita
//    desde un movil; los configs/scripts/codigo habituales caben de sobra.
//  - Deteccion de binario: si la cabecera contiene bytes nulos, no se
//    intenta editar (se avisa en vez de corromper el fichero).
//  - Decodificacion UTF-8 con fallback a Latin-1, y la codificacion real
//    usada se muestra en la barra de estado.
//  - Guardado atomico desde el punto de vista del usuario: trunca y
//    reescribe el remoto, con confirmacion al salir si hay cambios sin
//    guardar.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

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

  bool _loading = true;
  bool _loaded = false;
  bool _saving = false;
  bool _dirty = false;
  String? _error;
  String _encoding = '';
  int _size = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onEdit);
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onEdit() {
    if (!_loaded) return;
    if (!_dirty) setState(() => _dirty = true);
  }

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

  Future<void> _reloadWithConfirm() async {
    if (_dirty) {
      final r = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _C.card,
          title: const Text('Descartar cambios', style: TextStyle(color: _C.textHi)),
          content: const Text('Tienes cambios sin guardar que se perderan si recargas.',
              style: TextStyle(color: _C.textLo)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar', style: TextStyle(color: _C.textLo))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Descartar', style: TextStyle(color: _C.err))),
          ],
        ),
      );
      if (r != true) return;
    }
    _load();
  }

  String get _cursorLabel {
    final sel = _controller.selection;
    final text = _controller.text;
    final upto = sel.baseOffset.clamp(0, text.length);
    final before = text.substring(0, upto);
    final line = '\n'.allMatches(before).length + 1;
    final lastNl = before.lastIndexOf('\n');
    final col = upto - lastNl;
    return 'Ln $line, Col $col';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final r = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: _C.card,
            title: const Text('Cambios sin guardar', style: TextStyle(color: _C.textHi)),
            content: const Text('Quieres salir del editor sin guardar?',
                style: TextStyle(color: _C.textLo)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Seguir editando', style: TextStyle(color: _C.textLo))),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Salir sin guardar', style: TextStyle(color: _C.err))),
            ],
          ),
        );
        if (r == true && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        backgroundColor: _C.bg,
        appBar: AppBar(
          backgroundColor: _C.bg,
          iconTheme: const IconThemeData(color: _C.textLo),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.fileName, style: const TextStyle(color: _C.textHi, fontSize: 16)),
              Text('editor remoto SFTP', style: const TextStyle(color: _C.textLo, fontSize: 11)),
            ],
          ),
          actions: [
            if (_dirty)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Icon(Icons.circle, size: 8, color: _C.accent),
              ),
            IconButton(
              tooltip: 'Guardar',
              icon: const Icon(Icons.save_outlined),
              color: (_dirty && !_saving && _loaded) ? _C.ok : _C.textLo,
              onPressed: (_dirty && !_saving && _loaded) ? _save : null,
            ),
            PopupMenuButton<String>(
              iconColor: _C.textLo,
              color: _C.card,
              onSelected: (v) {
                if (v == 'reload') _reloadWithConfirm();
                if (v == 'info') _showInfo();
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'reload', child: Text('Recargar desde el servidor', style: TextStyle(color: _C.textHi))),
                const PopupMenuItem(value: 'info', child: Text('Info del fichero', style: TextStyle(color: _C.textHi))),
              ],
            ),
          ],
        ),
        body: _buildBody(),
      ),
    );
  }

  void _showInfo() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: Text(widget.fileName, style: const TextStyle(color: _C.textHi)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tamano: ${_fmtBytes(_size)}', style: const TextStyle(color: _C.textLo)),
            Text('Codificacion: $_encoding', style: const TextStyle(color: _C.textLo)),
            Text('Caracteres: ${_controller.text.length}', style: const TextStyle(color: _C.textLo)),
            Text('Lineas: ${_controller.text.isEmpty ? 0 : '\n'.allMatches(_controller.text).length + 1}', style: const TextStyle(color: _C.textLo)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar', style: TextStyle(color: _C.accent))),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _C.accent));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: _C.err, size: 40),
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: _C.textLo), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh, color: _C.accent),
                label: const Text('Reintentar', style: TextStyle(color: _C.accent)),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            maxLines: null,
            expands: true,
            keyboardType: TextInputType.multiline,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              height: 1.35,
              color: _C.textHi,
            ),
            cursorColor: _C.accent,
            decoration: const InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.all(12),
              hintText: '(fichero vacio)',
              hintStyle: TextStyle(color: _C.textLo),
            ),
          ),
        ),
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: const BoxDecoration(
            color: _C.card,
            border: Border(top: BorderSide(color: _C.border)),
          ),
          child: Row(
            children: [
              Text(_cursorLabel, style: const TextStyle(color: _C.textLo, fontSize: 11, fontFamily: 'monospace')),
              const Spacer(),
              Text('$_encoding · ${_fmtBytes(_controller.text.length)}', style: const TextStyle(color: _C.textLo, fontSize: 11, fontFamily: 'monospace')),
            ],
          ),
        ),
      ],
    );
  }
}
