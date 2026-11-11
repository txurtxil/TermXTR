// lib/src/monitor/connmap_service.dart
// v2.23.0: mapa de CONEXIONES — aristas reales entre los hosts configurados.
// Fase 1: `ss -tnp state established` (fallback netstat) en cada host; se
// conservan solo aristas cuyos DOS extremos son hosts conocidos (la LAN y
// tu WAN entran si estan configurados). Fase 2: v$session del Oracle -> aristas
// con el nombre real de la maquina cliente (Tomcat/Liferay). Solo consultas.

import 'dart:convert';
import 'dart:io';

import '../ssh/ssh_connector.dart';
import '../ssh/ssh_host.dart';
import 'monitor_log.dart';

class ConnEdge {
  final String fromIp;
  final String fromName;
  final String toIp;
  final String toName;
  final int port;
  final String service;
  final String? process;
  int count;
  ConnEdge({
    required this.fromIp,
    required this.fromName,
    required this.toIp,
    required this.toName,
    required this.port,
    required this.service,
    this.process,
    this.count = 1,
  });
}

class ConnMapService {
  static const Map<int, String> kServiceByPort = {
    1521: 'Oracle', 1522: 'Oracle',
    8080: 'Tomcat', 8009: 'Tomcat AJP', 8005: 'Tomcat admin', 8443: 'Tomcat HTTPS',
    5666: 'Nagios NRPE', 5667: 'Nagios NSCA',
    514: 'rsyslog',
    22: 'SSH', 80: 'HTTP', 443: 'HTTPS',
    3306: 'MySQL', 5432: 'PostgreSQL', 1433: 'SQL Server',
    3389: 'RDP', 5900: 'VNC',
    389: 'LDAP', 636: 'LDAPS', 53: 'DNS', 25: 'SMTP', 465: 'SMTPS', 587: 'SMTP',
    162: 'SNMP trap',
    9200: 'Elasticsearch', 9300: 'Elasticsearch nodo',
    27017: 'MongoDB', 11211: 'Memcached', 6379: 'Redis',
    8161: 'ActiveMQ', 5672: 'RabbitMQ', 1099: 'JMX', 4848: 'GlassFish',
  };

  static String serviceLabel(int port) => kServiceByPort[port] ?? 'puerto $port';

  static String _ipOf(String addr) {
    final i = addr.lastIndexOf(':');
    return i > 0 ? addr.substring(0, i) : addr;
  }

  static int _portOf(String addr) {
    final i = addr.lastIndexOf(':');
    return i > 0 ? (int.tryParse(addr.substring(i + 1)) ?? 0) : 0;
  }

  static Future<List<ConnEdge>> collect(List<SshHost> hosts) async {
    final known = <String, SshHost>{};
    for (final h in hosts) {
      known[h.hostname] = h;
    }
    final edges = <String, ConnEdge>{};

    void addEdge(String fromIp, String fromName, String toIp, String toName,
        int port, String? process, int count) {
      if (port <= 0) return;
      final a = fromIp.compareTo(toIp) <= 0 ? fromIp : toIp;
      final b = a == fromIp ? toIp : fromIp;
      final key = '$a>$b:$port';
      final e = edges[key];
      if (e != null) {
        e.count += count;
      } else {
        edges[key] = ConnEdge(
          fromIp: fromIp,
          fromName: fromName,
          toIp: toIp,
          toName: toName,
          port: port,
          service: serviceLabel(port),
          process: process,
          count: count,
        );
      }
    }

    for (final h in hosts) {
      // Fase 1: aristas TCP establecidas
      try {
        final conn = await SshConnector.connect(h);
        try {
          final raw = utf8.decode(
              await conn.c
                  .run("LC_ALL=C; ss -tnp state established 2>/dev/null || "
                      "netstat -tnp 2>/dev/null | grep ESTABLISHED")
                  .timeout(const Duration(seconds: 15)),
              allowMalformed: true);
          for (final line in raw.split('\n')) {
            final t = line.trim().split(RegExp(r'\s+'));
            if (t.length < 5) continue;
            final local = t[3];
            final remote = t[4];
            if (!local.contains(':') || !remote.contains(':')) continue;
            if (!RegExp(r'^[0-9]').hasMatch(local)) continue; // solo IPv4
            final lip = _ipOf(local);
            final rip = _ipOf(remote);
            final lport = _portOf(local);
            final rport = _portOf(remote);
            final lh = known[lip];
            final rh = known[rip];
            if (lh == null || rh == null) continue; // solo interna
            final proc = _processOf(line);
            // direccion: quien tiene el puerto de servicio conocido es el destino
            if (kServiceByPort.containsKey(rport) || !kServiceByPort.containsKey(lport)) {
              addEdge(lip, lh.name, rip, rh.name, rport, proc, 1);
            } else {
              addEdge(rip, rh.name, lip, lh.name, lport, proc, 1);
            }
          }
          // Fase 2: Oracle v$session (aristas DB con nombre de cliente)
          try {
            const oh = r"""
sqlplus -s / as sysdba <<'EOS' 2>/dev/null
set pages 0 head off feed off
select machine||'|'||program||'|'||count(*) from v$session where type='USER' group by machine, program;
EOS
""";
            final oraw = utf8.decode(
                await conn.c.run(oh).timeout(const Duration(seconds: 10)),
                allowMalformed: true);
            for (final line in oraw.split('\n')) {
              final p = line.trim().split('|');
              if (p.length != 3) continue;
              var machine = p[0].trim();
              final program = p[1].trim();
              final n = int.tryParse(p[2].trim()) ?? 1;
              if (machine.isEmpty) continue;
              // resolver maquina a host conocido (por hostname o por IP)
              String? ip = known.containsKey(machine) ? machine : null;
              if (ip == null) {
                for (final e in known.entries) {
                  if (machine.contains(e.value.name) ||
                      e.value.name.contains(machine)) {
                    ip = e.key;
                    break;
                  }
                }
              }
              if (ip == null) continue;
              addEdge(ip, known[ip]!.name, h.hostname, h.name, 1521, program, n);
            }
          } catch (_) {}
        } finally {
          conn.close();
        }
      } catch (e) {
        MonitorLog.write('connmap', 'fallo en ${h.name}: ${e.toString().substring(0, 80)}');
      }
    }
    final out = edges.values.toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    return out;
  }

  static String? _processOf(String line) {
    final m = RegExp(r'\(\("([^"]+)"').firstMatch(line);
    if (m != null) return m.group(1);
    final m2 = RegExp(r'/([A-Za-z0-9_.-]+)\s*$').firstMatch(line);
    return m2?.group(1);
  }
}
