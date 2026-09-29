// lib/src/sftp/sftp_favorites_service.dart
//
// Rutas guardadas por host, mismo patron de persistencia JSON que ya usan
// SshHostsService y ClipboardVault: un fichero plano dentro del rootfs,
// facil de exportar/importar mas adelante.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../widget/widget_sync.dart';

class SftpFavorite {
  final String id;
  final String hostId;
  final String path;
  String label;

  SftpFavorite({
    required this.id,
    required this.hostId,
    required this.path,
    required this.label,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'hostId': hostId,
        'path': path,
        'label': label,
      };

  static SftpFavorite fromJson(Map<String, dynamic> j) => SftpFavorite(
        id: j['id'] as String,
        hostId: j['hostId'] as String,
        path: j['path'] as String,
        label: j['label'] as String? ?? j['path'] as String,
      );
}

class SftpFavoritesService extends ChangeNotifier {
  static final SftpFavoritesService instance = SftpFavoritesService._();
  SftpFavoritesService._();

  static const String _fileRel = '/sftp_favorites.json';

  String? _rootfsPath;
  final List<SftpFavorite> _favorites = [];

  List<SftpFavorite> forHost(String hostId) =>
      _favorites.where((f) => f.hostId == hostId).toList();

  /// Todos los favoritos (lo usa WidgetSync para el espejo del widget).
  List<SftpFavorite> get all => List<SftpFavorite>.unmodifiable(_favorites);

  bool isFavorite(String hostId, String path) =>
      _favorites.any((f) => f.hostId == hostId && f.path == path);

  Future<void> loadFrom(String rootfsPath) async {
    _rootfsPath = rootfsPath;
    try {
      final f = File('$rootfsPath$_fileRel');
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return;
      final list = jsonDecode(raw) as List<dynamic>;
      _favorites
        ..clear()
        ..addAll(list.map((e) => SftpFavorite.fromJson(e as Map<String, dynamic>)));
      notifyListeners();
      Future.microtask(WidgetSync.push);
    } catch (_) {}
  }

  Future<void> _persist() async {
    if (_rootfsPath == null) return;
    try {
      final f = File('$_rootfsPath$_fileRel');
      await f.parent.create(recursive: true);
      final list = _favorites.map((h) => h.toJson()).toList();
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(list));
    } catch (_) {}
    Future.microtask(WidgetSync.push);
  }

  Future<void> toggle(String hostId, String path) async {
    final existing = _favorites.where((f) => f.hostId == hostId && f.path == path);
    if (existing.isNotEmpty) {
      _favorites.removeWhere((f) => f.hostId == hostId && f.path == path);
    } else {
      final label = path == '.' ? '/' : '/$path';
      _favorites.add(SftpFavorite(
        id: '${DateTime.now().microsecondsSinceEpoch}',
        hostId: hostId,
        path: path,
        label: label,
      ));
    }
    notifyListeners();
    await _persist();
  }

  Future<void> remove(String id) async {
    _favorites.removeWhere((f) => f.id == id);
    notifyListeners();
    await _persist();
  }
}
