// lib/src/ssh/tunnels_screen.dart
//
// v2.3.0: túneles SSH (port forwarding local, tipo `ssh -L`).
// Cada túnel = ServerSocket local en 127.0.0.1 + conexión SSH propia;
// cada conexión entrante se canaliza al destino remoto por direct-tcpip.

import 'dart:async';
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

class _Tunnel {
  final String id;
  final String name;
  final String sshHostName;
  final String remoteHost;
  final int remotePort;
  final int requestedPort;
  ServerSocket? server;
  SSHClient? client;
  SSHSocket? socket;
  StreamSubscription? _serverSub;
  final _conns = <StreamSubscription>[];
  DateTime startedAt = DateTime.now();
  String? error;

  _Tunnel({
    required this.id,
    required this.name,
    required this.sshHostName,
    required this.remoteHost,
    required this.remotePort,
    required this.requestedPort,
  });

  int get localPort => server?.port ?? requestedPort;

  Future<void> stop() async {
    await _serverSub?.cancel();
    for (final c in _conns) {
      await c.cancel();
    }
    _conns.clear();
    await server?.close();
    try {
      client?.close();
    } catch (_) {}
    try {
      await socket?.close();
    } catch (_) {}
  }
}

class TunnelsScreen extends StatefulWidget {
  const TunnelsScreen({super.key});

  @override
  State<TunnelsScreen> createState() => _TunnelsScreenState();
}

