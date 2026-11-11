// lib/src/monitor/map_screen.dart
// v2.24.0: MAPA UNIFICADO — unifica "Mapa de hosts" y "Mapa de conexiones".
// Grafo: nodos arrastrables (posicion persistida), aristas etiquetadas con
// servicio/puerto/conteo, grosor proporcional, colores por familia. Pestana
// Lista: la tabla de aristas. Nodos: estado (sondeo), top servicios.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../ssh/ssh_connector.dart';
import '../ssh/ssh_host.dart';
import '../storage/app_paths.dart';
import '../ui/app_theme.dart';
import 'connmap_service.dart';

class MapScreen extends StatefulWidget {
  final List<SshHost> hosts;
  const MapScreen({super.key, required this.hosts});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _Node {
  final String id;
  final String name;
  bool up;
  bool external;
  double fx;
  double fy;
  _Node(this.id, this.name,
      {this.up = false, this.external = false, this.fx = 0.5, this.fy = 0.5});
}

class _MapScreenState extends State<MapScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final List<_Node> _nodes = [];
  final List<ConnEdge> _edges = [];
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _layout = {};

  File get _layoutFile => File('${AppPaths.base}/map_layout.json');

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (await _layoutFile.exists()) {
        _layout = jsonDecode(await _layoutFile.readAsString());
      }
    } catch (_) {}
    final List<String> failures = [];
    // aristas (recolecta interna, loguea fallos por host)
    List<ConnEdge> edges;
    try {
      edges = await ConnMapService.collect(widget.hosts);
    } catch (e) {
      edges = const [];
    }
    // sondeo paralelo de estado
    final upMap = <String, bool>{};
    await Future.wait(widget.hosts.map((h) async {
      try {
        final c = await SshConnector.connect(h,
            timeout: const Duration(seconds: 5));
        upMap[h.hostname] = true;
        c.close();
      } catch (_) {
        upMap[h.hostname] = false;
        failures.add(h.name);
      }
    }));
    if (!mounted) return;
    setState(() {
      _edges
        ..clear()
        ..addAll(edges);
      _nodes.clear();
      for (final h in widget.hosts) {
        _nodes.add(_Node(h.hostname, h.name,
            up: upMap[h.hostname] ?? false)
          ..fx = ((_layout[h.hostname]?['fx']) as num?)?.toDouble() ?? -1
          ..fy = ((_layout[h.hostname]?['fy']) as num?)?.toDouble() ?? -1);
      }
      if (_edges.any((e) => e.fromIp == '<ext>' || e.toIp == '<ext>')) {
        _nodes.add(_Node('<ext>', '· externo ·', external: true)
          ..fx = ((_layout['<ext>']?['fx']) as num?)?.toDouble() ?? -1
          ..fy = ((_layout['<ext>']?['fy']) as num?)?.toDouble() ?? -1);
      }
      _loading = false;
      _error = _edges.isEmpty && failures.isNotEmpty
          ? 'fallo en: ' + failures.join(', ')
          : null;
    });
    // layout circular para los que no tienen posicion guardada
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoLayout());
  }

  void _autoLayout() {
    final size = context.size;
    if (size == null) return;
    final pend = _nodes.where((n) => n.fx < 0 || n.fy < 0).toList();
    if (pend.isEmpty) return;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = min(size.width, size.height) * 0.36;
    pend.sort((a, b) => b.name.compareTo(a.name));
    for (var i = 0; i < pend.length; i++) {
      final ang = -pi / 2 + (2 * pi * i / pend.length);
      pend[i].fx = ((cx + r * cos(ang)) / size.width).clamp(0.08, 0.92);
      pend[i].fy = ((cy + r * sin(ang)) / size.height).clamp(0.10, 0.90);
    }
    setState(() {});
  }

  Future<void> _saveLayout() async {
    final m = <String, dynamic>{};
    for (final n in _nodes) {
      m[n.id] = {'fx': n.fx, 'fy': n.fy};
    }
    try {
      await _layoutFile.writeAsString(jsonEncode(m), flush: true);
    } catch (_) {}
  }

  _Node? _nodeById(String id) {
    for (final n in _nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  Color _edgeColor(ConnEdge e) {
    if (e.port == 1521) return const Color(0xFFFF6B6B);
    if (e.service.contains('Tomcat')) return const Color(0xFFFFA94D);
    if (e.service.contains('Nagios')) return const Color(0xFF69DB7C);
    if (e.port == 22) return AppColors.textLo;
    if (e.port == 443 || e.port == 80) return AppColors.accent;
    return AppColors.textLo;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textHi),
        title: const Text('Mapa',
            style: TextStyle(color: AppColors.textHi, fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.textLo),
            onPressed: _loading ? null : _load,
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          indicatorColor: AppColors.accent,
          labelColor: AppColors.textHi,
          unselectedLabelColor: AppColors.textLo,
          tabs: const [Tab(text: 'Grafo'), Tab(text: 'Lista')],
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.accent))
          : TabBarView(
              controller: _tab,
              children: [_buildGraph(), _buildList()],
            ),
    );
  }

  Widget _buildGraph() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              style: const TextStyle(color: AppColors.err),
              textAlign: TextAlign.center),
        ),
      );
    }
    return LayoutBuilder(
      builder: (ctx, c) {
        final pos = <String, Offset>{};
        for (final n in _nodes) {
          pos[n.id] = Offset(n.fx * c.maxWidth, n.fy * c.maxHeight);
        }
        return Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _EdgePainter(_edges, pos, _nodeById, _edgeColor),
              ),
            ),
            for (final n in _nodes)
              Positioned(
                left: pos[n.id]!.dx - 52,
                top: pos[n.id]!.dy - 22,
                child: GestureDetector(
                  onPanUpdate: (d) {
                    setState(() {
                      n.fx = ((n.fx * c.maxWidth + d.delta.dx) / c.maxWidth)
                          .clamp(0.06, 0.94);
                      n.fy = ((n.fy * c.maxHeight + d.delta.dy) / c.maxHeight)
                          .clamp(0.06, 0.94);
                    });
                  },
                  onPanEnd: (_) => _saveLayout(),
                  child: Container(
                    width: 104,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                    decoration: BoxDecoration(
                      color: n.external
                          ? AppColors.cardAlt
                          : (n.up ? AppColors.card : AppColors.cardAlt),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: n.up ? AppColors.ok : AppColors.border),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Row(children: [
                        Icon(Icons.circle,
                            size: 7,
                            color: n.external
                                ? AppColors.textLo
                                : (n.up ? AppColors.ok : AppColors.err)),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(n.name,
                              style: const TextStyle(
                                  color: AppColors.textHi, fontSize: 10),
                              overflow: TextOverflow.ellipsis),
                        ),
                      ]),
                      if (!n.external)
                        Text(n.up ? 'up' : 'down',
                            style: TextStyle(
                                color: n.up ? AppColors.ok : AppColors.err,
                                fontSize: 8)),
                    ]),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildList() {
    if (_edges.isEmpty) {
      return const Center(
        child: Text('Sin conexiones visibles todavia.',
            style: TextStyle(color: AppColors.textLo)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _edges.length,
      separatorBuilder: (_, __) =>
          const Divider(color: AppColors.border, height: 8),
      itemBuilder: (_, i) {
        final e = _edges[i];
        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${e.fromName}  →  ${e.toName}',
                style: const TextStyle(
                    color: AppColors.textHi,
                    fontWeight: FontWeight.w600,
                    fontSize: 13)),
            const SizedBox(height: 4),
            Row(children: [
              Icon(Icons.cable, size: 14, color: _edgeColor(e)),
              const SizedBox(width: 6),
              Text('${e.service} · :${e.port}',
                  style: TextStyle(color: _edgeColor(e), fontSize: 12)),
              if (e.process != null && e.process!.isNotEmpty) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(e.process!,
                      style:
                          const TextStyle(color: AppColors.textLo, fontSize: 11),
                      overflow: TextOverflow.ellipsis),
                ),
              ],
              const Spacer(),
              Text('×${e.count}',
                  style: const TextStyle(color: AppColors.textLo, fontSize: 11)),
            ]),
          ]),
        );
      },
    );
  }
}

