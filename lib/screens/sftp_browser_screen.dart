import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/host_profile.dart';
import '../src/ssh/ssh_service.dart';
import 'editor_screen.dart';
import 'local_files_screen.dart';

/// Explorador de ficheros SFTP sobre un host. Conexion propia.
class SftpBrowserScreen extends StatefulWidget {
  final HostProfile host;
  const SftpBrowserScreen({super.key, required this.host});

  @override
  State<SftpBrowserScreen> createState() => _SftpBrowserScreenState();
}

class _SftpBrowserScreenState extends State<SftpBrowserScreen> {
  late final SshService _service;
  final _stack = <String>['/'];
  List<SftpName>? _items;
  String? _error;
  bool _busy = false;

  String get _cwd => _stack.last;

  @override
  void initState() {
    super.initState();
    _service = SshService(widget.host);
    _init();
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    await _service.connect();
    if (!_service.isConnected) {
      setState(() => _error = _service.error ?? 'Conexion fallida');
      return;
    }
    await _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sftp = await _service.sftp();
      final items = await sftp.listdir(_cwd);
      items.sort((a, b) {
        final ad = a.attr.isDirectory, bd = b.attr.isDirectory;
        if (ad != bd) return ad ? -1 : 1;
        return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _items = items.where((e) => e.filename != '.' && e.filename != '..').toList();
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  String _join(String dir, String name) =>
      dir == '/' ? '/$name' : '$dir/$name';

  void _enter(SftpName item) {
    if (item.attr.isDirectory) {
      _stack.add(_join(_cwd, item.filename));
      _refresh();
    } else {
      _fileActions(item);
    }
  }

  bool _up() {
    if (_stack.length > 1) {
      _stack.removeLast();
      _refresh();
      return true;
    }
    return false;
  }

  Future<void> _fileActions(SftpName item) async {
    final path = _join(_cwd, item.filename);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
                leading: const Icon(Icons.download),
                title: const Text('Descargar'),
                onTap: () => Navigator.pop(ctx, 'download')),
            ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Abrir en editor'),
                onTap: () => Navigator.pop(ctx, 'edit')),
            ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: const Text('Renombrar'),
                onTap: () => Navigator.pop(ctx, 'rename')),
            ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: const Text('Eliminar',
                    style: TextStyle(color: Colors.red)),
                onTap: () => Navigator.pop(ctx, 'delete')),
          ],
        ),
      ),
    );
    switch (action) {
      case 'download':
        await _download(item, path);
        break;
      case 'edit':
        await _editRemote(item, path);
        break;
      case 'rename':
        await _rename(item, path);
        break;
      case 'delete':
        await _delete(item, path);
        break;
    }
  }

  Future<void> _download(SftpName item, String path) async {
    try {
      setState(() => _busy = true);
      final sftp = await _service.sftp();
      final file = await sftp.open(path);
      final bytes = await file.readBytes();
      await file.close();
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/downloads');
      await dir.create(recursive: true);
      final local = File('${dir.path}/${item.filename}');
      await local.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Descargado: ${local.path}')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _editRemote(SftpName item, String path) async {
    try {
      setState(() => _busy = true);
      final sftp = await _service.sftp();
      final file = await sftp.open(path);
      final bytes = await file.readBytes();
      await file.close();
      final text = utf8.decode(bytes, allowMalformed: true);
      if (!mounted) return;
      setState(() => _busy = false);
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => EditorScreen(
            title: item.filename,
            path: path,
            initialContent: text,
            onSave: (content) async {
              final f = await sftp.open(
                path,
                mode: SftpFileOpenMode.write |
                    SftpFileOpenMode.create |
                    SftpFileOpenMode.truncate,
              );
              await f.writeBytes(
                  Uint8List.fromList(utf8.encode(content)),
                  offset: 0);
              await f.close();
            },
          ),
        ),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _rename(SftpName item, String path) async {
    final c = TextEditingController(text: item.filename);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Renombrar'),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Aceptar')),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == item.filename) return;
    try {
      final sftp = await _service.sftp();
      await sftp.rename(path, _join(_cwd, newName));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _delete(SftpName item, String path) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar'),
        content: Text('¿Eliminar "${item.filename}"?'),
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
    if (ok != true) return;
    try {
      final sftp = await _service.sftp();
      if (item.attr.isDirectory) {
        await sftp.rmdir(path);
      } else {
        await sftp.remove(path);
      }
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _mkdir() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nueva carpeta'),
        content: TextField(
            controller: c,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'nombre')),
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
    try {
      final sftp = await _service.sftp();
      await sftp.mkdir(_join(_cwd, name));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _upload() async {
    final picked = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => const LocalFilesScreen(selectMode: true),
      ),
    );
    if (picked == null) return;
    try {
      setState(() => _busy = true);
      final data = await File(picked).readAsBytes();
      final name = picked.split('/').last;
      final sftp = await _service.sftp();
      final f = await sftp.open(
        _join(_cwd, name),
        mode: SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      await f.writeBytes(data, offset: 0);
      await f.close();
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Subido: $name')));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async => !_up(),
      child: Scaffold(
        appBar: AppBar(
          title: Text('SFTP · ${_cwd}'),
          actions: [
            IconButton(
                icon: const Icon(Icons.refresh), onPressed: _refresh),
            IconButton(icon: const Icon(Icons.upload), onPressed: _upload),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: _mkdir,
          mini: true,
          child: const Icon(Icons.create_new_folder),
        ),
        body: _error != null
            ? Center(child: Text('Error: $_error'))
            : _items == null
                ? const Center(child: CircularProgressIndicator())
                : Stack(
                    children: [
                      ListView.builder(
                        itemCount: _items!.length,
                        itemBuilder: (_, i) {
                          final it = _items![i];
                          final dir = it.attr.isDirectory;
                          return ListTile(
                            leading: Icon(
                              dir
                                  ? Icons.folder
                                  : Icons.insert_drive_file,
                              color: dir ? Colors.amber : null,
                            ),
                            title: Text(it.filename),
                            subtitle: dir
                                ? null
                                : Text('${it.attr.size} bytes'),
                            onTap: () => _enter(it),
                          );
                        },
                      ),
                      if (_busy)
                        const LinearProgressIndicator(minHeight: 2),
                    ],
                  ),
      ),
    );
  }
}
