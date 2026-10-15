// lib/src/ssh/host_map_screen.dart
//
// v2.11.0: mapa de la red segun los datos de "Auditar servicios" de cada
// host (SshHost.audit). Arriba los gateways (routers) distintos; debajo
// las tarjetas de host con un LED por servicio escuchando y chips de con
// que otros equipos habla (segun su tabla ARP). Las lineas router->host
// se miden en el layout real (posiciones de widgets claveados).

import 'package:flutter/material.dart';

import 'ssh_host.dart';
import 'ssh_hosts_service.dart';

class _C {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const accent = Color(0xFF5E9BD6);
}

class HostMapScreen extends StatefulWidget {
  const HostMapScreen({super.key});

  @override
  State<HostMapScreen> createState() => _HostMapScreenState();
}

class _HostMapScreenState extends State<HostMapScreen> {
  final _svc = SshHostsService.instance;
  final _routerKeys = <String, GlobalKey>{};
  final _hostKeys = <String, GlobalKey>{};
  final _stackKey = GlobalKey();
  final List<_Link> _links = [];

  /// LED por tipo de servicio (color por puerto bien conocido).
  Color _svcColor(int port) {
    if (port == 22) return const Color(0xFF34C759);
    if (port == 80 || port == 443 || port == 8080 || port == 8443) return const Color(0xFF0A84FF);
    if (port == 21) return const Color(0xFFFF9F0A);
    if (port == 3306 || port == 5432 || port == 6379 || port == 27017) return const Color(0xFFBF5AF2);
    if (port == 445 || port == 139 || port == 135) return const Color(0xFF64D2FF);
    if (port == 53 || port == 67 || port == 68) return const Color(0xFF30B0C7);
    return _C.textLo;
  }

  Map<String, dynamic>? _auditOf(SshHost h) => h.audit;
  List<dynamic> _servicesOf(SshHost h) => (_auditOf(h)?['services'] as List?) ?? const [];
  String? _gatewayOf(SshHost h) => _auditOf(h)?['gateway'] as String?;
  String? _lanIpOf(SshHost h) => _auditOf(h)?['lanIp'] as String?;
  Map<String, dynamic> _arpOf(SshHost h) => (_auditOf(h)?['arp'] as Map?)?.cast<String, dynamic>() ?? const {};

