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
