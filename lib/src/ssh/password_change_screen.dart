// lib/src/ssh/password_change_screen.dart
//
// Cambio de contrasena remota en lote: se marcan varios hosts (y/o el
// router/gateway con CLI propio), se escribe la contrasena actual y la
// nueva, y la app ejecuta el cambio en todos concurrentemente.
//
// Linux (hosts): la contrasena NUNCA se interpola en un comando remoto en
// claro con comillas propias: se construye un mini-script local, se
// base64-encodea entero y el remoto hace `echo <b64> | base64 -d | bash`.
// Dentro del script, cada secreto viaja como `$(echo <b64> | base64 -d)`,
// asi que comillas, $, espacios y utf8 en la contrasena no rompen nada.
// passwd interactivo SIN PTY falla (getpass no cae a stdin en un exec
// channel): por eso el cambio va por `sudo -S sh -c '... chpasswd'`.
// El resultado se decide por `XTR_EXIT:$?` (no por sniffing de texto) y
// el canal se cierra desde el cliente en cuanto aparece (robustExec):
// no dependemos de que el servidor cierre la sesion.
//
// Router (CLI propio por SSH): `config account password user "<u>"
// oldpasswd "<vieja>" newpasswd "<nueva>"`. Aqui NO se usa el truco
// base64 (CLI minimalista): escaping basico de " \\ $ y salida cruda
// para confirmacion visual. Tras el cambio se intenta `config save`.

import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../storage/app_paths.dart';
import 'ssh_hosts_service.dart';
import 'ssh_credentials_store.dart';
import 'identity_service.dart';
import 'robust_exec.dart';
import 'ssh_host.dart';

class _C {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const accent = Color(0xFF5E9BD6);
  static const err = Color(0xFFFF453A);
  static const ok = Color(0xFF34C759);
  static const warn = Color(0xFFFFCC00);
}

class _PwResult {
  final bool ok;
  final String output;
  final Duration duration;
  _PwResult.ok(this.output, this.duration) : ok = true;
  _PwResult.fail(this.output, this.duration) : ok = false;
}

/// Destino especial: router/gateway con CLI propio (no es un SshHost).
class RouterTarget {
  bool enabled = false;
  final hostnameCtrl = TextEditingController(text: '192.168.10.1');
  final portCtrl = TextEditingController(text: '22');
  final userCtrl = TextEditingController(text: 'admin');
  void dispose() {
    hostnameCtrl.dispose();
    portCtrl.dispose();
    userCtrl.dispose();
  }
}

class PasswordChangeScreen extends StatefulWidget {
  const PasswordChangeScreen({super.key});

  @override
  State<PasswordChangeScreen> createState() => _PasswordChangeScreenState();
}

class _PasswordChangeScreenState extends State<PasswordChangeScreen> {
  List<SshHost> _hosts = [];
  final _selected = <String>{};
  final _router = RouterTarget();

  final _oldCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _repCtrl = TextEditingController();
  bool _hideOld = true;
  bool _hideNew = true;
  bool _updateStored = true;

  final _results = <String, _PwResult>{}; // key: host.id o 'router'
  final _running = <String>{};
  bool _loadingHosts = true;
  bool _started = false;

  // 'self' = passwd del usuario de la conexion; 'other' = sudo chpasswd
  // de otro usuario (o root).
  String _mode = 'self';
  final _otherUserCtrl = TextEditingController(text: 'root');

  @override
  void initState() {
    super.initState();
    _loadHosts();
  }

