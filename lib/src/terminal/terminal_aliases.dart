// v2.37.0/2.38.0 — atajos de shell para la terminal: 'c' envia 'clear',
// 'l' envia 'ls -la', etc. Se expanden al pulsar Enter; la linea tecleada
// se borra en remoto con Ctrl-U antes de enviar la expansion.
// Persistente en aliases.json; gestionable desde Utilidades > Atajos de shell.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../storage/app_paths.dart';
import '../ui/app_theme.dart';

class TerminalAliases {
  static final Map<String, String> _map = {...defaults};
  static bool enabled = true;
  static bool _loaded = false;

  static const defaults = <String, String>{
    'c': 'clear',
    'l': 'ls -la',
    'll': 'ls -l',
    'lt': 'ls -ltr',
    'p': 'pwd',
    'd': 'df -h',
    'f': 'free -h',
    's': 'ss -tuln',
    'h': 'history',
  };

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File('${AppPaths.base}/aliases.json');
      if (!f.existsSync()) {
        await save();
        return;
      }
      final j = jsonDecode(await f.readAsString());
      if (j is Map) {
        enabled = j['enabled'] != false;
        _map.clear();
        final a = j['aliases'];
        if (a is Map) {
          a.forEach((k, v) => _map[k.toString()] = v.toString());
        }
        if (_map.isEmpty) _map.addAll(defaults);
      }
    } catch (_) {}
  }

  static Future<void> save() async {
    try {
      final f = File('${AppPaths.base}/aliases.json');
      await f.writeAsString(jsonEncode({'enabled': enabled, 'aliases': _map}));
    } catch (_) {}
  }

  /// Devuelve la expansion si [typed] es SOLO un atajo (sin espacios/args).
  static String? match(String typed) {
    if (!enabled || typed.isEmpty || typed.contains(' ')) return null;
    return _map[typed];
  }

  static Future<void> setEnabled(bool v) async {
    enabled = v;
    await save();
  }

  static Future<void> upsert(String k, String v) async {
    _map[k] = v;
    await save();
  }

  static Future<void> remove(String k) async {
    _map.remove(k);
    await save();
  }

  static Map<String, String> get all => Map.unmodifiable(_map);
}

// ---------------------------------------------------------------------------
// UI de gestion (Utilidades > Atajos de shell)
// ---------------------------------------------------------------------------
Future<void> showAliasesManager(BuildContext context) async {
  await TerminalAliases.ensureLoaded();
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.card,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final entries = TerminalAliases.all.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.6,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
                  child: Row(
                    children: [
                      const Icon(Icons.keyboard, color: AppColors.accent),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('Atajos de shell',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textHi)),
                      ),
                      IconButton(
                        tooltip: 'Nuevo atajo',
                        icon: const Icon(Icons.add, color: AppColors.accent),
                        onPressed: () async {
                          final r = await _aliasDialog(ctx);
                          if (r != null) {
                            await TerminalAliases.upsert(r.$1, r.$2);
                            setSheet(() {});
                          }
                        },
                      ),
                    ],
                  ),
                ),
                SwitchListTile(
                  dense: true,
                  value: TerminalAliases.enabled,
                  activeColor: AppColors.accent,
                  title: const Text('Atajos activos',
                      style: TextStyle(color: AppColors.textHi, fontSize: 13)),
                  subtitle: const Text(
                      'Al pulsar Enter, si la línea es un atajo se envía la expansión',
                      style:
                          TextStyle(color: AppColors.textLo, fontSize: 11)),
                  onChanged: (v) async {
                    await TerminalAliases.setEnabled(v);
                    setSheet(() {});
                  },
                ),
                const Divider(color: AppColors.border),
                Expanded(
                  child: ListView(
                    children: [
                      for (final e in entries)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.arrow_forward,
                              color: AppColors.textLo, size: 16),
                          title: Text(e.key,
                              style: const TextStyle(
                                  color: AppColors.accent,
                                  fontFamily: 'monospace',
                                  fontSize: 13)),
                          subtitle: Text(e.value,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: AppColors.textLo, fontSize: 11)),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline,
                                color: AppColors.err, size: 18),
                            onPressed: () async {
                              await TerminalAliases.remove(e.key);
                              setSheet(() {});
                            },
                          ),
                          onTap: () async {
                            final r = await _aliasDialog(ctx,
                                initialKey: e.key, initialCmd: e.value);
                            if (r != null) {
                              if (r.$1 != e.key) {
                                await TerminalAliases.remove(e.key);
                              }
                              await TerminalAliases.upsert(r.$1, r.$2);
                              setSheet(() {});
                            }
                          },
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    ),
  );
}

Future<(String, String)?> _aliasDialog(BuildContext ctx,
    {String initialKey = '', String initialCmd = ''}) async {
  final keyCtrl = TextEditingController(text: initialKey);
  final cmdCtrl = TextEditingController(text: initialCmd);
  return showDialog<(String, String)>(
    context: ctx,
    builder: (dctx) => AlertDialog(
      backgroundColor: AppColors.card,
      title: Text(initialKey.isEmpty ? 'Nuevo atajo' : 'Editar atajo',
          style: const TextStyle(color: AppColors.textHi, fontSize: 15)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: keyCtrl,
            style: const TextStyle(
                color: AppColors.textHi, fontFamily: 'monospace'),
            decoration: const InputDecoration(
                labelText: 'Atajo (una palabra, sin espacios)',
                labelStyle: TextStyle(color: AppColors.textLo)),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: cmdCtrl,
            maxLines: 2,
            style: const TextStyle(color: AppColors.textHi, fontSize: 12),
            decoration: const InputDecoration(
                labelText: 'Comando',
                labelStyle: TextStyle(color: AppColors.textLo)),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dctx),
          child: const Text('Cancelar',
              style: TextStyle(color: AppColors.textLo)),
        ),
        FilledButton(
          onPressed: () {
            final k = keyCtrl.text.trim();
            final v = cmdCtrl.text.trim();
            if (k.isEmpty || v.isEmpty || k.contains(' ')) return;
            Navigator.pop(dctx, (k, v));
          },
          child: const Text('Guardar'),
        ),
      ],
    ),
  );
}
