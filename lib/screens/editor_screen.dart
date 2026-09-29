import 'package:flutter/material.dart';

/// Editor de texto sencillo: undo/redo, guardar, confirmacion de cambios.
/// - [onSave] null => solo lectura.
/// - Si [askTitleOnSave] es true, pide nombre de fichero al guardar.
class EditorScreen extends StatefulWidget {
  final String title;
  final String? path;
  final String initialContent;
  final Future<void> Function(String content)? onSave;
  final bool askTitleOnSave;

  const EditorScreen({
    super.key,
    required this.title,
    this.path,
    this.initialContent = '',
    this.onSave,
    this.askTitleOnSave = false,
  });

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final TextEditingController _ctrl;
  final _undo = <String>[];
  final _redo = <String>[];
  bool _dirty = false;
  bool _saving = false;
  String? _savedTitle;
  DateTime _lastSnapshot = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _canSave => widget.onSave != null;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialContent);
    _undo.add(widget.initialContent); // punto de partida deshacible
    _savedTitle = widget.title;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    final now = DateTime.now();
    if (now.difference(_lastSnapshot).inMilliseconds > 800) {
      _undo.add(_ctrl.text);
      if (_undo.length > 200) _undo.removeAt(0);
      _redo.clear();
      _lastSnapshot = now;
    }
    if (!_dirty) setState(() => _dirty = true);
  }

  void _undoIt() {
    if (_undo.isEmpty) return;
    _redo.add(_ctrl.text);
    _ctrl.text = _undo.removeLast();
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    setState(() {});
  }

  void _redoIt() {
    if (_redo.isEmpty) return;
    _undo.add(_ctrl.text);
    _ctrl.text = _redo.removeLast();
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    setState(() {});
  }

  Future<String?> _askName() async {
    final c = TextEditingController(text: widget.path ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nombre del fichero'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'ruta/nombre.txt'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Guardar')),
        ],
      ),
    );
  }

  Future<bool> _save() async {
    final cb = widget.onSave;
    if (cb == null) return true;
    if (widget.askTitleOnSave) {
      final name = await _askName();
      if (name == null || name.isEmpty) return false;
      _savedTitle = name;
    }
    setState(() => _saving = true);
    try {
      await cb(_ctrl.text);
      if (!mounted) return false;
      setState(() {
        _saving = false;
        _dirty = false;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Guardado')));
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error al guardar: $e')));
      return false;
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty || !_canSave) return true;
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cambios sin guardar'),
        content: const Text('¿Que quieres hacer?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('Seguir editando')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'discard'),
              child: const Text('Descartar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('Guardar')),
        ],
      ),
    );
    if (r == 'discard') return true;
    if (r == 'save') return _save();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _confirmDiscard,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_savedTitle ?? widget.title),
          actions: [
            IconButton(
              icon: const Icon(Icons.undo),
              onPressed: _undo.isEmpty ? null : _undoIt,
            ),
            IconButton(
              icon: const Icon(Icons.redo),
              onPressed: _redo.isEmpty ? null : _redoIt,
            ),
            if (_canSave)
              IconButton(
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save),
                onPressed: _saving ? null : _save,
              ),
          ],
        ),
        body: Column(
          children: [
            if (_dirty && _canSave)
              Container(
                width: double.infinity,
                color: Colors.orange.shade700,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child:
                    const Text('Sin guardar', style: TextStyle(fontSize: 12)),
              ),
            Expanded(
              child: TextField(
                controller: _ctrl,
                onChanged: _onChanged,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                readOnly: !_canSave,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 14,
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.all(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
