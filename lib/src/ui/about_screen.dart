// lib/src/ui/about_screen.dart
// v2.20.0: pantalla "Acerca de" — version, descripcion, repo y licencias.

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

class _C {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const accent = Color(0xFF5E9BD6);
}

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});
  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String _v = '';
  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform()
        .then((p) => setState(() => _v = 'v${p.version} (build ${p.buildNumber})'))
        .catchError((_) => setState(() => _v = ''));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.bg,
      appBar: AppBar(
        backgroundColor: _C.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: _C.textHi),
        title: const Text('Acerca de',
            style: TextStyle(color: _C.textHi, fontSize: 16)),
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Center(
            child: Text('TermXTR',
                style: TextStyle(
                    color: _C.textHi,
                    fontSize: 28,
                    fontWeight: FontWeight.w700))),
        const SizedBox(height: 4),
        Center(
            child: Text(_v.isEmpty ? '' : _v,
                style: const TextStyle(color: _C.accent, fontSize: 13))),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: _C.card, borderRadius: BorderRadius.circular(10)),
          child: const Text(
            'Cliente SSH/SFTP con identidad de claves, ProxyJump, Wake-on-LAN, '
            'Monitor de sistemas (Linux y Oracle) y widget de fondo fantasma. '
            'La navaja suiza del administrador de sistemas: todo por SSH, '
            'sin instalar nada en los servidores.',
            style: TextStyle(color: _C.textLo, fontSize: 13),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: _C.card, borderRadius: BorderRadius.circular(10)),
          child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Repositorio',
                    style: TextStyle(
                        color: _C.textHi, fontWeight: FontWeight.w600)),
                SizedBox(height: 6),
                SelectableText('github.com/txurtxil/TermXTR',
                    style: TextStyle(
                        color: _C.accent,
                        fontSize: 13,
                        fontFamily: 'monospace')),
                SizedBox(height: 10),
                Text('Licencias',
                    style: TextStyle(
                        color: _C.textHi, fontWeight: FontWeight.w600)),
                SizedBox(height: 6),
                Text(
                    'Codigo propio bajo licencia del autor. Incluye software de '
                    'terceros: Flutter, dartssh2, xterm.dart, cryptography y '
                    'device_info_plus (sus licencias MIT/BSD aplican).',
                    style: TextStyle(color: _C.textLo, fontSize: 12)),
              ]),
        ),
      ]),
    );
  }
}