class _EdgePainter extends CustomPainter {
  final List<ConnEdge> edges;
  final Map<String, Offset> pos;
  final _Node? Function(String) nodeById;
  final Color Function(ConnEdge) colorOf;
  _EdgePainter(this.edges, this.pos, this.nodeById, this.colorOf);

  @override
  void paint(Canvas canvas, Size size) {
    for (final e in edges) {
      final a = pos[e.fromIp];
      final b = pos[e.toIp];
      if (a == null || b == null) continue;
      final color = colorOf(e);
      final stroke = (1.2 + min(e.count, 12) * 0.28);
      final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      final ctrl = Offset(mid.dx, mid.dy - 18);
      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, b.dx, b.dy);
      canvas.drawPath(
          path,
          Paint()
            ..color = color.withValues(alpha: 0.65)
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke);
      // flecha en destino
      final dir = (b - ctrl);
      final d2 = Offset.fromDirection(dir.direction, 14);
      final p = Paint()..color = color.withValues(alpha: 0.8);
      canvas.drawPath(
          Path()
            ..moveTo(b.dx, b.dy)
            ..lineTo(b.dx - d2.dx + d2.dy * 0.4, b.dy - d2.dy - d2.dx * 0.4)
            ..lineTo(b.dx - d2.dx - d2.dy * 0.4, b.dy - d2.dy + d2.dx * 0.4)
            ..close(),
          p);
      // etiqueta
      final tp = TextPainter(
        text: TextSpan(
          text: '${e.service} ×${e.count}',
          style: TextStyle(color: color, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final pill = RRect.fromRectAndRadius(
          Rect.fromCenter(center: mid, width: tp.width + 10, height: 16),
          const Radius.circular(8));
      canvas.drawRRect(
          pill, Paint()..color = AppColors.bg.withValues(alpha: 0.85));
      tp.paint(canvas, Offset(mid.dx - tp.width / 2, mid.dy - 8));
    }
  }

  @override
  bool shouldRepaint(covariant _EdgePainter oldDelegate) => true;
}
