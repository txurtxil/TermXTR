// lib/src/terminal/command_history.dart
//
// v2.5.0: historial de comandos por host (persistido en JSON) con
// sugerencia estilo fish: el primer comando del historial que empieza
// por lo tecleado, distinto del propio prefijo.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../storage/app_paths.dart';

class CommandHistory {
  static const _maxEntries = 500;
  static final _cache = <String, List<String>>{};

  static File _f(String hostId) {
    final safe =
        hostId.replaceAll(RegExp('[^a-zA-Z0-9_-]'), '_');
    return File('${AppPaths.base}/cmdhist_$safe.json');
  }

  static Future<List<String>> load(String hostId) async {
    if (_cache.containsKey(hostId)) return _cache[hostId]!;
    try {
      final f = _f(hostId);
      if (await f.exists()) {
        final list = jsonDecode(await f.readAsString()) as List;
        _cache[hostId] =
            list.map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return _cache.putIfAbsent(hostId, () => []);
  }

  static Future<void> add(String hostId, String cmd) async {
    final list = await load(hostId);
    list.remove(cmd);
    list.insert(0, cmd);
    if (list.length > _maxEntries) {
      list.removeRange(_maxEntries, list.length);
    }
    unawaited(_save(hostId));
  }

  static Future<void> _save(String hostId) async {
    try {
      await _f(hostId)
          .writeAsString(jsonEncode(_cache[hostId] ?? []), flush: true);
    } catch (_) {}
  }

  /// Primera entrada que empieza por [prefix] y es distinta de el.
  static String? suggest(String hostId, String prefix) {
    final list = _cache[hostId];
    if (list == null || prefix.isEmpty) return null;
    for (final c in list) {
      if (c.startsWith(prefix) && c != prefix) return c;
    }
    return null;
  }
}
