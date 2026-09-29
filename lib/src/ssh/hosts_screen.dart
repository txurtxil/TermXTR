import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:share_plus/share_plus.dart';

import 'ssh_host.dart';
import 'ssh_hosts_service.dart';
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
        h.username.toLowerCase().contains(q)).toList();
  }

  Future<void> _exportHosts() async {
    final hosts = _svc.hosts;
    final list = [];
    
    for (final h in hosts) {
      final json = h.toJson();
      final pwd = await SshCredentialsStore.readPassword(h.id);
      if (pwd != null && pwd.isNotEmpty) {
        json['password_export'] = pwd;
      }
      list.add(json);
    }
    
    final jsonString = const JsonEncoder.withIndent('  ').convert(list);
    
    try {
      final file = XFile.fromData(
        utf8.encode(jsonString),
        name: 'xtr_hosts_backup.json',
        mimeType: 'application/json',
      );
      // Usar share_plus esquiva el error UnimplementedError de file_selector en Android
      await Share.shareXFiles([file], text: 'Copia de seguridad de Hosts XTR');
    } catch (e) {
      if (mounted) {
        Clipboard.setData(ClipboardData(text: jsonString));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error al crear archivo. Copiado al portapapeles como alternativa.')));
      }
    }
  }

  Future<void> _importHosts() async {
    try {
      const XTypeGroup typeGroup = XTypeGroup(label: 'JSONs', extensions: <String>['json']);
      final XFile? file = await openFile(acceptedTypeGroups: <XTypeGroup>[typeGroup]);
      
      if (file == null) return;
      
      final content = await file.readAsString();
      final list = jsonDecode(content) as List<dynamic>;
      int count = 0;
      
      for (final item in list) {
        final map = item as Map<String, dynamic>;
        final pwd = map.remove('password_export') as String?;
        final host = SshHost.fromJson(map);
        
        final existing = _svc.hosts.where((h) => h.id == host.id).toList();
        if (existing.isNotEmpty) {
          await _svc.update(host);
        } else {
          await _svc.add(host);
        }
        
        if (pwd != null && pwd.isNotEmpty) {
          await SshCredentialsStore.savePassword(host.id, pwd);
        }
        count++;
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$count hosts importados con éxito')));
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
            tooltip: 'Cerrar todas las conexiones SFTP',
            icon: const Icon(Icons.link_off, color: _C.textLo),
            onPressed: () async {
              await SftpConnectionPool.instance.disconnectAll();
              if (mounted) setState(() {});
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: _C.textLo),
            color: _C.card,
            onSelected: (val) {
              if (val == 'export') _exportHosts();
              if (val == 'import') _importHosts();
            },
            itemBuilder: (ctx) => [
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
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: hosts.length,
                    itemBuilder: (context, i) => _hostTile(hosts[i]),
                  ),
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
        subtitle: Text('${h.username}@${h.hostname}${h.port != 22 ? ':${h.port}' : ''}', style: const TextStyle(color: _C.textLo, fontSize: 12)),
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
          ],
        ),
      ),
    );
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
      await SshHostsService.instance.update(widget.existing!.copyWith(name: name, hostname: hostname, port: port, username: username, keyPath: keyPath.isEmpty ? null : keyPath, initialPath: initialPath.isEmpty ? null : initialPath, osTag: _osTag));
    } else {
      hostId = SshHostsService.instance.newId();
      await SshHostsService.instance.add(SshHost(id: hostId, name: name, hostname: hostname, port: port, username: username, keyPath: keyPath.isEmpty ? null : keyPath, initialPath: initialPath.isEmpty ? null : initialPath, osTag: _osTag));
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
