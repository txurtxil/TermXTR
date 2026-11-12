// v2.37.0 — atajos de shell para la terminal: 'c' envia 'clear',
// 'l' envia 'ls -la', etc. Se expanden al pulsar Enter; la linea tecleada
// se borra en remoto con Ctrl-U antes de enviar la expansion.
// Persistente en aliases.json; desactivable con enabled=false.
import 'dart:convert';
import 'dart:io';

import '../storage/app_paths.dart';

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
      if (!f.existsSync()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is Map) {
        if (j['enabled'] == false) enabled = false;
        _map
          ..clear()
          ..addAll(defaults);
        final custom = j['aliases'];
        if (custom is Map) {
          custom.forEach((k, v) => _map[k.toString()] = v.toString());
        }
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

  static Map<String, String> get all => Map.unmodifiable(_map);
}
