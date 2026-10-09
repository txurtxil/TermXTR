import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:share_plus/share_plus.dart';

import 'ssh_host.dart';
import 'ssh_hosts_service.dart';
import 'multi_exec_screen.dart';
import 'identity_screen.dart';
import 'identity_service.dart';
import 'snippets_screen.dart';
import 'tunnels_screen.dart';
import '../sftp/transfers_screen.dart';
import 'power_service.dart';
import 'ssh_credentials_store.dart';
import '../storage/app_paths.dart';
import '../sftp/sftp_browser_screen.dart';
import '../sftp/sftp_connection_pool.dart';

class _C {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const cardAlt = Color(0xFF242426);
  static const border = Color(0xFF3A3A3C);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const accent = Color(0xFF5E9BD6);
  static const err = Color(0xFFFF453A);
}

const Map<String, Color> _osColors = {
  'debian': Color(0xFFD70A53), 'ubuntu': Color(0xFFE95420),
  'raspbian': Color(0xFFC51A4A), 'generic': Color(0xFF2D5F8A),
};

class HostsScreen extends StatefulWidget {
  final void Function(SshHost host) onConnect;
  final String? rootfsPath;
  final void Function(SshHost host)? onOpenTerminalFromSftp;

  const HostsScreen({super.key, required this.onConnect, this.rootfsPath, this.onOpenTerminalFromSftp});

  @override
  State<HostsScreen> createState() => _HostsScreenState();
}

