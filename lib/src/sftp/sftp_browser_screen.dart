// lib/src/sftp/sftp_browser_screen.dart
//
// Explorador visual de ficheros por SFTP: navegar tocando carpetas,
// descargar, eliminar, crear carpeta, subir archivos.
//
// v2: seleccion multiple (mantener pulsado para entrar, tocar para sumar
// mas) valida para borrar y descargar varios elementos de golpe; subir
// tambien acepta varios ficheros a la vez. El borrado de carpetas ahora es
// recursivo de verdad (antes fallaba con SftpStatusError code 4 -- rmdir
// exige la carpeta vacia, y estas carpetas de medios nunca lo estan).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ssh/ssh_host.dart';
import 'sftp_service.dart';
import 'sftp_favorites_service.dart';
import 'sftp_connection_pool.dart';
import 'local_file_picker_screen.dart';
import 'sftp_text_editor_screen.dart';

class _C {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const cardAlt = Color(0xFF242426);
  static const border = Color(0xFF3A3A3C);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const accent = Color(0xFF5E9BD6);
  static const err = Color(0xFFFF453A);
  static const ok = Color(0xFF34C759);
}

class SftpBrowserScreen extends StatefulWidget {
  final SshHost host;
  final String rootfsPath;
  /// Si se pasa, aparece "Abrir terminal SSH" en el menu: navega de vuelta
  /// a la terminal y abre una pestana ssh a este mismo host, SIN cerrar
  /// esta conexion sftp (vive en SftpConnectionPool, no en esta pantalla).
  final void Function(SshHost host)? onOpenTerminal;

  /// true cuando vive integrado en la pantalla de la terminal (panel
  /// alternante shell<->SFTP): sin flecha atrás y barra más baja.
  final bool embedded;

  /// Ruta inicial explicita (deep-link desde el widget de escritorio con un
  /// favorito SFTP). Manda sobre la ultima carpeta visitada y sobre el
  /// initialPath del host.
  final String? initialDir;

  const SftpBrowserScreen({
    super.key,
    required this.host,
    required this.rootfsPath,
    this.onOpenTerminal,
    this.embedded = false,
    this.initialDir,
  });

  @override
  State<SftpBrowserScreen> createState() => _SftpBrowserScreenState();
}

enum _LoadState { connecting, ready, error }
enum _SortBy { name, date, size }

class _SftpBrowserScreenState extends State<SftpBrowserScreen> {
  late SftpService _svc;
  _LoadState _state = _LoadState.connecting;
  String _error = '';
  // Arranca en initialPath si el host lo tiene configurado; si no, en el
  // home del usuario remoto como siempre ('.' es lo que ya usaba sftp).
  // La última carpeta visitada en este host manda sobre la ruta inicial:
  // al alternar shell<->SFTP (o reabrir desde Hosts) vuelves donde estabas.
  // Un deep-link del widget (initialDir) manda sobre todo lo anterior.
  late String _path = widget.initialDir ??
      SftpConnectionPool.instance.lastPathFor(widget.host.id) ??
      ((widget.host.initialPath?.trim().isNotEmpty ?? false)
          ? widget.host.initialPath!.trim()
          : '.');
  List<SftpEntry> _entries = [];
  _SortBy _sortBy = _SortBy.name;
  bool _sortAsc = true;
  bool _showHidden = true;
  bool _busy = false;
  String _busyLabel = '';

