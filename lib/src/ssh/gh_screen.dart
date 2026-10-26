// lib/src/ssh/gh_screen.dart
//
// v2.15.0: CONSOLA GH — gestionar GitHub desde la app via gh CLI en un
// host SSH. Es la "opcion B" del apartado GitHub: el telefono no habla con
// la API de GitHub directamente; abre un SSH al host elegido (z1 por
// defecto, donde gh ya esta autenticado como txurtxil) y ejecuta comandos
// gh de SOLO LECTURA, mostrando el resultado en una tarjeta con copiar.
//
// Receta de conexion: copiada de _auditHost (hosts_screen.dart), que es la
// version probada en batalla: contrasena desde SshCredentialsStore (prompt
// si falta, con opcion de recordarla), keyPath del host o identidad de la
// app como fallback, known_hosts accept-new anti-MITM, client.run(cmd).
//
// Comandos (todos RC=0 verificados en z1, salida no interactiva):
//   gh auth status
//   gh repo list --limit 20
//   gh search prs --author=@me --state=open --limit 20
//   gh search issues --assignee=@me --state=open --limit 20
//   gh release list -R <repo> -L 15
//   gh run list -R <repo> -L 15
// gh pr/issue status NO se usan: exigen estar dentro de un repo git y
// fallan con "not a git repository" fuera de uno (verificado en z1).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../storage/app_paths.dart';
import '../terminal/terminal_session.dart';
import 'identity_service.dart';
import 'ssh_credentials_store.dart';
import 'ssh_host.dart';
import 'ssh_hosts_service.dart';

class GhConsoleScreen extends StatefulWidget {
  const GhConsoleScreen({super.key});

  @override
  State<GhConsoleScreen> createState() => _GhConsoleScreenState();
}

class _GhConsoleScreenState extends State<GhConsoleScreen> {
  static const _bg = Color(0xFF1C1C1E);
  static const _card = Color(0xFF2C2C2E);
  static const _border = Color(0xFF3A3A3C);
  static const _textHi = Color(0xFFEAEAEC);
  static const _textLo = Color(0xFF9A9AA0);
  static const _accent = Color(0xFF5E9BD6);
  static const _ok = Color(0xFF34C759);
  static const _err = Color(0xFFFF453A);

  final List<SshHost> _hosts = [];
  SshHost? _host;
  final TextEditingController _repoCtrl =
      TextEditingController(text: 'txurtxil/TermXTR');
  SSHClient? _client;
  bool _busy = false;
  String _title = '';
  String _output = '';
  bool _outputOk = false;
  bool _hasOutput = false;
  bool _rememberPwd = false;

  @override
  void initState() {
    super.initState();
    _loadHosts();
  }

  @override
  void dispose() {
    _repoCtrl.dispose();
    _client?.close();
    super.dispose();
  }

