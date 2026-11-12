// lib/src/monitor/connmap_service.dart
// v2.23.2: parser robusto - algunos ss (con filtro 'state established') NO
// imprimen la columna State: se buscan los DOS primeros tokens con forma
// IP:puerto en vez de indices fijos. Timeout de conexion corto (6s).

import 'dart:convert';

import '../ssh/ssh_connector.dart';
import '../ssh/ssh_host.dart';
import 'monitor_log.dart';

// v2.31.0 - datos rapidos por host para auditoria (SO, uptime, carga).
class HostFacts {
  String os = '';
  String uptime = '';
  double load1 = 0;
}

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
    8161: 'ActiveMQ', 5672: 'RabbitMQ', 1099: 'JMX', 4848: 'GlassFish', 8007: 'Tomcat HTTP',
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

  static bool _isAddr(String t) {
    return t.contains(':') &&
        t.length > 4 &&
        RegExp(r'^[0-9]').hasMatch(t) &&
        !t.startsWith('users:');
  }

  // v2.31.0 - hechos por hostname, llenados como efecto lateral de collect().
  static final Map<String, HostFacts> facts = {};
  static void clearFacts() => facts.clear();

  static Future<List<ConnEdge>> collect(List<SshHost> hosts) async {
    final known = <String, SshHost>{};
    for (final h in hosts) {
      known[h.hostname] = h;
    }
    const extName = '· externo ·';
    const extIp = '<ext>';
    clearFacts();
    final edges = <String, ConnEdge>{};
    final failures = <String>[];

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
      try {
        final conn = await SshConnector.connect(h,
            timeout: const Duration(seconds: 6));
        try {
          final raw = utf8.decode(
              await conn.c
                  .run("LC_ALL=C; ss -tnp state established 2>/dev/null || "
                      "netstat -tnp 2>/dev/null | grep ESTABLISHED; "
                      "echo __TX_FACTS__; . /etc/os-release 2>/dev/null; "
                      "echo \"OS=\${PRETTY_NAME:-desconocido}\"; "
                      "echo \"LOAD=\$(cut -d' ' -f1 /proc/loadavg)\"; "
                      "echo \"UPTIME=\$(uptime -p 2>/dev/null || echo n/a)\"")
                  .timeout(const Duration(seconds: 12)),
              allowMalformed: true);
          var parsed = 0;
          for (final line in raw.split('\n')) {
            if (line.startsWith('OS=')) {
              (facts[h.hostname] ??= HostFacts()).os = line.substring(3);
              continue;
            }
            if (line.startsWith('LOAD=')) {
              (facts[h.hostname] ??= HostFacts()).load1 =
                  double.tryParse(line.substring(5)) ?? 0;
              continue;
            }
            if (line.startsWith('UPTIME=')) {
              (facts[h.hostname] ??= HostFacts()).uptime = line.substring(7);
              continue;
            }
            String? local;
            String? remote;
            for (final tok in line.trim().split(RegExp(r'\s+'))) {
              if (_isAddr(tok)) {
                if (local == null) {
                  local = tok;
                } else {
                  remote = tok;
                  break;
                }
              }
            }
            if (local == null || remote == null) continue;
            final lip = _ipOf(local);
            final rip = _ipOf(remote);
            final lport = _portOf(local);
            final rport = _portOf(remote);
            final lh = known[lip];
            final rh = known[rip];
            final proc = _processOf(line);
            final lsvc = kServiceByPort.containsKey(lport);
            final rsvc = kServiceByPort.containsKey(rport);
            parsed++;
            if (lh != null && rh != null) {
              if (rsvc || !lsvc) {
                addEdge(lip, lh.name, rip, rh.name, rport, proc, 1);
              } else {
                addEdge(rip, rh.name, lip, lh.name, lport, proc, 1);
              }
            } else if (lh != null) {
              if (lsvc) {
                addEdge(extIp, extName, lip, lh.name, lport, proc, 1);
              } else if (rsvc) {
                addEdge(lip, lh.name, extIp, extName, rport, proc, 1);
              }
            } else if (rh != null) {
              if (rsvc) {
                addEdge(extIp, extName, rip, rh.name, rport, proc, 1);
              } else if (lsvc) {
                addEdge(rip, rh.name, extIp, extName, lport, proc, 1);
              }
            }
          }
          MonitorLog.write(
              'connmap', h.name + ': ' + parsed.toString() + ' lineas');
          try {
            const oh = r"""
sqlplus -s / as sysdba <<'EOS' 2>/dev/null
set pages 0 head off feed off
select machine||'|'||program||'|'||count(*) from v$session where type='USER' group by machine, program;
EOS
""";
            final oraw = utf8.decode(
                await conn.c.run(oh).timeout(const Duration(seconds: 8)),
                allowMalformed: true);
            for (final line in oraw.split('\n')) {
              final p = line.trim().split('|');
              if (p.length != 3) continue;
              var machine = p[0].trim();
              final program = p[1].trim();
              final n = int.tryParse(p[2].trim()) ?? 1;
              if (machine.isEmpty) continue;
              String? ip = _matchMachine(machine, known);
              if (ip == null) continue;
              addEdge(
                  ip, known[ip]!.name, h.hostname, h.name, 1521, program, n);
            }
          } catch (_) {}
        } finally {
          conn.close();
        }
      } catch (e) {
        failures.add(h.name);
        final em = e.toString();
        MonitorLog.write('connmap',
            'fallo en ${h.name}: ' +
                (em.length > 60 ? em.substring(0, 60) : em));
      }
    }
    final out = edges.values.toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    if (out.isEmpty && failures.isNotEmpty) {
      throw StateError('sin datos: fallo en ' + failures.join(', '));
    }
    return out;
  }

  /// Empareja el nombre de maquina de v\$session (p. ej. 'tomcat1.midom')
  /// con un host configurado, por IP exacta, nombre exacto o prefijo.
  static String? _matchMachine(String machine, Map<String, SshHost> known) {
    if (known.containsKey(machine)) return machine;
    final m = machine.toLowerCase();
    final first = m.split('.').first;
    for (final e in known.entries) {
      final hn = e.value.name.toLowerCase();
      final hh = e.key.toLowerCase();
      if (m == hn || m == hh) return e.key;
      if (hn.isNotEmpty && (m.startsWith(hn) || hn.startsWith(m))) {
        return e.key;
      }
      if (first.isNotEmpty &&
          hn.isNotEmpty &&
          (first == hn || hn.startsWith(first) || first.startsWith(hn))) {
        return e.key;
      }
      if (first.isNotEmpty &&
          hh.isNotEmpty &&
          (first == hh || hh.startsWith(first))) {
        return e.key;
      }
    }
    return null;
  }

  static String? _processOf(String line) {
    final m = RegExp(r'\(\("([^"]+)"').firstMatch(line);
    if (m != null) return m.group(1);
    final m2 = RegExp(r'/([A-Za-z0-9_.-]+)\s*$').firstMatch(line);
    return m2?.group(1);
  }
}
