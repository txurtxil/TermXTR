import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:xterm/xterm.dart';
import 'terminal_keybar.dart';
import 'terminal_session.dart';
import 'keybar_config.dart';
import 'keybar_settings_screen.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  

  final List<TerminalSession> _sessions = [];
  int _activeIndex = 0;
  static const int _maxSessions = 5;

  List<KeyConfigItem> _keybarConfig = KeyCatalog.defaultConfig;

  final List<String> _logLines = [];
  double? _progress = 0.0;
  bool _spinning = false;
  bool _booting = true;
  bool _hasSelection = false;
  String? _error;

  double _fontSize = 14.0;
  static const double _minFont = 8.0;
  static const double _maxFont = 28.0;

  TerminalSession get _active => _sessions[_activeIndex];

  @override
  void initState() {
    super.initState();
    _boot();
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
      // Carga la configuración del teclado guardada
      _keybarConfig = await KeybarConfig.load();

      
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;

      _addSession(initial: true);

      setState(() => _booting = false);

      SchedulerBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.endOfFrame.then((_) {
          if (mounted) _startActiveSession();
        });
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _booting = false;
      });
    }
  }

  void _addSession({bool initial = false}) {
    if (_sessions.length >= _maxSessions) {
      _toast('Máximo $_maxSessions sesiones');
      return;
    }
    final n = _sessions.length + 1;
    final session = TerminalSession('Sesión $n');
    session.controller.addListener(_onSelectionChanged);
    _sessions.add(session);
    if (!initial) {
      setState(() => _activeIndex = _sessions.length - 1);
      SchedulerBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.endOfFrame.then((_) {
          if (mounted) _startActiveSession();
        });
      });
    }
  }

  void _startActiveSession() {
    final s = _active;
    if (s.isStarted) return;
    s.start(columns: s.terminal.viewWidth, rows: s.terminal.viewHeight);
  }

  void _switchTo(int index) {
    if (index == _activeIndex) return;
    setState(() => _activeIndex = index);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.endOfFrame.then((_) {
        if (mounted) _startActiveSession();
      });
    });
  }

  void _closeSession(int index) {
    if (_sessions.length == 1) {
      _toast('No puedes cerrar la última sesión');
      return;
    }
    final s = _sessions[index];
    s.controller.removeListener(_onSelectionChanged);
    s.dispose();
    setState(() {
      _sessions.removeAt(index);
      if (_activeIndex >= _sessions.length) {
        _activeIndex = _sessions.length - 1;
      }
    });
  }

  void _onSelectionChanged() {
    final has = _active.controller.selection != null;
    if (has != _hasSelection && mounted) {
      setState(() => _hasSelection = has);
    }
  }

  void _changeFont(double delta) {
    setState(() {
      _fontSize = (_fontSize + delta).clamp(_minFont, _maxFont);
    });
  }

  void _copySelection() {
    final sel = _active.controller.selection;
    if (sel != null) {
      final text = _active.terminal.buffer.getText(sel);
      if (text.isNotEmpty) {
        Clipboard.setData(ClipboardData(text: text));
        _active.controller.clearSelection();
        _toast('Copiado al portapapeles');
      }
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      _active.terminal.textInput(text);
    }
  }

  void _copyScreen() {
    final buffer = _active.terminal.buffer;
    final sb = StringBuffer();
    for (int i = 0; i < _active.terminal.viewHeight; i++) {
      final line = buffer.lines[buffer.height - _active.terminal.viewHeight + i];
      sb.writeln(line.toString().trimRight());
    }
    Clipboard.setData(ClipboardData(text: sb.toString().trimRight()));
    _toast('Pantalla copiada al portapapeles');
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
      );
    }
  }

  void _openKeybarSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => KeybarSettingsScreen(
          initial: _keybarConfig,
          onChanged: (newConfig) {
            setState(() => _keybarConfig = List.from(newConfig));
          },
        ),
      ),
    );
  }

  void _showMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    const Icon(Icons.tab, color: Colors.lightBlueAccent, size: 18),
                    const SizedBox(width: 8),
                    Text('Sesiones (${_sessions.length}/$_maxSessions)', style: const TextStyle(color: Colors.lightBlueAccent, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              ..._sessions.asMap().entries.map((e) {
                final i = e.key;
                final s = e.value;
                final active = i == _activeIndex;
                return ListTile(
                  dense: true,
                  leading: Icon(active ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: active ? Colors.greenAccent : Colors.white38, size: 20),
                  title: Text(s.name, style: TextStyle(color: active ? Colors.white : Colors.white70)),
                  trailing: _sessions.length > 1
                      ? IconButton(icon: const Icon(Icons.close, color: Colors.redAccent, size: 18), onPressed: () { Navigator.pop(ctx); _closeSession(i); })
                      : null,
                  onTap: () { Navigator.pop(ctx); _switchTo(i); },
                );
              }),
              if (_sessions.length < _maxSessions)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.add, color: Colors.greenAccent, size: 20),
                  title: const Text('Nueva sesión', style: TextStyle(color: Colors.white)),
                  onTap: () { Navigator.pop(ctx); _addSession(); },
                ),
              const Divider(color: Colors.white24),
              ListTile(
                leading: const Icon(Icons.content_paste, color: Colors.greenAccent),
                title: const Text('Pegar', style: TextStyle(color: Colors.white)),
                onTap: () { Navigator.pop(ctx); _paste(); },
              ),
              ListTile(
                leading: const Icon(Icons.copy_all, color: Colors.greenAccent),
                title: const Text('Copiar pantalla', style: TextStyle(color: Colors.white)),
                onTap: () { Navigator.pop(ctx); _copyScreen(); },
              ),
              const Divider(color: Colors.white24),
              ListTile(
                leading: const Icon(Icons.keyboard, color: Colors.greenAccent),
                title: const Text('Configurar teclado', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Mostrar, ocultar y reordenar teclas', style: TextStyle(color: Colors.white54)),
                onTap: () { Navigator.pop(ctx); _openKeybarSettings(); },
              ),
              ListTile(
                leading: const Icon(Icons.format_size, color: Colors.greenAccent),
                title: const Text('Tamaño de fuente', style: TextStyle(color: Colors.white)),
                subtitle: Text('${_fontSize.toInt()} pt', style: const TextStyle(color: Colors.white54)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(icon: const Icon(Icons.remove, color: Colors.white), onPressed: () { _changeFont(-1); Navigator.pop(ctx); _showMenu(); }),
                    IconButton(icon: const Icon(Icons.add, color: Colors.white), onPressed: () { _changeFont(1); Navigator.pop(ctx); _showMenu(); }),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.cleaning_services, color: Colors.greenAccent),
                title: const Text('Limpiar pantalla', style: TextStyle(color: Colors.white)),
                onTap: () { _active.terminal.charInput('l'.codeUnitAt(0), ctrl: true); Navigator.pop(ctx); },
              ),
              ListTile(
                leading: const Icon(Icons.restart_alt, color: Colors.amberAccent),
                title: const Text('Reiniciar sesión actual', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _active.restart(columns: _active.terminal.viewWidth, rows: _active.terminal.viewHeight);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    for (final s in _sessions) {
      s.controller.removeListener(_onSelectionChanged);
      s.dispose();
    }
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
    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Text('ERROR:\n$_error', style: const TextStyle(color: Colors.red, fontFamily: 'monospace')),
            ),
          ),
        ),
      );
    }

    if (_booting) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('TermXTR · arranque', style: TextStyle(color: Colors.white38, fontFamily: 'monospace', fontSize: 12)),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.builder(
                    itemCount: _logLines.length,
                    itemBuilder: (ctx, i) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        _logLines[i],
                        style: TextStyle(color: _lineColor(_logLines[i]), fontFamily: 'monospace', fontSize: 13, height: 1.3),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: _spinning ? null : _progress, backgroundColor: Colors.white10, color: Colors.greenAccent),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  IndexedStack(
                    index: _activeIndex,
                    children: _sessions.map((s) {
                      return TerminalView(
                        s.terminal,
                        controller: s.controller,
                        autofocus: true,
                        backgroundOpacity: 1.0,
                        deleteDetection: true,
                        keyboardType: TextInputType.visiblePassword,
                        textStyle: TerminalStyle(fontSize: _fontSize, fontFamily: 'monospace'),
                      );
                    }).toList(),
                  ),
                  if (_hasSelection)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Material(
                        color: Colors.green.shade700,
                        borderRadius: BorderRadius.circular(8),
                        elevation: 4,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: _copySelection,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.copy, color: Colors.white, size: 18),
                                SizedBox(width: 6),
                                Text('Copiar', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_sessions.length > 1)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                        child: Text('${_active.name} (${_activeIndex + 1}/${_sessions.length})', style: const TextStyle(color: Colors.lightBlueAccent, fontSize: 11, fontFamily: 'monospace')),
                      ),
                    ),
                ],
              ),
            ),
            TerminalKeybar(
              terminal: _active.terminal,
              config: _keybarConfig,
              onFontIncrease: () => _changeFont(1),
              onFontDecrease: () => _changeFont(-1),
              onMenu: _showMenu,
            ),
          ],
        ),
      ),
    );
  }
}