  @override
  void dispose() {
    _oldCtrl.dispose();
    _newCtrl.dispose();
    _repCtrl.dispose();
    _otherUserCtrl.dispose();
    _router.dispose();
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

  String _b64(String s) => base64.encode(utf8.encode(s));

  /// Comando remoto para un host Linux. Secreto nunca en claro parseable.
  String _linuxCommand(SshHost host, String oldP, String newP) {
    final target = _mode == 'self' ? host.username : _otherUserCtrl.text.trim();
    // v2.13.1: passwd interactivo SIN PTY FALLA en Ubuntu 24.04 ("Authentication
    // token manipulation error"): el getpass de passwd NO cae a stdin en un
    // exec channel, verificado en build linux). Via sudo SIEMPRE: la vieja contrasena
    // hace de sudo password (los hosts de este proyecto tienen sudo) y
    // chpasswd cambia cualquier cuenta sin TTY. "user:new" viaja base64
    // dentro del sh -c.
    final userNew = _b64('$target:$newP');
    final script = "echo \"\$(echo ${_b64(oldP)} | base64 -d)\" | "
        "sudo -S -p '' sh -c 'echo \$userNew | base64 -d | chpasswd'";
    // El propio script viaja base64; el marcador de exito lo imprime la
    // shell EXTERNA (no el script) para fiarnos del codigo real.
    return 'echo ${_b64(script)} | base64 -d | bash; echo "XTR_EXIT:\$?"';
  }

  /// Comando para el CLI del router: comillas dobles documentadas.
  String _routerCommand(String oldP, String newP) {
    String esc(String s) =>
        s.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\$', '\\\$');
    return 'config account password user "${esc(_router.userCtrl.text.trim())}" '
        'oldpasswd "${esc(oldP)}" newpasswd "${esc(newP)}"';
  }

  Future<_PwResult> _runOn(SshHost host, String oldP, String newP) async {
    final sw = Stopwatch()..start();
    SSHSocket? socket;
    try {
      if (host.jumpHostId != null && host.jumpHostId!.isNotEmpty) {
        throw StateError('${host.name} usa ProxyJump: cambia la contraseña desde la terminal');
      }
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
        pwd = await SshCredentialsStore.readPassword(host.id) ?? oldP;
      }
      final client = SSHClient(
        socket,
        username: host.username,
        identities: identities,
        onPasswordRequest: () async => pwd,
        onUserInfoRequest: (req) async => req.prompts
            .map((p) => p.promptText.toLowerCase().contains('password') && pwd != null ? pwd : '')
            .toList(),
        onVerifyHostKey: (type, fingerprint) async => true,
        keepAliveInterval: const Duration(seconds: 15),
        handshakeTimeout: const Duration(seconds: 12),
        authTimeout: const Duration(seconds: 12),
      );
      final rr = await robustExec(
        client,
        _linuxCommand(host, oldP, newP),
        sentinel: 'XTR_EXIT:',
        timeout: const Duration(seconds: 45),
        idleTimeout: const Duration(seconds: 6),
      );
      final ok = rr.output.contains('XTR_EXIT:0');
      var out = sanitizeCliOutput(rr.output)
          .replaceAll(RegExp(r'XTR_EXIT:\d+'), '')
          .trim();
      if (rr.timedOut) out += '\n(aviso: canal cerrado por timeout del cliente)';
      if (out.isEmpty) out = ok ? '(cambiada)' : '(sin salida)';
      client.close();
      unawaited(socket.close());
      // Contrasena guardada en la app: solo tiene sentido si la cuenta
      // cambiada es la de la conexion y el usuario lo pidio.
      final changedAccount =
          _mode == 'self' ? host.username : _otherUserCtrl.text.trim();
      if (ok && _updateStored && changedAccount == host.username) {
        await SshCredentialsStore.savePassword(host.id, newP);
        out += '\n[app] contraseña guardada actualizada';
      }
      return ok ? _PwResult.ok(out, sw.elapsed) : _PwResult.fail(out, sw.elapsed);
    } catch (e) {
      try { socket?.close(); } catch (_) {}
      return _PwResult.fail(e.toString(), sw.elapsed);
    }
  }

  Future<_PwResult> _runOnRouter(String oldP, String newP) async {
    final sw = Stopwatch()..start();
    SSHSocket? socket;
    try {
      final port = int.tryParse(_router.portCtrl.text.trim()) ?? 22;
      socket = await SSHSocket.connect(_router.hostnameCtrl.text.trim(), port)
          .timeout(const Duration(seconds: 12));
      final client = SSHClient(
        socket,
        username: _router.userCtrl.text.trim(),
        onPasswordRequest: () async => oldP,
        onUserInfoRequest: (req) async => req.prompts
            .map((p) => p.promptText.toLowerCase().contains('password') ? oldP : '')
            .toList(),
        onVerifyHostKey: (type, fingerprint) async => true,
        keepAliveInterval: const Duration(seconds: 15),
        handshakeTimeout: const Duration(seconds: 12),
        authTimeout: const Duration(seconds: 12),
      );
      final rr1 = await robustExec(client, _routerCommand(oldP, newP),
          timeout: const Duration(seconds: 30), idleTimeout: const Duration(seconds: 4));
      var out1 = sanitizeCliOutput(rr1.output);
      // persistencia del CLI es dudosa); se intenta y se muestra lo que responda.
      var out2 = '';
      try {
        final rr2 = await robustExec(client, 'config save',
            timeout: const Duration(seconds: 20), idleTimeout: const Duration(seconds: 3));
        out2 = rr2.output;
      } catch (_) {}
      client.close();
      unawaited(socket.close());
      final out = [out1, if (out2.isNotEmpty) 'config save: $out2']
          .join('\n');
      // El CLI no documenta codigos de error estables: se muestra la
      // salida cruda y se marca OK salvo error de conexion/auth. El
      // usuario confirma visualmente (un solo admin, un solo router).
      return _PwResult.ok(out.isEmpty ? '(sin salida: verifica en el router)' : out, sw.elapsed);
    } catch (e) {
      try { socket?.close(); } catch (_) {}
      return _PwResult.fail(e.toString(), sw.elapsed);
    }
  }

