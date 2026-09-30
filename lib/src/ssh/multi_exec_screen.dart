// lib/src/ssh/multi_exec_screen.dart
//
// Multitarea v2.1.0: ejecutar un comando shell en varios hosts a la vez
// y ver todos los resultados concurrentemente.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

import '../storage/app_paths.dart';
import 'ssh_hosts_service.dart';
import 'ssh_credentials_store.dart';
import 'identity_service.dart';
import 'ssh_host.dart';

class _C {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const accent = Color(0xFF5E9BD6);
  static const err = Color(0xFFFF453A);
  static const ok = Color(0xFF34C759);
}

class _ExecResult {
  final bool ok;
  final String output;
  final Duration duration;
  _ExecResult.ok(this.output, this.duration) : ok = true;
  _ExecResult.fail(this.output, this.duration) : ok = false;
}

class MultiExecScreen extends StatefulWidget {
  const MultiExecScreen({super.key});

  @override
  State<MultiExecScreen> createState() => _MultiExecScreenState();
}

class _MultiExecScreenState extends State<MultiExecScreen> {
  List<SshHost> _hosts = [];
  final _selected = <String>{};
  final _cmdCtrl = TextEditingController();
  final _results = <String, _ExecResult>{};
  final _running = <String>{};
  bool _loadingHosts = true;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _loadHosts();
  }

  @override
  void dispose() {
    _cmdCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadHosts() async {
    try {
      await SshHostsService.instance.loadFrom(AppPaths.base);
      _hosts = List.of(SshHostsService.instance.hosts);
    } catch (_) {
      _hosts = [];
    }
    if (!mounted) return;
    setState(() => _loadingHosts = false);
  }

  Future<_ExecResult> _runOn(SshHost host, String cmd) async {
    final sw = Stopwatch()..start();
    SSHSocket? socket;
    try {
if (host.jumpHostId != null && host.jumpHostId!.isNotEmpty) throw StateError('\${host.name} usa ProxyJump: usalo desde la terminal');
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
        onUserInfoRequest: (req) async =>
            req.prompts.map((p) => p.promptText.toLowerCase().contains('password') && pwd != null ? pwd : '').toList(),
        onVerifyHostKey: (type, fingerprint) async => true,
        keepAliveInterval: const Duration(seconds: 15),
        handshakeTimeout: const Duration(seconds: 12),
        authTimeout: const Duration(seconds: 12),
      );
      final bytes = await client
          .run(cmd)
          .timeout(const Duration(seconds: 120));
      final out = utf8.decode(bytes, allowMalformed: true).trim();
      client.close();
      unawaited(socket.close());
      return _ExecResult.ok(out.isEmpty ? '(sin salida)' : out, sw.elapsed);
    } catch (e) {
      try {
        socket?.close();
      } catch (_) {}
      return _ExecResult.fail(e.toString(), sw.elapsed);
    }
  }

  Future<void> _run() async {
    final cmd = _cmdCtrl.text.trim();
    if (cmd.isEmpty || _selected.isEmpty) return;
    setState(() {
      _started = true;
      _results.clear();
      _running.addAll(_selected);
    });
    final tasks = <Future>[];
    for (final h in _hosts) {
      if (!_selected.contains(h.id)) continue;
      tasks.add(_runOn(h, cmd).then((r) {
        if (!mounted) return;
        setState(() {
          _running.remove(h.id);
          _results[h.id] = r;
        });
      }));
    }
    await Future.wait(tasks);
  }

  @override
  Widget build(BuildContext context) {
    final done = _results.length;
    final total = _selected.length;
    return Scaffold(
      backgroundColor: _C.bg,
      appBar: AppBar(
        backgroundColor: _C.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: _C.textHi),
        title: const Text('Ejecutar en varios hosts',
            style: TextStyle(color: _C.textHi, fontSize: 16)),
      ),
      body: Column(
        children: [
          if (_loadingHosts)
            const Expanded(
                child: Center(
                    child: CircularProgressIndicator(color: _C.accent)))
          else if (_hosts.isEmpty)
            const Expanded(
              child: Center(
                child: Text('No hay hosts configurados',
                    style: TextStyle(color: _C.textLo)),
              ),
            )
          else
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(8),
                children: [
                  for (final h in _hosts)
                    CheckboxListTile(
                      dense: true,
                      value: _selected.contains(h.id),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          _selected.add(h.id);
                        } else {
                          _selected.remove(h.id);
                        }
                      }),
                      title: Text(h.name,
                          style: const TextStyle(color: _C.textHi)),
                      subtitle: Text(
                          '${h.username}@${h.hostname}${h.port != 22 ? ':${h.port}' : ''}',
                          style: const TextStyle(
                              color: _C.textLo, fontSize: 12)),
                      activeColor: _C.accent,
                    ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _cmdCtrl,
                    style: const TextStyle(
                        color: _C.textHi,
                        fontFamily: 'monospace',
                        fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Comando a ejecutar en los $_selectedCount hosts...',
                      hintStyle:
                          const TextStyle(color: _C.textLo, fontSize: 13),
                      filled: true,
                      fillColor: _C.card,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.play_arrow,
                            color: _C.accent),
                        tooltip: 'Ejecutar',
                        onPressed:
                            _selected.isEmpty ? null : _run,
                      ),
                    ),
                    onSubmitted: (_) => _run(),
                  ),
                  if (_started) ...[
                    const SizedBox(height: 12),
                    if (_running.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: _C.accent)),
                            const SizedBox(width: 8),
                            Text('Ejecutando... $done/$total',
                                style: const TextStyle(
                                    color: _C.textLo, fontSize: 12)),
                          ],
                        ),
                      ),
                    for (final h in _hosts)
                      if (_results.containsKey(h.id))
                        _resultCard(h, _results[h.id]!),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  int get _selectedCount => _selected.length;

  Widget _resultCard(SshHost h, _ExecResult r) {
    return Card(
      color: _C.card,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                    r.ok
                        ? Icons.check_circle
                        : Icons.error,
                    size: 16,
                    color: r.ok ? _C.ok : _C.err),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(h.name,
                      style: const TextStyle(
                          color: _C.textHi,
                          fontWeight: FontWeight.w500)),
                ),
                Text(
                    '${r.duration.inMilliseconds} ms',
                    style: const TextStyle(
                        color: _C.textLo, fontSize: 10)),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              r.output,
              style: TextStyle(
                color: r.ok ? _C.textHi : _C.err,
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
