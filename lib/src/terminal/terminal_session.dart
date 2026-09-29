import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';
import 'package:dartssh2/dartssh2.dart';
import '../ssh/ssh_host.dart';
import '../ssh/identity_service.dart';
import '../storage/app_paths.dart';
import 'terminal_recorder.dart';

/// Una sesión de terminal independiente (una pestaña): su propio Terminal,
/// Controller y transporte. Desde v14.24 hay DOS transportes:
///
///  - LOCAL: PTY directo contra `/system/bin/sh` de Android (toybox). Sin
///    Debian ni proot: un shell básico (cd/ls/cat/...) que corre como uid
///    de la app. Se anuncia con un banner al abrirse.
///  - SSH: cliente dartssh2 puro (mismo stack que el navegador SFTP): TCP
///    directo desde el proceso de la app, autenticación por clave (OpenSSH
///    PEM) o contraseña (Keystore via SshCredentialsStore, que el view
///    inyecta en [password]), known_hosts en JSON con política accept-new,
///    keepalive de transporte cada 15 s y resize real vía SSHPtyConfig.
///
/// La geometría celda<->píxel y la selección no cambian: siguen saliendo de
/// xterm (renderTerminal) como hasta ahora.
class TerminalSession {
  final String name;
  final Terminal terminal = Terminal(maxLines: 10000);
  final TerminalController controller = TerminalController();
  /// Vive en el objeto sesión (no en un mapa por índice): si se cierra una
  /// pestaña intermedia los índices se desplazan y el dato debe viajar con
  /// su sesión. El overlay de selección lo usa para el auto-scroll.
  final ScrollController scrollController = ScrollController();
  final TerminalRecorder recorder;

  /// Host remoto al que se conecta esta sesión (siempre SSH; el shell
  /// local fue eliminado en v2.0.0 por no aportar funcionalidad real).
  final SshHost sourceHost;

  /// Contraseña guardada (Keystore) para hosts sin clave. La inyecta el
  /// view antes de start(); si es null y el servidor pide contraseña, la
  /// autenticación falla con mensaje claro en pantalla.
  final String? password;

  SSHClient? _ssh;
  SSHSession? _shell;
  bool _started = false;
  bool _closed = false;

  /// Entrada del usuario que llega antes de que la shell SSH esté lista
  /// (la conexión es async): se encola y se vuelca al conectar.
  final List<String> _pendingOutput = <String>[];

  TerminalSession(this.name, {required this.sourceHost, this.password})
      : recorder = TerminalRecorder(label: name);

  bool get isStarted => _started;
  bool get isSsh => true;

  /// Arranca el transporte con el tamaño dado. Idempotente.
  void start({required int columns, required int rows}) {
    if (_started) return;
    _started = true;
    _closed = false;

    unawaited(recorder.startSession(AppPaths.base));

    terminal.onResize = (w, h, pw, ph) {
      _shell?.resizeTerminal(w, h);
    };
    // Único punto de entrada del teclado: el transporte puede no estar
    // listo todavía (la conexión SSH es async) — lo que se teclee durante
    // la conexión se encola y se vuelca al abrirse la shell.
    terminal.onOutput = _handleOutput;

    unawaited(_startSsh(columns, rows));
  }

  void _handleOutput(String data) {
    final shell = _shell;
    if (shell != null) {
      shell.write(utf8.encode(data));
      return;
    }
    _pendingOutput.add(data);
  }


  // ── Transporte SSH: dartssh2 ────────────────────────────────────────

