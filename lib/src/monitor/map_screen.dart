// lib/src/monitor/map_screen.dart
// v2.24.2: arrastre por Listener (inmune a la arena de gestos del tap),
// insignia de conexiones por nodo, icono BD en nodos Oracle, filtros por
// servicio (grafo + lista), leyenda, aristas LED, detalle al tocar.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:xterm/xterm.dart';

import '../ssh/ssh_connector.dart';
import '../ssh/ssh_credentials_store.dart';
import '../ssh/ssh_host.dart';
import '../ssh/ssh_hosts_service.dart';
import '../storage/app_paths.dart';
import '../terminal/terminal_session.dart';
import '../terminal/terminal_view.dart';
import '../ui/app_theme.dart';
import 'connmap_service.dart';
import 'maneuvers.dart';
import 'report_pdf.dart';

class MapScreen extends StatefulWidget {
  final List<SshHost> hosts;
  // v2.39.0 — cuando se pide auditar UN host desde su menu: preseleccion
  // y auditoria inmediata (accion explicita del usuario).
  final Set<String>? initialSelection;
  const MapScreen(
      {super.key, required this.hosts, this.initialSelection});

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
  // v2.31.0
  String os = '';
  String uptime = '';
  double load1 = 0;
  _Node(this.id, this.name,
      {this.up = false, this.external = false, this.fx = 0.5, this.fy = 0.5});
}

