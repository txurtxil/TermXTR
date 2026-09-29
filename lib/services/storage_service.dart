import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/host_profile.dart';

/// Persistencia simple en JSON dentro del directorio de documentos de la app.
/// Evita anadir dependencias nuevas: path_provider ya esta en pubspec.
class StorageService {
  static final StorageService instance = StorageService._();
  StorageService._();

  Directory? _docs;
  List<HostProfile>? _hostsCache;
  AppSettings? _settingsCache;

  Future<Directory> get docs async {
    if (_docs != null) return _docs!;
    _docs = await getApplicationDocumentsDirectory();
    return _docs!;
  }

  Future<File> get _hostsFile async =>
      File('${(await docs).path}/hosts.json');

  Future<File> get _settingsFile async =>
      File('${(await docs).path}/settings.json');

  // ---------------- Hosts ----------------

  Future<List<HostProfile>> loadHosts() async {
    if (_hostsCache != null) return _hostsCache!;
    try {
      final f = await _hostsFile;
      if (!await f.exists()) {
        _hostsCache = [];
        return _hostsCache!;
      }
      final list = jsonDecode(await f.readAsString()) as List<dynamic>;
      _hostsCache = list
          .map((e) => HostProfile.fromJson(e as Map<String, dynamic>))
          .whereType<HostProfile>()
          .toList();
    } catch (_) {
      _hostsCache = [];
    }
    return _hostsCache!;
  }

  Future<void> _saveHosts() async {
    final f = await _hostsFile;
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(
        jsonEncode(_hostsCache!.map((h) => h.toJson()).toList()));
    await tmp.rename(f.path);
  }

  Future<void> addHost(HostProfile host) async {
    await loadHosts();
    _hostsCache!.add(host);
    await _saveHosts();
  }

  Future<void> updateHost(HostProfile host) async {
    await loadHosts();
    final i = _hostsCache!.indexWhere((h) => h.id == host.id);
    if (i >= 0) _hostsCache![i] = host;
    await _saveHosts();
  }

  Future<void> deleteHost(String id) async {
    await loadHosts();
    _hostsCache!.removeWhere((h) => h.id == id);
    await _saveHosts();
  }

  Future<void> touchHost(String id) async {
    await loadHosts();
    final i = _hostsCache!.indexWhere((h) => h.id == id);
    if (i >= 0) {
      _hostsCache![i] = _hostsCache![i]
          .copyWith(lastConnected: DateTime.now().millisecondsSinceEpoch);
      await _saveHosts();
    }
  }

  // ---------------- Settings ----------------

  Future<AppSettings> loadSettings() async {
    if (_settingsCache != null) return _settingsCache!;
    try {
      final f = await _settingsFile;
      if (await f.exists()) {
        _settingsCache =
            AppSettings.fromJson(jsonDecode(await f.readAsString()));
      }
    } catch (_) {}
    _settingsCache ??= const AppSettings();
    return _settingsCache!;
  }

  Future<void> saveSettings(AppSettings s) async {
    _settingsCache = s;
    final f = await _settingsFile;
    await f.writeAsString(jsonEncode(s.toJson()));
  }
}

class AppSettings {
  final bool darkTheme; // false = claro
  final double terminalFontSize;

  const AppSettings({
    this.darkTheme = true,
    this.terminalFontSize = 14,
  });

  AppSettings copyWith({bool? darkTheme, double? terminalFontSize}) =>
      AppSettings(
        darkTheme: darkTheme ?? this.darkTheme,
        terminalFontSize: terminalFontSize ?? this.terminalFontSize,
      );

  Map<String, dynamic> toJson() =>
      {'darkTheme': darkTheme, 'terminalFontSize': terminalFontSize};

  static AppSettings fromJson(dynamic j) {
    if (j is! Map) return const AppSettings();
    return AppSettings(
      darkTheme: j['darkTheme'] != false,
      terminalFontSize: (j['terminalFontSize'] is num)
          ? (j['terminalFontSize'] as num).toDouble()
          : 14,
    );
  }
}
