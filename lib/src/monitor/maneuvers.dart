// v2.36.0 — Maniobras: acciones rapidas (read-only por defecto) por host.
// Ejecuta comandos predefinidos (o personalizados) via el pool SSH y muestra
// el resultado en una hoja. Pensado para operar desde Windows o movil sin
// abrir terminal completa.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../storage/app_paths.dart';
import '../ssh/ssh_connector.dart';
import '../ssh/ssh_host.dart';
import '../ui/app_theme.dart';

class Maneuver {
  final String name;
  final String command;
  final bool oracle;
  const Maneuver(this.name, this.command, {this.oracle = false});
}

class ManeuversService {
  static final List<Maneuver> _custom = [];
  static List<Maneuver> get custom => List.unmodifiable(_custom);

  static const defaults = <Maneuver>[
    Maneuver('Carga (uptime)', 'LC_ALL=C; uptime'),
    Maneuver('Top CPU', 'LC_ALL=C; ps -eo pcpu,pmem,args --sort=-pcpu | head -8'),
    Maneuver('Discos',
        'LC_ALL=C; df -hP | grep -vE "^(tmpfs|devtmpfs|overlay|shm)"'),
    Maneuver('Memoria', 'LC_ALL=C; free -m'),
    Maneuver('Conexiones', 'LC_ALL=C; ss -s 2>/dev/null | head -12'),
    Maneuver('Servicios fallidos',
        'LC_ALL=C; systemctl --failed --no-legend --plain 2>/dev/null | head -15'),
    Maneuver('Errores kernel (dmesg)',
        "LC_ALL=C; (dmesg -T 2>/dev/null || dmesg) | tail -15"),
  ];

  static const oracle = <Maneuver>[
    Maneuver(
        'Tablespaces',
        "sqlplus -s / as sysdba <<'EOS'\n"
            "set pages 100 feed off head off\n"
            "select tablespace_name||' '||round(used_percent,1) from dba_tablespace_usage_metrics order by 2 desc fetch first 12 rows only;\n"
            'EOS',
        oracle: true),
    Maneuver(
        'Sesiones',
        "sqlplus -s / as sysdba <<'EOS'\n"
            "set pages 100 feed off head off\n"
            "select status||' '||count(*) from v\$session group by status;\n"
            'EOS',
        oracle: true),
    Maneuver(
        'Alert log (errores)',
        "LC_ALL=C; tail -200 \$ORACLE_HOME/diag/rdbms/*/*/trace/alert_*.log 2>/dev/null | grep -E 'ORA-|WARNING' | tail -20",
        oracle: true),
  ];

  static Future<void> load() async {
    try {
      final f = File('${AppPaths.base}/maneuvers.json');
      if (!f.existsSync()) return;
      final l = jsonDecode(await f.readAsString()) as List;
      _custom
        ..clear()
        ..addAll(l.map((e) => Maneuver(e['name'], e['command'])));
    } catch (_) {}
  }

  static Future<void> add(Maneuver m) async {
    _custom.add(m);
    await _save();
  }

  static Future<void> _save() async {
    try {
      final f = File('${AppPaths.base}/maneuvers.json');
      await f.writeAsString(jsonEncode(_custom
          .map((m) => {'name': m.name, 'command': m.command})
          .toList()));
    } catch (_) {}
  }
}

Future<void> showManeuversSheet(BuildContext context, SshHost host,
    {bool withOracle = false}) async {
  await ManeuversService.load();
  if (!context.mounted) return;
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.card,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final items = <Maneuver>[
          ...ManeuversService.defaults,
          if (withOracle) ...ManeuversService.oracle,
          ...ManeuversService.custom,
        ];
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                child: Row(
                  children: [
                    const Icon(Icons.bolt, color: AppColors.accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Maniobras — ${host.name}',
                          style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textHi)),
                    ),
                    IconButton(
                      tooltip: 'Nueva maniobra',
                      icon: const Icon(Icons.add, color: AppColors.accent),
                      onPressed: () async {
                        final added = await _addDialog(ctx);
                        if (added != null) {
                          await ManeuversService.add(added);
                          setSheet(() {});
                        }
                      },
                    ),
                  ],
                ),
              ),
              const Divider(color: AppColors.border),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final m in items)
                      ListTile(
                        dense: true,
                        leading: Icon(
                            m.oracle
                                ? Icons.storage
                                : (ManeuversService.custom.contains(m)
                                    ? Icons.build
                                    : Icons.terminal),
                            color: AppColors.textLo,
                            size: 18),
                        title: Text(m.name,
                            style: const TextStyle(color: AppColors.textHi)),
                        subtitle: Text(
                          m.command.replaceAll('\n', ' '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.textLo, fontSize: 10),
                        ),
                        trailing: const Icon(Icons.play_arrow,
                            color: AppColors.accent, size: 18),
                        onTap: () {
                          Navigator.pop(ctx);
                          _runManeuver(context, host, m);
                        },
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    ),
  );
}

Future<Maneuver?> _addDialog(BuildContext context) async {
  final nameCtrl = TextEditingController();
  final cmdCtrl = TextEditingController();
  return showDialog<Maneuver>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.card,
      title: const Text('Nueva maniobra',
          style: TextStyle(color: AppColors.textHi, fontSize: 15)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
                'Comando propio: bajo tu responsabilidad. Los predefinidos son de solo lectura.',
                style: TextStyle(color: AppColors.warn, fontSize: 11)),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: nameCtrl,
            style: const TextStyle(color: AppColors.textHi),
            decoration: const InputDecoration(
                labelText: 'Nombre',
                labelStyle: TextStyle(color: AppColors.textLo)),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: cmdCtrl,
            maxLines: 3,
            style: const TextStyle(color: AppColors.textHi, fontSize: 12),
            decoration: const InputDecoration(
                labelText: 'Comando',
                labelStyle: TextStyle(color: AppColors.textLo)),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancelar',
              style: TextStyle(color: AppColors.textLo)),
        ),
        FilledButton(
          onPressed: () {
            if (nameCtrl.text.trim().isEmpty ||
                cmdCtrl.text.trim().isEmpty) {
              return;
            }
            Navigator.pop(
                ctx, Maneuver(nameCtrl.text.trim(), cmdCtrl.text.trim()));
          },
          child: const Text('Guardar'),
        ),
      ],
    ),
  );
}

Future<void> _runManeuver(
    BuildContext context, SshHost host, Maneuver m) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
      SnackBar(content: Text('⚡ ${m.name} en ${host.name}…')));
  String out;
  try {
    final conn = await SshConnector.connect(host,
        timeout: const Duration(seconds: 8));
    try {
      final raw = await conn.c
          .run(m.command)
          .timeout(const Duration(seconds: 30));
      out = utf8.decode(raw, allowMalformed: true);
    } finally {
      conn.close();
    }
    if (out.trim().isEmpty) out = '(sin salida)';
  } catch (e) {
    out = 'ERROR: $e';
  }
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.card,
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.65,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
            child: Row(
              children: [
                const Icon(Icons.bolt, color: AppColors.accent, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('${m.name} — ${host.name}',
                      style: const TextStyle(
                          color: AppColors.textHi,
                          fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: AppColors.textLo),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
          ),
          const Divider(color: AppColors.border, height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                out,
                style: TextStyle(
                    color:
                        out.startsWith('ERROR') ? AppColors.err : AppColors.textHi,
                    fontSize: 12,
                    fontFamily: 'monospace'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