class _MapScreenState extends State<MapScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final List<_Node> _nodes = [];
  final List<ConnEdge> _edges = [];
  bool _loading = false; // v2.29.2: sin auto-auditoria, no cargando al entrar
  bool _showExternal = false; // v2.30.0 - ocultar '· externo ·' por defecto
  final List<String> _auditLog = []; // v2.34.0
  // v2.40.0 — shell incrustado
  TerminalSession? _shell;
  SshHost? _shellHost;
  bool _shellOpen = false;
  String _groupFilter = ''; // v2.29.0 '' = todos los grupos
  Set<String> _selHosts = {}; // v2.29.0 nombres; vacio = todos
  String? _error;
  Map<String, dynamic> _layout = {};
  String _filter = 'Todos';
  _Node? _drag;
  bool _exporting = false; // v2.26.0

  File get _layoutFile => File('${AppPaths.base}/map_layout.json');

  static const _filters = [
    'Todos', 'Oracle', 'Tomcat', 'Nagios', 'rsyslog', 'SSH', 'Web'
  ];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    // v2.29.1: SIN auto-auditoria al entrar. Se audita solo a peticion
    // explicita: boton de actualizar, chip de grupo o 'Auditar seleccion'.
    // v2.39.0: excepcion — venir con initialSelection ES la peticion
    // explicita (menu 'Auditar este host en el mapa').
    if (widget.initialSelection != null &&
        widget.initialSelection!.isNotEmpty) {
      _selHosts = {...widget.initialSelection!};
      _load();
    } else {
      _restoreSnapshot();
    }
  }



  @override
  void dispose() {
    _tab.dispose();
    _shell?.dispose();
    super.dispose();
  }

  // v2.29.0 — mapa selectivo: por grupo y por host
  List<SshHost> get _effectiveHosts {
    var hs = widget.hosts;
    if (_groupFilter.isNotEmpty) {
      hs = hs.where((h) => h.group == _groupFilter).toList();
    }
    if (_selHosts.isNotEmpty) {
      hs = hs.where((h) => _selHosts.contains(h.name)).toList();
    }
    return hs;
  }

  // v2.30.0 - filtro de ruido: nodo y aristas externas
  List<_Node> get _displayNodes =>
      _nodes.where((n) => _showExternal || !n.external).toList();

  List<ConnEdge> get _displayEdges => _visibleEdges
      .where(
          (e) => _showExternal || (e.fromIp != '<ext>' && e.toIp != '<ext>'))
      .toList();

  void _showHostPicker() {
    final base = _groupFilter.isEmpty
        ? widget.hosts
        : widget.hosts.where((h) => h.group == _groupFilter).toList();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Auditar solo estos hosts',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textHi)),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final h in base)
                          CheckboxListTile(
                            dense: true,
                            value: _selHosts.contains(h.name),
                            title: Text(h.name,
                                style:
                                    const TextStyle(color: AppColors.textHi)),
                            subtitle: Text(
                                '${h.hostname}${(h.group?.isEmpty ?? true) ? '' : ' · ${h.group}'}',
                                style:
                                    const TextStyle(color: AppColors.textLo)),
                            onChanged: (v) => setSheet(() {
                              if (v == true) {
                                _selHosts.add(h.name);
                              } else {
                                _selHosts.remove(h.name);
                              }
                            }),
                          ),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      TextButton(
                        onPressed: () {
                          _selHosts.clear();
                          Navigator.pop(ctx);
                          setState(() {});
                          _load();
                        },
                        child: const Text('Todos',
                            style: TextStyle(color: AppColors.textLo)),
                      ),
                      FilledButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          setState(() {});
                          _load();
                        },
                        child: const Text('Auditar selección'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    if (_effectiveHosts.isEmpty) {
      setState(() {
        _edges.clear();
        _nodes.clear();
        _recalcMeta();
        _loading = false;
      });
      return;
    }
    try {
      if (await _layoutFile.exists()) {
        _layout = jsonDecode(await _layoutFile.readAsString());
      }
    } catch (_) {}
    final List<String> failures = [];
    List<ConnEdge> edges;
    try {
      _auditLog.clear();
      edges = await ConnMapService.collect(
        _effectiveHosts,
        onLog: (m) {
          if (!mounted) return;
          setState(() => _auditLog.add(m));
        },
      );
    } catch (e) {
      edges = const [];
    }
    final upMap = <String, bool>{};
    await Future.wait(_effectiveHosts.map((h) async {
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
      for (final h in _effectiveHosts) {
        final hf = ConnMapService.facts[h.hostname];
        _nodes.add(_Node(h.hostname, h.name, up: upMap[h.hostname] ?? false)
          ..fx = ((_layout[h.hostname]?['fx']) as num?)?.toDouble() ?? -1
          ..fy = ((_layout[h.hostname]?['fy']) as num?)?.toDouble() ?? -1
          ..os = hf?.os ?? ''
          ..uptime = hf?.uptime ?? ''
          ..load1 = hf?.load1 ?? 0);
      }
      if (_edges.any((e) => e.fromIp == '<ext>' || e.toIp == '<ext>')) {
        _nodes.add(_Node('<ext>', '· externo ·', external: true)
          ..fx = ((_layout['<ext>']?['fx']) as num?)?.toDouble() ?? -1
          ..fy = ((_layout['<ext>']?['fy']) as num?)?.toDouble() ?? -1);
      }
      _recalcMeta();
      unawaited(_saveSnapshot());
      _loading = false;
      _error = _visibleEdges.isEmpty && failures.isNotEmpty
          ? 'fallo en: ' + failures.join(', ')
          : null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoLayout());
  }

  // v2.40.0 — persistir/restaurar la ultima auditoria (salir del mapa no la pierde)
  Future<void> _saveSnapshot() async {
    try {
      final f = File('${AppPaths.base}/map_snapshot.json');
      final j = <String, dynamic>{
        'ts': DateTime.now().toIso8601String(),
        'group': _groupFilter,
        'sel': _selHosts.toList(),
        'edges': [
          for (final e in _edges)
            {
              'fip': e.fromIp,
              'fn': e.fromName,
              'tip': e.toIp,
              'tn': e.toName,
              'p': e.port,
              's': e.service,
              'pr': e.process,
              'c': e.count
            }
        ],
        'listen': {
          for (final e in ConnMapService.listen.entries)
            e.key: [
              for (final l in e.value)
                {'pr': l.proto, 'po': l.port, 'pg': l.program}
            ]
        },
        'docker': {
          for (final e in ConnMapService.docker.entries)
            e.key: [
              for (final c in e.value)
                {'n': c.name, 'i': c.image, 's': c.status, 'p': c.ports}
            ]
        },
        'facts': {
          for (final e in ConnMapService.facts.entries)
            e.key: {'os': e.value.os, 'up': e.value.uptime, 'l': e.value.load1}
        },
      };
      await f.writeAsString(jsonEncode(j));
    } catch (_) {}
  }

  Future<void> _restoreSnapshot() async {
    try {
      final f = File('${AppPaths.base}/map_snapshot.json');
      if (!f.existsSync()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return;
      ConnMapService.clearFacts();
      (j['facts'] as Map?)?.forEach((k, v) {
        ConnMapService.facts[k.toString()] = HostFacts()
          ..os = (v['os'] ?? '').toString()
          ..uptime = (v['up'] ?? '').toString()
          ..load1 = ((v['l'] ?? 0) as num).toDouble();
      });
      ConnMapService.listen.clear();
      (j['listen'] as Map?)?.forEach((k, v) {
        ConnMapService.listen[k.toString()] = [
          for (final l in (v as List)) ListenSvc(l['pr'], l['po'], l['pg'])
        ];
      });
      ConnMapService.docker.clear();
      (j['docker'] as Map?)?.forEach((k, v) {
        ConnMapService.docker[k.toString()] = [
          for (final c in (v as List))
            DockerCtr(c['n'], c['i'], c['s'], c['p'])
        ];
      });
      final edges = <ConnEdge>[
        for (final e in (j['edges'] as List? ?? const []))
          ConnEdge(
              fromIp: e['fip'],
              fromName: e['fn'],
              toIp: e['tip'],
              toName: e['tn'],
              port: e['p'],
              service: e['s'],
              process: e['pr'],
              count: e['c'])
      ];
      if (!mounted) return;
      setState(() {
        _groupFilter = (j['group'] ?? '').toString();
        _selHosts = {
          for (final x in (j['sel'] as List? ?? const [])) x.toString()
        };
        _edges
          ..clear()
          ..addAll(edges);
        _nodes
          ..clear()
          ..addAll([
          for (final h in widget.hosts)
            if (edges.any((e) => e.fromIp == h.hostname ||
                    e.toIp == h.hostname) ||
                (ConnMapService.listen[h.hostname]?.isNotEmpty ?? false) ||
                (ConnMapService.docker[h.hostname]?.isNotEmpty ?? false))
              _Node(h.hostname, h.name, up: true)
                ..fx = -1
                ..fy = -1
                ..os = ConnMapService.facts[h.hostname]?.os ?? ''
                ..uptime = ConnMapService.facts[h.hostname]?.uptime ?? ''
                ..load1 = ConnMapService.facts[h.hostname]?.load1 ?? 0,
          if (edges.any((e) => e.fromIp == '<ext>' || e.toIp == '<ext>'))
            _Node('<ext>', '· externo ·', external: true),
          ]);
        _recalcMeta();
      });
      final ts = (j['ts'] ?? '').toString();
      if (ts.isNotEmpty) {
        final d = DateTime.tryParse(ts);
        final hhmm = d == null
            ? ts
            : d.hour.toString().padLeft(2, '0') + ':' +
                d.minute.toString().padLeft(2, '0');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(
                    'Mostrando la auditoría de las $hhmm — pulsa 🔄 para re-auditar')));
          }
        });
      }
    } catch (_) {}
  }

  // v2.40.0 — shell incrustado en el mapa
  Future<void> _openShell(SshHost h) async {
    _shell?.dispose();
    final pwd = await SshCredentialsStore.readPassword(h.id);
    final s = TerminalSession(h.name, sourceHost: h, password: pwd);
    s.start(columns: 100, rows: 20);
    setState(() {
      _shell = s;
      _shellHost = h;
      _shellOpen = true;
    });
  }

  Future<void> _toggleShell() async {
    if (_shellOpen) {
      setState(() => _shellOpen = false);
      return;
    }
    SshHost? h = _shellHost;
    if (h != null && !_effectiveHosts.any((x) => x.name == h!.name)) {
      h = null;
    }
    if (h == null) {
      final cands = _effectiveHosts;
      if (cands.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Sin hosts en el alcance actual')));
        return;
      }
      if (cands.length == 1) {
        h = cands.first;
      } else {
        h = await showModalBottomSheet<SshHost>(
          context: context,
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(14),
                  child: Text('Shell en…',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textHi)),
                ),
                for (final x in cands)
                  ListTile(
                    dense: true,
                    title: Text(x.name,
                        style: const TextStyle(color: AppColors.textHi)),
                    subtitle: Text(x.hostname,
                        style: const TextStyle(color: AppColors.textLo)),
                    onTap: () => Navigator.pop(ctx, x),
                  ),
              ],
            ),
          ),
        );
        if (h == null) return;
      }
    }
    await _openShell(h);
  }

  void _closeShell() {
    _shell?.dispose();
    setState(() {
      _shell = null;
      _shellHost = null;
      _shellOpen = false;
    });
  }

  Widget _buildShellPanel() {
    final s = _shell;
    if (s == null) return const SizedBox.shrink();
    return Container(
      height: 260,
      color: const Color(0xFF101418),
      child: Column(children: [
        Container(
          height: 30,
          color: const Color(0xFF161B22),
          child: Row(children: [
            const SizedBox(width: 8),
            const Icon(Icons.terminal, size: 14, color: AppColors.accent),
            const SizedBox(width: 6),
            Expanded(
                child: Text('shell — ${_shellHost?.name ?? ''}',
                    style: const TextStyle(
                        color: AppColors.textHi, fontSize: 12))),
            IconButton(
                icon: const Icon(Icons.keyboard_hide,
                    size: 16, color: AppColors.textLo),
                tooltip: 'Ocultar',
                onPressed: () => setState(() => _shellOpen = false)),
            IconButton(
                icon: const Icon(Icons.close, size: 16, color: AppColors.err),
                tooltip: 'Cerrar sesión',
                onPressed: _closeShell),
          ]),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: TerminalView(s.terminal, controller: s.controller),
          ),
        ),
      ]),
    );
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

  // v2.30.0 - ficha de nodo: IPs, grupo y servicios con puerto/proceso/conteo.
  void _showNodeDetail(_Node n) {
    final myEdges =
        _displayEdges.where((e) => e.fromIp == n.id || e.toIp == n.id).toList();
    final ips = <String>{};
    final agg = <String, int>{};
    final procOf = <String, String>{};
    if (ips.isEmpty &&
        RegExp(r'^\d{1,3}(\.\d{1,3}){3}\$').hasMatch(n.id)) {
      ips.add(n.id);
    }
    for (final e in myEdges) {
      final other = e.fromIp == n.id ? e.toIp : e.fromIp;
      if (other != '<ext>') ips.add(other);
      final k = '${e.service} :${e.port}';
      agg[k] = (agg[k] ?? 0) + e.count;
      final pr = e.process ?? '';
      if (pr.isNotEmpty) procOf[k] = pr;
    }
    var group = '';
    for (final h in widget.hosts) {
      if (h.name == n.name || h.hostname == n.id) {
        group = h.group ?? '';
        break;
      }
    }
    final keys = agg.keys.toList()..sort();
    // v2.34.0 - puertos en escucha (dedup, conocidos primero)
    final seenL = <String>{};
    final lsvcs = <ListenSvc>[];
    for (final e in ConnMapService.listen[n.id] ?? const <ListenSvc>[]) {
      if (seenL.add('\${e.proto}:\${e.port}')) lsvcs.add(e);
    }
    SshHost? mhost;
    for (final h in widget.hosts) {
      if (h.name == n.name || h.hostname == n.id) {
        mhost = h;
        break;
      }
    }
    final hasOracle = (ConnMapService.listen[n.id] ?? const <ListenSvc>[])
        .any((e) => e.port == 1521);
    lsvcs.sort((a, b) {
      final ka = ConnMapService.kServiceByPort.containsKey(a.port) ? 0 : 1;
      final kb = ConnMapService.kServiceByPort.containsKey(b.port) ? 0 : 1;
      if (ka != kb) return ka - kb;
      return a.port.compareTo(b.port);
    });
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.card,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Icon(Icons.circle,
                size: 12, color: n.up ? AppColors.ok : AppColors.err),
            const SizedBox(width: 8),
            Expanded(
              child: Text(n.name,
                  style: const TextStyle(
                      color: AppColors.textHi,
                      fontWeight: FontWeight.w600,
                      fontSize: 16)),
            ),
            Text(n.up ? 'UP' : 'DOWN',
                style: TextStyle(
                    color: n.up ? AppColors.ok : AppColors.err,
                    fontWeight: FontWeight.bold)),
          ]),
          if (group.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Grupo: $group',
                    style:
                        const TextStyle(color: AppColors.textLo, fontSize: 12)),
              ),
            ),
          if (ips.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Text('IPs: ${ips.take(4).join(', ')}',
                  style:
                      const TextStyle(color: AppColors.textLo, fontSize: 12)),
            ),
          if (n.os.isNotEmpty || n.load1 > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  [
                    if (n.os.isNotEmpty) 'SO: ${n.os}',
                    if (n.uptime.isNotEmpty && n.uptime != 'n/a')
                      'Up: ${n.uptime.replaceFirst('up ', '')}',
                    if (n.load1 > 0) 'Carga: ${n.load1.toStringAsFixed(2)}',
                  ].join(' · '),
                  style:
                      const TextStyle(color: AppColors.textLo, fontSize: 12),
                ),
              ),
            ),
          const Divider(color: AppColors.border, height: 18),
          for (final k in keys)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(children: [
                Expanded(
                  child: Text(k,
                      style: const TextStyle(
                          color: AppColors.textHi, fontSize: 13)),
                ),
                if (procOf[k] != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(procOf[k]!,
                        style: const TextStyle(
                            color: AppColors.textLo, fontSize: 12)),
                  ),
                Text('x${agg[k]}',
                    style:
                        const TextStyle(color: AppColors.accent, fontSize: 12)),
              ]),
            ),
          if (lsvcs.isNotEmpty) ...[
            const Divider(color: AppColors.border, height: 18),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('En escucha (\${lsvcs.length}):',
                  style: const TextStyle(
                      color: AppColors.textHi,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 4),
            for (final e in lsvcs.take(24))
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(children: [
                  Text(e.proto,
                      style: const TextStyle(
                          color: AppColors.textLo, fontSize: 11)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        '\${ConnMapService.serviceLabel(e.port)} :\${e.port}',
                        style: const TextStyle(
                            color: AppColors.textHi, fontSize: 12)),
                  ),
                  if (e.program.isNotEmpty)
                    Text(e.program,
                        style: const TextStyle(
                            color: AppColors.textLo, fontSize: 11)),
                ]),
              ),
          ],
          if (ConnMapService.docker[n.id]?.isNotEmpty ?? false) ...[
            const Divider(color: AppColors.border, height: 18),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                  'Docker (\${ConnMapService.docker[n.id]!.length}):',
                  style: const TextStyle(
                      color: AppColors.textHi,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 4),
            for (final c in ConnMapService.docker[n.id]!.take(12))
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(children: [
                  Expanded(
                    child: Text(c.name,
                        style: const TextStyle(
                            color: AppColors.textHi, fontSize: 12)),
                  ),
                  Text(c.status,
                      style: const TextStyle(
                          color: AppColors.textLo, fontSize: 11)),
                ]),
              ),
          ],
          if (mhost != null) ...[
            const Divider(color: AppColors.border, height: 18),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  showManeuversSheet(context, mhost!,
                      withOracle: hasOracle);
                },
                icon: const Icon(Icons.bolt,
                    color: AppColors.accent, size: 18),
                label: const Text('Maniobras',
                    style: TextStyle(color: AppColors.accent)),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  final hh = mhost!;
                  Navigator.pop(context);
                  _openShell(hh);
                },
                icon: const Icon(Icons.terminal,
                    color: AppColors.accent, size: 18),
                label: const Text('Shell aquí',
                    style: TextStyle(color: AppColors.accent)),
              ),
            ),
          ],
          if (keys.isEmpty)
            const Text('Sin conexiones visibles para este filtro.',
                style: TextStyle(color: AppColors.textLo, fontSize: 12)),
        ]),
      ),
    );
  }

  void _onTapGraph(TapDownDetails d, Size size) {
    // v2.30.0: tocar un nodo abre su ficha de detalle
    for (final n in _displayNodes) {
      final p = Offset(n.fx * size.width, n.fy * size.height);
      if ((p - d.localPosition).distance < 48) {
        _showNodeDetail(n);
        return;
      }
    }
    ConnEdge? best;
    var bd = 34.0;
    for (final e in _displayEdges) {
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

  // v2.26.0
  Future<void> _exportPdf() async {
    if (_exporting || _nodes.isEmpty) return;
    setState(() => _exporting = true);
    try {
      final bytes = await buildTopologyReport(
        nodes: _displayNodes
            .map((n) => TopoNodeDto(
                id: n.id,
                name: n.name,
                up: n.up,
                external: n.external,
                fx: n.fx,
                fy: n.fy,
                os: n.os,
                uptime: n.uptime,
                load1: n.load1,
                hostIp: n.id,
                listen: [
                  for (final e in ConnMapService.listen[n.id] ??
                      const <ListenSvc>[])
                    TopoListenDto(e.proto, e.port, e.program),
                ],
                docker: [
                  for (final c in ConnMapService.docker[n.id] ??
                      const <DockerCtr>[])
                    TopoDockerDto(c.name, c.image, c.status, c.ports),
                ]))
            .toList(),
        edges: _displayEdges,
        appVersion: '2.40.0',
        scopeTitle: _groupFilter.isEmpty ? null : _groupFilter,
        groupOf: {for (final h in widget.hosts) h.name: h.group ?? ''},
      );
      final path = await saveAndSharePdf(
          bytes,
          'topologia_${_nowForFile()}',
          'Informe de topología TermXTR');
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
            tooltip: 'Shell en el mapa',
            icon: const Icon(Icons.terminal, color: AppColors.textLo),
            onPressed: _loading ? null : _toggleShell,
          ),
          IconButton(
            tooltip: 'Seleccionar hosts',
            icon: Icon(
                _selHosts.isEmpty
                    ? Icons.checklist
                    : Icons.playlist_add_check,
                color: _selHosts.isEmpty
                    ? AppColors.textLo
                    : AppColors.accent),
            onPressed: _loading ? null : _showHostPicker,
          ),
          IconButton(
            tooltip: 'Exportar topología PDF',
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.textLo))
                : const Icon(Icons.picture_as_pdf, color: AppColors.textLo),
            onPressed: (_nodes.isEmpty || _exporting) ? null : _exportPdf,
          ),
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
      bottomSheet: _shellOpen ? _buildShellPanel() : null,
      body: _loading
          ? Column(
              children: [
                const SizedBox(height: 24),
                const CircularProgressIndicator(color: AppColors.accent),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      for (final m in _auditLog)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text(m,
                              style: const TextStyle(
                                  color: AppColors.textLo, fontSize: 11)),
                        ),
                    ],
                  ),
                ),
              ],
            )
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
    if (_nodes.isEmpty) {
      final groups = SshHostsService.instance.groupNames;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.hub_outlined,
                  size: 40, color: AppColors.textLo),
              const SizedBox(height: 10),
              if (groups.isEmpty)
                const Text(
                  'Sin auditoria todavia.\nCrea hosts con grupo (Desarrollo / Preproduccion / Produccion) y pulsa el boton de actualizar.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textLo, fontSize: 13),
                )
              else ...[
                const Text('Elige que auditar:',
                    style: TextStyle(color: AppColors.textLo, fontSize: 13)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final g in ['', ...groups])
                      ActionChip(
                        avatar: g.isEmpty
                            ? null
                            : CircleAvatar(
                                radius: 5,
                                backgroundColor: Color(SshHostsService
                                    .instance
                                    .groupColor(g))),
                        label: Text(g.isEmpty ? 'Todos' : g,
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.textHi)),
                        backgroundColor: AppColors.card,
                        side: const BorderSide(color: AppColors.border),
                        onPressed: () => setState(() {
                          _groupFilter = g;
                          _selHosts.clear();
                          _load();
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: _showHostPicker,
                  icon: const Icon(Icons.checklist,
                      color: AppColors.accent, size: 18),
                  label: const Text('Elegir hosts concretos',
                      style: TextStyle(color: AppColors.accent)),
                ),
              ],
            ],
          ),
        ),
      );
    }
    final vis = _displayEdges;
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
                  painter: _EdgePainter(vis, _displayNodes, _edgeColor),
                ),
              ),
            ),
            for (final n in _displayNodes)
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
                      // v2.38.0 — contadores de auditoria en la caja del nodo
                      if (!n.external &&
                          ((ConnMapService.listen[n.id]?.isNotEmpty ??
                                  false) ||
                              (ConnMapService.docker[n.id]?.isNotEmpty ??
                                  false)))
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '▸${ConnMapService.listen[n.id]?.length ?? 0} ⬡${ConnMapService.docker[n.id]?.length ?? 0}',
                            style: const TextStyle(
                                color: AppColors.textLo, fontSize: 7),
                          ),
                        ),
                    ]),
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              top: 6,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (SshHostsService.instance.groupNames.isNotEmpty)
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 3),
                            child: FilterChip(
                              label: const Text('Todos',
                                  style: TextStyle(fontSize: 10)),
                              selected: _groupFilter.isEmpty,
                              onSelected: (_) => setState(() {
                                _groupFilter = '';
                                _selHosts.clear();
                                _load();
                              }),
                              selectedColor:
                                  AppColors.accent.withValues(alpha: 0.25),
                              checkmarkColor: AppColors.textHi,
                              labelStyle: TextStyle(
                                  color: _groupFilter.isEmpty
                                      ? AppColors.textHi
                                      : AppColors.textLo,
                                  fontSize: 10),
                              backgroundColor: AppColors.card,
                              side:
                                  const BorderSide(color: AppColors.border),
                            ),
                          ),
                          for (final g
                              in SshHostsService.instance.groupNames)
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 3),
                              child: FilterChip(
                                avatar: CircleAvatar(
                                    radius: 5,
                                    backgroundColor: Color(
                                        SshHostsService.instance
                                            .groupColor(g))),
                                label: Text(g,
                                    style: const TextStyle(fontSize: 10)),
                                selected: _groupFilter == g,
                                onSelected: (_) => setState(() {
                                  _groupFilter = g;
                                  _selHosts.clear();
                                  _load();
                                }),
                                selectedColor:
                                    AppColors.accent.withValues(alpha: 0.25),
                                checkmarkColor: AppColors.textHi,
                                labelStyle: TextStyle(
                                    color: _groupFilter == g
                                        ? AppColors.textHi
                                        : AppColors.textLo,
                                    fontSize: 10),
                                backgroundColor: AppColors.card,
                                side: const BorderSide(
                                    color: AppColors.border),
                              ),
                            ),
                        ],
                      ),
                    ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: FilterChip(
                            label: const Text('· externo ·',
                                style: TextStyle(fontSize: 10)),
                            selected: _showExternal,
                            onSelected: (_) =>
                                setState(() => _showExternal = !_showExternal),
                            selectedColor:
                                AppColors.accent.withValues(alpha: 0.25),
                            checkmarkColor: AppColors.textHi,
                            labelStyle: TextStyle(
                                color: _showExternal
                                    ? AppColors.textHi
                                    : AppColors.textLo,
                                fontSize: 10),
                            backgroundColor: AppColors.card,
                            side: const BorderSide(color: AppColors.border),
                          ),
                        ),
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
                ],
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

  // v2.38.0 — secciones de auditoria por nodo para la pestaña Lista.
  List<Widget> _auditSections() {
    final out = <Widget>[];
    for (final n in _displayNodes) {
      if (n.external) continue;
      final l = ConnMapService.listen[n.id] ?? const <ListenSvc>[];
      final d = ConnMapService.docker[n.id] ?? const <DockerCtr>[];
      if (l.isEmpty && d.isEmpty) continue;
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(2, 10, 2, 4),
        child: Text(n.name,
            style: const TextStyle(
                color: AppColors.textHi,
                fontWeight: FontWeight.bold,
                fontSize: 13)),
      ));
      for (final e in l) {
        out.add(Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 2),
          child: Row(children: [
            Text(e.proto,
                style:
                    const TextStyle(color: AppColors.textLo, fontSize: 10)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                  '${ConnMapService.serviceLabel(e.port)} :${e.port}${e.program.isNotEmpty ? '  -  ${e.program}' : ''}',
                  style: const TextStyle(
                      color: AppColors.textHi, fontSize: 11)),
            ),
          ]),
        ));
      }
      for (final c in d) {
        out.add(Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 2),
          child: Row(children: [
            const Icon(Icons.view_agenda,
                size: 11, color: AppColors.accent),
            const SizedBox(width: 6),
            Expanded(
              child: Text('${c.name}  -  ${c.status}',
                  style: const TextStyle(
                      color: AppColors.textHi, fontSize: 11)),
            ),
          ]),
        ));
      }
    }
    return out;
  }

  Widget _buildList() {
    final vis = _displayEdges;
    final auditChildren = _auditSections();
    if (vis.isEmpty && auditChildren.isEmpty) {
      return const Center(
        child: Text('Sin conexiones visibles para este filtro.',
            style: TextStyle(color: AppColors.textLo)),
      );
    }
    if (vis.isEmpty) {
      return ListView(
          padding: const EdgeInsets.all(12), children: auditChildren);
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: vis.length + (auditChildren.isEmpty ? 0 : 1),
      separatorBuilder: (_, __) =>
          const Divider(color: AppColors.border, height: 8),
      itemBuilder: (_, i) {
        if (auditChildren.isNotEmpty && i == vis.length) {
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(color: AppColors.border, height: 16),
                ...auditChildren,
              ]);
        }
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
