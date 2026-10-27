import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';
import 'package:dartssh2/dartssh2.dart';
import '../ssh/ssh_host.dart';
import '../ssh/identity_service.dart';
import 'command_history.dart';
import '../ssh/ssh_credentials_store.dart';
import '../ssh/ssh_hosts_service.dart';
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

  // ---- v2.5.0: historial y sugerencia fantasma (fish-style) ----

  String currentLine = '';
  String? suggestion;

  /// Interruptor global (persistido en la vista) de la barra de
  /// sugerencias fish-style. Por defecto DESACTIVADO: varios usuarios la
  /// encuentran molesta al escribir.
  static bool suggestionsEnabled = false;
  final suggestionNotify = ValueNotifier<String?>(null);

  void _updateSuggestion() {
    final v = (suggestion == null || suggestion!.isEmpty) ? null : suggestion;
    if (suggestionNotify.value != v) suggestionNotify.value = v;
  }

  void _trackInput(String data) {
    if (data.startsWith('\x1b')) return; // secuencias de escape
    if (data == '\r' || data == '\n') {
      final cmd = currentLine.trim();
      if (cmd.length > 1 && !cmd.startsWith(' ')) {
        unawaited(CommandHistory.add(sourceHost.id, cmd));
      }
      currentLine = '';
      suggestion = null;
      _updateSuggestion();
      return;
    }
    if (data == '\x7f') {
      if (currentLine.isNotEmpty) {
        currentLine = currentLine.substring(0, currentLine.length - 1);
      }
    } else if (data == '\x03') {
      currentLine = '';
    } else if (data.length == 1) {
      final c = data.codeUnitAt(0);
      if (c >= 32 && c != 127) currentLine += data;
    } else {
      // pegado: quedarse con la ultima linea
      final txt = data.replaceAll('\r', '');
      final idx = txt.lastIndexOf('\n');
      currentLine += idx >= 0 ? txt.substring(idx + 1) : txt;
      if (currentLine.length > 4096) {
        currentLine = currentLine.substring(currentLine.length - 4096);
      }
    }
    if (suggestionsEnabled) {
      final s = CommandHistory.suggest(sourceHost.id, currentLine);
      suggestion = (s != null && s != currentLine) ? s : null;
    } else {
      suggestion = null;
    }
    _updateSuggestion();
  }

  /// Acepta la sugerencia: envia el resto al shell como si lo teclearas.
  void acceptSuggestion() {
    final s = suggestion;
    if (s == null || s.length <= currentLine.length) return;
    final rest = s.substring(currentLine.length);
    currentLine = s;
    suggestion = null;
    _updateSuggestion();
    _handleOutput(rest);
  }

  void _handleOutput(String data) {
    if (data == '\t' && suggestion != null) {
      acceptSuggestion();
      return;
    }
    _trackInput(data);
    final shell = _shell;
    if (shell != null) {
      shell.write(utf8.encode(data));
      return;
    }
    _pendingOutput.add(data);
  }


  // ── Transporte SSH: dartssh2 ────────────────────────────────────────

  /// Abre un canal direct-tcpip hacia [host] a traves de su host salto.
  /// El cliente del salto se cierra solo cuando el canal muere.
  Future<SSHSocket> _openJumpChannel(SshHost host) async {
    final jumpId = host.jumpHostId!;
    SshHost? jump;
    for (final h in SshHostsService.instance.hosts) {
      if (h.id == jumpId) {
        jump = h;
        break;
      }
    }
    if (jump == null) throw StateError('Host salto no encontrado');

    final jumpSocket = await SSHSocket.connect(jump.hostname, jump.port)
        .timeout(const Duration(seconds: 12));
    List<SSHKeyPair>? jumpIdentities;
    final jk = jump.keyPath;
    if (jk != null && jk.trim().isNotEmpty) {
      final jf = await AppPaths.resolveKey(jk.trim());
      if (jf != null) {
        jumpIdentities = SSHKeyPair.fromPem(await jf.readAsString());
      }
    }
    String? jumpPwd;
    if (jumpIdentities == null) {
      jumpIdentities = await IdentityService.loadIdentity();
      jumpPwd = await SshCredentialsStore.readPassword(jump.id);
    }
    final jumpClient = SSHClient(
      jumpSocket,
      username: jump.username,
      identities: jumpIdentities,
      onPasswordRequest: () async => jumpPwd,
      onVerifyHostKey: (t, f) async => true,
      keepAliveInterval: const Duration(seconds: 15),
      handshakeTimeout: const Duration(seconds: 15),
      authTimeout: const Duration(seconds: 15),
    );
    final channel =
        await jumpClient.forwardLocal(host.hostname, host.port);
    unawaited(channel.done.whenComplete(() {
      try {
        jumpClient.close();
      } catch (_) {}
    }));
    return channel;
  }

  /// v2.10.1: 'hostname:puerto' cuando se rechaza la conexion porque la
  /// huella del host cambio frente a la guardada en known_hosts.
  String? _hostKeyRejectInfo;

  Future<void> _startSsh(int columns, int rows) async {
    final host = sourceHost;
    unawaited(CommandHistory.load(host.id));
    terminal.write('\x1b[90mConectando a ${host.username}@${host.hostname}:${host.port}...\x1b[0m\r\n');
    _hostKeyRejectInfo = null;
    try {
      // v2.7.0: ProxyJump — el transporte puede ser un canal direct-tcpip
      // a traves del host salto (SSHForwardChannel implementa SSHSocket).
      late SSHSocket socket;
      if (host.jumpHostId != null && host.jumpHostId!.isNotEmpty) {
        terminal.write('\x1b[90m[proxyjump]\x1b[0m\r\n');
        socket = await _openJumpChannel(host);
      } else {
        socket = await SSHSocket.connect(host.hostname, host.port)
            .timeout(const Duration(seconds: 12));
      }

      // v2.16.1: la clave del host y la identidad NO son excluyentes.
      // Antes: si el host tenia keyPath (aunque fuera un fichero viejo no
      // autorizado en el servidor), la identidad de la app ni se intentaba
      // y el password tampoco -> SSHAuthFailError en bucle (visto en z1:
      // keyPath=id_ed25519.bin caducado). Ahora: keyPath primero, identidad
      // SIEMPRE como fallback, y password siempre ofrecido.
      List<SSHKeyPair>? identities;
      final keyPath = host.keyPath;
      if (keyPath != null && keyPath.trim().isNotEmpty) {
        try {
          final keyFile = await AppPaths.resolveKey(keyPath.trim());
          if (keyFile != null) {
            identities = SSHKeyPair.fromPem(await keyFile.readAsString());
          } else {
            terminal.write('\x1b[33m[aviso: no se encuentra la clave $keyPath; se usa la identidad de la app]\x1b[0m\r\n');
          }
        } catch (_) {
          terminal.write('\x1b[33m[aviso: la clave $keyPath no es valida; se usa la identidad de la app]\x1b[0m\r\n');
        }
      }

      try {
        final id = await IdentityService.loadIdentity();
        if (id != null && id.isNotEmpty) {
          identities = [...(identities ?? const <SSHKeyPair>[]), ...id];
        }
      } catch (_) {}

      final knownHosts = await TerminalSession.loadKnownHosts();
      final hostKey = '${host.hostname}:${host.port}';

      _ssh = SSHClient(
        socket,
        username: host.username,
        identities: identities,
        // v2.16.1: el password guardado se ofrece SIEMPRE como fallback
        // (antes solo si no habia identidad, lo que dejaba sin metodos a
        // hosts con identidad no autorizada en el servidor).
        onPasswordRequest: () async {
          final saved = password;
          if (saved != null && saved.isNotEmpty) return saved;
          return null;
        },
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
            await TerminalSession.saveKnownHosts(knownHosts);
            return true;
          }
          // v2.10.1: huella cambiada -> rechazo explicito; el catch de
          // _startSsh lo distingue del error generico y explica que hacer.
          _hostKeyRejectInfo = hostKey;
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
      if (_hostKeyRejectInfo != null) {
        terminal.write('\r\n\x1b[31m[conexión rechazada: la huella SSH de $_hostKeyRejectInfo cambió]\x1b[0m\r\n');
        terminal.write('\x1b[90mSi el servidor fue reinstalado, borra la entrada antigua en Hosts → ⋮ → Hosts conocidos y reconecta.\x1b[0m\r\n');
        terminal.write('\x1b[90mSi NO esperabas este cambio, no continues: podria ser un ataque (MITM).\x1b[0m\r\n');
        return;
      }
      final msg = e.toString().replaceAll('\n', ' ');
      terminal.write('\r\n\x1b[31m[conexión fallida: $msg]\x1b[0m\r\n');
      // v2.16.1: la auth fallida tiene SIEMPRE las mismas 3 causas; se
      // listan para que el usuario no tenga que adivinar (visto en z1:
      // keyPath caducado + identidad no autorizada + password ausente).
      terminal.write(
          '\x1b[90mCausas típicas: (1) la clave del host no está autorizada en el servidor, (2) la identidad de la app no está en authorized_keys del servidor (copia la pública en \x1b[0m\x1b[33mHosts → ⋮ → Identidad SSH\x1b[0m\x1b[90m), (3) falta la contraseña (guárdala en Hosts → editar).\x1b[0m\r\n');
    }
  }

  // v2.11.0: publico y estatico; tambien lo usa la auditoria de
  // hosts_screen (politica accept-new compartida terminal/SFTP/auditoria).
  static Future<Map<String, String>> loadKnownHosts() async {
    try {
      final f = File('${AppPaths.base}/ssh_known_hosts.json');
      if (!await f.exists()) return {};
      final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }

  static Future<void> saveKnownHosts(Map<String, String> hosts) async {
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
    suggestionNotify.dispose();
    _killTransport();
    unawaited(recorder.dispose());
    scrollController.dispose();
    controller.dispose();
  }
}
