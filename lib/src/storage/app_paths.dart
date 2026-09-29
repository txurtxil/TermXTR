// lib/src/storage/app_paths.dart
//
// Rutas de almacenamiento de la app y migración desde el contenedor Debian
// (v14.24: la app deja de depender de proot/Debian; los datos que vivían en
// /root/.xtr y las claves de /root/.ssh se traen al almacenamiento privado).
//
// Base: <applicationSupportDirectory>/xtr  (el antiguo rootfs estaba en
// <applicationSupportDirectory>/debian, hermano de esta carpeta).
//
// Convención de las rutas relativas (mismo esquema que antes):
//   ssh_hosts.json, sftp_favorites.json, clipboard_history.jsonl,
//   ssh_known_hosts.json, sessions/, keys/

import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AppPaths {
  static String? _base;
  static String? _keysDir;

  /// Resuelve y crea la estructura. Idempotente.
  static Future<void> init() async {
    if (_base != null) return;
    final support = await getApplicationSupportDirectory();
    _base = '${support.path}/xtr';
    _keysDir = '$_base/keys';
    await Directory(keysDir).create(recursive: true);
    await Directory('$_base/sessions').create(recursive: true);
  }

  static String get base {
    final b = _base;
    if (b == null) {
      throw StateError('AppPaths.init() no se ha llamado todavía');
    }
    return b;
  }

  static String get keysDir {
    final k = _keysDir;
    if (k == null) {
      throw StateError('AppPaths.init() no se ha llamado todavía');
    }
    return k;
  }

  /// Claves importadas (nombre de fichero -> ruta absoluta).
  static Future<List<String>> listKeys() async {
    final dir = Directory(keysDir);
    if (!await dir.exists()) return [];
    final names = <String>[];
    await for (final e in dir.list()) {
      if (e is File && !e.path.endsWith('.pub')) {
        names.add(e.path.split('/').last);
      }
    }
    names.sort();
    return names;
  }

  /// Copia una clave elegida por el usuario (file_selector) al almacén de
  /// la app. Devuelve el nombre de fichero dentro de keysDir.
  static Future<String> importKey(File src) async {
    final name = src.path.split('/').last;
    await src.copy('$keysDir/$name');
    return name;
  }

  /// Migra datos del contenedor Debian si existe y aún no se ha migrado:
  ///   <support>/debian/root/.xtr/*   -> base/     (salvo sshpass_*, muertos)
  ///   <support>/debian/root/.ssh/*   -> keysDir/  (sin .pub)
  ///   keyPath "/root/.ssh/X" en hosts -> "/keys/X"
  /// Marca .migrated_v1424 para no repetirlo nunca.
  static Future<void> migrateLegacyData() async {
    final marker = File('$base/.migrated_v1424');
    if (await marker.exists()) return;
    try {
      final support = await getApplicationSupportDirectory();
      final old = Directory('${support.path}/debian');
      if (await old.exists()) {
        final xtr = Directory('${old.path}/root/.xtr');
        if (await xtr.exists()) {
          await for (final e in xtr.list()) {
            if (e is! File) continue;
            final name = e.path.split('/').last;
            if (name.startsWith('sshpass_')) continue; // residuo del hack antiguo
            try {
              await e.copy('$base/$name');
            } catch (_) {}
          }
        }
        final ssh = Directory('${old.path}/root/.ssh');
        if (await ssh.exists()) {
          await for (final e in ssh.list()) {
            if (e is! File || e.path.endsWith('.pub')) continue;
            try {
              await e.copy('$keysDir/${e.path.split('/').last}');
            } catch (_) {}
          }
        }
        // Reescribir keyPath legacy en el JSON de hosts migrado.
        final hostsFile = File('$base/ssh_hosts.json');
        if (await hostsFile.exists()) {
          try {
            var raw = await hostsFile.readAsString();
            raw = raw.replaceAll('"/root/.ssh/', '"/keys/');
            await hostsFile.writeAsString(raw);
          } catch (_) {}
        }
      }
    } catch (_) {}
    try {
      await marker.writeAsString('ok');
    } catch (_) {}
  }

  /// Resuelve un keyPath de host a un File real, con tolerancia a rutas
  /// legacy: '/keys/X' -> base/keys/X; '/root/.ssh/X' -> keysDir/X.
  static Future<File?> resolveKey(String keyPath) async {
    var f = File('$base$keyPath');
    if (await f.exists()) return f;
    if (keyPath.startsWith('/root/.ssh/')) {
      f = File('$keysDir/${keyPath.split('/').last}');
      if (await f.exists()) return f;
    }
    return null;
  }
}
