// lib/src/monitor/monitor_service.dart
// Servicio del Monitor de sistemas (v2.18.8). Comandos read-only por SSH;
// nada instalado en el servidor. Dos fases: fetch() (sistema, rapido) y
// fetchDirs() (directorios, segundo plano). v2.18.8: fix parseo df (se
// descarta la cabecera y se limpia el % de Use%) + servicios auditados
// (unidades configurables por host en la sombra/Monitor).

import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import '../ssh/identity_service.dart';
import '../ssh/ssh_credentials_store.dart';
import '../ssh/ssh_connector.dart';
import '../ssh/ssh_host.dart';
import '../sftp/sftp_favorites_service.dart';
import '../storage/app_paths.dart';
import 'ghost_config.dart';
import 'monitor_log.dart';
import 'monitor_models.dart';

Future<void> dirCacheLoad() async {
  try {
    final f = File('${AppPaths.base}/monitor_dir_cache.json');
    if (await f.exists()) {
      _dirCache = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    }
  } catch (_) {}
}

Future<void> dirCacheSave() async {
  try {
    await File('${AppPaths.base}/monitor_dir_cache.json')
        .writeAsString(jsonEncode(_dirCache), flush: true);
  } catch (_) {}
}

Map<String, dynamic> _dirCache = {};
const _cacheMax = 200;

Future<void> dirCachePut(String hostId, String path, double bytes) async {
  _dirCache[hostId] ??= <String, dynamic>{};
  final m = _dirCache[hostId] as Map<String, dynamic>;
  m[path] = {'bytes': bytes, 'ts': DateTime.now().millisecondsSinceEpoch};
  if (m.length > _cacheMax) {
    final keys = m.keys.toList();
    for (final k in keys.take(m.length - _cacheMax)) {
      m.remove(k);
    }
  }
  await dirCacheSave();
}

double? dirCacheGet(String hostId, String path) {
  try {
    final e = (_dirCache[hostId] as Map<String, dynamic>?)?[path]
        as Map<String, dynamic>?;
    final v = e?['bytes'];
    return v is num ? v.toDouble() : null;
  } catch (_) {
    return null;
  }
}

String dirCacheAge(String hostId, String path) {
  try {
    final e = (_dirCache[hostId] as Map<String, dynamic>?)?[path]
        as Map<String, dynamic>?;
    final ts = e?['ts'] as int?;
    if (ts == null) return '';
    final diff = DateTime.now().millisecondsSinceEpoch - ts;
    final m = (diff / 60000).round();
    return m < 60 ? '${m}m' : '${(m / 60).round()}h';
  } catch (_) {
    return '';
  }
}

// v2.20.0: historial local de metricas (JSONL en el movil). Cada fetch
// guarda % de discos y bytes de directorios -> tendencias por fechas sin
// instalar nada en el servidor. Rotacion suave a 2 MB.
File get _samplesFile => File('\${AppPaths.base}/monitor_samples.jsonl');

Future<void> sampleAppend(
    String hostId, Map<String, double> mounts, Map<String, double> dirs) async {
  try {
    final rec = jsonEncode({
      'ts': DateTime.now().millisecondsSinceEpoch,
      'h': hostId,
      'm': mounts,
      'd': dirs,
    });
    final f = _samplesFile;
    await f.writeAsString('\$rec\n', mode: FileMode.append, flush: true);
    if (await f.length() > 2 * 1024 * 1024) {
      final lines = await f.readAsLines();
      await f.writeAsString(lines.sublist(lines.length ~/ 2).join('\n') + '\n');
    }
  } catch (_) {}
}

Future<List<Map<String, dynamic>>> sampleQuery(
    String hostId, String kind, String key, int sinceMs) async {
  try {
    final f = _samplesFile;
    if (!await f.exists()) return const [];
    final byTs = <int, double>{};
    for (final l in await f.readAsLines()) {
      try {
        final r = jsonDecode(l) as Map<String, dynamic>;
        if (r['h'] != hostId) continue;
        final ts = r['ts'] as int;
        if (ts < sinceMs) continue;
        final v = (r[kind == 'mount' ? 'm' : 'd'] as Map<String, dynamic>?)?[key];
        if (v is num) byTs[ts] = v.toDouble();
      } catch (_) {}
    }
    final ts = byTs.keys.toList()..sort();
    return [for (final k in ts) {'ts': k, 'v': byTs[k]}];
  } catch (_) {
    return const [];
  }
}

Future<void> sampleBackfill(
    String hostId, String path, Map<int, double> monthCumBytes) async {
  for (final e in monthCumBytes.entries) {
    try {
      final rec = jsonEncode({
        'ts': e.key,
        'h': hostId,
        'd': {path: e.value},
        'backfilled': true,
      });
      await _samplesFile.writeAsString('\$rec\n',
          mode: FileMode.append, flush: true);
    } catch (_) {}
  }
}


class MonitorService {
  static const _dirs = ['/var', '/opt', '/tmp'];

