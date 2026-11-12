// lib/src/monitor/monitor_models.dart
// Modelos del Monitor de sistemas (v2.18.0). Solo consultas por SSH: la app
// lanza comandos read-only y pinta el resultado; NADA se instala en los
// servidores.

class FsInfo {
  final String mount;
  final double pct; // 0-100
  final String free;
  final String size;
  FsInfo(this.mount, this.pct, this.free, this.size);
}

class DirInfo {
  final String path;
  final double bytes;
  final bool slow; // el du supero el timeout
  DirInfo(this.path, this.bytes, {this.slow = false});
}

class LoadInfo {
  final double l1, l5, l15;
  final double memPct; // 0-100
  LoadInfo(this.l1, this.l5, this.l15, this.memPct);
}

class OracleInfo {
  final bool present;
  final bool up;
  final bool? listenerUp;
  final Map<String, double> tablespaces; // nombre -> % usado
  OracleInfo(
      {required this.present,
      this.up = false,
      this.listenerUp,
      this.tablespaces = const {}});
}

// v2.25.0
class TopProc {
  final String name;
  final double cpu; // %
  final double mem; // %
  TopProc(this.name, this.cpu, this.mem);
}

class TempSensor {
  final String name;
  final double celsius;
  TempSensor(this.name, this.celsius);
}

class NetIface {
  final String name;
  final double rxBytes;
  final double txBytes;
  NetIface(this.name, this.rxBytes, this.txBytes);
}

class MonitorSnapshot {
  final DateTime ts;
  LoadInfo? load;
  List<FsInfo> fs;
  List<DirInfo> dirs;
  int failedUnits;
  List<String> failedNames;
  int servicesRunning;
  Map<String, String> unitStates;
  OracleInfo oracle;
  List<TopProc> top; // v2.25.0
  List<TempSensor> temps; // v2.25.0
  List<NetIface> net; // v2.25.0
  int netEstablished; // v2.25.0
  MonitorSnapshot(
      {required this.ts,
      this.load,
      this.fs = const [],
      this.dirs = const [],
      this.failedUnits = 0,
      this.failedNames = const [],
      this.servicesRunning = 0,
      this.unitStates = const {},
      this.top = const [],
      this.temps = const [],
      this.net = const [],
      this.netEstablished = 0,
      required this.oracle});

  static String humanBytes(double b) {
    if (b <= 0) return '0 B';
    const u = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    var v = b;
    while (v >= 1024 && i < u.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${u[i]}';
  }
}
