// lib/src/ssh/ssh_hosts_service.dart
//
// Guarda y carga la lista de hosts. Mismo patron que ClipboardVault: un
// singleton (la lista de hosts es global, tiene sentido verla igual desde
// cualquier pestana), persistido en un JSON plano dentro del propio rootfs
// para poder exportar/importar sin fricciones mas adelante.

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

  String? _rootfsPath;
  final List<SshHost> _hosts = [];

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
  }

  Future<void> _persist() async {
    if (_rootfsPath == null) return;
    try {
      final f = File('$_rootfsPath$_fileRel');
      await f.parent.create(recursive: true);
      final list = _hosts.map((h) => h.toJson()).toList();
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(list));
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

  String newId() => '${DateTime.now().microsecondsSinceEpoch}';
}
