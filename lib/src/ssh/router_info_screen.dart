// lib/src/ssh/router_info_screen.dart
//
// Consola de exploracion de la LAN via SSH al router/gateway (CLI propio:
// show/config/iptables/...). No es un host Linux: cada comando se envia tal
// cual al CLI del router y la salida cruda se muestra tal cual (la
// sintaxis exacta varia por firmware; lo que falle se ve y se corrige con
// el comando personalizado). La contrasena del router es VOLATIL: vive
// solo en memoria del State, jamas se guarda.

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'robust_exec.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';

class _C {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const accent = Color(0xFF5E9BD6);
  static const err = Color(0xFFFF453A);
}

class _CmdResult {
  final String cmd;
  final bool ok; // false = el comando/devolucion fallo (se muestra igual)
  final String output;
  final Duration duration;
  _CmdResult(this.cmd, this.ok, this.output, this.duration);
}

/// Bateria inicial "informe de la LAN". Sintaxis tipica Broadcom; lo que
/// no exista en este firmware devuelve error y se ajusta aqui o al vuelo
/// con el campo de comando personalizado.
// Bateria VERIFICADA contra el CLI real del router (25-oct): "show" sin
// subcomando imprime la lista valida; la anterior mezclaba sintaxis linux
// y casi todo daba "command error!".
const _kLanReport = [
  'show status',
  'show interface',
  'show arp',
  'show dhcp',
  'show lan',
  'show route',
  'show dns',
  'show wan',
  'show portforward',
  'show ppp',
  'show upnp',
];

class RouterInfoScreen extends StatefulWidget {
  const RouterInfoScreen({super.key});

  @override
  State<RouterInfoScreen> createState() => _RouterInfoScreenState();
}

class _RouterInfoScreenState extends State<RouterInfoScreen> {
  final _hostCtrl = TextEditingController(text: '192.168.10.1');
  final _portCtrl = TextEditingController(text: '22');
  final _userCtrl = TextEditingController(text: 'admin');
  final _passCtrl = TextEditingController();
  bool _savePass = false;
  final _customCtrl = TextEditingController();
  final _pingCtrl = TextEditingController(text: '192.168.10.28');
  bool _hidePass = true;
  bool _connecting = false;
  bool _runningBatch = false;
  final _results = <_CmdResult>[];
  final _expanded = <int>{};

  @override

  @override
  void initState() {
    super.initState();
    _loadCreds();
  }

  static const _kHost = 'router_cli_host';
  static const _kPort = 'router_cli_port';
  static const _kUser = 'router_cli_user';
  static const _kPass = 'router_cli_pass';

