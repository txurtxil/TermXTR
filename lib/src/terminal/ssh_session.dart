import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:xterm/xterm.dart';

import '../../models/host_profile.dart';
import '../ssh/ssh_service.dart';
import 'terminal_session.dart';

/// Sesion de terminal remota sobre SSH (dartssh2).
/// Misma API publica que TerminalSession para integrarse en TerminalScreen.
class SshSession implements AppSession {
  final HostProfile host;
  final SshService service;

  @override
  final String name;

  @override
  final Terminal terminal = Terminal(maxLines: 10000);

  @override
  final TerminalController controller = TerminalController();

  SSHSession? _channel;
  StreamSubscription? _outSub;
  bool _started = false;
  bool _disposed = false;

  SshSession(this.host)
      : name = host.name.isEmpty ? host.subtitle : host.name,
        service = SshService(host) {
    terminal.onOutput = (data) {
      _channel?.write(utf8.encode(data));
    };
    terminal.onResize = (w, h, pw, ph) {
      _channel?.resizeTerminal(w, h);
    };
  }

  @override
  bool get isStarted => _started;

  @override
  Future<void> start({int columns = 80, int rows = 24}) async {
    if (_started) return;
    _started = true;
    unawaited(_run(columns, rows));
  }

  Future<void> _run(int columns, int rows) async {
    terminal.write('Conectando a ${host.subtitle}...\r\n');
    await service.connect();
    if (_disposed) return;
    if (!service.isConnected) {
      terminal.write('Conexion fallida: ${service.error ?? 'error'}\r\n');
      return;
    }
    try {
      _channel = await service.openShell(columns, rows);
      terminal.eraseDisplay();
      terminal.eraseScrollbackOnly();
      _outSub = _channel!.stdout.listen((data) {
        terminal.write(utf8.decode(data, allowMalformed: true));
      });
      unawaited(_channel!.done.then((_) {
        if (!_disposed) terminal.write('\r\n[desconectado]\r\n');
      }));
    } catch (e) {
      terminal.write('Error de shell: $e\r\n');
    }
  }

  @override
  Future<void> restart({int columns = 80, int rows = 24}) async {
    await _outSub?.cancel();
    try {
      _channel?.close();
    } catch (_) {}
    _channel = null;
    _started = false;
    terminal.eraseDisplay();
    terminal.eraseScrollbackOnly();
    await service.disconnect();
    await start(columns: columns, rows: rows);
  }

  @override
  void dispose() {
    _disposed = true;
    _outSub?.cancel();
    try {
      _channel?.close();
    } catch (_) {}
    unawaited(service.dispose());
  }
}
