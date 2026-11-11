// lib/src/monitor/map_screen.dart
// v2.24.2: arrastre por Listener (inmune a la arena de gestos del tap),
// insignia de conexiones por nodo, icono BD en nodos Oracle, filtros por
// servicio (grafo + lista), leyenda, aristas LED, detalle al tocar.

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
  int degree = 0;
  bool isDb = false;
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
  String _filter = 'Todos';
  _Node? _drag;

  File get _layoutFile => File('${AppPaths.base}/map_layout.json');

  static const _filters = [
    'Todos', 'Oracle', 'Tomcat', 'Nagios', 'rsyslog', 'SSH', 'Web'
  ];

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
    List<ConnEdge> edges;
    try {
      edges = await ConnMapService.collect(widget.hosts);
    } catch (e) {
      edges = const [];
    }
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
        _nodes.add(_Node(h.hostname, h.name, up: upMap[h.hostname] ?? false)
          ..fx = ((_layout[h.hostname]?['fx']) as num?)?.toDouble() ?? -1
          ..fy = ((_layout[h.hostname]?['fy']) as num?)?.toDouble() ?? -1);
      }
      if (_edges.any((e) => e.fromIp == '<ext>' || e.toIp == '<ext>')) {
        _nodes.add(_Node('<ext>', '· externo ·', external: true)
          ..fx = ((_layout['<ext>']?['fx']) as num?)?.toDouble() ?? -1
          ..fy = ((_layout['<ext>']?['fy']) as num?)?.toDouble() ?? -1);
      }
      _recalcMeta();
      _loading = false;
      _error = _visibleEdges.isEmpty && failures.isNotEmpty
          ? 'fallo en: ' + failures.join(', ')
          : null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoLayout());
  }

  void _recalcMeta() {
    for (final n in _nodes) {
      n.degree = 0;
      n.isDb = false;
    }
    for (final e in _edges) {
      for (final n in _nodes) {
        if (n.id == e.fromIp || n.id == e.toIp) n.degree += e.count;
      }
      if (e.port == 1521) {
        for (final n in _nodes) {
          if (n.id == e.fromIp || n.id == e.toIp) n.isDb = true;
        }
      }
    }
  }

  List<ConnEdge> get _visibleEdges {
    if (_filter == 'Todos') return _edges;
    return _edges.where((e) {
      switch (_filter) {
        case 'Oracle':
          return e.port == 1521;
        case 'Tomcat':
          return e.service.contains('Tomcat');
        case 'Nagios':
          return e.service.contains('Nagios');
        case 'rsyslog':
          return e.service.contains('rsyslog');
        case 'SSH':
          return e.port == 22;
        case 'Web':
          return e.port == 80 || e.port == 443;
        default:
          return true;
      }
    }).toList();
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
      pend[i].fx = ((cx + r * cos(ang)) / size.width).clamp(0.12, 0.88);
      pend[i].fy = ((cy + r * sin(ang)) / size.height).clamp(0.12, 0.88);
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

  Color _edgeColor(ConnEdge e) {
    if (e.port == 1521) return const Color(0xFFFF5C5C);
    if (e.service.contains('Tomcat')) return const Color(0xFFFFA94D);
    if (e.service.contains('Nagios')) return const Color(0xFF69DB7C);
    if (e.service.contains('rsyslog')) return const Color(0xFF74C0FC);
    if (e.port == 22) return const Color(0xFFB2B2B8);
    if (e.port == 443 || e.port == 80) return const Color(0xFF5E9BD6);
    return const Color(0xFFB2B2B8);
  }

  Offset _posOf(String id, Size size) {
    for (final n in _nodes) {
      if (n.id == id) return Offset(n.fx * size.width, n.fy * size.height);
    }
    return Offset(size.width / 2, size.height / 2);
  }

  Offset _midOf(ConnEdge e, Size size) {
    final a = _posOf(e.fromIp, size);
    final b = _posOf(e.toIp, size);
    final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
    final ctrl = Offset(mid.dx, mid.dy - 18);
    return Offset(0.25 * a.dx + 0.5 * ctrl.dx + 0.25 * b.dx,
        0.25 * a.dy + 0.5 * ctrl.dy + 0.25 * b.dy);
  }

  void _onTapGraph(TapDownDetails d, Size size) {
    ConnEdge? best;
    var bd = 34.0;
    for (final e in _visibleEdges) {
      final m = _midOf(e, size);
      final dist = (m - d.localPosition).distance;
      if (dist < bd) {
        bd = dist;
        best = e;
      }
    }
    if (best == null) return;
    final e = best;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.card,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${e.fromName}  →  ${e.toName}',
              style: const TextStyle(
                  color: AppColors.textHi,
                  fontWeight: FontWeight.w600,
                  fontSize: 15)),
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.cable, size: 16, color: _edgeColor(e)),
            const SizedBox(width: 6),
            Text('${e.service} · puerto ${e.port}',
                style: TextStyle(color: _edgeColor(e), fontSize: 13)),
          ]),
          if (e.process != null && e.process!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                const Icon(Icons.terminal, size: 14, color: AppColors.textLo),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(e.process!,
                      style:
                          const TextStyle(color: AppColors.textLo, fontSize: 12)),
                ),
              ]),
            ),
          const SizedBox(height: 6),
          Text('×${e.count} conexiones',
              style: const TextStyle(color: AppColors.textHi, fontSize: 16)),
        ]),
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
    final vis = _visibleEdges;
    return LayoutBuilder(
      builder: (ctx, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        final mx = 64.0 / size.width;
        final my = 46.0 / size.height;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTapDown: (d) => _onTapGraph(d, size),
                child: CustomPaint(
                  painter: _EdgePainter(vis, _nodes, _edgeColor),
                ),
              ),
            ),
            for (final n in _nodes)
              Positioned(
                left: n.fx * size.width - 52,
                top: n.fy * size.height - 22,
                child: Listener(
                  onPointerDown: (e) => _drag = n,
                  onPointerMove: (e) {
                    if (_drag != n) return;
                    setState(() {
                      n.fx = ((n.fx * size.width + e.delta.dx) / size.width)
                          .clamp(mx, 1 - mx);
                      n.fy = ((n.fy * size.height + e.delta.dy) / size.height)
                          .clamp(my, 1 - my);
                    });
                  },
                  onPointerUp: (e) {
                    if (_drag == n) {
                      _drag = null;
                      _saveLayout();
                    }
                  },
                  child: Container(
                    width: 104,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                    decoration: BoxDecoration(
                      color: n.external ? AppColors.cardAlt : AppColors.card,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: n.up ? AppColors.ok : AppColors.border,
                        width: n.up ? 1.4 : 1,
                      ),
                      boxShadow: n.up
                          ? [
                              BoxShadow(
                                color: AppColors.ok.withValues(alpha: 0.25),
                                blurRadius: 8,
                              )
                            ]
                          : null,
                    ),
                    child:
                        Column(mainAxisSize: MainAxisSize.min, children: [
                      Row(children: [
                        Icon(Icons.circle,
                            size: 7,
                            color: n.external
                                ? AppColors.textLo
                                : (n.up ? AppColors.ok : AppColors.err)),
                        const SizedBox(width: 4),
                        if (n.isDb)
                          const Padding(
                            padding: EdgeInsets.only(right: 3),
                            child: Icon(Icons.storage,
                                size: 10, color: Color(0xFFFF5C5C)),
                          ),
                        Expanded(
                          child: Text(n.name,
                              style: const TextStyle(
                                  color: AppColors.textHi, fontSize: 10),
                              overflow: TextOverflow.ellipsis),
                        ),
                      ]),
                      Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (!n.external)
                              Text(n.up ? 'up' : 'down',
                                  style: TextStyle(
                                      color: n.up
                                          ? AppColors.ok
                                          : AppColors.err,
                                      fontSize: 8)),
                            if (n.degree > 0) ...[
                              if (!n.external)
                                const SizedBox(width: 5),
                              Text('×${n.degree}',
                                  style: const TextStyle(
                                      color: AppColors.accent, fontSize: 8)),
                            ],
                          ]),
                    ]),
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              top: 6,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final f in _filters)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: FilterChip(
                          label: Text(f,
                              style: const TextStyle(fontSize: 10)),
                          selected: _filter == f,
                          onSelected: (_) => setState(() => _filter = f),
                          selectedColor:
                              AppColors.accent.withValues(alpha: 0.25),
                          checkmarkColor: AppColors.textHi,
                          labelStyle: TextStyle(
                              color: _filter == f
                                  ? AppColors.textHi
                                  : AppColors.textLo,
                              fontSize: 10),
                          backgroundColor: AppColors.card,
                          side: const BorderSide(color: AppColors.border),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 8,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  _LegendChip('Oracle', Color(0xFFFF5C5C)),
                  _LegendChip('Tomcat', Color(0xFFFFA94D)),
                  _LegendChip('Nagios', Color(0xFF69DB7C)),
                  _LegendChip('SSH', Color(0xFFB2B2B8)),
                  _LegendChip('Web', Color(0xFF5E9BD6)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildList() {
    final vis = _visibleEdges;
    if (vis.isEmpty) {
      return const Center(
        child: Text('Sin conexiones visibles para este filtro.',
            style: TextStyle(color: AppColors.textLo)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: vis.length,
      separatorBuilder: (_, __) =>
          const Divider(color: AppColors.border, height: 8),
      itemBuilder: (_, i) {
        final e = vis[i];
        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (e.port == 1521)
                const Padding(
                  padding: EdgeInsets.only(right: 5),
                  child:
                      Icon(Icons.storage, size: 14, color: Color(0xFFFF5C5C)),
                ),
              Expanded(
                child: Text('${e.fromName}  →  ${e.toName}',
                    style: const TextStyle(
                        color: AppColors.textHi,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
              ),
            ]),
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

class _LegendChip extends StatelessWidget {
  final String label;
  final Color color;
  const _LegendChip(this.label, this.color);
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: 6)],
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(color: AppColors.textLo, fontSize: 9)),
      ]),
    );
  }
}