class _HostsScreenState extends State<HostsScreen> {
  final _svc = SshHostsService.instance;
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  /// v2.10.0: grupos colapsados (clave '' = 'Sin grupo').
  final Set<String> _collapsed = {};

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChange);
  }

  @override
  void dispose() {
    _svc.removeListener(_onChange);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  List<SshHost> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _svc.hosts;
    return _svc.hosts.where((h) =>
        h.name.toLowerCase().contains(q) ||
        h.hostname.toLowerCase().contains(q) ||
        h.username.toLowerCase().contains(q) ||
        (h.group ?? '').toLowerCase().contains(q)).toList();
  }

  /// v2.10.0: exporta todo o un solo grupo. Esquema version 3: añade
  /// 'group' en cada host y 'groupMeta' (colores). Sigue leyendo/exportando
  /// backups v2 (sin grupos) sin problemas.
  Future<void> _exportHosts({String? group}) async {
    final hosts = group == null ? _svc.hosts : _svc.hostsInGroup(group);
    if (hosts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No hay hosts que exportar')));
      return;
    }
    final list = <Map<String, dynamic>>[];
    for (final h in hosts) {
      final json = h.toJson();
      final pwd = await SshCredentialsStore.readPassword(h.id);
      if (pwd != null && pwd.isNotEmpty) {
        json['password_export'] = pwd;
      }
      list.add(json);
    }

    // Snippets solo tienen sentido en el backup completo.
    List<dynamic> snippets = [];
    if (group == null) {
      try {
        final sf = File('${AppPaths.base}/snippets.json');
        if (await sf.exists()) {
          snippets = jsonDecode(await sf.readAsString()) as List<dynamic>;
        }
      } catch (_) {}
    }
    final groupMeta = <String, int>{};
    for (final g in _svc.groupNames) {
      groupMeta[g] = _svc.groupColor(g);
    }
    final backup = {
      'type': 'termxtr-backup',
      'version': 3,
      'exportedAt': DateTime.now().toIso8601String(),
      'hosts': list,
      if (group == null) 'snippets': snippets,
      'groupMeta': groupMeta,
    };
    final jsonString = const JsonEncoder.withIndent('  ').convert(backup);

    try {
      final safe = group == null
          ? 'termxtr_backup'
          : 'termxtr_hosts_' + group.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final file = XFile.fromData(
        utf8.encode(jsonString),
        name: '$safe.json',
        mimeType: 'application/json',
      );
      // Usar share_plus esquiva el error UnimplementedError de file_selector en Android
      await Share.shareXFiles([file], text: group == null ? 'Copia de seguridad de Hosts XTR' : 'Hosts del grupo $group');
    } catch (e) {
      if (mounted) {
        Clipboard.setData(ClipboardData(text: jsonString));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error al crear archivo. Copiado al portapapeles como alternativa.')));
      }
    }
  }

  /// v2.10.0: import con preview. Clasifica cada host como nuevo,
  /// actualizable (mismo id, backup de este dispositivo) o duplicado
  /// (misma hostname:puerto:usuario, distinto id, backup de otro
  /// dispositivo) y deja elegir que hacer con los duplicados antes de
  /// escribir nada.
  Future<void> _importHosts() async {
    try {
      const XTypeGroup typeGroup = XTypeGroup(label: 'JSONs', extensions: <String>['json']);
      final XFile? file = await openFile(acceptedTypeGroups: <XTypeGroup>[typeGroup]);

      if (file == null) return;

      final content = await file.readAsString();
      final decoded = jsonDecode(content);
      List<dynamic> list;
      List<dynamic>? snippets;
      Map<String, dynamic>? groupMeta;
      if (decoded is Map && decoded['type'] == 'termxtr-backup') {
        list = (decoded['hosts'] as List?) ?? [];
        snippets = decoded['snippets'] as List?;
        groupMeta = decoded['groupMeta'] as Map<String, dynamic>?;
      } else {
        list = decoded as List<dynamic>;
      }
      if (list.isEmpty) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('El fichero no contiene hosts')));
        return;
      }

      final existingById = <String, SshHost>{};
      final existingByKey = <String, SshHost>{};
      for (final h in _svc.hosts) {
        existingById[h.id] = h;
        existingByKey['${h.hostname}:${h.port}:${h.username}'] = h;
      }

      final parsed = <_ImportEntry>[];
      var fresh = 0, updates = 0, dupes = 0;
      for (final item in list) {
        final map = Map<String, dynamic>.from(item as Map);
        final pwd = map.remove('password_export') as String?;
        final host = SshHost.fromJson(map);
        final byId = existingById[host.id];
        final byKey = existingByKey['${host.hostname}:${host.port}:${host.username}'];
        if (byId != null) {
          parsed.add(_ImportEntry(host, pwd, _ImportKind.update, byId));
          updates++;
        } else if (byKey != null) {
          parsed.add(_ImportEntry(host, pwd, _ImportKind.dupe, byKey));
          dupes++;
        } else {
          parsed.add(_ImportEntry(host, pwd, _ImportKind.fresh, null));
          fresh++;
        }
      }

      if (!mounted) return;
      var sel = _DupeMode.skip;
      final mode = await showDialog<_DupeMode>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDlg) {
            return AlertDialog(
              backgroundColor: _C.card,
              title: const Text('Importar hosts', style: TextStyle(color: _C.textHi, fontSize: 16)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$fresh nuevos · $updates actualizables · $dupes duplicados', style: const TextStyle(color: _C.textLo, fontSize: 13)),
                  const SizedBox(height: 12),
                  for (final opt in const [
                    (_DupeMode.skip, 'Omitir duplicados', 'Solo añade hosts que no existen ya'),
                    (_DupeMode.update, 'Actualizar duplicados', 'Los duplicados sobrescriben el host existente (misma maquina)'),
                    (_DupeMode.importAll, 'Importar todo como nuevos', 'Crea copias con nuevo id (puede haber hosts repetidos)'),
                  ])
                    RadioListTile<_DupeMode>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: opt.$1,
                      groupValue: sel,
                      onChanged: (v) => setDlg(() => sel = v ?? _DupeMode.skip),
                      title: Text(opt.$2, style: const TextStyle(color: _C.textHi, fontSize: 14)),
                      subtitle: Text(opt.$3, style: const TextStyle(color: _C.textLo, fontSize: 11)),
                      activeColor: _C.accent,
                    ),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar', style: TextStyle(color: _C.textLo))),
                FilledButton(onPressed: () => Navigator.pop(ctx, sel), child: const Text('Importar')),
              ],
            );
          },
        ),
      );
      if (mode == null) return;

      var count = 0;
      for (final e in parsed) {
        var h = e.host;
        if (e.kind == _ImportKind.dupe) {
          if (mode == _DupeMode.skip) continue;
          if (mode == _DupeMode.update) {
            h = SshHost(
              id: e.existing!.id, name: h.name, hostname: h.hostname, port: h.port,
              username: h.username, keyPath: h.keyPath, initialPath: h.initialPath,
              osTag: h.osTag, lastUsed: h.lastUsed, jumpHostId: h.jumpHostId,
              macAddress: h.macAddress, group: h.group,
            );
            await _svc.update(h);
          } else {
            h = SshHost(
              id: _svc.newId(), name: h.name, hostname: h.hostname, port: h.port,
              username: h.username, keyPath: h.keyPath, initialPath: h.initialPath,
              osTag: h.osTag, lastUsed: h.lastUsed, jumpHostId: h.jumpHostId,
              macAddress: h.macAddress, group: h.group,
            );
            await _svc.add(h);
          }
        } else if (e.kind == _ImportKind.update) {
          await _svc.update(h);
        } else {
          await _svc.add(h);
        }
        if (e.pwd != null && e.pwd!.isNotEmpty) {
          await SshCredentialsStore.savePassword(h.id, e.pwd!);
        }
        count++;
      }
      // Restaurar colores de grupo si el backup los trae.
      if (groupMeta != null) {
        for (final e in groupMeta.entries) {
          if (e.value is num) await _svc.setGroupColor(e.key, (e.value as num).toInt());
        }
      }
      // Restaurar snippets si el backup completo los trae.
      if (snippets != null) {
        try {
          final sf = File('${AppPaths.base}/snippets.json');
          await sf.writeAsString(jsonEncode(snippets), flush: true);
        } catch (_) {}
      }
      if (!mounted) return;
      final extra = snippets != null ? ' y ${snippets.length} snippets' : '';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$count hosts$extra importados con éxito')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error: Archivo inválido o corrupto')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hosts = _filtered;
    return Scaffold(
      backgroundColor: _C.bg,
      appBar: AppBar(
        backgroundColor: _C.bg,
        elevation: 0,
        title: const Text('Hosts', style: TextStyle(color: _C.textHi)),
        iconTheme: const IconThemeData(color: _C.textHi),
        actions: [
          IconButton(
            tooltip: 'Cola de transferencias entre equipos',
            icon: const Icon(Icons.swap_horiz, color: _C.textLo),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const TransfersScreen()),
              );
            },
          ),
          IconButton(
            tooltip: 'Identidad SSH (claves sin password)',
            icon: const Icon(Icons.vpn_key, color: _C.textLo),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const IdentityScreen()),
              );
            },
          ),
          IconButton(
            tooltip: 'Snippets de comandos',
            icon: const Icon(Icons.electric_bolt, color: _C.textLo),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SnippetsScreen()),
              );
            },
          ),
          IconButton(
            tooltip: 'Ejecutar comando en varios hosts',
            icon: const Icon(Icons.playlist_play, color: _C.textLo),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const MultiExecScreen()),
              );
            },
          ),
          IconButton(
            tooltip: 'Cerrar todas las conexiones SFTP',
            icon: const Icon(Icons.link_off, color: _C.textLo),
            onPressed: () async {
              await SftpConnectionPool.instance.disconnectAll();
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            tooltip: 'Grupos de hosts',
            icon: const Icon(Icons.folder_shared, color: _C.textLo),
            onPressed: _groupsManager,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: _C.textLo),
            color: _C.card,
            onSelected: (val) {
              if (val == 'export') _exportHosts();
              if (val == 'import') _importHosts();
              if (val == 'tunnels') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const TunnelsScreen()),
                );
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'tunnels', child: Text('Tuneles SSH (port forwarding)', style: TextStyle(color: _C.textHi))),
              const PopupMenuItem(value: 'export', child: Text('Exportar hosts a fichero', style: TextStyle(color: _C.textHi))),
              const PopupMenuItem(value: 'import', child: Text('Importar hosts de fichero', style: TextStyle(color: _C.textHi))),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v),
              style: const TextStyle(color: _C.textHi, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Buscar host…',
                hintStyle: const TextStyle(color: _C.textLo, fontSize: 14),
                prefixIcon: const Icon(Icons.search, color: _C.textLo, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, color: _C.textLo, size: 18),
                        onPressed: () { _searchCtrl.clear(); setState(() => _query = ''); },
                      ),
                filled: true,
                fillColor: _C.cardAlt,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
          ),
          Expanded(
            child: hosts.isEmpty
                ? Center(child: Text(_query.isEmpty ? 'Sin hosts todavía · toca + para añadir uno' : 'Ningún host coincide con la búsqueda', style: const TextStyle(color: _C.textLo, fontSize: 13)))
                : _query.isNotEmpty
                    ? ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: hosts.length,
                        itemBuilder: (context, i) => _hostTile(hosts[i]),
                      )
                    : _groupedList(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: _C.accent,
        onPressed: () => _openEditor(),
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _hostTile(SshHost h) {
    final color = _osColors[h.osTag] ?? _osColors['generic']!;
    // Avatar estilo Termius: cuadrado redondeado con la inicial del host.
    final initial = h.name.trim().isEmpty ? '?' : h.name.trim()[0].toUpperCase();
    return Dismissible(
      key: ValueKey(h.id), direction: DismissDirection.endToStart,
      background: Container(color: _C.err, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete, color: Colors.white)),
      confirmDismiss: (_) => _confirmDelete(h), onDismissed: (_) => _svc.remove(h.id),
      child: ListTile(
        onTap: () async { await _svc.touch(h.id); widget.onConnect(h); },
        onLongPress: () => _openEditor(existing: h),
        leading: Container(
          width: 42, height: 42,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
          alignment: Alignment.center,
          child: Text(initial, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
        ),
        title: Text(h.name, style: const TextStyle(color: _C.textHi, fontWeight: FontWeight.w500)),
        subtitle: Text(_subtitle(h), style: const TextStyle(color: _C.textLo, fontSize: 12)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.rootfsPath != null)
              Stack(
                clipBehavior: Clip.none,
                children: [
                  IconButton(
                    icon: const Icon(Icons.folder_open, color: _C.textLo, size: 20),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => SftpBrowserScreen(host: h, rootfsPath: widget.rootfsPath!, onOpenTerminal: widget.onOpenTerminalFromSftp),
                    )).then((_) { if (mounted) setState(() {}); }),
                  ),
                  if (SftpConnectionPool.instance.isConnected(h.id))
                    Positioned(right: 6, top: 6, child: Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFF34C759), shape: BoxShape.circle))),
                ],
              ),
            const Icon(Icons.chevron_right, color: _C.textLo),
            PopupMenuButton<String>(
              iconColor: _C.textLo,
              onSelected: (v) {
                if (v == 'move') _pickGroup(h);
                if (v == 'sendkey') _sendKeyToHost(h);
                if (v == 'jump') _pickJumpHost(h);
                if (v == 'unjump') _clearJump(h);
                if (v == 'shutdown') _powerAction(h, false);
                if (v == 'reboot') _powerAction(h, true);
                if (v == 'prep-power') _preparePower(h);
                if (v == 'setmac') _setMac(h);
                if (v == 'wake') _wake(h);
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                    value: 'move',
                    child: Text('Mover a grupo...')),
                const PopupMenuItem(
                    value: 'sendkey',
                    child: Text('Enviar clave publica (sin password despues)')),
                const PopupMenuItem(
                    value: 'jump',
                    child: Text('Conectar a traves de... (ProxyJump)')),
                if (h.jumpHostId != null)
                  const PopupMenuItem(
                      value: 'unjump', child: Text('Quitar salto ProxyJump')),
                const PopupMenuItem(
                    value: 'shutdown', child: Text('Apagar equipo')),
                const PopupMenuItem(
                    value: 'reboot', child: Text('Reiniciar equipo')),
                const PopupMenuItem(
                    value: 'prep-power',
                    child: Text('Preparar apagado sin contrasena (una vez)')),
                if (h.macAddress == null)
                  const PopupMenuItem(
                      value: 'setmac',
                      child: Text('Guardar MAC (Wake-on-LAN)')),
                if (h.macAddress != null) ...[
                  const PopupMenuItem(
                      value: 'wake', child: Text('Encender (Wake-on-LAN)')),
                  const PopupMenuItem(
                      value: 'setmac', child: Text('Cambiar MAC')),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _subtitle(SshHost h) {
    final g = (h.group != null && h.group!.isNotEmpty) ? '[${h.group}] ' : '';
    return '$g${h.username}@${h.hostname}${h.port != 22 ? ':${h.port}' : ''}';
  }

  /// v2.10.0: lista agrupada: una seccion por grupo + 'Sin grupo' al final.
  Widget _groupedList() {
    final groups = _svc.groupNames;
    final ungrouped = _svc.hostsInGroup('');
    if (groups.isEmpty && ungrouped.isEmpty) {
      return const Center(child: Text('Sin hosts todavia', style: TextStyle(color: _C.textLo, fontSize: 13)));
    }
    final children = <Widget>[];
    for (final g in groups) {
      children.add(_groupHeader(g));
      if (!_collapsed.contains(g)) {
        children.addAll(_svc.hostsInGroup(g).map(_hostTile));
      }
    }
    if (ungrouped.isNotEmpty) {
      children.add(_groupHeader(''));
      if (!_collapsed.contains('')) {
        children.addAll(ungrouped.map(_hostTile));
      }
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: children,
    );
  }

  Widget _groupHeader(String name) {
    final label = name.isEmpty ? 'Sin grupo' : name;
    final color = Color(_svc.groupColor(name));
    final total = _svc.hostsInGroup(name).length;
    final collapsed = _collapsed.contains(name);
    return InkWell(
      onTap: () => setState(() => collapsed ? _collapsed.remove(name) : _collapsed.add(name)),
      onLongPress: name.isEmpty ? null : () => _groupMenu(name),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Row(
          children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(child: Text(label, style: const TextStyle(color: _C.textHi, fontSize: 13, fontWeight: FontWeight.w600))),
            Text('$total', style: const TextStyle(color: _C.textLo, fontSize: 12)),
            const SizedBox(width: 4),
            Icon(collapsed ? Icons.expand_more : Icons.expand_less, color: _C.textLo, size: 18),
          ],
        ),
      ),
    );
  }

  /// Menu de un grupo (mantener pulsada la cabecera): renombrar, color,
  /// exportar solo ese grupo, eliminar.
  Future<void> _groupMenu(String name) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _C.card,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.edit, color: _C.textLo), title: const Text('Renombrar grupo', style: TextStyle(color: _C.textHi)), onTap: () => Navigator.pop(ctx, 'rename')),
            ListTile(leading: const Icon(Icons.palette, color: _C.textLo), title: const Text('Cambiar color', style: TextStyle(color: _C.textHi)), onTap: () => Navigator.pop(ctx, 'color')),
            ListTile(leading: const Icon(Icons.upload_file, color: _C.textLo), title: const Text('Exportar solo este grupo', style: TextStyle(color: _C.textHi)), onTap: () => Navigator.pop(ctx, 'export')),
            ListTile(leading: const Icon(Icons.delete_outline, color: _C.err), title: const Text('Eliminar grupo (los hosts quedan sin grupo)', style: TextStyle(color: _C.textHi)), onTap: () => Navigator.pop(ctx, 'delete')),
          ],
        ),
      ),
    );
    if (action == null) return;
    if (!mounted) return;
    if (action == 'rename') {
      final nn = await _promptGroupName(initial: name);
      if (nn != null && nn != name) {
        await _svc.renameGroup(name, nn);
        if (_collapsed.remove(name)) _collapsed.add(nn);
      }
    } else if (action == 'color') {
      await _groupColorDialog(name);
    } else if (action == 'export') {
      await _exportHosts(group: name);
    } else if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _C.card,
          title: const Text('Eliminar grupo?', style: TextStyle(color: _C.textHi)),
          content: Text('"$name" desaparece y sus hosts pasan a "Sin grupo".', style: const TextStyle(color: _C.textLo)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar', style: TextStyle(color: _C.textLo))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Eliminar', style: TextStyle(color: _C.err))),
          ],
        ),
      );
      if (ok == true) {
        await _svc.deleteGroup(name);
        _collapsed.remove(name);
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _groupColorDialog(String name) async {
    var sel = _svc.groupColor(name);
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: _C.card,
          title: Text('Color de $name', style: const TextStyle(color: _C.textHi, fontSize: 15)),
          content: Wrap(
            spacing: 10, runSpacing: 10,
            children: [
              for (final c in SshHostsService.palette)
                GestureDetector(
                  onTap: () => setDlg(() => sel = c),
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: Color(c), shape: BoxShape.circle,
                      border: Border.all(color: sel == c ? Colors.white : Colors.transparent, width: 3),
                    ),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar', style: TextStyle(color: _C.textLo))),
            FilledButton(onPressed: () => Navigator.pop(ctx, sel), child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (picked != null) await _svc.setGroupColor(name, picked);
  }

  /// Dialogo del boton de la AppBar: lista de grupos con conteo.
  Future<void> _groupsManager() async {
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: _C.card,
          title: const Text('Grupos', style: TextStyle(color: _C.textHi, fontSize: 16)),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final g in _svc.groupNames)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(radius: 8, backgroundColor: Color(_svc.groupColor(g))),
                    title: Text(g, style: const TextStyle(color: _C.textHi, fontSize: 14)),
                    subtitle: Text('${_svc.hostsInGroup(g).length} hosts', style: const TextStyle(color: _C.textLo, fontSize: 11)),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(icon: const Icon(Icons.palette, size: 18, color: _C.textLo), onPressed: () async { await _groupColorDialog(g); setDlg(() {}); }),
                      IconButton(icon: const Icon(Icons.edit, size: 18, color: _C.textLo), onPressed: () async { final nn = await _promptGroupName(initial: g); if (nn != null && nn != g) { await _svc.renameGroup(g, nn); if (_collapsed.remove(g)) _collapsed.add(nn); } setDlg(() {}); }),
                      IconButton(icon: const Icon(Icons.delete_outline, size: 18, color: _C.err), onPressed: () async { await _svc.deleteGroup(g); _collapsed.remove(g); setDlg(() {}); }),
                    ]),
                  ),
                if (_svc.groupNames.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Sin grupos todavia. Manten pulsado un host y elige "Mover a grupo..." para crear el primero.', style: TextStyle(color: _C.textLo, fontSize: 13)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar', style: TextStyle(color: _C.textLo))),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<String?> _promptGroupName({String initial = ''}) async {
    final c = TextEditingController(text: initial);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('Nombre del grupo', style: TextStyle(color: _C.textHi, fontSize: 15)),
        content: TextField(
          controller: c,
          autofocus: true,
          style: const TextStyle(color: _C.textHi),
          decoration: const InputDecoration(hintText: 'Desarrollo, Produccion...', hintStyle: TextStyle(color: _C.textLo)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Guardar')),
        ],
      ),
    );
    if (r == null || r.isEmpty) return null;
    return r;
  }

  /// Menu contextual del host: mover a grupo (existente o nuevo).
  Future<void> _pickGroup(SshHost h) async {
    final groups = _svc.groupNames;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _C.card,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (h.group != null && h.group!.isNotEmpty)
              ListTile(leading: const Icon(Icons.remove_circle_outline, color: _C.err), title: const Text('Quitar del grupo', style: TextStyle(color: _C.textHi)), onTap: () => Navigator.pop(ctx, '')),
            for (final g in groups)
              if (g != h.group)
                ListTile(
                  leading: CircleAvatar(radius: 8, backgroundColor: Color(_svc.groupColor(g))),
                  title: Text(g, style: const TextStyle(color: _C.textHi)),
                  onTap: () => Navigator.pop(ctx, g),
                ),
            ListTile(leading: const Icon(Icons.create_new_folder, color: _C.accent), title: const Text('Nuevo grupo...', style: TextStyle(color: _C.accent)), onTap: () => Navigator.pop(ctx, '*new*')),
          ],
        ),
      ),
    );
    if (picked == null) return;
    String? target = picked;
    if (picked == '*new*') {
      target = await _promptGroupName();
      if (target == null) return;
    }
    await _svc.assignGroup(h.id, target.isEmpty ? null : target);
    if (mounted) setState(() {});
  }

  Future<void> _wake(SshHost h) async {
    if (h.macAddress == null || h.macAddress!.isEmpty) return;
    final ok = await PowerService.wakeOnLan(h.macAddress!, ip: h.hostname);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? 'Magic packet enviado a ${h.macAddress} (LAN: puede tardar unos segundos)'
          : 'No se pudo enviar el magic packet'),
      backgroundColor: ok ? const Color(0xFF34C759) : const Color(0xFFFF453A),
    ));
  }

  Future<void> _setMac(SshHost h) async {
    final c = TextEditingController(text: h.macAddress ?? '');
    final mac = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('MAC para Wake-on-LAN',
            style: TextStyle(color: _C.textHi, fontSize: 15)),
        content: TextField(
          controller: c,
          autofocus: true,
          style: const TextStyle(color: _C.textHi),
          decoration: const InputDecoration(
              hintText: 'AA:BB:CC:DD:EE:FF',
              hintStyle: TextStyle(color: _C.textLo)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Guardar')),
        ],
      ),
    );
    if (mac == null) return;
    if (mac.isNotEmpty &&
        !RegExp(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$').hasMatch(mac)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('MAC invalida (usa AA:BB:CC:DD:EE:FF)')));
      return;
    }
    await SshHostsService.instance
        .update(h.copyWith(macAddress: mac.isEmpty ? null : mac));
    await SshHostsService.instance.loadFrom(AppPaths.base);
    if (mounted) setState(() {});
  }

  Future<void> _preparePower(SshHost h) async {
    final c = TextEditingController();
    final pwd = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: Text('Contrasena sudo de ${h.name}',
            style: const TextStyle(color: _C.textHi, fontSize: 15)),
        content: TextField(
          controller: c,
          obscureText: true,
          autofocus: true,
          style: const TextStyle(color: _C.textHi),
          decoration: const InputDecoration(
              labelText: 'Se usa una sola vez',
              labelStyle: TextStyle(color: _C.textLo)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text),
              child: const Text('Instalar')),
        ],
      ),
    );
    if (pwd == null || pwd.isEmpty || !mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        backgroundColor: _C.card,
        content: Row(
          children: [
            SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: _C.accent)),
            SizedBox(width: 16),
            Text('Instalando regla sudo...',
                style: TextStyle(color: _C.textHi)),
          ],
        ),
      ),
    );
    final r = await PowerService.preparePasswordless(h, password: pwd);
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(r.ok
          ? 'Listo: ${h.name} se apaga/reinicia sin contrasena'
          : 'Error: ${r.message}'),
      backgroundColor:
          r.ok ? const Color(0xFF34C759) : const Color(0xFFFF453A),
    ));
  }

  Future<void> _powerAction(SshHost h, bool reboot) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: Text(reboot ? 'Reiniciar ${h.name}' : 'Apagar ${h.name}',
            style: const TextStyle(color: _C.textHi)),
        content: Text(
            reboot
                ? 'El equipo se reiniciara ahora.'
                : 'El equipo se apagara ahora.',
            style: const TextStyle(color: _C.textLo)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFF453A)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(reboot ? 'Reiniciar' : 'Apagar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: _C.card,
        content: Row(
          children: [
            const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: _C.accent)),
            const SizedBox(width: 16),
            Text(reboot ? 'Reiniciando...' : 'Apagando...',
                style: const TextStyle(color: _C.textHi)),
          ],
        ),
      ),
    );
    final r =
        reboot ? await PowerService.reboot(h) : await PowerService.shutdown(h);
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(r.ok ? r.message : 'Error: ${r.message}'),
      backgroundColor:
          r.ok ? const Color(0xFF34C759) : const Color(0xFFFF453A),
    ));
  }

  Future<void> _clearJump(SshHost h) async {
    await SshHostsService.instance
        .update(h.copyWith(clearJump: true));
    await SshHostsService.instance.loadFrom(AppPaths.base);
    if (mounted) setState(() {});
  }

  Future<void> _pickJumpHost(SshHost h) async {
    await SshHostsService.instance.loadFrom(AppPaths.base);
    final hosts = SshHostsService.instance.hosts
        .where((x) => x.id != h.id)
        .toList();
    if (hosts.isEmpty) return;
    final jump = await showDialog<SshHost>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: _C.card,
        title: Text('Salto para ${h.name} (ProxyJump)',
            style: const TextStyle(color: _C.textHi)),
        children: [
          for (final x in hosts)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, x),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(x.name,
                        style: const TextStyle(color: _C.textHi)),
                    Text(
                        '${x.username}@${x.hostname}${x.port != 22 ? ':${x.port}' : ''}',
                        style: const TextStyle(
                            color: _C.textLo, fontSize: 11)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (jump == null) return;
    await SshHostsService.instance
        .update(h.copyWith(jumpHostId: jump.id));
    await SshHostsService.instance.loadFrom(AppPaths.base);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${h.name} ahora conecta a traves de ${jump.name}')));
  }

  Future<void> _sendKeyToHost(SshHost h) async {
    String? pwd = await SshCredentialsStore.readPassword(h.id);
    pwd ??= await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = TextEditingController();
        return AlertDialog(
          backgroundColor: _C.card,
          title: Text('Contrasena de ${h.name}',
              style: const TextStyle(color: _C.textHi, fontSize: 15)),
          content: TextField(
            controller: c,
            obscureText: true,
            autofocus: true,
            style: const TextStyle(color: _C.textHi),
            decoration: const InputDecoration(
                labelText: 'Se usa una sola vez para instalar la clave',
                labelStyle: TextStyle(color: _C.textLo)),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, c.text),
                child: const Text('Instalar')),
          ],
        );
      },
    );
    if (pwd == null || pwd.isEmpty) return;
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        backgroundColor: _C.card,
        content: Row(
          children: [
            SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: _C.accent)),
            SizedBox(width: 16),
            Text('Instalando clave...',
                style: TextStyle(color: _C.textHi)),
          ],
        ),
      ),
    );
    try {
      await IdentityService.installKeyToHost(h, password: pwd);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Clave instalada en ${h.name}: ya no pedira contrasena'),
        backgroundColor: const Color(0xFF34C759),
      ));
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error: \$e'),
        backgroundColor: const Color(0xFFFF453A),
      ));
    }
  }

  Future<bool> _confirmDelete(SshHost h) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('¿Eliminar host?', style: TextStyle(color: _C.textHi)),
        content: Text(h.name, style: const TextStyle(color: _C.textLo)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar', style: TextStyle(color: _C.textLo))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Eliminar', style: TextStyle(color: _C.err))),
        ],
      ),
    );
    return r ?? false;
  }

  void _openEditor({SshHost? existing}) {
    showModalBottomSheet(context: context, backgroundColor: Colors.transparent, isScrollControlled: true, builder: (_) => _HostEditorSheet(existing: existing));
  }
}

