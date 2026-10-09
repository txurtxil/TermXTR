// lib/src/ssh/ssh_hosts_service.dart
//
// Guarda y carga la lista de hosts. Mismo patron que ClipboardVault: un
// singleton (la lista de hosts es global, tiene sentido verla igual desde
// cualquier pestana), persistido en un JSON plano dentro del propio rootfs
// para poder exportar/importar sin fricciones mas adelante.
//
// v2.10.0: los grupos son un campo mas de cada host (SshHost.group). Los
// colores de grupo viven en /ssh_groups.json ({"Nombre": 4281234567}) para
// no cambiar el formato del JSON de hosts, que ya consumen otras piezas
// (backup v2.4.0, widget de escritorio...).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'ssh_host.dart';
import '../widget/widget_sync.dart';

class SshHostsService extends ChangeNotifier {
  static final SshHostsService instance = SshHostsService._();
  SshHostsService._();

  static const String _fileRel = '/ssh_hosts.json';
  static const String _groupsFileRel = '/ssh_groups.json';

  String? _rootfsPath;
  final List<SshHost> _hosts = [];
  final Map<String, int> _groupColors = {};

  /// Mas usado recientemente primero; sin uso, alfabetico. Igual que
  /// cualquier lista de hosts SSH que se precie.
  List<SshHost> get hosts {
    final list = List<SshHost>.from(_hosts);
    list.sort((a, b) {
      if (a.lastUsed != null && b.lastUsed != null) {
        return b.lastUsed!.compareTo(a.lastUsed!);
      }
      if (a.lastUsed != null) return -1;
      if (b.lastUsed != null) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  /// Nombres de grupo unicos (sin null), ordenados alfabeticamente.
  List<String> get groupNames {
    final set = <String>{};
    for (final h in _hosts) {
      final g = h.group;
      if (g != null && g.isNotEmpty) set.add(g);
    }
    final list = set.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  /// Hosts de un grupo concreto ('' = sin grupo). Mismo orden que [hosts].
  List<SshHost> hostsInGroup(String group) {
    final list = hosts.where((h) => (h.group ?? '') == group).toList();
    return list;
  }

  /// Paleta determinista para grupos sin color guardado. Mismo nombre =>
  /// mismo color siempre, incluso tras reinstalar o importar en otro sitio.
  static const palette = [
    0xFF5E9BD6, 0xFF34C759, 0xFFFF9F0A, 0xFFFF453A, 0xFFBF5AF2,
    0xFF64D2FF, 0xFF30B0C7, 0xFFAC8E68, 0xFF0A84FF, 0xFFFF375F,
  ];

  /// Color ARGB de un grupo: el guardado en ssh_groups.json o uno
  /// determinista derivado del nombre.
  int groupColor(String group) {
    final saved = _groupColors[group];
    if (saved != null) return saved;
    return palette[group.hashCode.abs() % palette.length];
  }

  Future<void> loadFrom(String rootfsPath) async {
    _rootfsPath = rootfsPath;
    try {
      final f = File('$rootfsPath$_fileRel');
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return;
      final list = jsonDecode(raw) as List<dynamic>;
      _hosts
        ..clear()
        ..addAll(list.map((e) => SshHost.fromJson(e as Map<String, dynamic>)));
      notifyListeners();
      // Espejo para el widget de escritorio (fire-and-forget).
      Future.microtask(WidgetSync.push);
    } catch (_) {
      // JSON corrupto o ilegible: se sigue con la lista vacia en vez de
      // tirar la pantalla de hosts abajo por un fichero roto.
    }
    try {
      final gf = File('$rootfsPath$_groupsFileRel');
      _groupColors.clear();
      if (await gf.exists()) {
        final raw = await gf.readAsString();
        if (raw.trim().isNotEmpty) {
          final map = jsonDecode(raw) as Map<String, dynamic>;
          map.forEach((k, v) {
            if (v is num) _groupColors[k] = v.toInt();
          });
        }
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _persist() async {
    if (_rootfsPath == null) return;
    try {
      final f = File('$_rootfsPath$_fileRel');
      await f.parent.create(recursive: true);
      final list = _hosts.map((h) => h.toJson()).toList();
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(list));
    } catch (_) {}
    try {
      final gf = File('$_rootfsPath$_groupsFileRel');
      await gf.writeAsString(const JsonEncoder.withIndent('  ').convert(_groupColors));
    } catch (_) {}
    // Espejo para el widget de escritorio (fire-and-forget).
    Future.microtask(WidgetSync.push);
  }

  Future<void> add(SshHost host) async {
    _hosts.add(host);
    notifyListeners();
    await _persist();
  }

  Future<void> update(SshHost host) async {
    final i = _hosts.indexWhere((h) => h.id == host.id);
    if (i == -1) return;
    _hosts[i] = host;
    notifyListeners();
    await _persist();
  }

  Future<void> remove(String id) async {
    _hosts.removeWhere((h) => h.id == id);
    notifyListeners();
    await _persist();
  }

  Future<void> touch(String id) async {
    final i = _hosts.indexWhere((h) => h.id == id);
    if (i == -1) return;
    _hosts[i].lastUsed = DateTime.now();
    notifyListeners();
    await _persist();
  }

  /// v2.10.0: asigna/limpia el grupo de un host.
  Future<void> assignGroup(String hostId, String? group) async {
    final i = _hosts.indexWhere((h) => h.id == hostId);
    if (i == -1) return;
    final g = (group == null || group.trim().isEmpty) ? null : group.trim();
    if ((_hosts[i].group ?? '') == (g ?? '')) return;
    _hosts[i].group = g;
    notifyListeners();
    await _persist();
  }

  /// v2.10.0: renombra un grupo en todos sus hosts y traslada su color.
  Future<void> renameGroup(String oldName, String newName) async {
    final target = newName.trim();
    if (oldName == target || target.isEmpty) return;
    for (final h in _hosts) {
      if (h.group == oldName) h.group = target;
    }
    final color = _groupColors.remove(oldName);
    if (color != null) _groupColors[target] = color;
    notifyListeners();
    await _persist();
  }

  /// v2.10.0: elimina un grupo; sus hosts pasan a "sin grupo". El color
  /// guardado se conserva por si el grupo se recrea.
  Future<void> deleteGroup(String name) async {
    for (final h in _hosts) {
      if (h.group == name) h.group = null;
    }
    notifyListeners();
    await _persist();
  }

  /// v2.10.0: fija el color ARGB de un grupo.
  Future<void> setGroupColor(String name, int argb) async {
    _groupColors[name] = argb;
    notifyListeners();
    await _persist();
  }

  String newId() => '${DateTime.now().microsecondsSinceEpoch}';
}
