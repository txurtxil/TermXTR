import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'editor_screen.dart';

/// Ficheros locales de la app (documentos + downloads).
/// En [selectMode] devuelve la ruta elegida con Navigator.pop (para subir por SFTP).
class LocalFilesScreen extends StatefulWidget {
  final bool selectMode;
  const LocalFilesScreen({super.key, this.selectMode = false});

  @override
  State<LocalFilesScreen> createState() => _LocalFilesScreenState();
}

class _LocalFilesScreenState extends State<LocalFilesScreen> {
  List<FileSystemEntity> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<Directory> get _dir async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory(docs.path);
  }

  Future<void> _reload() async {
    final dir = await _dir;
    if (!await dir.exists()) await dir.create(recursive: true);
    final files = dir.listSync()
      ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    if (!mounted) return;
    setState(() {
      _files = files;
      _loading = false;
    });
  }

  Future<void> _newFile() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nuevo fichero'),
        content: TextField(
            controller: c,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'nombre.txt')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Crear')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final dir = await _dir;
    final f = File('${dir.path}/$name');
    if (await f.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ya existe un fichero con ese nombre')));
      return;
    }
    await f.create();
    await _open(f);
    await _reload();
  }

  Future<void> _open(File f) async {
    final text = await f.readAsString();
    if (!mounted) return;
    if (widget.selectMode) {
      Navigator.pop(context, f.path);
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EditorScreen(
          title: f.path.split('/').last,
          path: f.path,
          initialContent: text,
          onSave: (content) => f.writeAsString(content, flush: true),
        ),
      ),
    );
    await _reload();
  }

  Future<void> _delete(FileSystemEntity e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar'),
        content: Text('¿Eliminar "${e.path.split('/').last}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok == true) {
      await e.delete(recursive: true);
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.selectMode
            ? 'Elegir fichero para subir'
            : 'Archivos locales'),
      ),
      floatingActionButton: widget.selectMode
          ? null
          : FloatingActionButton(
              onPressed: _newFile,
              child: const Icon(Icons.add),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
              ? const Center(
                  child: Text('Sin ficheros. Pulsa + para crear uno.',
                      textAlign: TextAlign.center))
              : ListView.builder(
                  itemCount: _files.length,
                  itemBuilder: (_, i) {
                    final e = _files[i];
                    final name = e.path.split('/').last;
                    final isDir = e is Directory;
                    return ListTile(
                      leading: Icon(
                          isDir ? Icons.folder : Icons.insert_drive_file,
                          color: isDir ? Colors.amber : null),
                      title: Text(name),
                      onTap: isDir ? null : () => _open(e as File),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => _delete(e),
                      ),
                    );
                  },
                ),
    );
  }
}
