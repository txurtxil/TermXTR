import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

import '../../models/host_profile.dart';

/// Estado de una conexion SSH.
enum SshState { disconnected, connecting, connected, failed }

/// Envuelve dartssh2 (2.22.5): conectar, abrir shell interactiva y SFTP.
class SshService {
  final HostProfile host;
  SSHClient? _client;
  SSHSocket? _socket;
  SftpClient? _sftp;
  SshState state = SshState.disconnected;
  String? error;

  final _stateCtrl = StreamController<SshState>.broadcast();
  Stream<SshState> get onStateChange => _stateCtrl.stream;

  SshService(this.host);

  bool get isConnected => state == SshState.connected;

  Future<void> connect() async {
    if (state == SshState.connected || state == SshState.connecting) return;
    _setState(SshState.connecting);
    try {
      _socket = await SSHSocket.connect(host.hostname, host.port,
          timeout: const Duration(seconds: 15));
      List<SSHKeyPair>? identities;
      if (host.useKey && host.secret.trim().isNotEmpty) {
        identities = SSHKeyPair.fromPem(host.secret.trim());
      }
      _client = SSHClient(
        _socket!,
        username: host.username,
        identities: identities,
        onPasswordRequest: () => host.secret,
        onVerifyHostKey: (type, fingerprint) => true, // home lab: aceptar host key
      );
      _setState(SshState.connected);
    } catch (e) {
      error = e.toString();
      _setState(SshState.failed);
      await _cleanup();
    }
  }

  /// Abre una shell interactiva con pty xterm del tamano dado.
  Future<SSHSession> openShell(int columns, int rows) async {
    final client = _client;
    if (client == null) throw StateError('No conectado');
    return client.shell(
      pty: SSHPtyConfig(type: 'xterm', width: columns, height: rows),
    );
  }

  /// Cliente SFTP (lo abre bajo demanda y lo cachea).
  Future<SftpClient> sftp() async {
    if (_sftp != null) return _sftp!;
    final client = _client;
    if (client == null) throw StateError('No conectado');
    _sftp = await client.sftp();
    return _sftp!;
  }

  void _setState(SshState s) {
    state = s;
    if (!_stateCtrl.isClosed) _stateCtrl.add(s);
  }

  Future<void> _cleanup() async {
    try {
      _client?.close();
    } catch (_) {}
    try {
      await _socket?.close();
    } catch (_) {}
    _client = null;
    _socket = null;
    _sftp = null;
  }

  Future<void> disconnect() async {
    await _cleanup();
    _setState(SshState.disconnected);
  }

  Future<void> dispose() async {
    await disconnect();
    await _stateCtrl.close();
  }
}