class _EdgePainter extends CustomPainter {
  final List<ConnEdge> edges;
  final List<_Node> nodes;
  final Color Function(ConnEdge) colorOf;
  _EdgePainter(this.edges, this.nodes, this.colorOf);

  Offset _posOf(String id, Size size) {
    for (final n in nodes) {
      if (n.id == id) return Offset(n.fx * size.width, n.fy * size.height);
    }
    return Offset(size.width / 2, size.height / 2);
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final e in edges) {
      final a = _posOf(e.fromIp, size);
      final b = _posOf(e.toIp, size);
      final color = colorOf(e);
      final stroke = 1.4 + min(e.count, 12) * 0.3;
      final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      final ctrl = Offset(mid.dx, mid.dy - 18);
      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, b.dx, b.dy);
      canvas.drawPath(
          path,
          Paint()
            ..color = color.withValues(alpha: 0.10)
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke * 4.5
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
      canvas.drawPath(
          path,
          Paint()
            ..color = color.withValues(alpha: 0.30)
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke * 2
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
      canvas.drawPath(
          path,
          Paint()
            ..color = color.withValues(alpha: 0.95)
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke);
      final dir = (b - ctrl);
      final d2 = Offset.fromDirection(dir.direction, 14);
      final p = Paint()
        ..color = color
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
      canvas.drawPath(
          Path()
            ..moveTo(b.dx, b.dy)
            ..lineTo(b.dx - d2.dx + d2.dy * 0.4, b.dy - d2.dy - d2.dx * 0.4)
            ..lineTo(b.dx - d2.dx - d2.dy * 0.4, b.dy - d2.dy + d2.dx * 0.4)
            ..close(),
          p);
      final tp = TextPainter(
        text: TextSpan(
          text: '${e.service} ×${e.count}',
          style: TextStyle(
              color: color, fontSize: 9, fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelMid = Offset(0.25 * a.dx + 0.5 * ctrl.dx + 0.25 * b.dx,
          0.25 * a.dy + 0.5 * ctrl.dy + 0.25 * b.dy);
      final pill = RRect.fromRectAndRadius(
          Rect.fromCenter(center: labelMid, width: tp.width + 10, height: 16),
          const Radius.circular(8));
      canvas.drawRRect(
          pill, Paint()..color = AppColors.bg.withValues(alpha: 0.88));
      tp.paint(canvas, Offset(labelMid.dx - tp.width / 2, labelMid.dy - 8));
    }
  }

  @override
  bool shouldRepaint(covariant _EdgePainter oldDelegate) => true;
}