  static String _normPath(String p) {
    var s0 = p.replaceAll(RegExp(r'/+'), '/');
    if (s0.length > 1) s0 = s0.replaceAll(RegExp(r'/$'), '');
    return s0.isEmpty ? '/' : s0;
  }

  
  /// Fase 1 (rapida): sistema + discos + servicios + oracle + unidades
  /// auditadas del host. Sin du.
  static Future<MonitorSnapshot> fetch(SshHost host,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final conn = await SshConnector.connect(host);
    try {
      final t0 = DateTime.now();
      MonitorLog.write('monitor',
          'fetch ${host.name} (${host.username}@${host.hostname}:${host.port})');
      final snap = MonitorSnapshot(
          ts: DateTime.now(),
          oracle: OracleInfo(present: false),
          fs: <FsInfo>[],
          dirs: <DirInfo>[],
          failedNames: <String>[],
          unitStates: <String, String>{});
      final cfg = await GhostConfigStore.forHost(host.id);

      // v2.18.8: el printf del awk lleva barra-n (sin ella el marcador
      // siguiente se pegaba y la memoria parseaba 0.0%).
      var core = r"""
LC_ALL=C; export LC_ALL
echo __TX_DF__
df -hP -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs
echo __TX_LOAD__
cut -d' ' -f1-3 /proc/loadavg
echo __TX_MEM__
awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%d\n",(t-a)/t*100}' /proc/meminfo
echo __TX_FAIL__
systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $2}' | head -5
echo __TX_ACTIVE__
systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | wc -l
echo __TX_UNITS__
for u in @@UNITS@@; do printf "%s %s
" "$u" "$(systemctl is-active $u 2>/dev/null)"; done
echo __TX_OH__
command -v sqlplus >/dev/null 2>&1 && echo yes || echo no
echo __TX_END__
""";
      if (cfg.units.isEmpty) {
        core = core.replaceAll('for u in @@UNITS@@; do', 'for u in; do');
      } else {
        core = core.replaceAll(
            '@@UNITS@@', cfg.units.map((e) => '"$e"').join(' '));
      }
      final coreRaw = utf8.decode(await conn.c.run(core).timeout(timeout),
          allowMalformed: true);
      MonitorLog.write('core', coreRaw.trim());
      _parseCore(snap, coreRaw);
      snap.failedUnits = snap.failedNames.length;
      await sampleAppend(host.id,
          {for (final f in snap.fs) f.mount: f.pct}, const {});

      if (snap.oracle.present) {
        const oh = r"""
pgrep -f ora_pmon_ >/dev/null 2>&1 && echo TX_UP || echo TX_DOWN
command -v lsnrctl >/dev/null 2>&1 && { lsnrctl status >/dev/null 2>&1 && echo TX_LUP || echo TX_LDOWN; } || echo TX_LNA
sqlplus -s / as sysdba <<'EOS' 2>/dev/null
set pages 0 feed off head off
select tablespace_name||' '||round(used_percent,1) from dba_tablespace_usage_metrics order by 2 desc fetch first 8 rows only;
EOS
""";
        try {
          final ohRaw =
              utf8.decode(await conn.c.run(oh).timeout(timeout), allowMalformed: true);
          MonitorLog.write('oracle', ohRaw.trim());
          _parseOracle(snap, ohRaw);
        } catch (e) {
          MonitorLog.write('oracle-error', '$e');
        }
      }
      MonitorLog.write('monitor',
          'ok en ${DateTime.now().difference(t0).inMilliseconds}ms (fs=${snap.fs.length} oracle=${snap.oracle.present})');
      return snap;
    } finally {
      conn.close();
    }
  }

  /// Fase 2: directorios (favoritos SFTP del host + defaults). Segundo plano.
  static Future<List<DirInfo>> fetchDirs(SshHost host) async {
    await dirCacheLoad();
    final conn = await SshConnector.connect(host);
    try {
      final favs = SftpFavoritesService.instance
          .forHost(host.id)
          .map((f) => _normPath(f.path))
          .toSet()
          .take(5)
          .toSet();
      final allDirs = <String>[
        ...favs,
        ..._dirs.where((d) => !favs.contains(d)),
      ];
      final dirList = allDirs.map((e) => "'$e'").join(' ');
      const tpl =
          'for d in @@DIRS@@; do ( out=\$(timeout 20 du -x -s -B1 "\$d" 2>/dev/null | awk \'{print \$1}\'); echo "__TX_DIR__ \$d"; echo "\${out:-TIMEOUT}" ) & done; wait';
      final dirsCmd = tpl.replaceAll('@@DIRS@@', dirList);
      MonitorLog.write('dirs', 'targets=${allDirs.join(' ')}');
      final dirsRaw = utf8.decode(
          await conn.c.run(dirsCmd).timeout(const Duration(seconds: 25)),
          allowMalformed: true);
      MonitorLog.write('dirs', dirsRaw.trim());
      final dirs = _parseDirs(dirsRaw);
      for (final d in dirs) {
        if (!d.slow) await dirCachePut(host.id, d.path, d.bytes);
      }
      await sampleAppend(host.id, const {},
          {for (final d in dirs) if (!d.slow) d.path: d.bytes});
      return dirs;
    } finally {
      conn.close();
    }
  }

