// lib/src/ssh/github_screen.dart
//
// v2.14.0: APARTADO GITHUB — trabajar con GitHub por SSH desde la app.
// GitHub no es "un host mas": el usuario es fijo (git), no da shell (el
// banner "Hi usuario!" ES la prueba de autenticacion) y la clave publica
// hay que pegarla en la web de GitHub. Por eso merece pantalla propia:
//
//  1. Identidad: estado de la clave Ed25519 de la app (IdentityService)
//     + copiar la linea publica OpenSSH al portapapeles.
//  2. Conexion: "Probar conexion" abre un SSH real a git@github.com:22 en
//     segundo plano (misma pila dartssh2 que las sesiones) y parsea el
//     banner. Sin tocar la shell interactiva: la sesion de terminal sigue
//     en su sitio.
//  3. Snippets: clone/pull/push/fetch con la URL SSH ya montada; tocar
//     copia al portapapeles.
//  4. "Abrir sesion GitHub": terminal normal al host (GitHub imprime el
//     banner de auth y corta — es la comprobacion "a ojo" clasica).
//
// El host git@github.com se crea solo la primera vez (id fijo 'gh-github',
// grupo 'GitHub') y aparece en la lista de hosts como cualquier otro, asi
// el SFTP/terminal/backup lo tratan sin codigo especial.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../terminal/terminal_session.dart';
import 'identity_service.dart';
import 'ssh_host.dart';
import 'ssh_hosts_service.dart';

class GithubScreen extends StatefulWidget {
  const GithubScreen({super.key, required this.onOpenTerminal});

  /// Abre una sesion de terminal al host dado (lo cablea HostsScreen con
  /// su onConnect, que cierra la pila de pantallas y conecta).
  final void Function(SshHost host) onOpenTerminal;

  @override
  State<GithubScreen> createState() => _GithubScreenState();
}

class _GithubScreenState extends State<GithubScreen> {
  // Misma paleta que hosts_screen (cada pantalla lleva su copia privada).
  static const _bg = Color(0xFF1C1C1E);
  static const _card = Color(0xFF2C2C2E);
  static const _border = Color(0xFF3A3A3C);
  static const _textHi = Color(0xFFEAEAEC);
  static const _textLo = Color(0xFF9A9AA0);
  static const _accent = Color(0xFF5E9BD6);
  static const _ok = Color(0xFF34C759);
  static const _err = Color(0xFFFF453A);

  static const String _hostId = 'gh-github';