class _TunnelsScreenState extends State<TunnelsScreen> {
  final _tunnels = <_Tunnel>[];
  List<SshHost> _hosts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadHosts();
  }

  @override
  void dispose() {
    // Los túneles siguen vivos en background mientras la app lo esté;
    // al salir de la pantalla NO se cierran (son de la sesión de app).
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
    setState(() => _loading = false);
  }

  Future<void> _addTunnel() async {
    if (_hosts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Primero configura un host')));
      return;
    }
    final host = await showDialog<SshHost>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: _C.card,
        title: const Text('Túnel a través de...',
            style: TextStyle(color: _C.textHi)),
        children: [
          for (final h in _hosts)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, h),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text('${h.name} (${h.username}@${h.hostname})',
                    style: const TextStyle(color: _C.textHi)),
              ),
            ),
        ],
      ),
    );
    if (host == null || !mounted) return;

    final name = TextEditingController();
    final localPort = TextEditingController(text: '0');
    final remoteHost = TextEditingController(text: '127.0.0.1');
    final remotePort = TextEditingController();
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('Nuevo túnel SSH',
            style: TextStyle(color: _C.textHi)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              style: const TextStyle(color: _C.textHi),
              decoration: const InputDecoration(
                  labelText: 'Nombre (opcional)',
                  labelStyle: TextStyle(color: _C.textLo)),
            ),
            TextField(
              controller: localPort,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: _C.textHi),
              decoration: const InputDecoration(
                  labelText: 'Puerto local (0 = automatico)',
                  labelStyle: TextStyle(color: _C.textLo)),
            ),
            TextField(
              controller: remoteHost,
              style: const TextStyle(color: _C.textHi),
              decoration: const InputDecoration(
                  labelText: 'Destino remoto',
                  labelStyle: TextStyle(color: _C.textLo)),
            ),
            TextField(
              controller: remotePort,
              keyboardType: TextInputType.number,
              autofocus: true,
              style: const TextStyle(color: _C.textHi),
              decoration: const InputDecoration(
                  labelText: 'Puerto remoto',
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
              child: const Text('Crear')),
        ],
      ),
    );
    if (r != true || !mounted) return;
    final lp = int.tryParse(localPort.text.trim()) ?? 0;
    final rp = int.tryParse(remotePort.text.trim());
    if (rp == null || rp < 1 || rp > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Puerto remoto invalido')));
      return;
    }
    await _startTunnel(
      host: host,
      name: name.text.trim().isEmpty
          ? '${remoteHost.text.trim()}:${rp}'
          : name.text.trim(),
      localPort: lp,
      remoteHost: remoteHost.text.trim(),
      remotePort: rp,
    );
  }

  Future<void> _startTunnel({
    required SshHost host,
    required String name,
    required int localPort,
    required String remoteHost,
    required int remotePort,
  }) async {
    final tunnel = _Tunnel(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      sshHostName: host.name,
      remoteHost: remoteHost,
      remotePort: remotePort,
      requestedPort: localPort,
    );
    setState(() {
      _tunnels.add(tunnel);
      tunnel.error = 'Conectando...';
    });
    try {
      final socket = await SSHSocket.connect(host.hostname, host.port)
          .timeout(const Duration(seconds: 12));
      tunnel.socket = socket;
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
        keepAliveInterval: const Duration(seconds: 15),
        handshakeTimeout: const Duration(seconds: 12),
        authTimeout: const Duration(seconds: 12),
      );
      tunnel.client = client;

      final server = await ServerSocket.bind('127.0.0.1', localPort);
      tunnel.server = server;
      tunnel.startedAt = DateTime.now();
      tunnel.error = null;

      tunnel._serverSub = server.listen((localSock) {
        _pipeConnection(tunnel, client, localSock, remoteHost, remotePort);
      });

      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Túnel activo: 127.0.0.1:${server.port} → $remoteHost:$remotePort via ${host.name}'),
        backgroundColor: _C.ok,
      ));
    } catch (e) {
      tunnel.error = e.toString();
      if (!mounted) return;
      setState(() {});
    }
  }

  void _pipeConnection(_Tunnel tunnel, SSHClient client, Socket localSock,
      String remoteHost, int remotePort) {
    SSHForwardChannel? channel;
    StreamSubscription? a;
    StreamSubscription? b;
    var closed = false;

    Future<void> cleanup() async {
      if (closed) return;
      closed = true;
      await a?.cancel();
      await b?.cancel();
      try {
        channel?.close();
      } catch (_) {}
      try {
        localSock.destroy();
      } catch (_) {}
      tunnel._conns.remove(a);
      tunnel._conns.remove(b);
    }

    client
        .forwardLocal(remoteHost, remotePort)
        .then((chan) {
      channel = chan;
      a = chan.stream.listen((data) {
        localSock.add(data);
      }, onDone: cleanup, onError: (_) => cleanup());
      b = localSock.listen((data) {
        chan.sink.add(data);
      }, onDone: () async {
        await chan.sink.close();
        await cleanup();
      }, onError: (_) => cleanup());
      tunnel._conns.add(a!);
      tunnel._conns.add(b!);
    }).catchError((_) => cleanup());
  }

  Future<void> _stopTunnel(_Tunnel t) async {
    await t.stop();
    setState(() => _tunnels.remove(t));
  }

  String _uptime(_Tunnel t) {
    final d = DateTime.now().difference(t.startedAt);
    if (d.inMinutes < 1) return '${d.inSeconds}s';
    if (d.inHours < 1) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inHours}h ${d.inMinutes % 60}m';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.bg,
      appBar: AppBar(
        backgroundColor: _C.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: _C.textHi),
        title: const Text('Túneles SSH',
            style: TextStyle(color: _C.textHi, fontSize: 16)),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: _C.accent,
        onPressed: _addTunnel,
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: _C.accent))
          : _tunnels.isEmpty && _defs.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Sin túneles.\n\nUn túnel reenvía un puerto local '
                      '(127.0.0.1:PUERTO) a través del servidor SSH hacia '
                      'cualquier destino que el servidor alcance — como '
                      '"ssh -L".\n\nPulsa + para crear uno.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _C.textLo),
                    ),
                  ),
                )
              : _tunnels.isEmpty
                  ? _buildDefs()
                  : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _tunnels.length,
                  itemBuilder: (_, i) {
                    final t = _tunnels[i];
                    final active = t.error == null;
                    return Card(
                      color: _C.card,
                      child: ListTile(
                        leading: Icon(
                            active
                                ? Icons.vpn_lock
                                : Icons.error_outline,
                            color: active ? _C.ok : _C.err),
                        title: Text(t.name,
                            style:
                                const TextStyle(color: _C.textHi)),
                        subtitle: Text(
                          active
                              ? '127.0.0.1:${t.localPort} → '
                                  '${t.remoteHost}:${t.remotePort} '
                                  'via ${t.sshHostName} · ${_uptime(t)}'
                              : 'Error: ${t.error}',
                          style: TextStyle(
                              color: active ? _C.textLo : _C.err,
                              fontSize: 11,
                              fontFamily: 'monospace'),
                        ),
                        trailing: active
                            ? IconButton(
                                icon: const Icon(Icons.stop,
                                    color: _C.err),
                                tooltip: 'Detener túnel',
                                onPressed: () => _stopTunnel(t),
                              )
                            : IconButton(
                                icon: const Icon(Icons.close,
                                    color: _C.textLo),
                                onPressed: () => setState(
                                    () => _tunnels.remove(t)),
                              ),
                      ),
                    );
                  },
                ),
    );
  }
}