  Future<void> _loadHosts() async {
    _hosts
      ..clear()
      ..addAll(SshHostsService.instance.hosts);
    if (_hosts.isEmpty) return;
    SshHost? pick;
    for (final h in _hosts) {
      final n = '${h.id} ${h.hostname}'.toLowerCase();
      if (n.contains('z1')) { pick = h; break; }
    }
    pick ??= _hosts.first;
    if (!mounted) return;
    setState(() => _host = pick);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  // --- Prompt de contrasena (mismo patron que el audit de hosts) --------

  Future<String?> _promptPassword(SshHost h) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        title: Text('Contrasena de ${h.name}',
            style: const TextStyle(color: _textHi, fontSize: 16)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: ctrl,
            obscureText: true,
            autofocus: true,
            style: const TextStyle(color: _textHi),
            decoration: const InputDecoration(
                hintText: 'Contrasena SSH',
                hintStyle: TextStyle(color: _textLo)),
          ),
          StatefulBuilder(builder: (ctx2, setS) => CheckboxListTile(
                dense: true,
                value: _rememberPwd,
                checkColor: Colors.white,
                activeColor: _accent,
                title: const Text('Recordar en la app',
                    style: TextStyle(color: _textLo, fontSize: 13)),
                onChanged: (v) => setS(() => _rememberPwd = v ?? false),
              )),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar',
                  style: TextStyle(color: _textLo))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Aceptar',
                  style: TextStyle(color: _accent))),
        ],
      ),
    );
    if (ok != true) return null;
    final pwd = ctrl.text;
    if (pwd.isEmpty) return null;
    if (_rememberPwd) await SshCredentialsStore.savePassword(h.id, pwd);
    return pwd;
  }

  // --- Conexion lazy (receta _auditHost) ---------------------------------

  Future<SSHClient> _ensureClient() async {
    final existing = _client;
    if (existing != null) return existing;
    final h = _host!;
    List<SSHKeyPair>? identities;
    final kp = h.keyPath?.trim() ?? '';
    if (kp.isNotEmpty) {
      final f = await AppPaths.resolveKey(kp);
      if (f != null) {
        identities = SSHKeyPair.fromPem(await f.readAsString());
      }
    }
    identities ??= await IdentityService.loadIdentity();
    var pwd = await SshCredentialsStore.readPassword(h.id);
    pwd ??= await _promptPassword(h);
    if (pwd == null) throw StateError('Contrasena no disponible para ${h.name}');
    final socket = await SSHSocket.connect(h.hostname, h.port)
        .timeout(const Duration(seconds: 12));
    final known = await TerminalSession.loadKnownHosts();
    final hostKey = '${h.hostname}:${h.port}';
    final client = SSHClient(
      socket,
      username: h.username,
      identities: identities ?? const [],
      onPasswordRequest: () => pwd,
      // Mismo patron que _auditHost: solo responde a prompts que piden
      // password; el resto van vacios (keyboard-interactive).
      onUserInfoRequest: (req) async => req.prompts
          .map((p) => p.promptText.toLowerCase().contains('password')
              ? (pwd ?? '')
              : '')
          .toList(),
      onVerifyHostKey: (type, fpBytes) async {
        final fp = '$type:${base64Encode(fpBytes)}';
        final saved = known[hostKey];
        if (saved == null || saved == fp) {
          known[hostKey] = fp;
          await TerminalSession.saveKnownHosts(known);
          return true;
        }
        return false;
      },
      keepAliveInterval: const Duration(seconds: 15),
      handshakeTimeout: const Duration(seconds: 15),
      authTimeout: const Duration(seconds: 15),
    );
    await client.authenticated.timeout(const Duration(seconds: 20));
    _client = client;
    return client;
  }

  // --- Acciones ----------------------------------------------------------

  Future<void> _run(String title, String cmd) async {
    setState(() {
      _busy = true;
      _title = title;
      _hasOutput = false;
    });
    var out = '';
    var ok = true;
    try {
      final client = await _ensureClient()
          .timeout(const Duration(seconds: 40));
      // dartssh2 3.3.1: run() devuelve solo stdout (Uint8List);
      // runWithResult() da stdout+stderr+exitCode.
      final res = await client
          .runWithResult(cmd)
          .timeout(const Duration(seconds: 40));
      final stdoutTxt = utf8.decode(res.stdout, allowMalformed: true);
      final stderrTxt = utf8.decode(res.stderr, allowMalformed: true);
      out = stdoutTxt.trim();
      final err = stderrTxt.trim();
      if (res.exitCode != 0) {
        ok = false;
        out = err.isEmpty ? 'gh salio con codigo ${res.exitCode}' : err;
      } else if (out.isEmpty && err.isNotEmpty) {
        // gh a veces escribe avisos en stderr con RC=0
        out = err;
      } else if (out.isEmpty) {
        out = '(sin resultados)';
      }
    } on TimeoutException {
      ok = false;
      out = 'Tiempo agotado. El host tardo demasiado; reintenta.';
      _client?.close();
      _client = null;
    } on SocketException {
      ok = false;
      out = 'Sin conexion a ${_host?.hostname}:${_host?.port}.';
      _client?.close();
      _client = null;
    } on StateError catch (e) {
      ok = false;
      out = e.message;
    } catch (e) {
      ok = false;
      final msg = e.toString();
      if (msg.contains('auth') || msg.contains('closed before')) {
        out = 'Autenticacion SSH rechazada en ${_host?.name}: revisa la '
            'contrasena o la clave del host.';
      } else if (msg.contains('ShellError') || msg.contains('gh:')) {
        out = 'gh fallo en el host (no instalado o no autenticado?). '
            'Prueba "gh auth status" tras conectar por terminal. Detalle: $msg';
      } else {
        out = msg.replaceAll('\n', ' ');
      }
      _client?.close();
      _client = null;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _hasOutput = true;
      _outputOk = ok;
      _output = out;
    });
  }

  // --- UI -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        title: const Text('GitHub · Consola gh',
            style: TextStyle(color: _textHi)),
        iconTheme: const IconThemeData(color: _textLo),
      ),
      body: ListView(children: [
        Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('HOST (donde corre gh)',
                  style: TextStyle(
                      color: _accent,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.6)),
              const SizedBox(height: 8),
              if (_host == null)
                const Text('Cargando hosts…',
                    style: TextStyle(color: _textLo))
              else
                DropdownButtonFormField<SshHost>(
                  value: _host,
                  dropdownColor: _card,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: _bg,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none),
                  ),
                  style: const TextStyle(color: _textHi, fontSize: 14),
                  items: [
                    for (final h in _hosts)
                      DropdownMenuItem(
                          value: h,
                          child: Text('${h.name} (${h.username}@${h.hostname})',
                              overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    _client?.close();
                    _client = null;
                    setState(() => _host = v);
                  },
                ),
              const SizedBox(height: 10),
              const Text('REPO (para releases y CI)',
                  style: TextStyle(
                      color: _accent,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.6)),
              const SizedBox(height: 8),
              TextField(
                controller: _repoCtrl,
                style: const TextStyle(color: _textHi, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'usuario/repo',
                  hintStyle:
                      const TextStyle(color: _textLo, fontSize: 14),
                  filled: true,
                  fillColor: _bg,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                _chip('Auth', () => _run('gh auth status', 'gh auth status')),
                _chip('Repos', () =>
                    _run('Tus repos', 'gh repo list --limit 20')),
                _chip('Mis PRs', () => _run(
                    'PRs abiertos tuyos',
                    'gh search prs --author=@me --state=open --limit 20')),
                _chip('Mis issues', () => _run(
                    'Issues abiertos asignados a ti',
                    'gh search issues --assignee=@me --state=open --limit 20')),
                _chip('Releases', () => _run(
                    'Releases de ${_repoCtrl.text.trim()}',
                    'gh release list -R ${_repoCtrl.text.trim()} -L 15')),
                _chip('CI runs', () => _run(
                    'CI de ${_repoCtrl.text.trim()}',
                    'gh run list -R ${_repoCtrl.text.trim()} -L 15')),
              ]),
            ],
          ),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Center(
                child: CircularProgressIndicator(color: _accent)),
          ),
        if (_hasOutput)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(
                      _outputOk
                          ? Icons.check_circle
                          : Icons.error,
                      size: 18,
                      color: _outputOk ? _ok : _err),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_title,
                        style: const TextStyle(
                            color: _textHi,
                            fontSize: 13,
                            fontWeight: FontWeight.bold)),
                  ),
                  GestureDetector(
                    onTap: () async {
                      await Clipboard.setData(
                          ClipboardData(text: _output));
                      if (mounted) _toast('Copiado');
                    },
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.copy,
                          size: 18, color: _accent),
                    ),
                  ),
                ]),
                const SizedBox(height: 10),
                SelectableText(
                  _output,
                  style: TextStyle(
                    color: _outputOk ? _textHi : _err,
                    fontSize: 12.5,
                    fontFamily: 'monospace',
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
      ]),
    );
  }

  Widget _chip(String label, VoidCallback onTap) {
    return ActionChip(
      backgroundColor: _bg,
      side: const BorderSide(color: _border),
      label: Text(label,
          style: const TextStyle(color: _textHi, fontSize: 13)),
      onPressed: _busy ? null : onTap,
    );
  }
}