  SshHost? _host;
  String _pubKey = '';
  String _fingerprint = '';
  bool _testing = false;
  bool? _testOk;
  String _testMsg = '';
  final TextEditingController _repoCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ensureReady();
  }

  @override
  void dispose() {
    _repoCtrl.dispose();
    super.dispose();
  }

  Future<void> _ensureReady() async {
    final svc = SshHostsService.instance;
    SshHost? h;
    for (final x in svc.hosts) {
      if (x.id == _hostId) { h = x; break; }
    }
    h ??= SshHost(
      id: _hostId,
      name: 'GitHub',
      hostname: 'github.com',
      port: 22,
      username: 'git',
      group: 'GitHub',
    );
    if (h.id == _hostId && !svc.hosts.any((x) => x.id == _hostId)) {
      await svc.add(h);
    }
    final pub = await IdentityService.ensureIdentity();
    final fp = await _fingerprintOf(pub);
    if (!mounted) return;
    setState(() {
      _host = h;
      _pubKey = pub;
      _fingerprint = fp;
    });
  }

  /// Huella OpenSSH (SHA256:...) de una linea publica, para comparar con la
  /// entrada de GitHub (Settings -> SSH keys muestra la misma huella).
  static Future<String> _fingerprintOf(String pubLine) async {
    try {
      final parts = pubLine.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) return '';
      final blob = base64.decode(parts[1]);
      final hash = await Sha256().hash(blob);
      return 'SHA256:' + base64.encode(hash.bytes).replaceAll('=', '');
    } catch (_) {
      return '';
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _copyPubKey() async {
    if (_pubKey.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _pubKey));
    if (mounted) _toast('Clave publica copiada — pegala en github.com/settings/keys');
  }

  // --- Prueba de conexion en segundo plano ------------------------------

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testOk = null;
      _testMsg = '';
    });
    String? user;
    String error = '';
    try {
      final identities = await IdentityService.loadIdentity();
      if (identities == null) {
        throw StateError('Sin identidad SSH en la app');
      }
      final socket = await SSHSocket.connect('github.com', 22)
          .timeout(const Duration(seconds: 12));
      final client = SSHClient(
        socket,
        username: 'git',
        identities: identities,
        onVerifyHostKey: (type, fingerprintBytes) async {
          // Misma politica accept-new que las sesiones: huella cambiada =
          // rechazo (anti-MITM), se explica abajo.
          final fingerprint = '$type:${base64.encode(fingerprintBytes)}';
          final known = await TerminalSession.loadKnownHosts();
          const hostKey = 'github.com:22';
          final saved = known[hostKey];
          if (saved == null || saved == fingerprint) {
            known[hostKey] = fingerprint;
            await TerminalSession.saveKnownHosts(known);
            return true;
          }
          return false;
        },
        keepAliveInterval: const Duration(seconds: 15),
        handshakeTimeout: const Duration(seconds: 15),
        authTimeout: const Duration(seconds: 15),
      );
      try {
        await client.authenticated.timeout(const Duration(seconds: 15));
        final shell = await client.shell();
        final banner = Completer<String>();
        final sub = shell.stdout.listen((data) {
          final s = utf8.decode(data, allowMalformed: true);
          if (!banner.isCompleted) banner.complete(s);
        });
        final raw = await banner.future.timeout(const Duration(seconds: 10),
            onTimeout: () => '');
        await sub.cancel();
        final m = RegExp(r'Hi ([^!\r\n]+)!').firstMatch(raw);
        if (m != null) {
          user = m.group(1);
        } else {
          error = 'Conectado pero sin banner de GitHub (respuesta inesperada)';
        }
      } finally {
        client.close();
      }
    } on TimeoutException {
      error = 'Tiempo agotado: sin respuesta de github.com:22. Si estas '
          'por una red que bloquea el 22, GitHub tambien acepta SSH por '
          '443 (ssh.github.com) — cambialo en el host GitHub de la lista.';
    } on SocketException {
      error = 'Sin conexion a github.com:22 (red?).';
    } on StateError catch (e) {
      error = e.message;
    } on SSHAuthFailError {
      // La clave publica que presenta la app no es la que GitHub tiene
      // registrada (p. ej. tras regenerar la identidad en la pantalla
      // Identidad despues de anadir la clave a GitHub). La huella visible
      // en la tarjeta Identidad permite comparar al instante.
      error = 'GitHub rechazo la clave publica. Compara la huella de la '
          'tarjeta Identidad con la de tu entrada en GitHub (Settings -> '
          'SSH keys): si difieren, la identidad se regenero — vuelve a '
          '"Copiar clave publica", borra la entrada vieja en GitHub y anade '
          'la nueva.';
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('auth') || msg.contains('closed before')) {
        // auth abortada por huella cambiada vs known_hosts, o GitHub
        // cerro antes de autenticar: en la practica = clave no registrada.
        error = 'GitHub no acepto la clave. Copia la publica '
            '(arriba) en github.com/settings/keys y reintenta. Si la '
            'huella de github.com cambio, revisa Hosts conocidos (SSH).';
      } else {
        error = e.toString().replaceAll('\n', ' ');
      }
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = user != null;
      _testMsg = user != null ? 'Autenticado en GitHub como $user' : error;
    });
  }

  // --- Snippets ----------------------------------------------------------

  String get _repo {
    var r = _repoCtrl.text.trim();
    r = r.replaceFirst(RegExp(r'^https?://github\.com/'), '');
    r = r.replaceFirst(RegExp(r'^git@github\.com:'), '');
    r = r.replaceFirst(RegExp(r'\.git$'), '');
    return r;
  }

  Future<void> _copySnippet(String cmd) async {
    if (_repo.isEmpty) {
      _toast('Escribe usuario/repo primero');
      return;
    }
    await Clipboard.setData(ClipboardData(text: cmd));
    if (mounted) _toast('Copiado: $cmd');
  }

  // --- UI ----------------------------------------------------------------

  Widget _section(String title, List<Widget> children) {
    return Container(
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
          Text(title,
              style: const TextStyle(
                  color: _accent,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.6)),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pub = _pubKey;
    final pubShort = pub.length > 58 ? '${pub.substring(0, 58)}…' : pub;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        title: const Text('GitHub · SSH', style: TextStyle(color: _textHi)),
        iconTheme: const IconThemeData(color: _textLo),
      ),
      body: ListView(
        children: [
          _section('Identidad', [
            Text(
              pub.isEmpty
                  ? 'Generando identidad Ed25519…'
                  : 'Clave Ed25519 de la app lista.\n$pubShort\n'
                      'Huella: ${_fingerprint.isEmpty ? '…' : _fingerprint}\n'
                      '(debe coincidir con tu entrada en GitHub)',
              style: const TextStyle(color: _textLo, fontSize: 13),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: pub.isEmpty ? null : _copyPubKey,
                  icon: const Icon(Icons.copy, size: 18, color: _accent),
                  label: const Text('Copiar clave publica',
                      style: TextStyle(color: _accent)),
                ),
              ),
            ]),
            const Text(
              'Pegala en GitHub → Settings → SSH and GPG keys → New SSH key.',
              style: TextStyle(color: _textLo, fontSize: 12),
            ),
          ]),
          _section('Conexion', [
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _testing ? null : _testConnection,
                style: FilledButton.styleFrom(backgroundColor: _accent),
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.wifi_tethering, size: 18),
                label: Text(_testing ? 'Probando…' : 'Probar conexion',
                    style: const TextStyle(color: Colors.white)),
              ),
            ),
            if (_testOk != null) ...[
              const SizedBox(height: 10),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(_testOk! ? Icons.check_circle : Icons.error,
                    size: 18, color: _testOk! ? _ok : _err),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_testMsg,
                      style: TextStyle(
                          color: _testOk! ? _ok : _err, fontSize: 13)),
                ),
              ]),
            ],
          ]),
          _section('Snippets (se copian al portapapeles)', [
            TextField(
              controller: _repoCtrl,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(color: _textHi, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'usuario/repo',
                hintStyle: const TextStyle(color: _textLo, fontSize: 14),
                filled: true,
                fillColor: _bg,
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _chip('Clonar', () => _copySnippet('git clone git@github.com:${_repo}.git')),
              _chip('Pull', () => _copySnippet('git pull git@github.com:${_repo}.git')),
              _chip('Push', () => _copySnippet('git push git@github.com:${_repo}.git')),
              _chip('Fetch', () => _copySnippet('git fetch git@github.com:${_repo}.git')),
            ]),
          ]),
          _section('Sesion', [
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _host == null
                    ? null
                    : () => widget.onOpenTerminal(_host!),
                icon: const Icon(Icons.terminal, size: 18, color: _accent),
                label: const Text('Abrir sesion GitHub (banner de auth)',
                    style: TextStyle(color: _accent)),
              ),
            ),
          ]),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _chip(String label, VoidCallback onTap) {
    return ActionChip(
      backgroundColor: _bg,
      side: const BorderSide(color: _border),
      label: Text(label, style: const TextStyle(color: _textHi, fontSize: 13)),
      onPressed: onTap,
    );
  }
}