  /// v2.20.0: reconstruye el historial de UNA carpeta desde las fechas de
  /// modificacion de sus ficheros (un solo paseo de find; suma por mes).
  /// Devuelve {ts_inicio_de_mes: bytes_acumulados} de los ultimos 12 meses.
  static Future<Map<int, double>> fetchDirHistory(
      SshHost host, String path) async {
    final conn = await SshConnector.connect(host);
    try {
      final safe = path.replaceAll("'", "'\\''");
      final cmd = "LC_ALL=C; find '" + safe +
          "' -type f -printf '%TY-%Tm %s\\n' 2>/dev/null | awk '{a[\$1]+=\$2} END{for (k in a) print k, a[k]}'";
      final raw = utf8.decode(
          await conn.c.run(cmd).timeout(const Duration(seconds: 90)),
          allowMalformed: true);
      final buckets = <String, double>{};
      for (final l in raw.split('\n')) {
        final p = l.trim().split(RegExp(r'\s+'));
        if (p.length == 2) {
          final v = double.tryParse(p[1]);
          if (v != null) buckets[p[0]] = v;
        }
      }
      final keys = buckets.keys.toList()..sort();
      var cum = 0.0;
      final out = <int, double>{};
      for (final k in keys) {
        cum += buckets[k]!;
        final ym = k.split('-');
        if (ym.length == 2) {
          final dt = DateTime(int.parse(ym[0]), int.parse(ym[1]), 1);
          out[dt.millisecondsSinceEpoch] = cum;
        }
      }
      return out;
    } finally {
      conn.close();
    }
  }

  static void _parseCore(MonitorSnapshot snap, String raw) {
    String? section;
    for (final line in raw.split('\n')) {
      final l = line.trim();
      if (l.startsWith('__TX_') && l.endsWith('__')) {
        section = l;
        continue;
      }
      if (l.isEmpty) continue;
      switch (section) {
        case '__TX_DF__':
          final p = l.split(RegExp(r'\s+'));
          // v2.18.8: descartar la cabecera y limpiar el % de Use%
          // (double.tryParse("76%") daba null -> barras siempre a 0).
          if (p.length >= 6 && p[0] != 'Filesystem') {
            final pct = double.tryParse(p[4].replaceAll('%', '')) ?? 0;
            snap.fs.add(FsInfo(p[5], pct, p[3], p[1]));
          }
          break;
        case '__TX_LOAD__':
          final p = l.split(' ');
          if (p.length >= 3) {
            snap.load = LoadInfo(
                double.tryParse(p[0]) ?? 0,
                double.tryParse(p[1]) ?? 0,
                double.tryParse(p[2]) ?? 0,
                snap.load?.memPct ?? 0);
          }
          break;
        case '__TX_MEM__':
          snap.load = LoadInfo(
              snap.load?.l1 ?? 0,
              snap.load?.l5 ?? 0,
              snap.load?.l15 ?? 0,
              double.tryParse(l.replaceAll(',', '.')) ?? 0);
          break;
        case '__TX_FAIL__':
          if (l.isNotEmpty && !l.startsWith('__TX_')) {
            snap.failedNames.add(l);
          }
          break;
        case '__TX_ACTIVE__':
          snap.servicesRunning = int.tryParse(l) ?? 0;
          break;
        case '__TX_UNITS__':
          final p = l.split(' ');
          if (p.length >= 2 && !p[0].startsWith('__TX_')) {
            snap.unitStates[p[0]] = p[1];
          }
          break;
        case '__TX_OH__':
          if (l == 'yes') snap.oracle = OracleInfo(present: true);
          break;
      }
    }
  }

  static List<DirInfo> _parseDirs(String raw) {
    final out = <DirInfo>[];
    String? cur;
    for (final line in raw.split('\n')) {
      final l = line.trim();
      if (l.startsWith('__TX_DIR__')) {
        cur = l.split(' ').length > 1 ? l.split(' ')[1] : null;
        continue;
      }
      if (cur != null) {
        final v = double.tryParse(l);
        out.add(DirInfo(cur, v ?? 0, slow: v == null));
        cur = null;
      }
    }
    return out;
  }

  static void _parseOracle(MonitorSnapshot snap, String raw) {
    final tbs = <String, double>{};
    bool? up, lup;
    for (final line in raw.split('\n')) {
      final l = line.trim();
      if (l == 'TX_UP') {
        up = true;
      } else if (l == 'TX_DOWN') {
        up = false;
      } else if (l == 'TX_LUP') {
        lup = true;
      } else if (l == 'TX_LDOWN') {
        lup = false;
      } else {
        final p = l.split(' ');
        if (p.length >= 2 && !p[0].startsWith('TX_')) {
          final v = double.tryParse(p[1]);
          if (v != null) tbs[p[0]] = v;
        }
      }
    }
    snap.oracle = OracleInfo(
        present: true, up: up ?? false, listenerUp: lup, tablespaces: tbs);
  }
}
