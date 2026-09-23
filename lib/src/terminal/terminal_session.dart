import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

/// Sesion de terminal local (shell del sistema) sobre un pseudo-terminal.
class TerminalSession {
  final String name;
  final Terminal terminal = Terminal(maxLines: 10000);
  final TerminalController controller = TerminalController();

  Pty? _pty;
  StreamSubscription<String>? _outSub;
  bool _started = false;

  TerminalSession(this.name) {
    terminal.onOutput = (data) {
      _pty?.write(utf8.encode(data));
    };
    terminal.onResize = (w, h, pw, ph) {
      _pty?.resize(h, w);
    };
  }

  bool get isStarted => _started;

  Future<void> start({int columns = 80, int rows = 24}) async {
    if (_started) return;
    _started = true;

    final shell = Platform.isAndroid
        ? '/system/bin/sh'
        : (Platform.environment['SHELL'] ?? '/bin/sh');

    _pty = Pty.start(
      shell,
      columns: columns,
      rows: rows,
      environment: {'HOME': Platform.environment['HOME'] ?? '/'},
    );

    _outSub = _pty!.output.cast<List<int>>().transform(utf8.decoder).listen(
          terminal.write,
          onError: (_) {},
        );
  }

  Future<void> restart({int columns = 80, int rows = 24}) async {
    await _outSub?.cancel();
    _pty?.kill();
    _pty = null;
    _started = false;
    terminal.eraseDisplay();
    terminal.eraseScrollbackOnly();
    terminal.buffer.clear();
    await start(columns: columns, rows: rows);
  }

  void dispose() {
    _outSub?.cancel();
    _pty?.kill();
    _pty = null;
  }
}
