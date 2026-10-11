// lib/src/ssh/known_hosts_screen.dart
//
// v2.10.1: gestion del known_hosts en JSON (mismo fichero que usan la
// terminal y SFTP: <appSupport>/xtr/ssh_known_hosts.json, clave
// "hostname:puerto" -> "tipo:huella_base64"). Lista, inspecciona y borra
// entradas. La politica de la app es accept-new: si una entrada no existe
// (o fue borrada), la primera conexion la acepta y guarda automaticamente;
// si la huella cambia frente a la guardada, la conexion se rechaza con
// mensaje explicito (ver _hostKeyRejectInfo en terminal_session.dart).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../storage/app_paths.dart';

class _C {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const err = Color(0xFFFF453A);
}

class KnownHostsScreen extends StatefulWidget {
  const KnownHostsScreen({super.key});

  @override
  State<KnownHostsScreen> createState() => _KnownHostsScreenState();
}

class _KnownHostsScreenState extends State<KnownHostsScreen> {
  Map<String, String> _entries = const {};
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var loaded = <String, String>{};
    try {
      final f = File('${AppPaths.base}/ssh_known_hosts.json');
      if (await f.exists()) {
        final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        loaded = map.map((k, v) => MapEntry(k, v as String));
      }
    } catch (_) {}
    final keys = loaded.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (mounted) {
      setState(() => _entries = {for (final k in keys) k: loaded[k]!});
    }
  }

  Future<void> _remove(String key) async {
    setState(() => _entries.remove(key));
    try {
      await File('${AppPaths.base}/ssh_known_hosts.json').writeAsString(jsonEncode(_entries));
    } catch (_) {}
  }

  Future<void> _confirmRemove(String key) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('Borrar huella guardada?', style: TextStyle(color: _C.textHi, fontSize: 15)),
        content: Text('$key\n\nLa proxima conexion volvera a aceptar y guardar la huella del servidor (accept-new).', style: const TextStyle(color: _C.textLo, fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar', style: TextStyle(color: _C.textLo))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Borrar', style: TextStyle(color: _C.err))),
        ],
      ),
    );
    if (ok == true) await _remove(key);
  }

  String _shortFp(String fp) => fp.length > 48 ? '${fp.substring(0, 28)}...${fp.substring(fp.length - 16)}' : fp;

  @override
  Widget build(BuildContext context) {
    final keys = _entries.keys.toList();
    return Scaffold(
      backgroundColor: _C.bg,
      appBar: AppBar(
        backgroundColor: _C.bg,
        elevation: 0,
        title: const Text('Hosts conocidos (SSH)', style: TextStyle(color: _C.textHi)),
        iconTheme: const IconThemeData(color: _C.textHi),
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text(
              'Huellas aceptadas al conectar (politica accept-new). Si una huella cambia en el servidor, borra la entrada y reconecta.',
              style: TextStyle(color: _C.textLo, fontSize: 12),
            ),
          ),
          Expanded(
            child: keys.isEmpty
                ? const Center(child: Text('Sin entradas todavia.', style: TextStyle(color: _C.textLo, fontSize: 13)))
                : ListView.builder(
                    itemCount: keys.length,
                    itemBuilder: (ctx, i) {
                      final k = keys[i];
                      final fp = _entries[k] ?? '';
                      final expanded = _expanded.contains(k);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ListTile(
                            dense: true,
                            title: Text(k, style: const TextStyle(color: _C.textHi, fontSize: 14)),
                            subtitle: Text(
                              expanded ? fp : _shortFp(fp),
                              style: const TextStyle(color: _C.textLo, fontSize: 11, fontFamily: 'monospace'),
                              maxLines: expanded ? null : 1,
                              overflow: expanded ? null : TextOverflow.ellipsis,
                            ),
                            onTap: () => setState(() => expanded ? _expanded.remove(k) : _expanded.add(k)),
                            onLongPress: () async {
                              await Clipboard.setData(ClipboardData(text: '$k $fp'));
                              if (ctx.mounted) {
                                ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Entrada copiada al portapapeles')));
                              }
                            },
                            trailing: IconButton(
                              tooltip: 'Borrar entrada',
                              icon: const Icon(Icons.delete_outline, color: _C.err, size: 20),
                              onPressed: () => _confirmRemove(k),
                            ),
                          ),
                          const Divider(height: 1, color: Color(0xFF2C2C2E)),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
