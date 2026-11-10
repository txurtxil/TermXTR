// lib/src/monitor/monitor_service.dart
// Servicio del Monitor de sistemas (v2.18.0). Conecta al host con el
// mismo flujo de auth que la sesion terminal y lanza comandos read-only
// agrupados. Sin agentes ni instalaciones en el servidor.

import 'dart:convert';
import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

import '../ssh/identity_service.dart';
import '../ssh/ssh_credentials_store.dart';
import '../ssh/ssh_host.dart';
import '../storage/app_paths.dart';
import 'monitor_log.dart';
import 'monitor_models.dart';

class MonitorService {
  // Directorios medidos con du (acotados, con timeout server-side).
  static const _dirs = ['/var', '/opt', '/tmp'];

  static Future<MonitorSnapshot> fetch(SshHost host,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final socket = await SSHSocket.connect(host.hostname, host.port)
        .timeout(const Duration(seconds: 12));
    SSHClient? client;
    try {
      // mismo auth que terminal_session (v2.16.1): clave del host si la
      // hay + identidad de la app como fallback; password siempre ofrecido.
      List<SSHKeyPair>? identities;
      final keyPath = host.keyPath;
      if (keyPath != null && keyPath.trim().isNotEmpty) {
        try {
          final keyFile = await AppPaths.resolveKey(keyPath.trim());
          if (keyFile != null) {
            identities = SSHKeyPair.fromPem(await keyFile.readAsString());
          }
        } catch (_) {}
      }
      try {
        final id = await IdentityService.loadIdentity();
        if (id != null && id.isNotEmpty) {
          identities = [...(identities ?? const <SSHKeyPair>[]), ...id];
        }
      } catch (_) {}
      final pwd = await SshCredentialsStore.readPassword(host.id);
      client = SSHClient(
        socket,
        username: host.username,
        identities: (identities != null && identities.isNotEmpty)
            ? identities
            : null,
        onPasswordRequest: () async => pwd,
        onUserInfoRequest: (req) async => req.prompts
            .map((p) =>
                p.promptText.toLowerCase().contains('password') && pwd != null
                    ? pwd
                    : '')
            .toList(),
        onVerifyHostKey: (type, fingerprint) async => true,
        handshakeTimeout: const Duration(seconds: 12),
        authTimeout: const Duration(seconds: 12),
      );

      final t0 = DateTime.now();
      MonitorLog.write('monitor',
          'fetch ${host.name} (${host.username}@${host.hostname}:${host.port})');
      // v2.18.1: listas growables explicitas (los defaults const del
      // constructor no admiten add/addAll -> "Cannot add to an unmodifiable
      // list", crash reportado 10-nov-2026).
      final snap = MonitorSnapshot(
          ts: DateTime.now(),
          oracle: OracleInfo(present: false),
          fs: <FsInfo>[],
          dirs: <DirInfo>[]);

      // 1) nucleo: df + load + mem + failed + deteccion oracle
      const core = r'''
LC_ALL=C; export LC_ALL
echo __TX_DF__
df -hP -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs
echo __TX_LOAD__
cut -d' ' -f1-3 /proc/loadavg
echo __TX_MEM__
awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%.1f",(t-a)/t*100}' /proc/meminfo
echo __TX_FAIL__
systemctl --failed --no-legend --plain 2>/dev/null | grep -c '.'
echo __TX_OH__
command -v sqlplus >/dev/null 2>&1 && echo yes || echo no
echo __TX_END__
''';
      final coreRaw = utf8.decode(await client.run(core).timeout(timeout),
          allowMalformed: true);
      MonitorLog.write('core', coreRaw.trim());
      _parseCore(snap, coreRaw);

      // 2) directorios (du acotado, timeout server-side de 6s por dir)
      final dirsCmd = 'for d in $_dirs; do echo "__TX_DIR__ \$d"; '
          "timeout 6 du -x -s -B1 \$d 2>/dev/null | awk '{print \$1}'; done";
      final dirsRaw = utf8.decode(await client.run(dirsCmd).timeout(timeout),
          allowMalformed: true);
      MonitorLog.write('dirs', dirsRaw.trim());
      snap.dirs.addAll(_parseDirs(dirsRaw));

      // 3) oracle (solo si hay sqlplus)
      if (snap.oracle.present) {
        const oh = r'''
pgrep -f ora_pmon_ >/dev/null 2>&1 && echo TX_UP || echo TX_DOWN
command -v lsnrctl >/dev/null 2>&1 && { lsnrctl status >/dev/null 2>&1 && echo TX_LUP || echo TX_LDOWN; } || echo TX_LNA
sqlplus -s / as sysdba <<'EOS' 2>/dev/null
set pages 0 feed off head off
select tablespace_name||' '||round(used_percent,1) from dba_tablespace_usage_metrics order by 2 desc fetch first 8 rows only;
EOS
''';
        try {
          final ohRaw = utf8.decode(await client.run(oh).timeout(timeout),
              allowMalformed: true);
          MonitorLog.write('oracle', ohRaw.trim());
          _parseOracle(snap, ohRaw);
        } catch (e) {
          MonitorLog.write('oracle-error', '$e');
        }
      }
      MonitorLog.write('monitor',
          'ok en ${DateTime.now().difference(t0).inMilliseconds}ms (fs=${snap.fs.length} dirs=${snap.dirs.length} oracle=${snap.oracle.present})');
      return snap;
    } catch (e) {
      MonitorLog.write('error', 'fetch ${host.name}: $e');
      rethrow;
    } finally {
      client?.close();
      try {
        await socket.close();
      } catch (_) {}
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
          if (p.length >= 6) {
            snap.fs.add(FsInfo(p[5], double.tryParse(p[4]) ?? 0, p[3], p[1]));
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
          snap.load = LoadInfo(snap.load?.l1 ?? 0, snap.load?.l5 ?? 0,
              snap.load?.l15 ?? 0, double.tryParse(l) ?? 0);
          break;
        case '__TX_FAIL__':
          snap.failedUnits = int.tryParse(l) ?? 0;
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