  Future<void> _loadCreds() async {
    try {
      final p = await SharedPreferences.getInstance();
      final h = p.getString(_kHost);
      if (h != null && h.isNotEmpty) _hostCtrl.text = h;
      final po = p.getString(_kPort);
      if (po != null && po.isNotEmpty) _portCtrl.text = po;
      final u = p.getString(_kUser);
      if (u != null && u.isNotEmpty) _userCtrl.text = u;
      final pa = p.getString(_kPass);
      if (pa != null && pa.isNotEmpty) {
        _passCtrl.text = pa;
        _savePass = true;
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _persistCreds() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kHost, _hostCtrl.text.trim());
      await p.setString(_kPort, _portCtrl.text.trim());
      await p.setString(_kUser, _userCtrl.text.trim());
      if (_savePass) {
        await p.setString(_kPass, _passCtrl.text);
      } else {
        await p.remove(_kPass);
      }
    } catch (_) {}
  }
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _customCtrl.dispose();
    _pingCtrl.dispose();
    super.dispose();
  }

  // v2.13.2: este SSH de router NO admite un segundo canal exec en la
  // misma conexion (el primero responde y los siguientes cuelgan: la
  // sintoma era "Leyendo LAN... 1/11" parado). Por eso NO hay sesion
  // persistente: CONEXION NUEVA POR COMANDO. Y cada comando se ejecuta
  // con robustExec: el CLI se queda en prompt sin cerrar el canal, asi
  // que se completa por silencio (idle) o timeout, cerrando el canal
  // desde el cliente. La "prueba de conexion" lanza un comando real para
  // FORZAR la autenticacion (la libreria autentica de forma perezosa al
  // abrir el primer canal: conectar y cerrar daba OK siempre).
  Future<SSHClient?> _connectOnce() async {
    setState(() => _connecting = true);
    try {
      final port = int.tryParse(_portCtrl.text.trim()) ?? 22;
      final socket = await SSHSocket.connect(_hostCtrl.text.trim(), port)
          .timeout(const Duration(seconds: 12));
      final pass = _passCtrl.text;
      return SSHClient(
        socket,
        username: _userCtrl.text.trim(),
        onPasswordRequest: () async => pass,
        onUserInfoRequest: (req) async => req.prompts
            .map((p) => p.promptText.toLowerCase().contains('password') ? pass : '')
            .toList(),
        onVerifyHostKey: (type, fingerprint) async => true,
        handshakeTimeout: const Duration(seconds: 12),
        authTimeout: const Duration(seconds: 12),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Conexion fallida: $e')));
      }
      return null;
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  /// Quita el eco del propio comando y el prompt ">" final del CLI.
  String _cleanCli(String raw, String cmd) {
    final lines = sanitizeCliOutput(raw).split('\n');
    final cleaned = <String>[];
    for (final l in lines) {
      if (l.trim() == cmd.trim()) continue;
      if (l.trim() == '>') continue;
      cleaned.add(l);
    }
    return cleaned.join('\n').trim();
  }


  Future<void> _runPing() async {
    final ip = _pingCtrl.text.trim();
    if (ip.isEmpty) return;
    // El CLI no tiene ping, pero tiene un shell linux oculto ("sh"):
    // entramos y lanzamos ping desde el propio router (o cerca).
    final sw = Stopwatch()..start();
    SSHSocket? socket;
    try {
      final port = int.tryParse(_portCtrl.text.trim()) ?? 22;
      socket = await SSHSocket.connect(_hostCtrl.text.trim(), port)
          .timeout(const Duration(seconds: 12));
      final pass = _passCtrl.text;
      final client = SSHClient(
        socket,
        username: _userCtrl.text.trim(),
        onPasswordRequest: () async => pass,
        onUserInfoRequest: (req) async => req.prompts
            .map((p) => p.promptText.toLowerCase().contains('password') ? pass : '')
            .toList(),
        onVerifyHostKey: (type, fingerprint) async => true,
        handshakeTimeout: const Duration(seconds: 12),
        authTimeout: const Duration(seconds: 12),
      );
      final r = await robustShell(client, 'sh\nping -c 4 $ip',
          timeout: const Duration(seconds: 40),
          idleTimeout: const Duration(seconds: 5));
      client.close();
      unawaited(socket.close());
      await _persistCreds();
      var out = sanitizeCliOutput(r.output);
      if (out.isEmpty) out = '(sin salida)';
      if (!mounted) return;
      setState(() {
        _results.add(_CmdResult('ping $ip', true, out, sw.elapsed));
        _expanded.add(_results.length - 1);
      });
    } catch (e) {
      try { socket?.close(); } catch (_) {}
      if (!mounted) return;
      setState(() {
        _results.add(_CmdResult('ping $ip', false, e.toString(), sw.elapsed));
        _expanded.add(_results.length - 1);
      });
    }
  }

  Future<void> _probe() async {
    // La autenticacion es perezosa: hay que abrir un canal con un comando
    // real. Si la contrasena es mala, robustShell lanza y cae en el catch.
    final c = await _connectOnce();
    if (c == null) return;
    try {
      final r = await robustShell(c, 'show status',
          timeout: const Duration(seconds: 15),
          idleTimeout: const Duration(seconds: 3));
      c.close();
      if (!mounted) return;
      if (r.output.isNotEmpty && !r.output.toLowerCase().contains('denied')) {
        await _persistCreds();
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Conexion y autenticacion OK')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Conexion OK pero sin respuesta del CLI: revisa usuario')));
      }
    } catch (e) {
      c.close();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Autenticacion fallida: $e')));
      }
    }
  }

  Future<_CmdResult> _exec(String cmd) async {
    final sw = Stopwatch()..start();
    SSHSocket? socket;
    try {
      final port = int.tryParse(_portCtrl.text.trim()) ?? 22;
      socket = await SSHSocket.connect(_hostCtrl.text.trim(), port)
          .timeout(const Duration(seconds: 12));
      final pass = _passCtrl.text;
      final client = SSHClient(
        socket,
        username: _userCtrl.text.trim(),
        onPasswordRequest: () async => pass,
        onUserInfoRequest: (req) async => req.prompts
            .map((p) => p.promptText.toLowerCase().contains('password') ? pass : '')
            .toList(),
        onVerifyHostKey: (type, fingerprint) async => true,
        handshakeTimeout: const Duration(seconds: 12),
        authTimeout: const Duration(seconds: 12),
      );
      // El CLI ignora el "exec" y solo saca su prompt ">": hay que abrir
      // sesion shell y escribir el comando por stdin (robustShell).
      final r = await robustShell(client, cmd,
          timeout: const Duration(seconds: 30),
          idleTimeout: const Duration(seconds: 3));
      client.close();
      unawaited(socket.close());
      await _persistCreds();
      var out = _cleanCli(r.output, cmd);
      if (r.timedOut && out.isEmpty) out = '(sin salida)';
      return _CmdResult(cmd, true, out.isEmpty ? '(sin salida)' : out, sw.elapsed);
    } catch (e) {
      try { socket?.close(); } catch (_) {}
      return _CmdResult(cmd, false, e.toString(), sw.elapsed);
    }
  }

  Future<void> _runBatch() async {
    if (_runningBatch) return;
    setState(() {
      _runningBatch = true;
      _results.clear();
      _expanded.clear();
    });
    for (final cmd in _kLanReport) {
      final r = await _exec(cmd);
      if (!mounted) return;
      setState(() {
        _results.add(r);
        _expanded.add(_results.length - 1);
      });
    }
    if (mounted) setState(() => _runningBatch = false);
  }

  Future<void> _runCustom() async {
    final cmd = _customCtrl.text.trim();
    if (cmd.isEmpty) return;
    _customCtrl.clear();
    final r = await _exec(cmd);
    if (!mounted) return;
    setState(() {
      _results.add(r);
      _expanded.add(_results.length - 1);
    });
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.bg,
      appBar: AppBar(
        backgroundColor: _C.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: _C.textHi),
        title: const Text('Router · comandos LAN',
            style: TextStyle(color: _C.textHi, fontSize: 16)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _hostCtrl,
                style: const TextStyle(color: _C.textHi, fontSize: 13),
                decoration: _dec('Router (host)', icon: Icons.dns),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _portCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: _C.textHi, fontSize: 13),
                decoration: _dec('Puerto'),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _userCtrl,
                style: const TextStyle(color: _C.textHi, fontSize: 13),
                decoration: _dec('Usuario', icon: Icons.person),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _passCtrl,
                obscureText: _hidePass,
                style: const TextStyle(color: _C.textHi, fontSize: 13),
                decoration: _dec('Contraseña', icon: Icons.lock).copyWith(
                  suffixIcon: IconButton(
                    icon: Icon(
                        _hidePass ? Icons.visibility : Icons.visibility_off,
                        color: _C.textLo,
                        size: 18),
                    onPressed: () => setState(() => _hidePass = !_hidePass),
                  ),
                ),
              ),
            ),
          ]),
          Row(children: [
            SizedBox(
              width: 24,
              child: Checkbox(
                value: _savePass,
                onChanged: (v) => setState(() => _savePass = v ?? false),
                activeColor: _C.accent,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const Expanded(
              child: Text('Recordar contraseña en este dispositivo',
                  style: TextStyle(color: _C.textLo, fontSize: 12)),
            ),
          ]),
          const SizedBox(height: 8),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: _C.accent)),
                  icon: _connecting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: _C.accent))
                      : const Icon(Icons.cable, color: _C.accent),
                  label: Text(_connecting ? 'Conectando…' : 'Probar conexion',
                      style: const TextStyle(color: _C.accent)),
                  onPressed: _connecting ? null : _probe,
                ),
              ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: _C.accent),
                icon: _runningBatch
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.dashboard),
                label: Text(_runningBatch
                    ? 'Leyendo LAN… ${_results.length}/${_kLanReport.length}'
                    : 'Informe completo LAN (${_kLanReport.length} comandos)'),
                onPressed: _runningBatch ? null : _runBatch,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _customCtrl,
            style: const TextStyle(
                color: _C.textHi, fontFamily: 'monospace', fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Comando personalizado del CLI (p. ej. "show ?")…',
              hintStyle: const TextStyle(color: _C.textLo, fontSize: 13),
              filled: true,
              fillColor: _C.card,
              isDense: true,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none),
              suffixIcon: IconButton(
                icon: const Icon(Icons.send, color: _C.accent),
                onPressed: _runCustom,
              ),
            ),
            onSubmitted: (_) => _runCustom(),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _pingCtrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(
                    color: _C.textHi, fontFamily: 'monospace', fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Ping desde el router a IP de la LAN…',
                  hintStyle: const TextStyle(color: _C.textLo, fontSize: 13),
                  filled: true,
                  fillColor: _C.card,
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none),
                ),
                onSubmitted: (_) => _runPing(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              style: IconButton.styleFrom(backgroundColor: _C.accent),
              icon: const Icon(Icons.network_ping, color: Colors.white),
              tooltip: 'Ping desde el router',
              onPressed: _runPing,
            ),
          ]),
          const SizedBox(height: 4),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'CLI propio del router (show/config/iptables/tcpdump/backup…). '
              'Salida cruda: lo que falle se ve y se ajusta. La contraseña '
              'no se guarda nunca.',
              style: TextStyle(color: _C.textLo, fontSize: 11),
            ),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < _results.length; i++) _card(i, _results[i]),
        ],
      ),
    );
  }

  InputDecoration _dec(String hint, {IconData? icon}) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: _C.textLo, fontSize: 13),
        prefixIcon:
            icon != null ? Icon(icon, color: _C.textLo, size: 18) : null,
        filled: true,
        fillColor: _C.card,
        isDense: true,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none),
      );

  Widget _card(int i, _CmdResult r) {
    final open = _expanded.contains(i);
    return Card(
      color: _C.card,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        key: PageStorageKey('rc$i'),
        initiallyExpanded: true,
        onExpansionChanged: (v) =>
            setState(() => v ? _expanded.add(i) : _expanded.remove(i)),
        backgroundColor: Colors.transparent,
        collapsedBackgroundColor: Colors.transparent,
        iconColor: _C.accent,
        collapsedIconColor: _C.textLo,
        leading: Icon(
            r.ok ? (open ? Icons.terminal : Icons.check_circle) : Icons.error,
            size: 16,
            color: r.ok ? (open ? _C.accent : _C.accent) : _C.err),
        title: Text(r.cmd,
            style: const TextStyle(
                color: _C.textHi,
                fontFamily: 'monospace',
                fontSize: 13)),
        subtitle: Text('${r.duration.inMilliseconds} ms',
            style: const TextStyle(color: _C.textLo, fontSize: 10)),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SelectableText(
                r.output,
                style: TextStyle(
                  color: r.ok ? _C.textHi : _C.err,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
