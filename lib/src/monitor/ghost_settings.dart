// lib/src/monitor/ghost_settings.dart
// v2.18.6: nitidez configurable de la sombra fantasma (opacidad del texto),
// ajustable desde el Monitor y persistida en JSON.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'dart:io';

import '../storage/app_paths.dart';

class GhostSettings {
  static double opacity = 0.55;

  static Future<void> load() async {
    try {
      final f = File('${AppPaths.base}/ghost_settings.json');
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        opacity = ((m['opacity'] as num?)?.toDouble() ?? 0.55).clamp(0.15, 0.95);
      }
    } catch (_) {}
  }

  static Future<void> set(double v) async {
    opacity = v.clamp(0.15, 0.95);
    try {
      await File('${AppPaths.base}/ghost_settings.json')
          .writeAsString(jsonEncode({'opacity': opacity}), flush: true);
    } catch (_) {}
  }
}

/// v2.20.2: bus manual de refresco de la sombra. El boton "Recargar" del
/// Monitor hace bump() y el widget fantasma reacciona (preview + polls).
class GhostRefreshBus {
  static final ValueNotifier<int> n = ValueNotifier<int>(0);
  static void bump() => n.value++;
}

/// v2.20.3: cache de las metricas de la sombra (carga/disco/mem) por host:
/// la sombra pinta AL INSTANTE lo ultimo conocido aunque el SSH aun este
/// conectando, y el poll en vivo lo refresca segundos despues.
class GhostMetricCache {
  static Map<String, dynamic> _m = {};

  static File get _f => File('\${AppPaths.base}/ghost_metric_cache.json');

  static Future<void> load() async {
    try {
      if (await _f.exists()) {
        _m = jsonDecode(await _f.readAsString()) as Map<String, dynamic>;
      }
    } catch (_) {}
  }

  static Future<void> save() async {
    try {
      await _f.writeAsString(jsonEncode(_m), flush: true);
    } catch (_) {}
  }

  /// Devuelve las tres lineas crudas (carga, disco, mem) como las espera
  /// el widget, o null si no hay nada guardado para ese host.
  static Future<String?> get(String hostId) async {
    await load();
    final e = _m[hostId] as Map<String, dynamic>?;
    if (e == null) return null;
    return '\${e['l']}\n\${e['d']}\n\${e['m']}';
  }

  static Future<void> put(
      String hostId, String l, String d, String m) async {
    await load();
    _m[hostId] = {
      'l': l,
      'd': d,
      'm': m,
      'ts': DateTime.now().millisecondsSinceEpoch,
    };
    await save();
  }
}
