// lib/src/monitor/monitor_log.dart
// Log simple del Monitor (v2.18.1): cada consulta graba fase, comandos,
// salida cruda, duracion y errores en un fichero consultable desde la app.
// Rotacion suave: al superar 512 KB se recorta a las ultimas 500 lineas.

import 'dart:io';

import '../storage/app_paths.dart';

class MonitorLog {
  static File get _f => File('${AppPaths.base}/logs/monitor.log');

  static Future<void> write(String phase, String msg) async {
    try {
      final f = _f;
      await f.parent.create(recursive: true);
      final ts = DateTime.now().toIso8601String();
      final cut = msg.length > 1500 ? '${msg.substring(0, 1500)}...' : msg;
      await f.writeAsString('[$ts] $phase: $cut\n',
          mode: FileMode.append, flush: true);
      if (await f.length() > 512 * 1024) {
        final lines = await f.readAsLines();
        final keep =
            lines.length > 500 ? lines.sublist(lines.length - 500) : lines;
        await f.writeAsString('${keep.join('\n')}\n', flush: true);
      }
    } catch (_) {}
  }

  static Future<String> readLast({int maxLines = 300}) async {
    try {
      final f = _f;
      if (!await f.exists()) return '(sin log todavia)';
      final lines = await f.readAsLines();
      final slice =
          lines.length > maxLines ? lines.sublist(lines.length - maxLines) : lines;
      return slice.join('\n');
    } catch (e) {
      return '(error leyendo log: $e)';
    }
  }
}
