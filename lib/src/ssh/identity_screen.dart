// lib/src/ssh/identity_screen.dart
//
// Pantalla de identidad SSH de la app (v2.2.0): ver/copiar la clave
// publica y regenerar el par. Una vez instalada en los hosts (menu de la
// lista de hosts) las conexiones no piden contraseña.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'identity_service.dart';

class _C {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const accent = Color(0xFF5E9BD6);
  static const err = Color(0xFFFF453A);
}

class IdentityScreen extends StatefulWidget {
  const IdentityScreen({super.key});

  @override
  State<IdentityScreen> createState() => _IdentityScreenState();
}

class _IdentityScreenState extends State<IdentityScreen> {
  String _pub = '';
  bool _generating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final p = await IdentityService.ensureIdentity();
      if (!mounted) return;
      setState(() {
        _pub = p;
        _generating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _generating = false;
      });
    }
  }

  Future<void> _copy() async {
    if (_pub.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _pub));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Clave publica copiada')));
  }

  Future<void> _regenerate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('¿Regenerar identidad?',
            style: TextStyle(color: _C.textHi)),
        content: const Text(
            'La clave actual dejara de funcionar en todos los hosts donde este instalada. Tendras que reinstalarla.',
            style: TextStyle(color: _C.textLo)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _C.err),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Regenerar')),
        ],
      ),
    );
    if (ok != true) return;
    await IdentityService.deleteIdentity();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.bg,
      appBar: AppBar(
        backgroundColor: _C.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: _C.textHi),
        title: const Text('Identidad SSH',
            style: TextStyle(color: _C.textHi, fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'Regenerar',
            icon: const Icon(Icons.refresh, color: _C.textLo),
            onPressed: _generating ? null : _regenerate,
          ),
        ],
      ),
      body: _generating
          ? const Center(
              child: CircularProgressIndicator(color: _C.accent))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!,
                        style: const TextStyle(color: _C.err)),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Text('Clave publica',
                        style: TextStyle(
                            color: _C.textHi,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(height: 6),
                    const Text(
                      'Instalala en los hosts desde el menu de cada host '
                      '(tres puntos > Enviar clave publica). A partir de '
                      'entonces las conexiones usaran esta clave y no '
                      'pediran contraseña.',
                      style: TextStyle(color: _C.textLo, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _C.card,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SelectableText(
                        _pub.isEmpty ? '(sin clave)' : _pub,
                        style: const TextStyle(
                          color: _C.textHi,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _pub.isEmpty ? null : _copy,
                      icon: const Icon(Icons.copy),
                      label: const Text('Copiar clave publica'),
                    ),
                  ],
                ),
    );
  }
}