  List<String> get _gateways {
    final set = <String>{};
    for (final h in _svc.hosts) {
      final g = _gatewayOf(h);
      if (g != null && g.isNotEmpty) set.add(g);
    }
    final list = set.toList()..sort();
    return list;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  /// Mide posiciones de routers y hosts dentro del Stack y genera las
  /// lineas router->host.
  void _measure() {
    final stackCtx = _stackKey.currentContext;
    if (stackCtx == null) return;
    final stackBox = stackCtx.findRenderObject() as RenderBox?;
    if (stackBox == null || !stackBox.attached) return;
    final origin = stackBox.localToGlobal(Offset.zero);
    Offset? posOf(GlobalKey? key) {
      final ctx = key?.currentContext;
      if (ctx == null) return null;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) return null;
      return box.localToGlobal(Offset.zero) - origin;
    }

    final links = <_Link>[];
    for (final h in _svc.hosts) {
      final g = _gatewayOf(h);
      if (g == null || g.isEmpty) continue;
      final rk = _routerKeys[g];
      final hk = _hostKeys[h.id];
      final rp = posOf(rk);
      final hp2 = posOf(hk);
      if (rp == null || hp2 == null) continue;
      links.add(_Link(rp, hp2));
    }
    if (!listEquals(links, _links) && mounted) {
      setState(() {
        _links
          ..clear()
          ..addAll(links);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hosts = _svc.hosts;
    final gateways = _gateways;
    for (final g in gateways) {
      _routerKeys.putIfAbsent(g, () => GlobalKey());
    }
    for (final h in hosts) {
      _hostKeys.putIfAbsent(h.id, () => GlobalKey());
    }
    // Lan IPs conocidas, para cruzar ARP con otros hosts.
    final ipToHost = <String, SshHost>{};
    for (final h in hosts) {
      final ip = _lanIpOf(h);
      if (ip != null) ipToHost[ip] = h;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());

    return Scaffold(
      backgroundColor: _C.bg,
      appBar: AppBar(
        backgroundColor: _C.bg,
        elevation: 0,
        title: const Text('Mapa de hosts', style: TextStyle(color: _C.textHi)),
        iconTheme: const IconThemeData(color: _C.textHi),
      ),
      body: hosts.isEmpty
          ? const Center(child: Text('Sin hosts todavia.', style: TextStyle(color: _C.textLo)))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Stack(
                key: _stackKey,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _MapPainter(_links),
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (gateways.isNotEmpty)
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 10,
                          children: [
                            for (final g in gateways)
                              Chip(
                                key: _routerKeys[g],
                                avatar: const Icon(Icons.router, size: 18, color: _C.accent),
                                label: Text('Router $g', style: const TextStyle(color: _C.textHi, fontSize: 12)),
                                backgroundColor: _C.card,
                              ),
                          ],
                        ),
                      if (gateways.isNotEmpty) const SizedBox(height: 36),
                      Wrap(
                        spacing: 10,
                        runSpacing: 14,
                        alignment: WrapAlignment.center,
                        children: [
                          for (final h in hosts) _hostCard(h, ipToHost),
                        ],
                      ),
                      const SizedBox(height: 20),
                      if (hosts.any((h) => _auditOf(h) == null))
                        const Padding(
                          padding: EdgeInsets.all(8),
                          child: Text(
                            'Consejo: manten pulsado un host y elige "Auditar servicios" para rellenar su tarjeta.',
                            style: TextStyle(color: _C.textLo, fontSize: 12),
                            textAlign: TextAlign.center,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }

  Widget _hostCard(SshHost h, Map<String, SshHost> ipToHost) {
    final audit = _auditOf(h);
    final services = _servicesOf(h);
    final gateway = _gatewayOf(h);
    final lanIp = _lanIpOf(h);
    final groupColor = Color(_svc.groupColor(h.group ?? ''));

    // Con quien habla: vecinos ARP que son otros hosts auditados.
    final peers = <SshHost>{};
    for (final e in _arpOf(h).entries) {
      final other = ipToHost[e.key];
      if (other != null && other.id != h.id) peers.add(other);
    }

    return GestureDetector(
      key: _hostKeys[h.id],
      onTap: () => _detail(h),
      child: Container(
        width: 250,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: _C.card,
          borderRadius: BorderRadius.circular(12),
          border: Border(left: BorderSide(color: groupColor, width: 4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(h.name, style: const TextStyle(color: _C.textHi, fontSize: 14, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                if (lanIp != null)
                  Text(lanIp, style: const TextStyle(color: _C.textLo, fontSize: 11, fontFamily: 'monospace')),
              ],
            ),
            if (h.group != null && h.group!.isNotEmpty)
              Text(h.group!, style: TextStyle(color: groupColor, fontSize: 11)),
            const SizedBox(height: 6),
            if (audit == null)
              const Text('Sin auditar', style: TextStyle(color: _C.textLo, fontSize: 12)),
            ...[
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final s in services)
                    _Led(port: s['port'] as int, color: _svcColor(s['port'] as int), label: '${s['program'] ?? s['proto']}:${s['port']}'),
                ],
              ),
              if (gateway != null && gateway.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Gateway: $gateway', style: const TextStyle(color: _C.textLo, fontSize: 11)),
                ),
              if (peers.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Conecta con: ${peers.map((p) => p.name).join(', ')}',
                    style: const TextStyle(color: _C.textLo, fontSize: 11),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  void _detail(SshHost h) {
    final audit = _auditOf(h);
    final services = _servicesOf(h);
    final arp = _arpOf(h);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: Text(h.name, style: const TextStyle(color: _C.textHi, fontSize: 15)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              Text('Auditado: ${audit?['at'] ?? '-'}', style: const TextStyle(color: _C.textLo, fontSize: 11)),
              Text('IP LAN: ${audit?['lanIp'] ?? '-'}  ·  Gateway: ${audit?['gateway'] ?? '-'}', style: const TextStyle(color: _C.textLo, fontSize: 11)),
              const SizedBox(height: 8),
              const Text('Servicios', style: TextStyle(color: _C.textHi, fontSize: 13, fontWeight: FontWeight.w600)),
              if (services.isEmpty) const Text('(ninguno detectado)', style: TextStyle(color: _C.textLo, fontSize: 12)),
              for (final s in services)
                Text('${s['proto']}  :${s['port']}  ${s['program']}', style: const TextStyle(color: _C.textLo, fontSize: 12, fontFamily: 'monospace')),
              const SizedBox(height: 8),
              const Text('Vecinos ARP', style: TextStyle(color: _C.textHi, fontSize: 13, fontWeight: FontWeight.w600)),
              if (arp.isEmpty) const Text('(ninguno)', style: TextStyle(color: _C.textLo, fontSize: 12)),
              for (final e in arp.entries)
                Text('${e.key}  ${e.value}', style: const TextStyle(color: _C.textLo, fontSize: 11, fontFamily: 'monospace')),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar', style: TextStyle(color: _C.textLo)))],
      ),
    );
  }
}

class _Led extends StatelessWidget {
  final int port;
  final Color color;
  final String label;
  const _Led({required this.port, required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 4)],
        ),
      ),
    );
  }
}

class _Link {
  final Offset router;
  final Offset host;
  const _Link(this.router, this.host);
}

class _MapPainter extends CustomPainter {
  final List<_Link> links;
  _MapPainter(this.links);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _C.accent.withValues(alpha: 0.5)
      ..strokeWidth = 1.2;
    for (final l in links) {
      final start = Offset(l.router.dx + 60, l.router.dy + 20);
      final end = Offset(l.host.dx + 125, l.host.dy);
      final mid = Offset(end.dx, start.dy + (end.dy - start.dy) / 2);
      final path = Path()
        ..moveTo(start.dx, start.dy)
        ..lineTo(mid.dx, mid.dy)
        ..lineTo(end.dx, end.dy);
      canvas.drawPath(path, paint);
      canvas.drawCircle(end, 2.5, paint..style = PaintingStyle.fill);
    }
  }

  @override
  bool shouldRepaint(_MapPainter old) => old.links != links;
}

bool listEquals(List<_Link> a, List<_Link> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if ((a[i].router - b[i].router).distance > 0.5 || (a[i].host - b[i].host).distance > 0.5) return false;
  }
  return true;
}
