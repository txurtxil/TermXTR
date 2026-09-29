import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import '../storage/app_paths.dart';
import 'terminal_keybar.dart';
import 'terminal_session.dart';
import 'keybar_config.dart';
import 'keybar_settings_screen.dart';
import 'clipboard_vault.dart';
import 'clipboard_vault_sheet.dart';
import 'selection_overlay_termux.dart';
import '../ssh/ssh_host.dart';
import '../ssh/ssh_hosts_service.dart';
import '../ssh/ssh_credentials_store.dart';
import '../ssh/hosts_screen.dart';
import '../sftp/sftp_browser_screen.dart';
import '../sftp/sftp_favorites_service.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});
  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> with WidgetsBindingObserver {
  final List<TerminalSession> _sessions = [];
  int _activeIndex = 0;
  static const int _maxSessions = 5;
  static const String _appVersion = 'v14.24';

  // Canal con el lado nativo para el widget de escritorio (XTR Hosts).
  static const MethodChannel _widgetCh = MethodChannel('xtr/widget');
  // Canal keep-alive: foreground service que mantiene el proceso (y las
  // sesiones SSH/SFTP hijas) vivo con la app en segundo plano.
  static const MethodChannel _keepAliveCh = MethodChannel('xtr/keepalive');

  List<KeyConfigItem> _keybarConfig = KeyCatalog.defaultConfig;
  final List<String> _logLines = [];
  double? _progress = 0.0;
  bool _spinning = false;
  bool _booting = true;
  bool _showHostsOnStartup = false;
  bool _keepAlive = true;
  String? _error;

  final Map<int, FocusNode> _focusNodes = {};
  final Map<int, GlobalKey<TerminalViewState>> _viewKeys = {};
  final Set<TerminalSession> _sftpOpened = {};
  final Set<TerminalSession> _sftpOpen = {};

  double _fontSize = 12.0;
  static const double _minFont = 8.0;
  static const double _maxFont = 28.0;

  TerminalSession get _active => _sessions[_activeIndex];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) {
          _focusNodes[_activeIndex]?.requestFocus();
          SystemChannels.textInput.invokeMethod('TextInput.show');
        }
      });
    }
  }

  void _appendLog(String line, {bool spinning = false, double? progress}) {
    if (!mounted) return;
    setState(() {
      _logLines.add(line);
      _spinning = spinning;
      if (progress != null) _progress = progress;
    });
  }

  Future<void> _boot() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _showHostsOnStartup = prefs.getBool('showHostsOnStartup') ?? false;
      // Keep-alive en 2o plano: por defecto ON. Sin un foreground service
      // Android mata el proceso al minimizar y las sesiones mueren con el
      // (el ServerAliveInterval no sirve si el proceso ya no existe).
      _keepAlive = prefs.getBool('keepAliveService') ?? true;
      if (_keepAlive) {
        try { await _keepAliveCh.invokeMethod('start'); } catch (_) {}
      }

      _keybarConfig = await KeybarConfig.load();

      // v14.24: sin contenedor Debian — los datos viven en el almacenamiento
      // privado de la app y se migran desde el rootfs antiguo si existe.
      await AppPaths.init();
      await AppPaths.migrateLegacyData();
      await ClipboardVault.instance.loadFrom(AppPaths.base);
      await SshHostsService.instance.loadFrom(AppPaths.base);
      await SftpFavoritesService.instance.loadFrom(AppPaths.base);
      _initWidgetChannel();

      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;

      _addSession(initial: true);
      setState(() => _booting = false);

      SchedulerBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.endOfFrame.then((_) {
          if (mounted) {
            _startActiveSession();
            if (_showHostsOnStartup) {
              Future.delayed(const Duration(milliseconds: 150), _openHosts);
            }
          }
        });
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _booting = false; });
    }
  }

  void _addSession({bool initial = false}) {
    if (_sessions.length >= _maxSessions) { _toast('Máximo $_maxSessions sesiones'); return; }
    _sessions.add(TerminalSession('Sesión ${_sessions.length + 1}'));
    if (!initial) {
      setState(() => _activeIndex = _sessions.length - 1);
      SchedulerBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.endOfFrame.then((_) { if (mounted) _startActiveSession(); });
      });
    }
  }

  void _startActiveSession() {
    final s = _active;
    if (s.isStarted) return;
    s.start(columns: s.terminal.viewWidth, rows: s.terminal.viewHeight);
  }

  Future<void> _connectToHost(SshHost host) async {
    if (_sessions.length >= _maxSessions) { _toast('Máximo $_maxSessions sesiones'); return; }
    // La contraseña guardada (Keystore) se inyecta en el cliente dartssh2;
    // el hack del fichero sshpass dentro del rootfs muere con el contenedor.
    String? pwd;
    final hasKey = host.keyPath != null && host.keyPath!.trim().isNotEmpty;
    if (!hasKey) {
      pwd = await SshCredentialsStore.readPassword(host.id);
      if (!mounted) return;
    }
    _sessions.add(TerminalSession(host.name, sourceHost: host, password: pwd));
    setState(() => _activeIndex = _sessions.length - 1);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.endOfFrame.then((_) { if (mounted) _startActiveSession(); });
    });
  }

  void _toggleSftp(TerminalSession s) {
    if (s.sourceHost == null) return;
    setState(() {
      if (_sftpOpen.remove(s)) return;
      _sftpOpened.add(s); _sftpOpen.add(s);
    });
  }

  void _openHosts() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => HostsScreen(
        rootfsPath: AppPaths.base,
        onConnect: (host) { Navigator.of(context).pop(); _connectToHost(host); },
        onOpenTerminalFromSftp: (host) { Navigator.of(context).popUntil((r) => r.isFirst); _connectToHost(host); },
      ),
    ));
  }

  void _switchTo(int index) {
    if (index == _activeIndex) return;
    setState(() => _activeIndex = index);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.endOfFrame.then((_) { if (mounted) _startActiveSession(); });
    });
  }

  void _closeSession(int index) {
    if (_sessions.length == 1) { _toast('No puedes cerrar la última sesión'); return; }
    final s = _sessions[index];
    _sftpOpen.remove(s); _sftpOpened.remove(s); s.dispose();
    setState(() {
      _sessions.removeAt(index);
      if (_activeIndex >= _sessions.length) _activeIndex = _sessions.length - 1;
    });
  }

  void _changeFont(double delta) { setState(() { _fontSize = (_fontSize + delta).clamp(_minFont, _maxFont); }); }

  void _copySelection() {
    final sel = _active.controller.selection;
    if (sel != null) {
      final text = _active.terminal.buffer.getText(sel);
      if (text.isNotEmpty) { Clipboard.setData(ClipboardData(text: text)); _active.controller.clearSelection(); _toast('Copiado al portapapeles'); }
    }
  }
  
  void _copyEntireSession(TerminalSession s) {
    final buf = s.terminal.buffer;
    final base = buf.createAnchor(0, 0);
    final extent = buf.createAnchor(buf.viewWidth - 1, buf.height - 1);
    s.controller.setSelection(base, extent);
    final sel = s.controller.selection;
    if (sel != null) {
      final text = buf.getText(sel);
      if (text.isNotEmpty) {
        Clipboard.setData(ClipboardData(text: text));
        _toast('Sesión completa copiada');
      }
    }
    s.controller.clearSelection();
  }

  void _selectAll() {
    final buf = _active.terminal.buffer;
    final topAbsolute = (buf.height - buf.viewHeight - buf.scrollBack).clamp(0, buf.height - 1).toInt();
    final bottomAbsolute = (topAbsolute + buf.viewHeight - 1).clamp(0, buf.height - 1).toInt();
    final base = buf.createAnchor(0, topAbsolute);
    final extent = buf.createAnchor(buf.viewWidth - 1, bottomAbsolute);
    _active.controller.setSelection(base, extent);
  }

  // ── Widget de escritorio (XTR Hosts) ──────────────────────────────────

  /// Escucha los avisos del lado nativo y recoge la accion pendiente
  /// (fetch+clear atomico en "getPendingAction": sin duplicados).
  void _initWidgetChannel() {
    _widgetCh.setMethodCallHandler((call) async {
      if (call.method == 'onWidgetAction') await _consumeWidgetAction();
    });
    // Arranque en frio por click del widget.
    _consumeWidgetAction();
  }

  Future<void> _consumeWidgetAction() async {
    try {
      final Map<dynamic, dynamic>? action =
          await _widgetCh.invokeMethod<Map<dynamic, dynamic>>('getPendingAction');
      if (action != null) _handleWidgetAction(action);
    } catch (_) {}
  }

  void _handleWidgetAction(Map<dynamic, dynamic> action) {
    if (!mounted) return;
    final type = action['type']?.toString();
    final hostId = action['hostId']?.toString();
    if (hostId == null || hostId.isEmpty) return;
    final matches = SshHostsService.instance.hosts.where((h) => h.id == hostId);
    if (matches.isEmpty) {
      _toast('El host del widget ya no existe');
      return;
    }
    final host = matches.first;
    if (type == 'sftp') {
      final path = action['path']?.toString();
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SftpBrowserScreen(
          host: host,
          rootfsPath: AppPaths.base,
          initialDir: (path != null && path.isNotEmpty) ? path : null,
          onOpenTerminal: (h) {
            Navigator.of(context).popUntil((r) => r.isFirst);
            _connectToHost(h);
          },
        ),
      ));
    } else {
      _connectToHost(host);
    }
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      _active.terminal.textInput(data.text!);
    }
  }

  void _toast(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 1)));
  }

  void _openKeybarSettings() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => KeybarSettingsScreen(initial: _keybarConfig, onChanged: (newConfig) { setState(() => _keybarConfig = List.from(newConfig)); }),
    ));
  }

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context, backgroundColor: const Color(0xFF1A1A1A),
      builder: (ctx) => SafeArea(
        child: StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(leading: const Icon(Icons.keyboard, color: Colors.greenAccent), title: const Text('Configurar teclado', style: TextStyle(color: Colors.white)), subtitle: const Text('Mostrar, ocultar y reordenar teclas', style: TextStyle(color: Colors.white54)), onTap: () { Navigator.pop(ctx); _openKeybarSettings(); }),
                ListTile(leading: const Icon(Icons.content_paste_go, color: Colors.greenAccent), title: const Text('Portapapeles e historial', style: TextStyle(color: Colors.white)), subtitle: const Text('Clips guardados y texto de la sesión', style: TextStyle(color: Colors.white54)), onTap: () { Navigator.pop(ctx); _openClipboardVault(_active); }),
                ListTile(
                  leading: const Icon(Icons.format_size, color: Colors.greenAccent), title: const Text('Tamaño de fuente', style: TextStyle(color: Colors.white)), subtitle: Text('${_fontSize.toInt()} pt', style: const TextStyle(color: Colors.white54)),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(icon: const Icon(Icons.remove, color: Colors.white), onPressed: () { _changeFont(-1); setModalState(() {}); }),
                    IconButton(icon: const Icon(Icons.add, color: Colors.white), onPressed: () { _changeFont(1); setModalState(() {}); }),
                  ]),
                ),
                SwitchListTile(
                  activeColor: Colors.greenAccent, secondary: const Icon(Icons.rocket_launch, color: Colors.amberAccent),
                  title: const Text('Arranque directo en Hosts', style: TextStyle(color: Colors.white)), subtitle: const Text('Abrir lista SSH/SFTP al iniciar', style: TextStyle(color: Colors.white54)),
                  value: _showHostsOnStartup,
                  onChanged: (bool value) async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('showHostsOnStartup', value);
                    setState(() => _showHostsOnStartup = value);
                    setModalState(() => _showHostsOnStartup = value);
                  },
                ),
                SwitchListTile(
                  activeColor: Colors.greenAccent, secondary: const Icon(Icons.bolt, color: Colors.greenAccent),
                  title: const Text('Mantener sesiones en 2º plano', style: TextStyle(color: Colors.white)), subtitle: const Text('Servicio en primer plano + wake lock (notificación persistente)', style: TextStyle(color: Colors.white54)),
                  value: _keepAlive,
                  onChanged: (bool value) async {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('keepAliveService', value);
                    try { await _keepAliveCh.invokeMethod(value ? 'start' : 'stop'); } catch (_) {}
                    setState(() => _keepAlive = value);
                    setModalState(() => _keepAlive = value);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.battery_saver, color: Colors.orangeAccent),
                  title: const Text('Excluir de optimización de batería', style: TextStyle(color: Colors.white)),
                  subtitle: const Text('Evita que Android/Samsung mate la app en segundo plano', style: TextStyle(color: Colors.white54)),
                  onTap: () async {
                    try { await _keepAliveCh.invokeMethod('batterySettings'); } catch (_) {}
                  },
                ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Portapapeles guardados (ClipboardVault): existía grabando desde hace
  /// versiones pero NO tenía entrada en ningún menú — quedó cableado aquí
  /// y en Utilidades en v14.22.
  void _openClipboardVault(TerminalSession s) {
    showClipboardVault(
      context,
      recorder: s.recorder,
      sessionLabel: _sessions.length > 1 ? s.name : null,
    );
  }

  Widget _menuHeader(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(label.toUpperCase(), style: const TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
    ),
  );

  void _showQuickScripts(TerminalSession s) {
    showModalBottomSheet<void>(
      context: context, backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('Utilidades', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), dense: true),
              const Divider(color: Colors.white24),
              _menuHeader('Portapapeles'),
              _scriptTile(ctx, s, 'Pegar', '', icon: Icons.paste, customAction: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (ctx.mounted) Navigator.pop(ctx);
                if (data?.text != null && data!.text!.isNotEmpty) {
                  s.terminal.textInput(data.text!);
                }
              }),
              _scriptTile(ctx, s, 'Copiar toda la sesión', '', icon: Icons.copy_all, customAction: () { Navigator.pop(ctx); _copyEntireSession(s); }),
              _scriptTile(ctx, s, 'Portapapeles guardados', '', icon: Icons.content_paste_go, customAction: () { Navigator.pop(ctx); _openClipboardVault(s); }),
              _menuHeader('Sesión'),
              _scriptTile(ctx, s, 'Autocompletar (Doble Tab)', '\t\t', icon: Icons.keyboard_tab),
              _scriptTile(ctx, s, 'Limpiar terminal (clear)', 'clear\n', icon: Icons.cleaning_services),
              _scriptTile(ctx, s, 'Reiniciar sesión actual', '', icon: Icons.restart_alt, customAction: () {
                Navigator.pop(ctx);
                s.restart(columns: s.terminal.viewWidth, rows: s.terminal.viewHeight);
              }),
              _menuHeader('Sistema'),
              _scriptTile(ctx, s, 'Espacio en disco (df -h)', 'df -h\n', icon: Icons.storage),
              _scriptTile(ctx, s, 'Memoria (free -h)', 'free -h\n', icon: Icons.bar_chart),
              // proot-safe: free lee /proc/meminfo (funciona); en cambio
              // `ip neigh` (netlink) y `ps/uptime` están capados en proot,
              // por eso ARP va por /proc y htop tiene fallback a top.
              _scriptTile(ctx, s, 'Tabla ARP (/proc/net/arp)', 'cat /proc/net/arp\n', icon: Icons.router),
              _scriptTile(ctx, s, 'Info de red (ip a)', 'ip a\n', icon: Icons.network_cell),
              _scriptTile(ctx, s, 'Mapeos de unidades (mount)', 'mount | column -t 2>/dev/null || mount\n', icon: Icons.usb),
              _scriptTile(ctx, s, 'Procesos activos (htop/top)', 'htop 2>/dev/null || top\n', icon: Icons.memory),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _scriptTile(BuildContext ctx, TerminalSession s, String label, String cmd, {IconData? icon, VoidCallback? customAction}) {
    return ListTile(
      dense: true, leading: Icon(icon ?? Icons.code, color: Colors.lightBlueAccent, size: 20),
      title: Text(label, style: const TextStyle(color: Colors.white)),
      onTap: () {
        if (customAction != null) {
          customAction();
        } else {
          Navigator.pop(ctx);
          s.terminal.textInput(cmd);
        }
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final n in _focusNodes.values) n.dispose();
    for (final s in _sessions) s.dispose();
    super.dispose();
  }

  Color _lineColor(String line) {
    if (line.contains('[ OK ]')) return Colors.greenAccent;
    if (line.contains('[ .. ]')) return Colors.amberAccent;
    if (line.contains('[ !! ]')) return Colors.orangeAccent;
    return Colors.white70;
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Scaffold(backgroundColor: Colors.black, body: SafeArea(child: Padding(padding: const EdgeInsets.all(16), child: SingleChildScrollView(child: Text('ERROR:\n$_error', style: const TextStyle(color: Colors.red, fontFamily: 'monospace'))))));
    if (_booting) return Scaffold(backgroundColor: Colors.black, body: SafeArea(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('LinuxContainer · arranque', style: TextStyle(color: Colors.white38, fontFamily: 'monospace', fontSize: 12)), const SizedBox(height: 12), Expanded(child: ListView.builder(itemCount: _logLines.length, itemBuilder: (ctx, i) => Padding(padding: const EdgeInsets.symmetric(vertical: 1), child: Text(_logLines[i], style: TextStyle(color: _lineColor(_logLines[i]), fontFamily: 'monospace', fontSize: 13, height: 1.3))))), const SizedBox(height: 12), LinearProgressIndicator(value: _spinning ? null : _progress, backgroundColor: Colors.white10, color: Colors.greenAccent), const SizedBox(height: 8)]))));
    return Scaffold(backgroundColor: Colors.black, body: SafeArea(child: _terminalView()));
  }

  Widget _terminalView() {
    return Column(
      children: [
        Container(
          color: const Color(0xFF1A1A1A), padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
          child: Row(
            children: [
              const SizedBox(width: 8),
              const Expanded(child: Text('XTR Terminal $_appVersion', style: TextStyle(color: Colors.white70, fontSize: 14, fontFamily: 'monospace', fontWeight: FontWeight.bold))),
              IconButton(tooltip: 'Hosts SSH / SFTP', onPressed: _openHosts, icon: const Icon(Icons.dns_rounded, color: Colors.lightBlueAccent, size: 22)),
              if (_active.sourceHost != null) IconButton(tooltip: _sftpOpen.contains(_active) ? 'Volver a la shell' : 'SFTP de este host', onPressed: () => _toggleSftp(_active), icon: Icon(_sftpOpen.contains(_active) ? Icons.terminal : Icons.folder_open, color: Colors.amberAccent, size: 22)),
              if (_sessions.length < _maxSessions) IconButton(tooltip: 'Nueva sesión', onPressed: _addSession, icon: const Icon(Icons.add, color: Colors.greenAccent, size: 22)),
            ],
          ),
        ),
        Container(
          height: 38,
          color: const Color(0xFF121212),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _sessions.length,
            itemBuilder: (context, i) {
              final s = _sessions[i];
              final isActive = i == _activeIndex;
              return GestureDetector(
                onTap: () => _switchTo(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: isActive ? const Color(0xFF2A2A2A) : Colors.transparent,
                    border: Border(bottom: BorderSide(color: isActive ? Colors.lightBlueAccent : Colors.transparent, width: 2)),
                  ),
                  child: Row(
                    children: [
                      Icon(s.sourceHost != null ? Icons.dns_rounded : Icons.computer, size: 14, color: s.sourceHost != null ? Colors.lightBlueAccent : Colors.tealAccent),
                      const SizedBox(width: 8),
                      Text(s.name, style: TextStyle(color: isActive ? Colors.white : Colors.white54, fontSize: 13, fontWeight: isActive ? FontWeight.bold : FontWeight.normal)),
                      if (_sessions.length > 1) ...[
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () => _closeSession(i),
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(color: Colors.white.withOpacity(0.1), shape: BoxShape.circle),
                            child: const Icon(Icons.close, size: 12, color: Colors.white70),
                          ),
                        )
                      ]
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _activeIndex,
            children: _sessions.asMap().entries.map((entry) {
              final i = entry.key; final s = entry.value;
              final focusNode = _focusNodes.putIfAbsent(i, () => FocusNode());
              final viewKey = _viewKeys.putIfAbsent(i, () => GlobalKey<TerminalViewState>());
              
              final terminalPane = GestureDetector(
                behavior: HitTestBehavior.translucent,
                onDoubleTap: () => _showQuickScripts(s),
                child: TermuxSelectionOverlay(
                  terminal: s.terminal, controller: s.controller, terminalViewKey: viewKey, scrollController: s.scrollController,
                  onCopy: _copySelection, onPaste: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    if (data?.text != null && data!.text!.isNotEmpty) s.terminal.textInput(data.text!);
                  }, onSelectAll: _selectAll,
                  child: TerminalView(s.terminal, key: viewKey, controller: s.controller, focusNode: focusNode, autofocus: true, backgroundOpacity: 1.0, deleteDetection: true, keyboardType: TextInputType.visiblePassword, scrollController: s.scrollController, textStyle: TerminalStyle(fontSize: _fontSize, fontFamily: 'monospace')),
                ),
              );

              if (s.sourceHost == null) return terminalPane;
              final sftpOpen = _sftpOpen.contains(s);
              return Stack(
                children: [
                  Offstage(offstage: sftpOpen, child: terminalPane),
                  if (_sftpOpened.contains(s)) Offstage(offstage: !sftpOpen, child: SftpBrowserScreen(host: s.sourceHost!, rootfsPath: AppPaths.base, embedded: true, onOpenTerminal: (_) => setState(() => _sftpOpen.remove(s)))),
                ],
              );
            }).toList(),
          ),
        ),
        if (!_sftpOpen.contains(_active)) TerminalKeybar(terminal: _active.terminal, config: _keybarConfig, onFontIncrease: () => _changeFont(1), onFontDecrease: () => _changeFont(-1), onMenu: _showSettings, onCopy: _copySelection, onPaste: _pasteClipboard),
      ],
    );
  }
}
