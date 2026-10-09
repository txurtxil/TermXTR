// lib/src/ssh/snippets_screen.dart
//
// Snippets v2.2.0: comandos reutilizables guardados. Cada snippet se
// ejecuta en el host elegido con un toque (resultado en un dialogo).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

import '../storage/app_paths.dart';
import 'identity_service.dart';
import 'ssh_credentials_store.dart';
import 'ssh_host.dart';
import 'ssh_hosts_service.dart';

class _C {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const accent = Color(0xFF5E9BD6);
  static const err = Color(0xFFFF453A);
  static const ok = Color(0xFF34C759);
}

class Snippet {
  final String id;
  final String name;
  final String command;
  const Snippet(
      {required this.id, required this.name, required this.command});

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'command': command};

  static Snippet? fromJson(dynamic j) {
    if (j is! Map) return null;
    return Snippet(
      id: (j['id'] ?? '').toString(),
      name: (j['name'] ?? '').toString(),
      command: (j['command'] ?? '').toString(),
    );
  }
}

class SnippetsScreen extends StatefulWidget {
  const SnippetsScreen({super.key});

  @override
  State<SnippetsScreen> createState() => _SnippetsScreenState();
}

class _SnippetsScreenState extends State<SnippetsScreen> {
  List<Snippet> _snippets = [];
  bool _loading = true;
  List<SshHost> _hosts = [];

  File get _file => File('${AppPaths.base}/snippets.json');

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    try {
      await SshHostsService.instance.loadFrom(AppPaths.base);
      _hosts = List.of(SshHostsService.instance.hosts);
    } catch (_) {
      _hosts = [];
    }
    try {
      if (await _file.exists()) {
        final list = jsonDecode(await _file.readAsString()) as List;
        _snippets =
            list.map(Snippet.fromJson).whereType<Snippet>().toList();
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
        jsonEncode(_snippets.map((s) => s.toJson()).toList()),
        flush: true);
    await tmp.rename(_file.path);
  }

  Future<void> _edit([Snippet? existing]) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final cmd = TextEditingController(text: existing?.command ?? '');
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: Text(existing == null ? 'Nuevo snippet' : 'Editar snippet',
            style: const TextStyle(color: _C.textHi)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              style: const TextStyle(color: _C.textHi),
              decoration: const InputDecoration(
                  labelText: 'Nombre',
                  labelStyle: TextStyle(color: _C.textLo)),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: cmd,
              maxLines: 3,
              style: const TextStyle(
                  color: _C.textHi, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                  labelText: 'Comando',
                  labelStyle: TextStyle(color: _C.textLo)),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Guardar')),
        ],
      ),
    );
    if (r != true || name.text.trim().isEmpty) return;
    setState(() {
      if (existing == null) {
        _snippets.add(Snippet(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: name.text.trim(),
          command: cmd.text.trim(),
        ));
      } else {
        final i = _snippets.indexWhere((s) => s.id == existing.id);
        if (i >= 0) {
          _snippets[i] = Snippet(
              id: existing.id,
              name: name.text.trim(),
              command: cmd.text.trim());
        }
      }
    });
    await _save();
  }

  Future<void> _delete(Snippet s) async {
    setState(() => _snippets.removeWhere((e) => e.id == s.id));
    await _save();
  }

  Future<String> _runOn(SshHost host, String command) async {
    SSHSocket? socket;
    try {
if (host.jumpHostId != null && host.jumpHostId!.isNotEmpty) throw StateError('${host.name} usa ProxyJump: usalo desde la terminal');
            socket = await SSHSocket.connect(host.hostname, host.port)
          .timeout(const Duration(seconds: 12));
      List<SSHKeyPair>? identities;
      final keyPath = host.keyPath;
      if (keyPath != null && keyPath.trim().isNotEmpty) {
        final keyFile = await AppPaths.resolveKey(keyPath.trim());
        if (keyFile != null) {
          identities = SSHKeyPair.fromPem(await keyFile.readAsString());
        }
      }
      String? pwd;
      if (identities == null) {
        identities = await IdentityService.loadIdentity();
        pwd = await SshCredentialsStore.readPassword(host.id);
      }
      final client = SSHClient(
        socket,
        username: host.username,
        identities: identities,
        onPasswordRequest: () async => pwd,
        onUserInfoRequest: (req) async => req.prompts
            .map((p) => p.promptText.toLowerCase().contains('password') &&
                    pwd != null
                ? pwd
                : '')
            .toList(),
        onVerifyHostKey: (type, fingerprint) async => true,
        handshakeTimeout: const Duration(seconds: 12),
        authTimeout: const Duration(seconds: 12),
      );
      final bytes = await client
          .run(command)
          .timeout(const Duration(seconds: 60));
      final out = utf8.decode(bytes, allowMalformed: true).trim();
      client.close();
      unawaited(socket.close());
      return out.isEmpty ? '(sin salida)' : out;
    } catch (e) {
      try {
        socket?.close();
      } catch (_) {}
      return 'ERROR: $e';
    }
  }

  Future<void> _run(Snippet s) async {
    if (_hosts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No hay hosts configurados')));
      return;
    }
    final host = await showDialog<SshHost>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: _C.card,
        title: const Text('Ejecutar en...',
            style: TextStyle(color: _C.textHi)),
        children: [
          for (final h in _hosts)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, h),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(h.name,
                        style:
                            const TextStyle(color: _C.textHi)),
                    Text(
                        '${h.username}@${h.hostname}${h.port != 22 ? ':${h.port}' : ''}',
                        style: const TextStyle(
                            color: _C.textLo, fontSize: 11)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (host == null) return;
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        backgroundColor: _C.card,
        content: Row(
          children: [
            SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: _C.accent)),
            SizedBox(width: 16),
            Text('Ejecutando...',
                style: TextStyle(color: _C.textHi)),
          ],
        ),
      ),
    );
    final out = await _runOn(host, s.command);
    if (!mounted) return;
    Navigator.pop(context); // cierra progress
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: Text('${s.name} · ${host.name}',
            style: const TextStyle(
                color: _C.textHi, fontSize: 14)),
        content: SingleChildScrollView(
          child: SelectableText(
            out,
            style: TextStyle(
              color: out.startsWith('ERROR')
                  ? _C.err
                  : _C.textHi,
              fontFamily: 'monospace',
              fontSize: 12,
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.bg,
      appBar: AppBar(
        backgroundColor: _C.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: _C.textHi),
        title: const Text('Snippets',
            style: TextStyle(color: _C.textHi, fontSize: 16)),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: _C.accent,
        onPressed: () => _edit(),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: _C.accent))
          : _snippets.isEmpty
              ? const Center(
                  child: Text(
                    'Sin snippets.\nPulsa + para guardar un comando.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _C.textLo),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _snippets.length,
                  itemBuilder: (_, i) {
                    final s = _snippets[i];
                    return Card(
                      color: _C.card,
                      child: ListTile(
                        title: Text(s.name,
                            style:
                                const TextStyle(color: _C.textHi)),
                        subtitle: Text(
                          s.command,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: _C.textLo,
                              fontFamily: 'monospace',
                              fontSize: 11),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.play_arrow,
                                  color: _C.accent),
                              tooltip: 'Ejecutar',
                              onPressed: () => _run(s),
                            ),
                            PopupMenuButton<String>(
                              iconColor: _C.textLo,
                              onSelected: (v) {
                                if (v == 'edit') _edit(s);
                                if (v == 'delete') _delete(s);
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                    value: 'edit',
                                    child: Text('Editar')),
                                PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Eliminar')),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
