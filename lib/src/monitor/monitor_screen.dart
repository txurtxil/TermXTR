// lib/src/monitor/monitor_screen.dart
// Pantalla del Monitor de sistemas (v2.18.0): consulta al host por SSH
// (comandos read-only, nada instalado en el servidor) y pinta el estado:
// discos, directorios, carga/memoria, servicios fallidos y Oracle.

import 'dart:async';

import 'package:flutter/material.dart';

import '../ssh/ssh_host.dart';
import 'monitor_models.dart';
import 'monitor_log.dart';
import 'monitor_service.dart';

class _C {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const accent = Color(0xFF5E9BD6);
  static const ok = Color(0xFF30D158);
  static const warn = Color(0xFFFFD60A);
  static const err = Color(0xFFFF453A);
}

class MonitorScreen extends StatefulWidget {
  final SshHost host;
  const MonitorScreen({super.key, required this.host});

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> {
  MonitorSnapshot? _snap;
  bool _loading = true;
  String? _error;
  bool _auto = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await MonitorService.fetch(widget.host);
      if (!mounted) return;
      setState(() {
        _snap = s;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _toggleAuto(bool v) {
    setState(() => _auto = v);
    _timer?.cancel();
    if (v) {
      _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
    }
  }

  Future<void> _showLog() async {
    final log = await MonitorLog.readLast();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('Log del Monitor',
            style: TextStyle(color: _C.textHi, fontSize: 14)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(log,
                style: const TextStyle(
                    color: _C.textLo, fontSize: 10, fontFamily: 'monospace')),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.bg,
      appBar: AppBar(
        backgroundColor: _C.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: _C.textHi),
        title: Text('Monitor — ${widget.host.name}',
            style: const TextStyle(color: _C.textHi, fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'Ver log',
            icon: const Icon(Icons.receipt_long, color: _C.textLo),
            onPressed: _showLog,
          ),
          Row(children: [
            const Text('Auto',
                style: TextStyle(color: _C.textLo, fontSize: 12)),
            Switch(value: _auto, onChanged: _toggleAuto),
          ]),
          IconButton(
            tooltip: 'Actualizar',
            icon: const Icon(Icons.refresh, color: _C.textLo),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!,
                    style: const TextStyle(color: _C.err)),
              ),
            )
          : _loading && _snap == null
              ? const Center(
                  child: CircularProgressIndicator(color: _C.accent))
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    children: [
                      if (_snap != null) ...[
                        _secLoad(_snap!.load),
                        _secFs(_snap!.fs),
                        _secDirs(_snap!.dirs),
                        _secSystemd(_snap!.failedUnits),
                        _secOracle(_snap!.oracle),
                        const SizedBox(height: 20),
                        Text(
                          'Solo consultas por SSH (nada instalado en el servidor). '
                          '${_snap!.ts.hour.toString().padLeft(2, '0')}:${_snap!.ts.minute.toString().padLeft(2, '0')}',
                          style:
                              const TextStyle(color: _C.textLo, fontSize: 11),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _card({required String title, required List<Widget> children}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _C.card,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: _C.textHi, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  Widget _secLoad(LoadInfo? l) {
    if (l == null) return const SizedBox.shrink();
    return _card(title: 'Sistema', children: [
      Row(children: [
        _chip('1m ${l.l1.toStringAsFixed(2)}'),
        _chip('5m ${l.l5.toStringAsFixed(2)}'),
        _chip('15m ${l.l15.toStringAsFixed(2)}'),
      ]),
      const SizedBox(height: 8),
      _bar('Memoria', l.memPct, '${l.memPct.toStringAsFixed(1)}%'),
    ]);
  }

  Widget _chip(String t) => Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: _C.bg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(t, style: const TextStyle(color: _C.textHi, fontSize: 12)),
      );

  Widget _bar(String label, double pct, String trailing) {
    final color = pct >= 90 ? _C.err : (pct >= 75 ? _C.warn : _C.ok);
    return Column(children: [
      Row(children: [
        Expanded(
            child: Text(label,
                style: const TextStyle(color: _C.textLo, fontSize: 12))),
        Text(trailing, style: TextStyle(color: color, fontSize: 12)),
      ]),
      const SizedBox(height: 4),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: (pct / 100).clamp(0.0, 1.0),
          minHeight: 6,
          backgroundColor: _C.bg,
          valueColor: AlwaysStoppedAnimation(color),
        ),
      ),
    ]);
  }

  Widget _secFs(List<FsInfo> fs) {
    if (fs.isEmpty) return const SizedBox.shrink();
    return _card(
        title: 'Discos',
        children: fs
            .map((f) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _bar(f.mount, f.pct,
                      '${f.pct.toStringAsFixed(0)}% · libre ${f.free}'),
                ))
            .toList());
  }

  Widget _secDirs(List<DirInfo> dirs) {
    if (dirs.isEmpty) return const SizedBox.shrink();
    final total = dirs.fold<double>(0, (a, d) => a + d.bytes);
    return _card(
        title: 'Directorios',
        children: dirs
            .map((d) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Expanded(
                        child: Text(d.path,
                            style: const TextStyle(
                                color: _C.textLo, fontSize: 13))),
                    Text(
                        d.slow
                            ? 'lento (>6s)'
                            : MonitorSnapshot.humanBytes(d.bytes),
                        style: const TextStyle(
                            color: _C.textHi, fontSize: 13)),
                    if (total > 0 && !d.slow) ...[
                      const SizedBox(width: 8),
                        SizedBox(
                          width: 60,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: (d.bytes / total).clamp(0.0, 1.0),
                              minHeight: 4,
                              backgroundColor: _C.bg,
                              valueColor: const AlwaysStoppedAnimation(_C.accent),
                            ),
                          ),
                        ),
                    ],
                  ]),
                ))
            .toList());
  }

  Widget _secSystemd(int failed) {
    return _card(title: 'Servicios systemd', children: [
      Row(children: [
        Icon(failed > 0 ? Icons.error : Icons.check_circle,
            color: failed > 0 ? _C.err : _C.ok, size: 16),
        const SizedBox(width: 8),
        Text('unidades fallidas: $failed',
            style: TextStyle(
                color: failed > 0 ? _C.err : _C.textLo, fontSize: 13)),
      ]),
    ]);
  }

  Widget _secOracle(OracleInfo o) {
    if (!o.present) {
      return _card(title: 'Oracle', children: const [
        Text('Oracle no detectado en este host (sin sqlplus)',
            style: TextStyle(color: _C.textLo, fontSize: 12)),
      ]);
    }
    final tbs = o.tablespaces.entries
        .map((e) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _bar('tbs ${e.key}', e.value,
                  '${e.value.toStringAsFixed(1)}%'),
            ))
        .toList();
    return _card(title: 'Oracle', children: [
      Row(children: [
        Icon(o.up ? Icons.check_circle : Icons.cancel,
            color: o.up ? _C.ok : _C.err, size: 16),
        const SizedBox(width: 8),
        Text('instancia ${o.up ? 'UP' : 'DOWN'}',
            style: const TextStyle(color: _C.textHi, fontSize: 13)),
        if (o.listenerUp != null) ...[
          const SizedBox(width: 16),
          Icon(o.listenerUp! ? Icons.wifi : Icons.wifi_off,
              color: o.listenerUp! ? _C.ok : _C.err, size: 16),
          const SizedBox(width: 4),
          Text('listener ${o.listenerUp! ? 'UP' : 'DOWN'}',
              style: const TextStyle(color: _C.textHi, fontSize: 13)),
        ],
      ]),
      if (tbs.isNotEmpty) ...[
        const SizedBox(height: 10),
        ...tbs,
      ],
    ]);
  }
}
