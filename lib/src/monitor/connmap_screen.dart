// lib/src/monitor/connmap_screen.dart
// v2.23.0: pantalla del mapa de conexiones — tabla de aristas reales entre
// hosts (quien habla con quien, por que puerto/servicio). La pintura del
// grafo llega en la fase 3; esto ya es utilidad pura.

import 'package:flutter/material.dart';

import '../ssh/ssh_host.dart';
import '../ui/app_theme.dart';
import 'connmap_service.dart';

class ConnMapScreen extends StatefulWidget {
  final List<SshHost> hosts;
  const ConnMapScreen({super.key, required this.hosts});

  @override
  State<ConnMapScreen> createState() => _ConnMapScreenState();
}

class _ConnMapScreenState extends State<ConnMapScreen> {
  List<ConnEdge>? _edges;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final e = await ConnMapService.collect(widget.hosts);
      if (mounted) setState(() { _edges = e; _loading = false; });
    } catch (err) {
      if (mounted) setState(() { _edges = []; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textHi),
        title: const Text('Mapa de conexiones',
            style: TextStyle(color: AppColors.textHi, fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.textLo),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
          : _edges == null || _edges!.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Sin conexiones entre hosts conocidos por ahora.\n'
                      'Conecta primero a los servidores (la app solo ve las conexiones que existen).',
                      style: TextStyle(color: AppColors.textLo),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: _edges!.length,
                  separatorBuilder: (_, __) => const Divider(color: AppColors.border, height: 8),
                  itemBuilder: (_, i) {
                    final e = _edges![i];
                    final a = e.fromName, b = e.toName;
                    return Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.card,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('$a  →  $b',
                              style: const TextStyle(
                                  color: AppColors.textHi,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13)),
                          const SizedBox(height: 4),
                          Row(children: [
                            Icon(
                              e.port == 1521
                                  ? Icons.storage
                                  : e.service.contains('Tomcat')
                                      ? Icons.settings_applications
                                      : e.service.contains('Nagios')
                                          ? Icons.monitor_heart
                                          : Icons.cable,
                              size: 14,
                              color: AppColors.accent,
                            ),
                            const SizedBox(width: 6),
                            Text('${e.service} · :${e.port}',
                                style: const TextStyle(
                                    color: AppColors.accent, fontSize: 12)),
                            if (e.process != null &&
                                e.process!.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(e.process!,
                                    style: const TextStyle(
                                        color: AppColors.textLo, fontSize: 11),
                                    overflow: TextOverflow.ellipsis),
                              ),
                            ],
                            const Spacer(),
                            Text('×${e.count}',
                                style: const TextStyle(
                                    color: AppColors.textLo, fontSize: 11)),
                          ]),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
