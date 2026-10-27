// lib/src/ssh/ssh_server_screen.dart
//
// v2.16.0: pantalla de control del SERVIDOR SSH de la app (opcion B).
// Menu ... de Hosts -> "Servidor SSH (esta app)".

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'identity_service.dart';
import 'ssh_server_service.dart';

class SshServerScreen extends StatefulWidget {
  const SshServerScreen({super.key});

  @override
  State<SshServerScreen> createState() => _SshServerScreenState();
}

class _SshServerScreenState extends State<SshServerScreen> {
  static const _bg = Color(0xFF1C1C1E);
  static const _card = Color(0xFF2C2C2E);
  static const _border = Color(0xFF3A3A3C);
  static const _textHi = Color(0xFFEAEAEC);
  static const _textLo = Color(0xFF9A9AA0);
  static const _accent = Color(0xFF5E9BD6);
  static const _ok = Color(0xFF34C759);
  static const _err = Color(0xFFFF453A);

  final _svc = SshServerService.instance;
  final TextEditingController _portCtrl = TextEditingController(text: '2222');
  String _pubKey = '';
  String _ips = '';
  String _error = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _portCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final pub = await IdentityService.ensureIdentity();
    final buf = StringBuffer();
    try {
      for (final iface in await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLinkLocal: false)) {
        for (final addr in iface.addresses) {
          buf.write('${iface.name} ${addr.address}\n');
        }
      }
    } catch (_) {/* sin permisos de red: se ignora */}
    if (!mounted) return;
    setState(() {
      _pubKey = pub;
      _ips = buf.toString().trim();
    });
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _toggle() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      if (_svc.isRunning) {
        await _svc.stop();
      } else {
        final port = int.tryParse(_portCtrl.text.trim()) ?? 2222;
        if (port < 1024 || port > 65535) {
          throw StateError('Puerto invalido: $port');
        }
        await _svc.start(port: port);
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceAll('\n', ' '));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final running = _svc.isRunning;
    final pubShort =
        _pubKey.length > 64 ? '${_pubKey.substring(0, 64)}…' : _pubKey;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        title: const Text('Servidor SSH (esta app)',
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
              Row(children: [
                Icon(running ? Icons.check_circle : Icons.circle_outlined,
                    size: 18, color: running ? _ok : _textLo),
                const SizedBox(width: 8),
                Text(running ? 'EN MARCHA en el puerto ${_svc.port}' : 'DETENIDO',
                    style: TextStyle(
                        color: running ? _ok : _textLo,
                        fontSize: 14,
                        fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _portCtrl,
                    enabled: !running,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: _textHi, fontSize: 14),
                    decoration: InputDecoration(
                      labelText: 'Puerto',
                      labelStyle: const TextStyle(color: _textLo, fontSize: 12),
                      filled: true,
                      fillColor: _bg,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _toggle,
                    style: FilledButton.styleFrom(
                        backgroundColor:
                            running ? _err : _accent),
                    icon: Icon(running ? Icons.stop : Icons.play_arrow,
                        size: 18),
                    label: Text(
                        _busy
                            ? '...'
                            : running
                                ? 'Detener'
                                : 'Arrancar servidor',
                        style: const TextStyle(color: Colors.white)),
                  ),
                ),
              ]),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(_error,
                    style: const TextStyle(color: _err, fontSize: 12.5)),
              ],
            ],
          ),
        ),
        _cardSection('Conectar desde otro equipo (p. ej. tu Windows)', [
          if (_ips.isNotEmpty)
            Text('IPs de este telefono:\n$_ips',
                style: const TextStyle(color: _textLo, fontSize: 12.5)),
          const SizedBox(height: 8),
          SelectableText(
            running
                ? 'ssh -p ${_svc.port} termxtr@<ip-del-telefono>'
                : 'ssh -p <puerto> termxtr@<ip-del-telefono>',
            style: const TextStyle(
                color: _textHi, fontSize: 13, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 6),
          const Text(
            'Cualquier nombre de usuario vale (aterrizas como el usuario de '
            'la app). Solo claves: la password nunca sirve. La shell es la '
            'de Android del usuario de la app.',
            style: TextStyle(color: _textLo, fontSize: 12.5),
          ),
        ]),
        _cardSection('Clave publica que autoriza el acceso', [
          Text(pubShort.isEmpty ? 'Generando identidad…' : pubShort,
              style: const TextStyle(color: _textLo, fontSize: 12)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _pubKey.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: _pubKey));
                    if (mounted) _toast('Copiada. Pegala en authorized_keys del cliente.');
                  },
            icon: const Icon(Icons.copy, size: 18, color: _accent),
            label: const Text('Copiar clave publica de la app',
                style: TextStyle(color: _accent)),
          ),
        ]),
        _cardSection('Log del servidor', [
          Text(_svc.log.isEmpty ? '(sin actividad)' : _svc.log,
              style: const TextStyle(
                  color: _textLo, fontSize: 11.5, fontFamily: 'monospace')),
        ]),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Text(
            'v2.16.0: el servidor vive mientras la app vive. Queda pendiente '
            'el servicio en primer plano (notificacion persistente) y el '
            'puente a las sesiones de la app (B2).',
            style: TextStyle(color: _textLo, fontSize: 11.5),
          ),
        ),
      ]),
    );
  }

  Widget _cardSection(String title, List<Widget> children) {
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
}
