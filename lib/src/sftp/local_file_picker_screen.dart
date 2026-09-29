// lib/src/sftp/local_file_picker_screen.dart
//
// Explorador del almacenamiento del propio telefono, para elegir que
// fichero(s) subir por SFTP. dart:io puro (Directory/File), mismo patron
// que sftp_browser_screen.dart -- cero dependencias nuevas.
//
// Selecciona uno o varios ficheros marcando la casilla; "Subir (N)" los
// devuelve todos de golpe via Navigator.pop(context, List<String>). Tocar
// una carpeta navega dentro, como siempre.

import 'dart:io';
import 'package:flutter/material.dart';

class _C {
  static const bg = Color(0xFF1C1C1E);
  static const cardAlt = Color(0xFF242426);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const accent = Color(0xFF5E9BD6);
}

class LocalFilePickerScreen extends StatefulWidget {
  /// false: se eligen FICHEROS (subida normal). true: se eligen CARPETAS
  /// (subida recursiva) — se marcan con checkbox y se puede seguir entrando
  /// en ellas tocando el nombre.
  final bool folderMode;
  const LocalFilePickerScreen({super.key, this.folderMode = false});

  @override
  State<LocalFilePickerScreen> createState() => _LocalFilePickerScreenState();
}

class _LocalFilePickerScreenState extends State<LocalFilePickerScreen> {
  static const String _startDir = '/storage/emulated/0';

  String _currentPath = _startDir;
  List<FileSystemEntity> _entries = [];
  final Set<String> _selected = {};
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(_startDir);
  }

  Future<void> _load(String path) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final dir = Directory(path);
      final list = await dir.list().toList();
      list.sort((a, b) {
        final aDir = a is Directory;
        final bDir = b is Directory;
        if (aDir != bDir) return aDir ? -1 : 1;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
      if (mounted) {
        setState(() {
          _currentPath = path;
          _entries = list;
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'No se pudo abrir esta carpeta: $e';
          _busy = false;
        });
      }
    }
  }

  void _up() {
    if (_currentPath == _startDir) return;
    final parent = Directory(_currentPath).parent.path;
    _load(parent.isEmpty ? _startDir : parent);
  }

  String _name(FileSystemEntity e) => e.path.split('/').last;

  void _toggle(String path) {
    setState(() {
      if (_selected.contains(path)) {
        _selected.remove(path);
      } else {
        _selected.add(path);
      }
    });
  }

  void _selectAllHere() {
    setState(() {
      for (final e in _entries) {
        final ok = widget.folderMode ? e is Directory : e is File;
        if (ok) _selected.add(e.path);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.bg,
      appBar: AppBar(
        backgroundColor: _C.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: _C.textHi),
        title: Text(
          _selected.isEmpty
              ? (widget.folderMode ? 'Elegir carpeta(s)' : 'Elegir fichero(s)')
              : '${_selected.length} seleccionado(s)',
          style: const TextStyle(color: _C.textHi, fontSize: 16),
        ),
        actions: [
          IconButton(
            tooltip: widget.folderMode
                ? 'Seleccionar todas las carpetas de aquí'
                : 'Seleccionar todos los ficheros de esta carpeta',
            icon: const Icon(Icons.select_all, color: _C.textLo),
            onPressed: _entries.any((e) => widget.folderMode ? e is Directory : e is File)
                ? _selectAllHere
                : null,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: _C.cardAlt,
            child: Row(
              children: [
                if (_currentPath != _startDir)
                  IconButton(
                    icon: const Icon(Icons.arrow_upward, color: _C.textLo, size: 18),
                    onPressed: _up,
                  ),
                Expanded(
                  child: Text(
                    _currentPath,
                    style: const TextStyle(color: _C.textLo, fontSize: 11, fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _buildBody()),
          if (_selected.isNotEmpty)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(_selected.toList()),
                    style: ElevatedButton.styleFrom(backgroundColor: _C.accent, padding: const EdgeInsets.symmetric(vertical: 14)),
                    child: Text('Subir (${_selected.length})', style: const TextStyle(color: Colors.white)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_busy) return const Center(child: CircularProgressIndicator(color: _C.accent));
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, style: const TextStyle(color: _C.textLo, fontSize: 12), textAlign: TextAlign.center),
        ),
      );
    }
    if (_entries.isEmpty) {
      return const Center(child: Text('Carpeta vacia', style: TextStyle(color: _C.textLo)));
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, i) {
        final e = _entries[i];
        final isDir = e is Directory;
        final selected = _selected.contains(e.path);
        final selectable = widget.folderMode ? isDir : !isDir;
        return ListTile(
          leading: selectable
              ? Checkbox(
                  value: selected,
                  onChanged: (_) => _toggle(e.path),
                  activeColor: _C.accent,
                )
              : Icon(
                  isDir ? Icons.folder : Icons.insert_drive_file_outlined,
                  color: isDir ? _C.accent : _C.textLo,
                ),
          title: Text(_name(e), style: const TextStyle(color: _C.textHi, fontSize: 14)),
          // Tocar una carpeta siempre entra en ella; marcarla es cosa del
          // checkbox (así se puede elegir sin perder la navegación).
          onTap: () {
            if (isDir) {
              _load(e.path);
            } else if (!widget.folderMode) {
              _toggle(e.path);
            }
          },
        );
      },
    );
  }
}
