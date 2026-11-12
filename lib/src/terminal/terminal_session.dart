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
import '../monitor/monitor_service.dart';
import '../monitor/ghost_config.dart';
import '../monitor/monitor_log.dart';
import '../sftp/sftp_favorites_service.dart';
import '../storage/app_paths.dart';
import 'terminal_aliases.dart';
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

  // v2.17.0: cuando el shell remoto termina (exit) o la conexion cae, la
  // vista cierra la pestana (a lo navegador). Solo se dispara si el cierre
  // NO fue pedido por el usuario (dispose pone _closed = true).
  void Function()? onSessionEnded;
  bool _endedNotified = false;

  /// Entrada del usuario que llega antes de que la shell SSH esté lista
  /// (la conexión es async): se encola y se vuelca al conectar.
  final List<String> _pendingOutput = <String>[];

  TerminalSession(this.name, {required this.sourceHost, this.password})
      : recorder = TerminalRecorder(label: name);

  /// v2.18.2/6: poll ligero para la SOMBRA FANTASMA del monitor (exec
  /// concurrente sobre la conexion de la sesion; solo lectura). Devuelve
  /// TRES lineas: load 1m, uso de / en % y memoria en %. v2.18.6: mem con
  /// printf %d (el separador decimal es_ES rompia el parseo -> 0.0%).
  Future<String?> monitorGhostLine() async {
    final c = _ssh;
    if (c == null) return null;
    try {
      final r = await c
          .run("LC_ALL=C; cut -d' ' -f1 /proc/loadavg; df -hP / | tail -1 | awk '{print \$5}'; awk '/MemTotal/{t=\$2}/MemAvailable/{a=\$2}END{printf \"%d\",(t-a)/t*100}' /proc/meminfo")
          .timeout(const Duration(seconds: 8));
      final t = utf8.decode(r, allowMalformed: true).trim();
      return t.isEmpty ? null : t;
    } catch (_) {
      return null;
    }
  }


  /// v2.20.1: vista previa INSTANTANEA de carpetas favoritas desde la
  /// cache (sin ejecutar nada en el servidor) — la sombra pinta esto al
  /// conectar y el du real lo refresca despues.
  Future<String?> ghostDirsPreview() async {
    await dirCacheLoad();
    try {
      final hostId = sourceHost.id;
      final favs = SftpFavoritesService.instance
          .forHost(hostId)
          .map((f) => f.path.startsWith('/') ? f.path : '/\${f.path}')
          .toSet()
          .take(5);
      final lines = <String>[];
      for (final f in favs) {
        final b = dirCacheGet(hostId, f);
        if (b != null) {
          var name = f == '/' ? '/' : f.split('/').last;
          if (name.length > 14) name = name.substring(0, 14);
          lines.add('$name\t${_humGhost(b)}~${dirCacheAge(hostId, f)}');
        }
      }
      return lines.isEmpty ? null : lines.join('\n');
    } catch (_) {
      return null;
    }
  }

  /// v2.20.7: extras de la sombra (carpetas favoritas + unidades auditadas).
  /// Las UNIDADES se consultan SIEMPRE, independientemente de que haya
  /// favoritos (antes: un early return por 'sin favoritos' saltaba las
  /// unidades y docker jamas aparecia en hosts sin carpetas marcadas).
  Future<String?> monitorGhostDirs() async {
    final c = _ssh;
    if (c == null) return null;
    await dirCacheLoad();
    final lines = <String>[];
    String? cur;
    void flush(String? path, String? val) {
      if (path == null) return;
      var name = path == '/' ? '/' : path.split('/').last;
      if (name.length > 14) name = name.substring(0, 14);
      final b = val == null ? null : double.tryParse(val);
      if (b != null) {
        lines.add('$name\t${_humGhost(b)}');
        dirCachePut(sourceHost.id, path, b);
        return;
      }
      final cb = dirCacheGet(sourceHost.id, path);
      if (cb != null) {
        final age = dirCacheAge(sourceHost.id, path);
        lines.add('$name\t${_humGhost(cb)}~$age');
      }
    }
    final favs = SftpFavoritesService.instance
        .forHost(sourceHost.id)
        .map((f) => f.path.startsWith('/') ? f.path : '/${f.path}')
        .toSet()
        .take(5)
        .toList();
    if (favs.isNotEmpty) {
      final dirList = favs.map((e) => "'$e'").join(' ');
      String? raw;
      try {
        final r = await c
            .run('for d in $dirList; do ( out=\$(timeout 20 du -x -s -B1 "\$d" 2>/dev/null | awk \'{print \$1}\'); echo "__D__ \$d"; echo "\${out:-TO}" ) & done; wait')
            .timeout(const Duration(seconds: 25));
        raw = utf8.decode(r, allowMalformed: true).trim();
      } catch (_) {}
      if (raw != null && raw.isNotEmpty) {
        for (final l in raw.split('\n')) {
          final t = l.trim();
          if (t.startsWith('__D__ ')) {
            flush(cur, null);
            cur = t.substring(6).trim();
            continue;
          }
          if (cur != null) {
            flush(cur, t);
            cur = null;
          }
        }
      }
      flush(cur, null);
    }
    // unidades auditadas: SIEMPRE (no dependen de favoritos)
    try {
      final cfg = await GhostConfigStore.forHost(sourceHost.id);
      if (cfg.units.isNotEmpty) {
        final ul = cfg.units.map((e) => '"$e"').join(' ');
        final ur = await c
            .run('for u in $ul; do printf "u\t%s\t%s\n" "\$u" "\$(systemctl is-active \$u 2>/dev/null)"; done')
            .timeout(const Duration(seconds: 8));
        final ut = utf8.decode(ur, allowMalformed: true).trim();
        if (ut.isNotEmpty) lines.addAll(ut.split('\n'));
      }
    } catch (_) {}
    MonitorLog.write('ghost-dirs',
        'favs=' + favs.join(' ') + ' -> ' + lines.length.toString() + ' lineas');
    return lines.isEmpty ? null : lines.join('\n');
  }

  /// true si este host tiene carpetas favoritas (la sombra asi sabe si el
  /// reloj de arena tiene sentido o no).
  Future<bool> hasGhostFavorites() async {
    try {
      final n = SftpFavoritesService.instance
          .forHost(sourceHost.id)
          .length;
      return n > 0;
    } catch (_) {
      return false;
    }
  }

  static String _humGhost(double b) {
    if (b <= 0) return '0B';
    const u = ['B', 'K', 'M', 'G', 'T'];
    var i = 0;
    var v = b;
    while (v >= 1024 && i < u.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)}${u[i]}';
  }

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
    // v2.37.0 - atajos de shell: si la linea tecleada ES un atajo (p.ej. 'c'),
    // se borra lo tecleado en remoto (Ctrl-U) y se envia la expansion.
    if (data == '\r' || data == '\n') {
      final typed = currentLine.trim();
      final expanded = TerminalAliases.match(typed);
      if (expanded != null) {
        CommandHistory.add(sourceHost.id, expanded);
        currentLine = '';
        suggestion = null;
        _updateSuggestion();
        final sh = _shell;
        if (sh != null) sh.write(utf8.encode('\x15$expanded\r'));
        return;
      }
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
            // v2.17.0: cierre remoto -> cerrar la pestana. Pausa breve
            // para que el mensaje se lea.
            Future.delayed(const Duration(milliseconds: 1200), () {
              if (!_closed && !_endedNotified) {
                _endedNotified = true;
                onSessionEnded?.call();
              }
            });
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