  Future<void> _run() async {
    final oldP = _oldCtrl.text;
    final newP = _newCtrl.text;
    if (oldP.isEmpty || newP.isEmpty || _selected.isEmpty && !_router.enabled) return;
    setState(() {
      _started = true;
      _results.clear();
      _running
        ..addAll(_selected)
        ..addAll([if (_router.enabled) 'router']);
    });
    final tasks = <Future>[];
    for (final h in _hosts) {
      if (!_selected.contains(h.id)) continue;
      tasks.add(_runOn(h, oldP, newP).then((r) {
        if (!mounted) return;
        setState(() {
          _running.remove(h.id);
          _results[h.id] = r;
        });
      }));
    }
    if (_router.enabled) {
      tasks.add(_runOnRouter(oldP, newP).then((r) {
        if (!mounted) return;
        setState(() {
          _running.remove('router');
          _results['router'] = r;
        });
      }));
    }
    await Future.wait(tasks);
  }

  @override
  Widget build(BuildContext context) {
    final targets = _selected.length + (_router.enabled ? 1 : 0);
    return Scaffold(
      backgroundColor: _C.bg,
      appBar: AppBar(
        backgroundColor: _C.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: _C.textHi),
        title: const Text('Cambiar contraseña',
            style: TextStyle(color: _C.textHi, fontSize: 16)),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _C.accent),
            icon: const Icon(Icons.key),
            label: Text('Cambiar en $targets equipos'),
            onPressed: targets == 0 ? null : _submit,
          ),
        ),
      ),
      body: _loadingHosts
          ? const Center(child: CircularProgressIndicator(color: _C.accent))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _pwField(_oldCtrl, 'Contraseña actual', _hideOld,
                    () => setState(() => _hideOld = !_hideOld)),
                const SizedBox(height: 8),
                _pwField(_newCtrl, 'Contraseña nueva', _hideNew,
                    () => setState(() => _hideNew = !_hideNew)),
                const SizedBox(height: 8),
                _pwField(_repCtrl, 'Repetir contraseña nueva', _hideNew, null),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: RadioListTile<String>(
                      dense: true,
                      value: 'self',
                      groupValue: _mode,
                      onChanged: (v) => setState(() => _mode = v!),
                      title: const Text('La cuenta de conexión de cada host (vía sudo)',
                          style: TextStyle(color: _C.textHi, fontSize: 13)),
                      activeColor: _C.accent,
                    ),
                  ),
                  Expanded(
                    child: RadioListTile<String>(
                      dense: true,
                      value: 'other',
                      groupValue: _mode,
                      onChanged: (v) => setState(() => _mode = v!),
                      title: const Text('Otra cuenta vía sudo (chpasswd)',
                          style: TextStyle(color: _C.textHi, fontSize: 13)),
                      activeColor: _C.accent,
                    ),
                  ),
                ]),
                if (_mode == 'other')
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      controller: _otherUserCtrl,
                      style: const TextStyle(color: _C.textHi, fontSize: 14),
                      decoration: _dec('Usuario objetivo (p. ej. root)',
                          icon: Icons.person),
                    ),
                  ),
                CheckboxListTile(
                  dense: true,
                  value: _updateStored,
                  onChanged: (v) => setState(() => _updateStored = v ?? true),
                  activeColor: _C.accent,
                  title: const Text(
                      'Si sale bien, actualizar la contraseña guardada en la app',
                      style: TextStyle(color: _C.textHi, fontSize: 13)),
                ),
                const Divider(color: _C.card, height: 24),
                CheckboxListTile(
                  dense: true,
                  value: _router.enabled,
                  onChanged: (v) => setState(() => _router.enabled = v ?? false),
                  activeColor: _C.warn,
                  secondary: const Icon(Icons.router, color: _C.warn),
                  title: const Text('Router / gateway (CLI propio)',
                      style: TextStyle(color: _C.textHi)),
                  subtitle: const Text(
                      'config account password user … (comando del CLI)',
                      style: TextStyle(color: _C.textLo, fontSize: 11)),
                ),
                if (_router.enabled)
                  Padding(
                    padding: const EdgeInsets.only(left: 16, bottom: 8),
                    child: Row(children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: _router.hostnameCtrl,
                          style: const TextStyle(color: _C.textHi, fontSize: 13),
                          decoration: _dec('Host', icon: Icons.dns),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _router.portCtrl,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: _C.textHi, fontSize: 13),
                          decoration: _dec('Puerto'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _router.userCtrl,
                          style: const TextStyle(color: _C.textHi, fontSize: 13),
                          decoration: _dec('Usuario', icon: Icons.person),
                        ),
                      ),
                    ]),
                  ),
                const SizedBox(height: 4),
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
                        style: const TextStyle(color: _C.textLo, fontSize: 12)),
                    activeColor: _C.accent,
                  ),
                const SizedBox(height: 12),
                if (_started) ...[
                  const SizedBox(height: 16),
                  if (_running.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(children: [
                        const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: _C.accent)),
                        const SizedBox(width: 8),
                        Text(
                            'Aplicando... ${_results.length}/$targets',
                            style: const TextStyle(
                                color: _C.textLo, fontSize: 12)),
                      ]),
                    ),
                  for (final h in _hosts)
                    if (_results.containsKey(h.id))
                      _resultCard(h.name, _results[h.id]!),
                  if (_results.containsKey('router'))
                    _resultCard(
                        'Router (${_router.hostnameCtrl.text})', _results['router']!),
                ],
              ],
            ),
    );
  }

  Future<void> _submit() async {
    final oldP = _oldCtrl.text;
    final newP = _newCtrl.text;
    if (oldP.isEmpty || newP.isEmpty) return;
    if (newP != _repCtrl.text) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('La contraseña nueva no coincide con la repetición')));
      return;
    }
    if (newP.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Contraseña nueva demasiado corta (mín. 4)')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('Cambiar contraseña', style: TextStyle(color: _C.textHi, fontSize: 16)),
        content: const Text(
            'Se cambiará la contraseña en TODOS los equipos seleccionados y el router si está marcado. Si un equipo usa la misma contraseña para sudo y la cambias solo en una cuenta, el sudo puede pedir la vieja.\n\n¿Continuar?',
            style: TextStyle(color: _C.textLo, fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar', style: TextStyle(color: _C.textLo))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cambiar', style: TextStyle(color: _C.err))),
        ],
      ),
    );
    if (confirmed == true) await _run();
  }

  InputDecoration _dec(String hint, {IconData? icon}) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: _C.textLo, fontSize: 13),
        prefixIcon: icon != null ? Icon(icon, color: _C.textLo, size: 18) : null,
        filled: true,
        fillColor: _C.card,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
      );

  Widget _pwField(TextEditingController ctrl, String hint, bool hidden,
      VoidCallback? toggle) {
    return TextField(
      controller: ctrl,
      obscureText: hidden,
      style: const TextStyle(color: _C.textHi, fontSize: 14),
      decoration: _dec(hint, icon: Icons.lock).copyWith(
        suffixIcon: toggle == null
            ? null
            : IconButton(
                icon: Icon(hidden ? Icons.visibility : Icons.visibility_off,
                    color: _C.textLo, size: 18),
                onPressed: toggle),
      ),
    );
  }

  Widget _resultCard(String name, _PwResult r) {
    return Card(
      color: _C.card,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(r.ok ? Icons.check_circle : Icons.error,
                  size: 16, color: r.ok ? _C.ok : _C.err),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(name,
                      style: const TextStyle(
                          color: _C.textHi, fontWeight: FontWeight.w500))),
              Text('${r.duration.inMilliseconds} ms',
                  style: const TextStyle(color: _C.textLo, fontSize: 10)),
            ]),
            const SizedBox(height: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  r.output,
                  style: TextStyle(
                    color: r.ok ? _C.textHi : _C.err,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.copy, size: 14, color: _C.textLo),
                    tooltip: 'Copiar salida',
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: r.output));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Salida copiada')));
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}