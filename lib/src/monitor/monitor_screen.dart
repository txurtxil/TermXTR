// lib/src/monitor/monitor_screen.dart
// Pantalla del Monitor de sistemas (v2.18.0): consulta al host por SSH
// (comandos read-only, nada instalado en el servidor) y pinta el estado:
// discos, directorios, carga/memoria, servicios fallidos y Oracle.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../ui/app_theme.dart';

import '../ssh/ssh_host.dart';
import 'monitor_models.dart';
import '../sftp/sftp_favorites_service.dart';
import '../storage/app_paths.dart';
import 'ghost_config.dart';
import 'ghost_settings.dart';
import 'alert_service.dart';
import 'monitor_log.dart';
import 'monitor_service.dart';
import 'maneuvers.dart';
import 'report_pdf.dart';


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
  GhostCfg _cfg = GhostCfg();
  String _histSel = '';
  int _histRange = 7 * 24;
  List<Map<String, dynamic>> _histData = [];
  bool _exporting = false; // v2.26.0
  bool _histBusy = false;
  final _unitCtrl = TextEditingController();
  Timer? _timer;
  final _newDirController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _newDirController.dispose();
    _unitCtrl.dispose();
    super.dispose();
  }

  String _norm(String p) {
    var s0 = p.replaceAll(RegExp(r'/+'), '/');
    if (s0.length > 1) s0 = s0.replaceAll(RegExp(r'/$'), '');
    return s0.isEmpty ? '/' : s0;
  }

  void _capToast() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Maximo 5 carpetas favoritas (quita una primero)')));
  }

  Future<void> _loadHist() async {
    if (_histSel.isEmpty) return;
    final kind = _histSel.startsWith('m:') ? 'mount' : 'dir';
    final key = _histSel.substring(2);
    final since = DateTime.now()
        .subtract(Duration(hours: _histRange))
        .millisecondsSinceEpoch;
    final data = await sampleQuery(widget.host.id, kind, key, since);
    if (!mounted) return;
    setState(() => _histData = data);
  }

  Future<void> _backfillHist() async {
    if (!_histSel.startsWith('d:') || _histBusy) return;
    setState(() => _histBusy = true);
    try {
      final hist = await MonitorService.fetchDirHistory(
          widget.host, _histSel.substring(2));
      if (hist.isNotEmpty) {
        await sampleBackfill(widget.host.id, _histSel.substring(2), hist);
        _histRange = 24 * 365;
        await _loadHist();
      }
    } catch (_) {}
    if (mounted) setState(() => _histBusy = false);
  }

  Future<void> _loadCfg() async {
    _cfg = await GhostConfigStore.forHost(widget.host.id);
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    _loadCfg();
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
      _loadDirs();
      final cfg = await GhostConfigStore.forHost(widget.host.id);
      AlertService.check(widget.host.id, widget.host.name, s, cfg.units);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadDirs() async {
    try {
      final dirs = await MonitorService.fetchDirs(widget.host);
      if (!mounted) return;
      setState(() {
        _snap!.dirs
          ..clear()
          ..addAll(dirs);
      });
    } catch (_) {}
  }

  void _toggleAuto(bool v) {
    setState(() => _auto = v);
    _timer?.cancel();
    if (v) {
      _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
    }
  }

  // v2.26.0
  Future<void> _exportPdf() async {
    if (_exporting || _snap == null) return;
    setState(() => _exporting = true);
    try {
      final bytes = await buildHostReport(
          hostName: widget.host.name,
          snap: _snap!,
          appVersion: '2.39.0');
      final path = await saveAndSharePdf(
          bytes,
          'informe_${fileSafe(widget.host.name)}'
              '_${_nowForFile()}',
          'Informe TermXTR - ${widget.host.name}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('PDF guardado en: $path')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error al generar el PDF: $e')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  String _nowForFile() =>
      DateTime.now().toString().substring(0, 16).replaceAll(RegExp(r'[^0-9]'), '');

  void _showLog() async {
    final log = await MonitorLog.readLast();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('Log del Monitor',
            style: TextStyle(color: AppColors.textHi, fontSize: 14)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(log,
                style: const TextStyle(
                    color: AppColors.textLo, fontSize: 10, fontFamily: 'monospace')),
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
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textHi),
        title: Text('Monitor — ${widget.host.name}',
            style: const TextStyle(color: AppColors.textHi, fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'Maniobras',
            icon: const Icon(Icons.bolt, color: AppColors.textLo),
            onPressed: (_snap == null)
                ? null
                : () => showManeuversSheet(context, widget.host,
                    withOracle: _snap!.oracle.present),
          ),
          IconButton(
            tooltip: 'Exportar informe PDF',
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.textLo))
                : const Icon(Icons.picture_as_pdf, color: AppColors.textLo),
            onPressed: (_snap == null || _exporting) ? null : _exportPdf,
          ),
          IconButton(
            tooltip: 'Ver log',
            icon: const Icon(Icons.receipt_long, color: AppColors.textLo),
            onPressed: _showLog,
          ),
          Row(children: [
            const Text('Auto',
                style: TextStyle(color: AppColors.textLo, fontSize: 12)),
            Switch(value: _auto, onChanged: _toggleAuto),
          ]),
          IconButton(
            tooltip: 'Actualizar',
            icon: const Icon(Icons.refresh, color: AppColors.textLo),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!,
                    style: const TextStyle(color: AppColors.err)),
              ),
            )
          : _loading && _snap == null
              ? const Center(
                  child: CircularProgressIndicator(color: AppColors.accent))
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    children: [
                      if (_snap != null) ...[
                        _secLoad(_snap!.load),
                        _secFs(_snap!.fs),
                        _secTop(_snap!.top),
                        _secTemps(_snap!.temps),
                        _secNet(_snap!),
                        _secDirs(_snap!.dirs),
                        _secSystemd(_snap!),
                        _secHistory(),
                        _secGhost(),
                        _secOracle(_snap!.oracle),
                        const SizedBox(height: 20),
                        Text(
                          'Solo consultas por SSH (nada instalado en el servidor). '
                          '${_snap!.ts.hour.toString().padLeft(2, '0')}:${_snap!.ts.minute.toString().padLeft(2, '0')}',
                          style:
                              const TextStyle(color: AppColors.textLo, fontSize: 11),
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
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: AppColors.textHi, fontWeight: FontWeight.w600)),
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
      _bar('Memoria (sin caché)', l.memPct, '${l.memPct.toStringAsFixed(1)}%'),
      if (l.swapPct > 0)
        _bar('Swap', l.swapPct, '${l.swapPct.toStringAsFixed(0)}%'),
    ]);
  }

  Widget _chip(String t) => Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(t, style: const TextStyle(color: AppColors.textHi, fontSize: 12)),
      );

  Widget _bar(String label, double pct, String trailing) {
    final color = pct >= 90 ? AppColors.err : (pct >= 75 ? AppColors.warn : AppColors.ok);
    return Column(children: [
      Row(children: [
        Expanded(
            child: Text(label,
                style: const TextStyle(color: AppColors.textLo, fontSize: 12))),
        Text(trailing, style: TextStyle(color: color, fontSize: 12)),
      ]),
      const SizedBox(height: 4),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: (pct / 100).clamp(0.0, 1.0),
          minHeight: 6,
          backgroundColor: AppColors.bg,
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
    if (dirs.isEmpty) {
      return _card(title: 'Directorios', children: const [
        Text('Midiendo carpetas (favoritos + /var /opt /tmp)...',
            style: TextStyle(color: AppColors.textLo, fontSize: 12)),
      ]);
    }
    final favs = SftpFavoritesService.instance;
    final total = dirs.fold<double>(0, (a, d) => a + d.bytes);
    final rows = dirs.map((d) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          AnimatedBuilder(
            animation: favs,
            builder: (_, __) => IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(
                favs.isFavorite(widget.host.id, d.path)
                    ? Icons.star
                    : Icons.star_border,
                size: 18,
                color: favs.isFavorite(widget.host.id, d.path)
                    ? AppColors.warn
                    : AppColors.textLo,
              ),
              tooltip: 'Favorito (medido aqui y en el navegador SFTP)',
              onPressed: () async {
                final cur = favs.isFavorite(widget.host.id, d.path);
                if (!cur && favs.forHost(widget.host.id).length >= 5) {
                  _capToast();
                  return;
                }
                await favs.toggle(widget.host.id, d.path);
                await _refresh();
              },
            ),
          ),
          Expanded(
              child: Text(d.path,
                  style: const TextStyle(color: AppColors.textLo, fontSize: 13))),
          Text(
              d.slow
                  ? (() {
                      final c = dirCacheGet(widget.host.id, d.path);
                      if (c != null) {
                        final age = dirCacheAge(widget.host.id, d.path);
                        return '${MonitorSnapshot.humanBytes(c)} (~$age)';
                      }
                      return 'lento (>20s)';
                    })()
                  : MonitorSnapshot.humanBytes(d.bytes),
              style: const TextStyle(color: AppColors.textHi, fontSize: 13)),
          if (total > 0 && !d.slow) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: 60,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: (d.bytes / total).clamp(0.0, 1.0),
                  minHeight: 4,
                  backgroundColor: AppColors.bg,
                  valueColor: const AlwaysStoppedAnimation(AppColors.accent),
                ),
              ),
            ),
          ],
        ]),
      );
    }).toList();
    rows.add(Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        const Icon(Icons.create_new_folder, size: 18, color: AppColors.textLo),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _newDirController,
            style: const TextStyle(color: AppColors.textHi, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Anadir carpeta (ej. /u01)',
              hintStyle: const TextStyle(color: AppColors.textLo, fontSize: 12),
              filled: true,
              fillColor: AppColors.bg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add, color: AppColors.accent),
          tooltip: 'Medir y guardar como favorito',
          onPressed: () async {
            var t = _newDirController.text.trim();
            if (t.isEmpty) return;
            t = _norm(t);
            final fv = SftpFavoritesService.instance;
            if (!fv.isFavorite(widget.host.id, t) &&
                fv.forHost(widget.host.id).length >= 5) {
              _capToast();
              return;
            }
            await fv.toggle(widget.host.id, t);
            _newDirController.clear();
            await _refresh();
          },
        ),
      ]),
    ));
    return _card(title: 'Directorios', children: rows);
  }

  Widget _secSystemd(MonitorSnapshot s) {
    final failed = s.failedUnits;
    return _card(title: 'Servicios systemd', children: [
      Row(children: [
        Icon(failed > 0 ? Icons.error : Icons.check_circle,
            color: failed > 0 ? AppColors.err : AppColors.ok, size: 16),
        const SizedBox(width: 8),
        Text('unidades fallidas: $failed',
            style: TextStyle(
                color: failed > 0 ? AppColors.err : AppColors.textLo, fontSize: 13)),
        const SizedBox(width: 16),
        const Icon(Icons.play_circle, color: AppColors.ok, size: 16),
        const SizedBox(width: 4),
        Text('servicios en marcha: ${s.servicesRunning}',
            style: const TextStyle(color: AppColors.textLo, fontSize: 13)),
      ]),
      if (s.unitStates.isNotEmpty) ...[
        const SizedBox(height: 6),
        for (final e in s.unitStates.entries)
          Row(children: [
            Icon(
                e.value == 'active' ? Icons.check_circle : Icons.error,
                size: 14,
                color: e.value == 'active' ? AppColors.ok : AppColors.err),
            const SizedBox(width: 6),
            Expanded(
                child: Text('${e.key} — ${e.value}',
                    style: TextStyle(
                        color: e.value == 'active' ? AppColors.textLo : AppColors.err,
                        fontSize: 12))),
          ]),
      ],
      if (s.failedNames.isNotEmpty) ...[
        const SizedBox(height: 6),
        for (final n in s.failedNames)
          Text('x $n', style: const TextStyle(color: AppColors.err, fontSize: 12)),
      ],
    ]);
  }

  static String _sparkBig(List<double> vals) {
    if (vals.length < 2) return '';
    const ch = '▁▂▃▄▅▆▇█';
    final lo = vals.reduce((a, b) => a < b ? a : b);
    final hi = vals.reduce((a, b) => a > b ? a : b);
    if (hi == lo) return ch[0] * vals.length;
    final take = vals.length > 44 ? vals.sublist(vals.length - 44) : vals;
    return take
        .map((v) => ch[((v - lo) / (hi - lo) * 7.999).clamp(0, 7).floor()])
        .join();
  }

  // v2.25.0
  Widget _secTop(List<TopProc> top) {
    if (top.isEmpty) return const SizedBox.shrink();
    return _card(
        title: 'Top procesos (CPU / MEM)',
        children: top
            .map((t) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(children: [
                    Expanded(
                        child: Text(t.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: AppColors.textHi, fontSize: 12))),
                    Text(
                        '${t.cpu.toStringAsFixed(1)}% / ${t.mem.toStringAsFixed(1)}%',
                        style:
                            const TextStyle(color: AppColors.textLo, fontSize: 12)),
                  ]),
                ))
            .toList());
  }

  // v2.25.0
  Widget _secTemps(List<TempSensor> temps) {
    if (temps.isEmpty) return const SizedBox.shrink();
    return _card(
        title: 'Temperaturas',
        children: temps.take(8).map((t) {
          final c = t.celsius;
          final color = c >= 80
              ? AppColors.err
              : (c >= 60 ? AppColors.warn : AppColors.ok);
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(children: [
              Expanded(
                  child: Text(t.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.textLo, fontSize: 12))),
              Text('${c.toStringAsFixed(0)} °C',
                  style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ]),
          );
        }).toList());
  }

  // v2.25.0
  Widget _secNet(MonitorSnapshot s) {
    if (s.net.isEmpty && s.netEstablished == 0) {
      return const SizedBox.shrink();
    }
    final rows = s.net
        .map((n) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                Expanded(
                    child: Text(n.name,
                        style: const TextStyle(
                            color: AppColors.textHi, fontSize: 12))),
                Text(
                    '↓ ${MonitorSnapshot.humanBytes(n.rxBytes)} · ↑ ${MonitorSnapshot.humanBytes(n.txBytes)}',
                    style:
                        const TextStyle(color: AppColors.textLo, fontSize: 12)),
              ]),
            ))
        .toList();
    return _card(title: 'Red', children: [
      ...rows,
      if (s.netEstablished > 0)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('conexiones TCP establecidas: ${s.netEstablished}',
              style: const TextStyle(color: AppColors.textLo, fontSize: 12)),
        ),
    ]);
  }

  Widget _secHistory() {
    final snap = _snap;
    if (snap == null) return const SizedBox.shrink();
    final targets = <String>[
      for (final f in snap.fs) 'm:${f.mount}',
      for (final d in snap.dirs) 'd:${d.path}',
    ];
    if (targets.isEmpty) return const SizedBox.shrink();
    if (_histSel.isEmpty || !targets.contains(_histSel)) {
      _histSel = targets.first;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadHist());
    }
    final vals = [for (final e in _histData) e['v'] as double];
    final spark = _sparkBig(vals);
    return _card(title: 'Historial de uso', children: [
      Wrap(spacing: 6, runSpacing: -8, children: [
        for (final t in targets)
          ChoiceChip(
            label: Text(t.substring(2), style: const TextStyle(fontSize: 11)),
            selected: _histSel == t,
            onSelected: (_) {
              _histSel = t;
              _loadHist();
            },
          ),
      ]),
      const SizedBox(height: 4),
      Wrap(spacing: 6, children: [
        for (final r in [('24h', 24), ('7d', 7 * 24), ('1m', 30 * 24), ('1a', 365 * 24)])
          ChoiceChip(
            label: Text(r.$1, style: const TextStyle(fontSize: 11)),
            selected: _histRange == r.$2,
            onSelected: (_) {
              _histRange = r.$2;
              _loadHist();
            },
          ),
      ]),
      const SizedBox(height: 8),
      if (_histBusy)
        const Padding(
          padding: EdgeInsets.all(8),
          child: CircularProgressIndicator(color: AppColors.accent),
        )
      else if (spark.isEmpty)
        const Text(
            'Aun no hay muestras para este rango: usa el Monitor unos dias, o reconstruye el pasado.',
            style: TextStyle(color: AppColors.textLo, fontSize: 11))
      else ...[
        Text(spark,
            style: const TextStyle(
                color: AppColors.accent, fontSize: 14, fontFamily: 'monospace')),
        const SizedBox(height: 4),
        Text(
          'min ${MonitorSnapshot.humanBytes(vals.reduce((a, b) => a < b ? a : b))}'
          ' · max ${MonitorSnapshot.humanBytes(vals.reduce((a, b) => a > b ? a : b))}'
          ' · ahora ${MonitorSnapshot.humanBytes(vals.last)}'
          '${vals.length > 1 ? ' · crecimiento +' + MonitorSnapshot.humanBytes(vals.last - vals.first) : ''}',
          style: const TextStyle(color: AppColors.textLo, fontSize: 11),
        ),
      ],
      if (_histSel.startsWith('d:'))
        TextButton.icon(
          onPressed: _histBusy ? null : _backfillHist,
          icon: const Icon(Icons.history, size: 16, color: AppColors.accent),
          label: const Text(
              'Reconstruir 12 meses desde el disco (fechas de modificacion)',
              style: TextStyle(color: AppColors.accent, fontSize: 11)),
        ),
    ]);
  }

  Widget _secGhost() {
    Future<void> save() async {
      await GhostConfigStore.put(widget.host.id, _cfg);
    }

    Widget sw(String label, bool v, void Function(bool) set) {
      return Row(children: [
        Expanded(
            child: Text(label,
                style: const TextStyle(color: AppColors.textLo, fontSize: 13))),
        Switch(
            value: v,
            onChanged: (nv) async {
              set(nv);
              await save();
              if (mounted) setState(() {});
            }),
      ]);
    }

    return _card(title: 'Widget de fondo fantasma (este servidor)', children: [
      const Text(
          'Administra lo que la sombra translucida muestra en la terminal de ESTE host.',
          style: TextStyle(color: AppColors.textLo, fontSize: 12)),
      sw('Carga', _cfg.showLoad, (v) => _cfg.showLoad = v),
      sw('Disco de /', _cfg.showDisk, (v) => _cfg.showDisk = v),
      sw('Memoria', _cfg.showMem, (v) => _cfg.showMem = v),
      sw('Sparklines de historial', _cfg.showSparks, (v) => _cfg.showSparks = v),
      sw('Directorios favoritos', _cfg.showDirs, (v) => _cfg.showDirs = v),
      const SizedBox(height: 4),
      Row(children: [
        const Icon(Icons.blur_off, size: 16, color: AppColors.textLo),
        Expanded(
          child: Slider(
            value: GhostSettings.opacity,
            min: 0.15,
            max: 0.95,
            divisions: 16,
            label: '${(GhostSettings.opacity * 100).round()}%',
            onChanged: (v) {
              GhostSettings.set(v);
              setState(() {});
            },
          ),
        ),
        const Icon(Icons.blur_on, size: 16, color: AppColors.textLo),
      ]),
      Row(children: [
        const Icon(Icons.zoom_out, size: 16, color: AppColors.textLo),
        Expanded(
          child: Slider(
            value: GhostSettings.scale,
            min: 0.7,
            max: 2.0,
            divisions: 13,
            label: '${(GhostSettings.scale * 100).round()}%',
            onChanged: (v) {
              GhostSettings.setScale(v);
              setState(() {});
            },
          ),
        ),
        const Icon(Icons.zoom_in, size: 16, color: AppColors.textLo),
      ]),
      TextButton.icon(
        onPressed: () {
          GhostRefreshBus.bump();
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Sombra actualizada en la terminal')));
        },
        icon: const Icon(Icons.refresh, size: 16, color: AppColors.accent),
        label: const Text('Recargar sombra ahora',
            style: TextStyle(color: AppColors.accent, fontSize: 11)),
      ),
      const Divider(color: AppColors.textLo, height: 12),
      const Text('Servicios auditados (aparecen en la sombra y arriba):',
          style: TextStyle(color: AppColors.textLo, fontSize: 12)),
      for (final u in _cfg.units)
        Row(children: [
          Expanded(
              child: Text(u,
                  style: const TextStyle(color: AppColors.textHi, fontSize: 13))),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18, color: AppColors.textLo),
            onPressed: () async {
              _cfg.units.remove(u);
              await save();
              await _refresh();
            },
          ),
        ]),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _unitCtrl,
            style: const TextStyle(color: AppColors.textHi, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'unidad systemd (ej. ssh, docker)',
              hintStyle: const TextStyle(color: AppColors.textLo, fontSize: 12),
              filled: true,
              fillColor: AppColors.bg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add, color: AppColors.accent),
          onPressed: () async {
            final t = _unitCtrl.text.trim();
            if (t.isEmpty || _cfg.units.contains(t)) return;
            _cfg.units.add(t);
            _unitCtrl.clear();
            await save();
            await _refresh();
          },
        ),
      ]),
    ]);
  }

  Widget _secOracle(OracleInfo o) {
    if (!o.present) {
      return _card(title: 'Oracle', children: const [
        Text('Oracle no detectado en este host (sin sqlplus)',
            style: TextStyle(color: AppColors.textLo, fontSize: 12)),
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
            color: o.up ? AppColors.ok : AppColors.err, size: 16),
        const SizedBox(width: 8),
        Text('instancia ${o.up ? 'UP' : 'DOWN'}',
            style: const TextStyle(color: AppColors.textHi, fontSize: 13)),
        if (o.listenerUp != null) ...[
          const SizedBox(width: 16),
          Icon(o.listenerUp! ? Icons.wifi : Icons.wifi_off,
              color: o.listenerUp! ? AppColors.ok : AppColors.err, size: 16),
          const SizedBox(width: 4),
          Text('listener ${o.listenerUp! ? 'UP' : 'DOWN'}',
              style: const TextStyle(color: AppColors.textHi, fontSize: 13)),
        ],
      ]),
      // v2.33.0 - ficha fina de la instancia
      if (o.instance.isNotEmpty || o.startup.isNotEmpty) ...[
        const SizedBox(height: 8),
        for (final kv in <(String, String, bool)>[
          if (o.instance.isNotEmpty)
            ('SID', '${o.instance} · ${o.status}', false),
          if (o.startup.isNotEmpty) ('Arranque', o.startup, false),
          ('Archivelog', o.archivelog ? 'SÍ' : 'NO', false),
          if (o.fraPct > 0) ('FRA', '${o.fraPct}%', o.fraPct >= 85),
          if (o.sessLimit > 0)
            ('Sesiones', '${o.sessUsed}/${o.sessLimit}',
                o.sessUsed * 100 >= o.sessLimit * 90),
          if (o.procLimit > 0)
            ('Procesos', '${o.procUsed}/${o.procLimit}',
                o.procUsed * 100 >= o.procLimit * 90),
          if (o.sgaMb > 0) ('SGA', '${o.sgaMb} MB', false),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(children: [
              SizedBox(
                  width: 92,
                  child: Text(kv.$1,
                      style: const TextStyle(
                          color: AppColors.textLo, fontSize: 12))),
              Expanded(
                  child: Text(kv.$2,
                      style: TextStyle(
                          color: kv.$3 ? AppColors.warn : AppColors.textHi,
                          fontSize: 12))),
            ]),
          ),
      ],
      if (tbs.isNotEmpty) ...[
        const SizedBox(height: 10),
        ...tbs,
      ],
    ]);
  }
}
