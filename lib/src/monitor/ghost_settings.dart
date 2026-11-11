// lib/src/monitor/ghost_settings.dart
// v2.21.1: nitidez + POSICION ARRASTRABLE del widget fantasma, persistidas
// en JSON (ghost_settings.json).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../storage/app_paths.dart';

class GhostSettings {
  static double opacity = 0.55;
  static double? posX;
  static double? posY;

  static Future<void> load() async {
    try {
      final f = File('${AppPaths.base}/ghost_settings.json');
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        opacity = ((m['opacity'] as num?)?.toDouble() ?? 0.55).clamp(0.15, 0.95);
        posX = (m['posX'] as num?)?.toDouble();
        posY = (m['posY'] as num?)?.toDouble();
      }
    } catch (_) {}
  }

  static Future<void> set(double v) async {
    opacity = v.clamp(0.15, 0.95);
    await _save();
  }

  /// Posicion arrastrada (null = defecto arriba-derecha).
  static Future<void> setPos(double? x, double? y) async {
    posX = x;
    posY = y;
    await _save();
  }

  static Future<void> _save() async {
    try {
      final m = <String, dynamic>{'opacity': opacity};
      if (posX != null && posY != null) {
        m['posX'] = posX;
        m['posY'] = posY;
      }
      await File('${AppPaths.base}/ghost_settings.json')
          .writeAsString(jsonEncode(m), flush: true);
    } catch (_) {}
  }
}

/// Bus manual de refresco de la sombra. El boton "Recargar" del Monitor
/// hace bump() y el widget fantasma reacciona (preview + polls).
class GhostRefreshBus {
  static final ValueNotifier<int> n = ValueNotifier<int>(0);
  static void bump() => n.value++;
}


/// v2.20.3: cache de metricas de la sombra (carga/disco/mem) por host.
class GhostMetricCache {
  static Map<String, dynamic> _m = {};

  static File get _f => File('${AppPaths.base}/ghost_metric_cache.json');

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

  static Future<String?> get(String hostId) async {
    await load();
    final e = _m[hostId] as Map<String, dynamic>?;
    if (e == null) return null;
    return [e['l'], e['d'], e['m']].join(String.fromCharCode(10));
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
