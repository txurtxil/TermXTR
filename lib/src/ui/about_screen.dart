// lib/src/ui/about_screen.dart
// v2.20.1: "Acerca de" con la estructura del Acerca de de LMB10: nombre +
// version, tagline, AUTOR (SurferRule), LICENCIA y enlaces (adaptados a
// TermXTR; sin dependencia url_launcher: los enlaces son seleccionables).

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
        .then((p) => setState(() => _v = 'v${p.version}'))
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
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Text('TermXTR',
              style: TextStyle(
                  color: _C.textHi,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Text(_v,
              style: const TextStyle(color: _C.textLo, fontSize: 13)),
        ]),
        const SizedBox(height: 10),
        const Center(
            child: Text(
                'La navaja suiza del administrador de sistemas: SSH/SFTP con\nclaves, ProxyJump, Wake-on-LAN, Monitor de sistemas (Linux y\nOracle) y sombra fantasma. Solo consultas: nada instalado\nen los servidores.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _C.textLo, fontSize: 12))),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: _C.card, borderRadius: BorderRadius.circular(10)),
          child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('AUTOR',
                    style: TextStyle(
                        color: _C.accent,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1)),
                SizedBox(height: 4),
                Text('SurferRule',
                    style: TextStyle(color: _C.textHi, fontSize: 13)),
                SizedBox(height: 12),
                Text('LICENCIA',
                    style: TextStyle(
                        color: _C.accent,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1)),
                SizedBox(height: 4),
                Text(
                    'Codigo propio del autor. Incluye Flutter, dartssh2, '
                    'xterm.dart, cryptography, device_info_plus y '
                    'package_info_plus (sus licencias MIT/BSD aplican).',
                    style: TextStyle(color: _C.textLo, fontSize: 12)),
                SizedBox(height: 12),
                Text('ENLACES',
                    style: TextStyle(
                        color: _C.accent,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1)),
                SizedBox(height: 6),
                SelectableText(
                    'Repositorio:  github.com/txurtxil/TermXTR',
                    style: TextStyle(
                        color: _C.accent,
                        fontSize: 12,
                        fontFamily: 'monospace')),
                SelectableText(
                    'Releases:      github.com/txurtxil/TermXTR/releases',
                    style: TextStyle(
                        color: _C.accent,
                        fontSize: 12,
                        fontFamily: 'monospace')),
                SelectableText(
                    'Ko-fi:         ko-fi.com/txurtxil',
                    style: TextStyle(
                        color: _C.accent,
                        fontSize: 12,
                        fontFamily: 'monospace')),
              ]),
        ),
      ]),
    );
  }
}