  // Modo seleccion: mantener pulsado un elemento entra, tocar otros suma.
  final Map<String, SftpEntry> _selected = {};
  bool get _selecting => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _svc = SftpConnectionPool.instance.forHost(widget.host, widget.rootfsPath);
    _connect();
  }

  @override
  void dispose() {
    // A proposito NO se cierra _svc aqui: la conexion vive en
    // SftpConnectionPool, no en esta pantalla. Volver atras (por ejemplo,
    // para abrir una pestana SSH) no debe cortarla.
    super.dispose();
  }

  Future<void> _connect() async {
    // Si ya esta conectada (se volvio a esta pantalla sin haber
    // desconectado), no hay que repetir el handshake ni pedir la
    // contrasena otra vez -- se va directo al listado.
    if (_svc.isConnected) {
      await _load(_path);
      if (mounted) setState(() => _state = _LoadState.ready);
      return;
    }
    setState(() {
      _state = _LoadState.connecting;
      _error = '';
    });
    try {
      await _svc.connect(
        onPasswordRequest: _askPassword,
        onHostKeyChanged: _warnHostKeyChanged,
      );
      await _load(_path);
      if (mounted) setState(() => _state = _LoadState.ready);
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _LoadState.error;
          _error = e.toString();
        });
      }
    }
  }

  Future<String> _askPassword() async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: Text('Contraseña de ${widget.host.username}@${widget.host.hostname}',
            style: const TextStyle(color: _C.textHi, fontSize: 15)),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          style: const TextStyle(color: _C.textHi),
          onSubmitted: (v) => Navigator.pop(ctx, v),
          decoration: const InputDecoration(
            filled: true,
            fillColor: _C.cardAlt,
            border: OutlineInputBorder(borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancelar', style: TextStyle(color: _C.textLo))),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Conectar', style: TextStyle(color: _C.accent))),
        ],
      ),
    );
    return result ?? '';
  }

  Future<bool> _warnHostKeyChanged(String fingerprint) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('⚠ La huella del servidor cambió', style: TextStyle(color: _C.err, fontSize: 15)),
        content: Text(
          'La identidad de ${widget.host.hostname} no coincide con la que se guardó '
          'la primera vez. Puede ser que el servidor se reinstalara, o que algo '
          'intermedio se esté haciendo pasar por él.\n\nNueva huella:\n$fingerprint',
          style: const TextStyle(color: _C.textLo, fontSize: 12.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar', style: TextStyle(color: _C.textLo))),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confiar de todos modos', style: TextStyle(color: _C.err))),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _load(String path) async {
    final entries = await _svc.list(path);
    SftpConnectionPool.instance.rememberPath(widget.host.id, path);
    if (mounted) setState(() { _path = path; _entries = entries; _selected.clear(); });
  }

  String _fullPath(SftpEntry e) => _path == '.' ? e.name : '$_path/${e.name}';

  void _enter(SftpEntry e) {
    _load(_fullPath(e));
  }

  void _up() {
    if (_path == '.' || !_path.contains('/')) {
      _load('.');
    } else {
      _load(_path.substring(0, _path.lastIndexOf('/')));
    }
  }

  String _fmtSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }

  String _fmtDate(DateTime? d) {
    if (d == null) return '';
    const meses = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
    return '${d.day} ${meses[d.month - 1]} ${d.year}';
  }

  // Las carpetas siempre van primero (convencion estandar de cualquier
  // explorador de archivos); el criterio elegido solo ordena DENTRO de
  // cada grupo.
  List<SftpEntry> get _sortedEntries {
    final list = _showHidden
        ? List<SftpEntry>.from(_entries)
        : _entries.where((e) => !e.name.startsWith('.')).toList();
    int cmp(SftpEntry a, SftpEntry b) {
      switch (_sortBy) {
        case _SortBy.date:
          final ad = a.modified;
          final bd = b.modified;
          if (ad == null && bd == null) return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          if (ad == null) return 1;
          if (bd == null) return -1;
          return ad.compareTo(bd);
        case _SortBy.size:
          return a.size.compareTo(b.size);
        case _SortBy.name:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
    }
    // Las carpetas siempre van primero (convención estándar de cualquier
    // explorador); el criterio y la dirección ordenan DENTRO de cada grupo.
    list.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      final c = cmp(a, b);
      return _sortAsc ? c : -c;
    });
    return list;
  }

  void _pickSort() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _C.card,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Text('Ordenar', style: TextStyle(color: _C.textHi, fontWeight: FontWeight.bold)),
              ),
              RadioListTile<_SortBy>(
                value: _SortBy.name,
                groupValue: _sortBy,
                activeColor: _C.accent,
                title: const Text('Nombre', style: TextStyle(color: _C.textHi)),
                onChanged: (v) { setState(() { _sortBy = v!; _sortAsc = true; }); setSheet(() {}); },
              ),
              RadioListTile<_SortBy>(
                value: _SortBy.date,
                groupValue: _sortBy,
                activeColor: _C.accent,
                title: const Text('Fecha', style: TextStyle(color: _C.textHi)),
                onChanged: (v) { setState(() { _sortBy = v!; _sortAsc = false; }); setSheet(() {}); },
              ),
              RadioListTile<_SortBy>(
                value: _SortBy.size,
                groupValue: _sortBy,
                activeColor: _C.accent,
                title: const Text('Tamaño', style: TextStyle(color: _C.textHi)),
                onChanged: (v) { setState(() { _sortBy = v!; _sortAsc = false; }); setSheet(() {}); },
              ),
              const Divider(color: _C.border, height: 1),
              SwitchListTile(
                value: _sortAsc,
                activeColor: _C.accent,
                title: Text(_sortAsc ? 'Ascendente' : 'Descendente',
                    style: const TextStyle(color: _C.textHi)),
                subtitle: Text(
                  _sortBy == _SortBy.name
                      ? (_sortAsc ? 'A a Z' : 'Z a A')
                      : _sortBy == _SortBy.date
                          ? (_sortAsc ? 'Antiguos primero' : 'Recientes primero')
                          : (_sortAsc ? 'Pequeños primero' : 'Grandes primero'),
                  style: const TextStyle(color: _C.textLo, fontSize: 12),
                ),
                onChanged: (v) { setState(() => _sortAsc = v); setSheet(() {}); },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  // ── Selección múltiple ─────────────────────────────────────────────────

  void _toggleSelect(SftpEntry e) {
    final path = _fullPath(e);
    setState(() {
      if (_selected.containsKey(path)) {
        _selected.remove(path);
      } else {
        _selected[path] = e;
      }
    });
  }

  void _selectAllHere() {
    setState(() {
      for (final e in _entries) {
        _selected[_fullPath(e)] = e;
      }
    });
  }

  void _clearSelection() => setState(() => _selected.clear());

  Future<void> _deleteSelected() async {
    final items = Map<String, SftpEntry>.from(_selected);
    final folders = items.values.where((e) => e.isDirectory).length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: Text('¿Eliminar ${items.length} elemento(s)?', style: const TextStyle(color: _C.textHi)),
        content: Text(
          folders > 0
              ? 'Incluye $folders carpeta(s) -- se borra TODO su contenido, sin '
                'posibilidad de deshacerlo.'
              : 'No se puede deshacer.',
          style: const TextStyle(color: _C.textLo, fontSize: 12.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar', style: TextStyle(color: _C.textLo))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Eliminar', style: TextStyle(color: _C.err))),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() { _busy = true; _busyLabel = 'Eliminando...'; });
    var done = 0;
    final messenger = ScaffoldMessenger.of(context);
    try {
      for (final entry in items.entries) {
        setState(() => _busyLabel = 'Eliminando ${done + 1}/${items.length}: ${entry.value.name}');
        await _svc.deleteRecursive(entry.key, isDirectory: entry.value.isDirectory);
        done++;
      }
      messenger.showSnackBar(SnackBar(content: Text('Eliminados $done elemento(s)')));
      _clearSelection();
      await _load(_path);
    } catch (err) {
      messenger.showSnackBar(SnackBar(
        content: Text('Fallo tras borrar $done de ${items.length}: $err'),
        backgroundColor: _C.err,
      ));
      await _load(_path);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _downloadSelected() async {
    final items = Map<String, SftpEntry>.from(_selected);
    setState(() { _busy = true; _busyLabel = 'Descargando...'; });
    var done = 0;
    final messenger = ScaffoldMessenger.of(context);
    try {
      for (final entry in items.entries) {
        final e = entry.value;
        if (e.isDirectory) {
          // Carpeta entera, recursivo; onProgress cuenta ficheros.
          await _svc.downloadFolder(entry.key, onProgress: (f) {
            if (mounted) setState(() => _busyLabel = 'Descargando ${e.name} · $f ficheros...');
          });
        } else {
          await _svc.download(entry.key, onProgress: (b) {
            if (mounted && e.size > 0) {
              setState(() => _busyLabel =
                  'Descargando ${done + 1}/${items.length}: ${e.name} · ${(100 * b / e.size).round()}%');
            }
          });
        }
        done++;
      }
      messenger.showSnackBar(SnackBar(content: Text('Descargados $done elemento(s) a Descargas/xtr_sftp/')));
      _clearSelection();
    } catch (err) {
      messenger.showSnackBar(SnackBar(
        content: Text('Fallo tras descargar $done de ${items.length}: $err'),
        backgroundColor: _C.err,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(SftpEntry e) async {
    setState(() { _busy = true; _busyLabel = 'Descargando ${e.name}...'; });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final local = await _svc.download(_fullPath(e), onProgress: (b) {
        if (mounted && e.size > 0) {
          setState(() => _busyLabel = 'Descargando ${e.name} · ${(100 * b / e.size).round()}%');
        }
      });
      messenger.showSnackBar(SnackBar(content: Text('Guardado en Descargas/xtr_sftp: $local')));
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text('Fallo al descargar: $err'), backgroundColor: _C.err));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(SftpEntry e) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('¿Eliminar?', style: TextStyle(color: _C.textHi)),
        content: Text(
          e.isDirectory ? '${e.name}\n\nEs una carpeta -- se borra TODO su contenido.' : e.name,
          style: const TextStyle(color: _C.textLo),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar', style: TextStyle(color: _C.textLo))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Eliminar', style: TextStyle(color: _C.err))),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() { _busy = true; _busyLabel = 'Eliminando ${e.name}...'; });
    try {
      await _svc.deleteRecursive(_fullPath(e), isDirectory: e.isDirectory);
      await _load(_path);
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No se pudo eliminar: $err'), backgroundColor: _C.err));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _newFolder() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('Nueva carpeta', style: TextStyle(color: _C.textHi)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: _C.textHi),
          decoration: const InputDecoration(filled: true, fillColor: _C.cardAlt, border: OutlineInputBorder(borderSide: BorderSide.none)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('Cancelar', style: TextStyle(color: _C.textLo))),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Crear', style: TextStyle(color: _C.accent))),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final remote = _path == '.' ? name : '$_path/$name';
    try {
      await _svc.mkdir(remote);
      await _load(_path);
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No se pudo crear: $err'), backgroundColor: _C.err));
      }
    }
  }

  Future<void> _gotoPath() async {
    final ctrl = TextEditingController(text: _path == '.' ? '~' : _path);
    final dest = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('Ir a la ruta', style: TextStyle(color: _C.textHi)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: _C.textHi, fontFamily: 'monospace', fontSize: 13),
          onSubmitted: (v) => Navigator.pop(ctx, v),
          decoration: const InputDecoration(
            hintText: '/etc/nginx  o  ~/proyectos',
            hintStyle: TextStyle(color: _C.textLo),
            filled: true,
            fillColor: _C.cardAlt,
            border: OutlineInputBorder(borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancelar', style: TextStyle(color: _C.textLo))),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Ir', style: TextStyle(color: _C.accent))),
        ],
      ),
    );
    if (dest == null || dest.trim().isEmpty || !mounted) return;
    var target = dest.trim();
    if (target == '~' || target == '~/') target = '.';
    try {
      await _load(target);
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No se pudo abrir: $err'), backgroundColor: _C.err));
      }
    }
  }

  void _copyCurrentPath() {
    final shown = _path == '.' ? '~' : _path;
    Clipboard.setData(ClipboardData(text: shown));
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ruta copiada: $shown')));
  }

  Future<void> _rename(SftpEntry e) async {
    final ctrl = TextEditingController(text: e.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: Text('Renombrar ${e.isDirectory ? 'carpeta' : 'fichero'}', style: const TextStyle(color: _C.textHi)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: _C.textHi),
          onSubmitted: (v) => Navigator.pop(ctx, v),
          decoration: const InputDecoration(
            filled: true,
            fillColor: _C.cardAlt,
            border: OutlineInputBorder(borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancelar', style: TextStyle(color: _C.textLo))),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Renombrar', style: TextStyle(color: _C.accent))),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == e.name || !mounted) return;
    if (newName.contains('/')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('El nombre no puede contener /'),
        backgroundColor: _C.err,
      ));
      return;
    }
    final newPath = _path == '.' ? newName : '$_path/$newName';
    setState(() { _busy = true; _busyLabel = 'Renombrando...'; });
    try {
      await _svc.rename(_fullPath(e), newPath);
      await _load(_path);
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No se pudo renombrar: $err'), backgroundColor: _C.err));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _downloadFolder(SftpEntry e) async {
    setState(() { _busy = true; _busyLabel = 'Descargando carpeta ${e.name}...'; });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final n = await _svc.downloadFolder(_fullPath(e), onProgress: (f) {
        if (mounted) setState(() => _busyLabel = 'Descargando ${e.name} · $f ficheros...');
      });
      messenger.showSnackBar(SnackBar(
          content: Text('Carpeta descargada ($n ficheros) en Descargas/xtr_sftp/')));
    } catch (err) {
      messenger.showSnackBar(SnackBar(
          content: Text('Fallo al descargar la carpeta: $err'), backgroundColor: _C.err));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uploadFolders() async {
    final localPaths = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(builder: (_) => const LocalFilePickerScreen(folderMode: true)),
    );
    if (localPaths == null || localPaths.isEmpty || !mounted) return;

    setState(() { _busy = true; _busyLabel = 'Subiendo carpetas...'; });
    var done = 0;
    final messenger = ScaffoldMessenger.of(context);
    try {
      for (final localPath in localPaths) {
        final name = localPath.split('/').last;
        await _svc.uploadFolder(localPath, _path, onProgress: (f) {
          if (mounted) {
            setState(() => _busyLabel =
                'Subiendo ${done + 1}/${localPaths.length}: $name · $f ficheros...');
          }
        });
        done++;
      }
      messenger.showSnackBar(SnackBar(content: Text('Subida(s) $done carpeta(s)')));
      await _load(_path);
    } catch (err) {
      messenger.showSnackBar(SnackBar(
        content: Text('Fallo tras subir $done de ${localPaths.length}: $err'),
        backgroundColor: _C.err,
      ));
      await _load(_path);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showStorage() async {
    try {
      final (total, free) = await _svc.statVfs(_path);
      if (!mounted) return;
      final used = total - free;
      final pct = total > 0 ? (100 * used / total).round() : 0;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _C.card,
          title: const Text('Espacio del servidor', style: TextStyle(color: _C.textHi)),
          content: Text(
            'Libre:  ${_fmtSize(free)}\n'
            'Usado: ${_fmtSize(used)} ($pct%)\n'
            'Total:  ${_fmtSize(total)}',
            style: const TextStyle(color: _C.textLo, fontFamily: 'monospace', fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar', style: TextStyle(color: _C.accent)),
            ),
          ],
        ),
      );
    } catch (_) {
      // statvfs es una extensión (statvfs@openssh.com): no todos los
      // servidores la tienen; se informa sin drama.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Este servidor no soporta la consulta de espacio (statvfs)'),
          backgroundColor: _C.err,
        ));
      }
    }
  }

  void _showFabMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _C.card,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_file, color: _C.accent),
              title: const Text('Subir archivo(s)', style: TextStyle(color: _C.textHi)),
              onTap: () { Navigator.pop(ctx); _uploadFiles(); },
            ),
            ListTile(
              leading: const Icon(Icons.drive_folder_upload_outlined, color: _C.accent),
              title: const Text('Subir carpeta(s)', style: TextStyle(color: _C.textHi)),
              subtitle: const Text('Recursivo: replica toda la estructura', style: TextStyle(color: _C.textLo, fontSize: 11)),
              onTap: () { Navigator.pop(ctx); _uploadFolders(); },
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined, color: _C.accent),
              title: const Text('Nueva carpeta', style: TextStyle(color: _C.textHi)),
              onTap: () { Navigator.pop(ctx); _newFolder(); },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _uploadFiles() async {
    final localPaths = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute(builder: (_) => const LocalFilePickerScreen()),
    );
    if (localPaths == null || localPaths.isEmpty || !mounted) return;

    setState(() { _busy = true; _busyLabel = 'Subiendo...'; });
    var done = 0;
    final messenger = ScaffoldMessenger.of(context);
    try {
      for (final localPath in localPaths) {
        final fileName = localPath.split('/').last;
        final total = await File(localPath).length();
        setState(() => _busyLabel = 'Subiendo ${done + 1}/${localPaths.length}: $fileName');
        final remote = _path == '.' ? fileName : '$_path/$fileName';
        await _svc.upload(localPath, remote, onProgress: (sent) {
          if (mounted && total > 0) {
            setState(() => _busyLabel =
                'Subiendo ${done + 1}/${localPaths.length}: $fileName · ${(100 * sent / total).round()}%');
          }
        });
        done++;
      }
      messenger.showSnackBar(SnackBar(content: Text('Subido(s) $done fichero(s)')));
      await _load(_path);
    } catch (err) {
      messenger.showSnackBar(SnackBar(
        content: Text('Fallo tras subir $done de ${localPaths.length}: $err'),
        backgroundColor: _C.err,
      ));
      await _load(_path);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showFavorites() {
    final favs = SftpFavoritesService.instance.forHost(widget.host.id);
    showModalBottomSheet(
      context: context,
      backgroundColor: _C.card,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Row(
                children: [
                  Icon(Icons.star, color: Color(0xFFFFD60A), size: 18),
                  SizedBox(width: 8),
                  Text('Favoritos', style: TextStyle(color: _C.textHi, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            if (favs.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('Sin rutas guardadas todavia. Toca la estrella arriba para guardar la actual.',
                    style: TextStyle(color: _C.textLo, fontSize: 12)),
              ),
            ...favs.map((f) => ListTile(
                  leading: const Icon(Icons.folder, color: _C.accent, size: 20),
                  title: Text(f.label, style: const TextStyle(color: _C.textHi, fontSize: 13)),
                  trailing: IconButton(
                    icon: const Icon(Icons.close, color: _C.textLo, size: 18),
                    onPressed: () async {
                      await SftpFavoritesService.instance.remove(f.id);
                      Navigator.pop(ctx);
                    },
                  ),
                  onTap: () { Navigator.pop(ctx); _load(f.path); },
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showActions(SftpEntry e) {
  void _edit(SftpEntry e) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SftpTextEditorScreen(
          fileName: e.name,
          loader: () => _svc.readFile(_fullPath(e)),
          saver: (bytes) => _svc.writeFile(_fullPath(e), bytes),
        ),
      ),
    ).then((_) => _load(_path));
  }

    showModalBottomSheet(
      context: context,
      backgroundColor: _C.card,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!e.isDirectory)
              ListTile(
                leading: const Icon(Icons.download, color: _C.accent),
                title: const Text('Descargar', style: TextStyle(color: _C.textHi)),
                onTap: () { Navigator.pop(ctx); _download(e); },
              ),
            
      if (!e.isDirectory)
        ListTile(
          leading: const Icon(Icons.edit_outlined, color: _C.accent),
          title: const Text("Editar", style: TextStyle(color: _C.textHi)),
          onTap: () { Navigator.pop(ctx); _edit(e); },
        ),
if (e.isDirectory)
              ListTile(
                leading: const Icon(Icons.download_for_offline_outlined, color: _C.accent),
                title: const Text('Descargar carpeta (recursivo)', style: TextStyle(color: _C.textHi)),
                onTap: () { Navigator.pop(ctx); _downloadFolder(e); },
              ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline, color: _C.accent),
              title: const Text('Renombrar', style: TextStyle(color: _C.textHi)),
              onTap: () { Navigator.pop(ctx); _rename(e); },
            ),
            ListTile(
              leading: const Icon(Icons.link, color: _C.textLo),
              title: const Text('Copiar ruta', style: TextStyle(color: _C.textHi)),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: _fullPath(e)));
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Ruta copiada: ${_fullPath(e)}')));
              },
            ),
            ListTile(
              leading: const Icon(Icons.check_box_outlined, color: _C.textLo),
              title: const Text('Seleccionar', style: TextStyle(color: _C.textHi)),
              onTap: () { Navigator.pop(ctx); _toggleSelect(e); },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: _C.err),
              title: const Text('Eliminar', style: TextStyle(color: _C.textHi)),
              onTap: () { Navigator.pop(ctx); _delete(e); },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.bg,
      appBar: _selecting ? _selectionAppBar() : _normalAppBar(),
      body: _buildBody(),
      floatingActionButton: _state == _LoadState.ready && !_selecting
          ? FloatingActionButton(
              backgroundColor: _C.accent,
              onPressed: _showFabMenu,
              child: const Icon(Icons.add, color: Colors.white),
            )
          : null,
    );
  }

  PreferredSizeWidget _normalAppBar() {
    return AppBar(
      backgroundColor: _C.bg,
      elevation: 0,
      automaticallyImplyLeading: !widget.embedded,
      toolbarHeight: widget.embedded ? 42 : null,
      iconTheme: const IconThemeData(color: _C.textHi),
      title: Text(widget.host.name, style: const TextStyle(color: _C.textHi, fontSize: 16)),
      actions: _state == _LoadState.ready
          ? [
              if (widget.onOpenTerminal != null)
                IconButton(
                  tooltip: widget.embedded
                      ? 'Volver a la terminal'
                      : 'Abrir terminal SSH (sin cortar esto)',
                  icon: const Icon(Icons.terminal, color: _C.textLo),
                  onPressed: () => widget.onOpenTerminal!(widget.host),
                ),
              IconButton(
                tooltip: 'Ordenar',
                icon: const Icon(Icons.sort, color: _C.textLo),
                onPressed: _pickSort,
              ),
              IconButton(
                tooltip: 'Favoritos',
                icon: const Icon(Icons.star_border, color: _C.textLo),
                onPressed: _showFavorites,
              ),
              IconButton(
                tooltip: SftpFavoritesService.instance.isFavorite(widget.host.id, _path)
                    ? 'Quitar de favoritos'
                    : 'Guardar esta ruta',
                icon: Icon(
                  SftpFavoritesService.instance.isFavorite(widget.host.id, _path)
                      ? Icons.star
                      : Icons.star_outline,
                  color: SftpFavoritesService.instance.isFavorite(widget.host.id, _path)
                      ? const Color(0xFFFFD60A)
                      : _C.textLo,
                ),
                onPressed: () async {
                  await SftpFavoritesService.instance.toggle(widget.host.id, _path);
                  if (mounted) setState(() {});
                },
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: _C.textLo),
                color: _C.card,
                onSelected: (v) {
                  switch (v) {
                    case 'goto':
                      _gotoPath();
                      break;
                    case 'refresh':
                      _load(_path);
                      break;
                    case 'storage':
                      _showStorage();
                      break;
                    case 'hidden':
                      setState(() => _showHidden = !_showHidden);
                      break;
                    case 'disconnect':
                      SftpConnectionPool.instance.disconnect(widget.host.id).then((_) {
                        if (!mounted) return;
                        setState(() {
                          _svc = SftpConnectionPool.instance.forHost(widget.host, widget.rootfsPath);
                          _state = _LoadState.connecting;
                        });
                        _connect();
                      });
                      break;
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'goto', child: Text('Ir a la ruta…')),
                  const PopupMenuItem(value: 'refresh', child: Text('Actualizar')),
                  const PopupMenuItem(value: 'storage', child: Text('Espacio del servidor')),
                  PopupMenuItem(
                    value: 'hidden',
                    child: Text(_showHidden ? 'Ocultar ficheros ocultos' : 'Mostrar ficheros ocultos'),
                  ),
                  const PopupMenuItem(value: 'disconnect', child: Text('Desconectar y reconectar')),
                ],
              ),
            ]
          : null,
    );
  }

  PreferredSizeWidget _selectionAppBar() {
    return AppBar(
      backgroundColor: _C.bg,
      elevation: 0,
      iconTheme: const IconThemeData(color: _C.textHi),
      leading: IconButton(icon: const Icon(Icons.close), onPressed: _clearSelection),
      title: Text('${_selected.length} seleccionado(s)', style: const TextStyle(color: _C.textHi, fontSize: 16)),
      actions: [
        IconButton(tooltip: 'Seleccionar todo', icon: const Icon(Icons.select_all, color: _C.textLo), onPressed: _selectAllHere),
        IconButton(tooltip: 'Descargar', icon: const Icon(Icons.download, color: _C.textLo), onPressed: _downloadSelected),
        IconButton(tooltip: 'Eliminar', icon: const Icon(Icons.delete_outline, color: _C.err), onPressed: _deleteSelected),
      ],
    );
  }

  Widget _buildBody() {
    if (_state == _LoadState.connecting) {
      return const Center(child: CircularProgressIndicator(color: _C.accent));
    }
    if (_state == _LoadState.error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: _C.err, size: 40),
              const SizedBox(height: 12),
              Text(_error, style: const TextStyle(color: _C.textLo, fontSize: 12), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _connect,
                style: ElevatedButton.styleFrom(backgroundColor: _C.accent),
                child: const Text('Reintentar', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: _C.cardAlt,
          child: Row(
            children: [
              if (_path != '.' && !_selecting)
                IconButton(icon: const Icon(Icons.arrow_upward, color: _C.textLo, size: 18), onPressed: _up),
              Expanded(
                child: Text(
                  _busy ? _busyLabel : (_path == '.' ? '/' : '/$_path'),
                  style: const TextStyle(color: _C.textLo, fontSize: 12, fontFamily: 'monospace'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Copiar ruta',
                icon: const Icon(Icons.copy, color: _C.textLo, size: 16),
                onPressed: _copyCurrentPath,
              ),
              if (_busy)
                const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _C.accent)),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(_path),
            color: _C.accent,
            backgroundColor: _C.card,
            child: _entries.isEmpty
                ? ListView(children: const [
                    Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: Text('Carpeta vacía', style: TextStyle(color: _C.textLo))),
                    ),
                  ])
                : ListView.builder(
                    itemCount: _sortedEntries.length,
                    itemBuilder: (context, i) {
                      final e = _sortedEntries[i];
                      final path = _fullPath(e);
                      final selected = _selected.containsKey(path);
                      final dateStr = _fmtDate(e.modified);
                      final subtitle = e.isDirectory
                          ? (dateStr.isEmpty ? null : dateStr)
                          : (dateStr.isEmpty ? _fmtSize(e.size) : '${_fmtSize(e.size)} - $dateStr');
                      return ListTile(
                        leading: _selecting
                            ? Checkbox(value: selected, onChanged: (_) => _toggleSelect(e), activeColor: _C.accent)
                            : Icon(
                                e.isDirectory ? Icons.folder : Icons.insert_drive_file_outlined,
                                color: e.isDirectory ? _C.accent : _C.textLo,
                              ),
                        title: Text(e.name, style: const TextStyle(color: _C.textHi, fontSize: 14)),
                        subtitle: subtitle == null
                            ? null
                            : Text(subtitle, style: const TextStyle(color: _C.textLo, fontSize: 11)),
                        selected: selected,
                        selectedTileColor: _C.cardAlt,
                        onTap: () {
                          if (_selecting) {
                            _toggleSelect(e);
                          } else if (e.isDirectory) {
                            _enter(e);
                          } else {
                            _showActions(e);
                          }
                        },
                        onLongPress: () {
                          if (!_selecting) _toggleSelect(e);
                        },
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}