  Future<void> _startSsh(int columns, int rows) async {
    final host = sourceHost;
    terminal.write('\x1b[90mConectando a ${host.username}@${host.hostname}:${host.port}...\x1b[0m\r\n');
    try {
      final socket = await SSHSocket.connect(host.hostname, host.port)
          .timeout(const Duration(seconds: 12));

      List<SSHKeyPair>? identities;
      final keyPath = host.keyPath;
      if (keyPath != null && keyPath.trim().isNotEmpty) {
        final keyFile = await AppPaths.resolveKey(keyPath.trim());
        if (keyFile != null) {
          identities = SSHKeyPair.fromPem(await keyFile.readAsString());
        } else {
          terminal.write('\x1b[33m[aviso: no se encuentra la clave $keyPath]\x1b[0m\r\n');
        }
      }

      if (identities == null) {
        identities = await IdentityService.loadIdentity();
      }

      final knownHosts = await _loadKnownHosts();
      final hostKey = '${host.hostname}:${host.port}';

      _ssh = SSHClient(
        socket,
        username: host.username,
        identities: identities,
        onPasswordRequest: identities == null
            ? () async {
                final saved = password;
                if (saved != null && saved.isNotEmpty) return saved;
                return null;
              }
            : null,
        onUserInfoRequest: (req) async {
          // Keyboard-interactive: responder con la contraseña guardada a
          // los prompts que la piden (case-insensitive). Otros prompts
          // (OTP, etc.) se quedan sin respuesta: falla con mensaje claro.
          final saved = password;
          return req.prompts.map((p) {
            final asksPassword = p.promptText.toLowerCase().contains('password');
            return (asksPassword && saved != null && saved.isNotEmpty) ? saved : '';
          }).toList();
        },
        keepAliveInterval: const Duration(seconds: 15),
        handshakeTimeout: const Duration(seconds: 15),
        authTimeout: const Duration(seconds: 15),
        onVerifyHostKey: (type, fingerprintBytes) async {
          final fingerprint = '$type:${base64.encode(fingerprintBytes)}';
          final saved = knownHosts[hostKey];
          if (saved == null || saved == fingerprint) {
            knownHosts[hostKey] = fingerprint;
            await _saveKnownHosts(knownHosts);
            return true;
          }
          // Huella cambiada: se rechaza (la sesión muere con mensaje).
          return false;
        },
      );

      await _ssh!.authenticated;

      _shell = await _ssh!.shell(
        pty: SSHPtyConfig(
          type: 'xterm-256color',
          width: columns > 0 ? columns : 80,
          height: rows > 0 ? rows : 24,
        ),
      );

      terminal.write('\x1b[2K\r'); // borra la línea de "Conectando..."
      _shell!.stdout.listen(
        (data) {
          final s = utf8.decode(data, allowMalformed: true);
          terminal.write(s);
          recorder.feed(s);
        },
        onError: (_) {},
        onDone: () {
          if (!_closed) {
            terminal.write('\r\n\x1b[90m[sesión finalizada]\x1b[0m\r\n');
          }
        },
      );

      // El dispatcher de onOutput puesto en start() ya encolaba lo tecleado
      // mientras conectaba; aquí solo hay que volcar la cola.
      for (final p in _pendingOutput) {
        _shell!.write(utf8.encode(p));
      }
      _pendingOutput.clear();

      final initial = host.initialPath?.trim();
      if (initial != null && initial.isNotEmpty) {
        _shell!.write(utf8.encode('cd "$initial" 2>/dev/null || cd\n'));
      }
    } catch (e) {
      final msg = e.toString().replaceAll('\n', ' ');
      terminal.write('\r\n\x1b[31m[conexión fallida: $msg]\x1b[0m\r\n');
      if (password == null || password!.isEmpty) {
        terminal.write(
            '\x1b[90mSi el servidor pide contraseña, guárdala en la ficha del host (Hosts → editar).\x1b[0m\r\n');
      }
    }
  }

  Future<Map<String, String>> _loadKnownHosts() async {
    try {
      final f = File('${AppPaths.base}/ssh_known_hosts.json');
      if (!await f.exists()) return {};
      final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveKnownHosts(Map<String, String> hosts) async {
    try {
      await File('${AppPaths.base}/ssh_known_hosts.json')
          .writeAsString(jsonEncode(hosts));
    } catch (_) {}
  }


  /// Reinicia el transporte de esta sesión.
  void restart({required int columns, required int rows}) {
    _killTransport();
    _started = false;
    _pendingOutput.clear();
    terminal.write('\r\n\x1b[1;33m[reiniciando sesión...]\x1b[0m\r\n');
    start(columns: columns, rows: rows);
  }

  void _killTransport() {
    _closed = true;
    try {
      _shell?.close();
    } catch (_) {}
    _shell = null;
    try {
      _ssh?.close();
    } catch (_) {}
    _ssh = null;
  }

  void dispose() {
    _killTransport();
    unawaited(recorder.dispose());
    scrollController.dispose();
    controller.dispose();
  }
}
