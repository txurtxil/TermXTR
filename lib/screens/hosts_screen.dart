import 'package:flutter/material.dart';

import '../models/host_profile.dart';
import '../services/storage_service.dart';
import '../src/terminal/terminal_view.dart';
import 'sftp_browser_screen.dart';

/// Pantalla de gestion de perfiles SSH: lista + CRUD completo.
class HostsScreen extends StatefulWidget {
  const HostsScreen({super.key});

  @override
  State<HostsScreen> createState() => _HostsScreenState();
}

class _HostsScreenState extends State<HostsScreen> {
  List<HostProfile> _hosts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final hosts = await StorageService.instance.loadHosts();
    if (!mounted) return;
    setState(() {
      _hosts = hosts;
      _loading = false;
    });
  }

  Future<void> _openForm([HostProfile? existing]) async {
    final result = await showDialog<HostProfile>(
      context: context,
      builder: (_) => HostFormDialog(existing: existing),
    );
    if (result != null) {
      if (existing == null) {
        await StorageService.instance.addHost(result);
      } else {
        await StorageService.instance.updateHost(result);
      }
      await _reload();
    }
  }

  Future<void> _delete(HostProfile host) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar host'),
        content: Text('¿Eliminar "${host.name}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok == true) {
      await StorageService.instance.deleteHost(host.id);
      await _reload();
    }
  }

  Future<void> _connect(HostProfile host) async {
    await StorageService.instance.touchHost(host.id);
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TerminalScreen(host: host)),
    );
  }

  Future<void> _openSftp(HostProfile host) async {
    await StorageService.instance.touchHost(host.id);
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SftpBrowserScreen(host: host)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hosts SSH')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openForm(),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _hosts.isEmpty
              ? const Center(
                  child: Text(
                    'Sin hosts todavia.\nPulsa + para anadir uno.',
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  itemCount: _hosts.length,
                  itemBuilder: (_, i) {
                    final h = _hosts[i];
                    return Dismissible(
                      key: Key(h.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Colors.red,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        child:
                            const Icon(Icons.delete, color: Colors.white),
                      ),
                      confirmDismiss: (_) async {
                        await _delete(h);
                        return false;
                      },
                      child: ListTile(
                        leading: Icon(h.useKey ? Icons.vpn_key : Icons.lock),
                        title: Text(h.name),
                        subtitle: Text(h.subtitle),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.terminal),
                              tooltip: 'Conectar terminal',
                              onPressed: () => _connect(h),
                            ),
                            IconButton(
                              icon: const Icon(Icons.folder),
                              tooltip: 'Explorador SFTP',
                              onPressed: () => _openSftp(h),
                            ),
                          ],
                        ),
                        onTap: () => _connect(h),
                        onLongPress: () => _openForm(h),
                      ),
                    );
                  },
                ),
    );
  }
}

/// Formulario de alta/edicion de host.
class HostFormDialog extends StatefulWidget {
  final HostProfile? existing;
  const HostFormDialog({super.key, this.existing});

  @override
  State<HostFormDialog> createState() => _HostFormDialogState();
}

class _HostFormDialogState extends State<HostFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _hostname;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _secret;
  late final TextEditingController _notes;
  bool _useKey = false;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    final h = widget.existing;
    _name = TextEditingController(text: h?.name ?? '');
    _hostname = TextEditingController(text: h?.hostname ?? '');
    _port = TextEditingController(text: h != null ? '${h.port}' : '22');
    _username = TextEditingController(text: h?.username ?? '');
    _secret = TextEditingController(text: h?.secret ?? '');
    _notes = TextEditingController(text: h?.notes ?? '');
    _useKey = h?.useKey ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _hostname.dispose();
    _port.dispose();
    _username.dispose();
    _secret.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final h = HostProfile(
      id: widget.existing?.id ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      name: _name.text.trim(),
      hostname: _hostname.text.trim(),
      port: int.parse(_port.text.trim()),
      username: _username.text.trim(),
      useKey: _useKey,
      secret: _secret.text,
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    );
    Navigator.pop(context, h);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Nuevo host' : 'Editar host'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Nombre'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Obligatorio' : null,
              ),
              TextFormField(
                controller: _hostname,
                decoration:
                    const InputDecoration(labelText: 'Hostname o IP'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Obligatorio' : null,
              ),
              TextFormField(
                controller: _port,
                decoration: const InputDecoration(labelText: 'Puerto'),
                keyboardType: TextInputType.number,
                validator: (v) {
                  final p = int.tryParse(v ?? '');
                  if (p == null || p < 1 || p > 65535) {
                    return 'Puerto invalido';
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: _username,
                decoration: const InputDecoration(labelText: 'Usuario'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Obligatorio' : null,
              ),
              SwitchListTile(
                title: const Text('Autenticar con clave privada (PEM)'),
                value: _useKey,
                onChanged: (v) => setState(() => _useKey = v),
              ),
              TextFormField(
                controller: _secret,
                decoration: InputDecoration(
                  labelText: _useKey ? 'Clave privada PEM' : 'Password',
                  helperText: _useKey
                      ? 'Pega la clave privada OpenSSH completa'
                      : null,
                  suffixIcon: IconButton(
                    icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                obscureText: _obscure && !_useKey,
                maxLines: _useKey ? 6 : 1,
                validator: (v) =>
                    (v == null || v.isEmpty) ? 'Obligatorio' : null,
              ),
              TextFormField(
                controller: _notes,
                decoration: const InputDecoration(labelText: 'Notas'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(onPressed: _save, child: const Text('Guardar')),
      ],
    );
  }
}