enum _ImportKind { fresh, update, dupe }

enum _DupeMode { skip, update, importAll }

class _ImportEntry {
  final SshHost host;
  final String? pwd;
  final _ImportKind kind;
  final SshHost? existing;
  _ImportEntry(this.host, this.pwd, this.kind, this.existing);
}

class _HostEditorSheet extends StatefulWidget {
  final SshHost? existing;
  const _HostEditorSheet({this.existing});
  @override
  State<_HostEditorSheet> createState() => _HostEditorSheetState();
}

class _HostEditorSheetState extends State<_HostEditorSheet> {
  late final TextEditingController _name, _hostname, _port, _username, _password, _initialPath;
  String _osTag = 'generic';
  bool _obscurePassword = true;

  /// Claves importadas en el almacén de la app (solo nombres de fichero).
  List<String> _keys = [];
  String? _selectedKey;

  /// v2.10.0: grupo del host (null = sin grupo).
  String? _group;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _hostname = TextEditingController(text: e?.hostname ?? '');
    _port = TextEditingController(text: (e?.port ?? 22).toString());
    _username = TextEditingController(text: e?.username ?? 'root');
    _initialPath = TextEditingController(text: e?.initialPath ?? '');
    _password = TextEditingController();
    _osTag = e?.osTag ?? 'generic';
    _group = (e?.group != null && e!.group!.isNotEmpty) ? e.group : null;
    // keyPath guardado: '/keys/<nombre>' (o legacy '/root/.ssh/<nombre>').
    _selectedKey = e?.keyPath?.split('/').last;
    _reloadKeys();
    if (e != null) SshCredentialsStore.readPassword(e.id).then((pwd) { if (mounted && pwd != null) setState(() => _password.text = pwd); });
  }

  Future<void> _reloadKeys() async {
    final keys = await AppPaths.listKeys();
    if (mounted) setState(() => _keys = keys);
  }

  /// Importa una clave privada desde el almacenamiento del teléfono.
  /// Se leen bytes vía XFile (file_selector devuelve content:// en Android
  /// y dart:io no puede abrirlos) y se copian al almacén de la app.
  Future<void> _importKey() async {
    try {
      final XFile? f = await openFile();
      if (f == null) return;
      final bytes = await f.readAsBytes();
      final name = f.name.isEmpty ? 'id_imported' : f.name;
      await File('${AppPaths.keysDir}/$name').writeAsBytes(bytes);
      await _reloadKeys();
      if (mounted) setState(() => _selectedKey = name);
    } catch (_) {}
  }

  @override
  void dispose() { _name.dispose(); _hostname.dispose(); _port.dispose(); _username.dispose(); _password.dispose(); _initialPath.dispose(); super.dispose(); }

  InputDecoration _dec(String label, {String? hint}) => InputDecoration(labelText: label, hintText: hint, labelStyle: const TextStyle(color: _C.textLo), hintStyle: const TextStyle(color: _C.textLo), filled: true, fillColor: _C.cardAlt, border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none));

  Future<void> _save() async {
    final hostname = _hostname.text.trim();
    final username = _username.text.trim();
    if (hostname.isEmpty || username.isEmpty) return;

    final name = _name.text.trim().isEmpty ? hostname : _name.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 22;
    final keyPath = _selectedKey == null ? '' : '/keys/$_selectedKey';
    final initialPath = _initialPath.text.trim();
    final password = _password.text;

    String hostId;
    if (widget.existing != null) {
      hostId = widget.existing!.id;
      await SshHostsService.instance.update(widget.existing!.copyWith(name: name, hostname: hostname, port: port, username: username, keyPath: keyPath.isEmpty ? null : keyPath, initialPath: initialPath.isEmpty ? null : initialPath, osTag: _osTag, group: _group, clearGroup: _group == null));
    } else {
      hostId = SshHostsService.instance.newId();
      await SshHostsService.instance.add(SshHost(id: hostId, name: name, hostname: hostname, port: port, username: username, keyPath: keyPath.isEmpty ? null : keyPath, initialPath: initialPath.isEmpty ? null : initialPath, osTag: _osTag, group: _group));
    }
    
    await SshCredentialsStore.savePassword(hostId, password);
    if (mounted) Navigator.pop(context);
  }

  /// Selector de clave privada: desplegable con las claves del almacén de la
  /// app + botón para importar desde el teléfono.
  Widget _keySelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: _C.cardAlt, borderRadius: BorderRadius.circular(10)),
      child: Row(
        children: [
          const Icon(Icons.key, color: _C.textLo, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _keys.contains(_selectedKey) ? _selectedKey : null,
                isExpanded: true,
                hint: const Text('Clave privada (opcional)', style: TextStyle(color: _C.textLo, fontSize: 14)),
                dropdownColor: _C.card,
                style: const TextStyle(color: _C.textHi, fontSize: 14),
                items: [
                  ..._keys.map((k) => DropdownMenuItem<String>(
                        value: k,
                        child: Text(k, overflow: TextOverflow.ellipsis),
                      )),
                ],
                onChanged: (v) => setState(() => _selectedKey = v),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Importar clave desde el teléfono',
            icon: const Icon(Icons.download, color: _C.accent, size: 20),
            onPressed: _importKey,
          ),
        ],
      ),
    );
  }


  /// v2.10.0: desplegable de grupo con los existentes + opcion de crear.
  Widget _groupSelector() {
    final names = SshHostsService.instance.groupNames;
    final value = (_group != null && names.contains(_group)) ? _group : null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: _C.cardAlt, borderRadius: BorderRadius.circular(10)),
      child: Row(
        children: [
          const Icon(Icons.folder_shared, color: _C.textLo, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: value,
                isExpanded: true,
                hint: const Text('Sin grupo', style: TextStyle(color: _C.textLo, fontSize: 14)),
                dropdownColor: _C.card,
                style: const TextStyle(color: _C.textHi, fontSize: 14),
                items: [
                  for (final g in names)
                    DropdownMenuItem<String>(
                      value: g,
                      child: Row(children: [
                        CircleAvatar(radius: 6, backgroundColor: Color(SshHostsService.instance.groupColor(g))),
                        const SizedBox(width: 8),
                        Expanded(child: Text(g, overflow: TextOverflow.ellipsis)),
                      ]),
                    ),
                ],
                onChanged: (v) => setState(() => _group = v),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Crear grupo nuevo',
            icon: const Icon(Icons.create_new_folder, color: _C.accent, size: 20),
            onPressed: () async {
              final c = TextEditingController();
              final r = await showDialog<String>(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: _C.card,
                  title: const Text('Nuevo grupo', style: TextStyle(color: _C.textHi, fontSize: 15)),
                  content: TextField(
                    controller: c, autofocus: true,
                    style: const TextStyle(color: _C.textHi),
                    decoration: const InputDecoration(hintText: 'Desarrollo, Produccion...', hintStyle: TextStyle(color: _C.textLo)),
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Crear')),
                  ],
                ),
              );
              if (r != null && r.isNotEmpty && mounted) setState(() => _group = r);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(color: _C.bg, borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.existing == null ? 'Nuevo host' : 'Editar host', style: const TextStyle(color: _C.textHi, fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: 14),
              TextField(controller: _name, style: const TextStyle(color: _C.textHi), decoration: _dec('Nombre', hint: 'RPi5, opcional')),
              const SizedBox(height: 10),
              TextField(controller: _hostname, style: const TextStyle(color: _C.textHi), decoration: _dec('Host', hint: '192.168.10.140 o dominio')),
              const SizedBox(height: 10),
              Row(children: [ Expanded(flex: 2, child: TextField(controller: _username, style: const TextStyle(color: _C.textHi), decoration: _dec('Usuario'))), const SizedBox(width: 10), Expanded(child: TextField(controller: _port, keyboardType: TextInputType.number, style: const TextStyle(color: _C.textHi), decoration: _dec('Puerto'))), ]),
              const SizedBox(height: 10),
              _keySelector(),
              const SizedBox(height: 10),
              TextField(controller: _password, obscureText: _obscurePassword, style: const TextStyle(color: _C.textHi), decoration: _dec('Contraseña (opcional)', hint: 'Se guarda cifrada').copyWith(suffixIcon: IconButton(icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility, color: _C.textLo, size: 18), onPressed: () => setState(() => _obscurePassword = !_obscurePassword)))),
              const SizedBox(height: 10),
              TextField(controller: _initialPath, style: const TextStyle(color: _C.textHi), decoration: _dec('Carpeta inicial (opcional)', hint: '/  o  /var/www')),
              const SizedBox(height: 10),
              _groupSelector(),
              const SizedBox(height: 14),
              Wrap(spacing: 8, children: _osColors.keys.map((tag) { final selected = tag == _osTag; return ChoiceChip(label: Text(tag), selected: selected, onSelected: (_) => setState(() => _osTag = tag), selectedColor: _osColors[tag], backgroundColor: _C.cardAlt, labelStyle: TextStyle(color: selected ? Colors.white : _C.textLo, fontSize: 12)); }).toList()),
              const SizedBox(height: 18),
              SizedBox(width: double.infinity, child: ElevatedButton(onPressed: _save, style: ElevatedButton.styleFrom(backgroundColor: _C.accent, padding: const EdgeInsets.symmetric(vertical: 14)), child: Text(widget.existing == null ? 'Añadir' : 'Guardar', style: const TextStyle(color: Colors.white)))),
            ],
          ),
        ),
      ),
    );
  }
}
