// lib/src/monitor/ghost_config.dart
// v2.18.8: configuracion POR HOST del widget de fondo (sombra fantasma):
// que metricas muestra (carga/disco/mem/sparklines) y que servicios systemd
// audita. Persistida en JSON; administrada desde la pantalla Monitor.

import 'dart:convert';
import 'dart:io';

import '../storage/app_paths.dart';

class GhostCfg {
  bool showLoad;
  bool showDisk;
  bool showMem;
  bool showSparks;
  bool showDirs;
  List<String> units;

  GhostCfg(
      {this.showLoad = true,
      this.showDisk = true,
      this.showMem = true,
      this.showSparks = true,
      this.showDirs = true,
      List<String>? units})
      : units = units ?? [];

  factory GhostCfg.fromJson(Map<String, dynamic> j) => GhostCfg(
        showLoad: j['load'] ?? true,
        showDisk: j['disk'] ?? true,
        showMem: j['mem'] ?? true,
        showSparks: j['sparks'] ?? true,
        showDirs: j['dirs'] ?? true,
        units: (j['units'] as List?)?.cast<String>() ?? const [],
      );

  Map<String, dynamic> toJson() =>
      {'load': showLoad, 'disk': showDisk, 'mem': showMem, 'sparks': showSparks, 'dirs': showDirs, 'units': units};
}

class GhostConfigStore {
  static Map<String, dynamic> _m = {};

  static Future<void> load() async {
    try {
      final f = File('${AppPaths.base}/ghost_config.json');
      if (await f.exists()) {
        _m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      }
    } catch (_) {}
  }

  static Future<void> _save() async {
    try {
      await File('${AppPaths.base}/ghost_config.json')
          .writeAsString(jsonEncode(_m), flush: true);
    } catch (_) {}
  }

  static Future<GhostCfg> forHost(String hostId) async {
    await load();
    final j = _m[hostId];
    return j == null ? GhostCfg() : GhostCfg.fromJson(j as Map<String, dynamic>);
  }

  static Future<void> put(String hostId, GhostCfg c) async {
    await load();
    _m[hostId] = c.toJson();
    await _save();
  }
}
