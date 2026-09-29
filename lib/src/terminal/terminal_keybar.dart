import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';
import 'keybar_config.dart';

/// Barra de teclas configurable. El botón ⋮ (menú) es fijo a la izquierda.
/// El resto de teclas se renderizan según [config] (solo visibles, en orden).
/// Ctrl es sticky: se combina con la siguiente tecla pulsada.
class TerminalKeybar extends StatefulWidget {
  final Terminal terminal;
  final List<KeyConfigItem> config;
  final VoidCallback? onFontIncrease;
  final VoidCallback? onFontDecrease;
  final VoidCallback? onMenu;
  final VoidCallback? onCopy;
  final Future<void> Function()? onPaste;

  const TerminalKeybar({
    super.key,
    required this.terminal,
    required this.config,
    this.onFontIncrease,
    this.onFontDecrease,
    this.onMenu,
    this.onCopy,
    this.onPaste,
  });

  @override
  State<TerminalKeybar> createState() => _TerminalKeybarState();
}

class _TerminalKeybarState extends State<TerminalKeybar> {
  bool _ctrl = false;

  void _clearCtrl() {
    if (_ctrl) setState(() => _ctrl = false);
  }

  void _handle(KeyDef def) {
    switch (def.action) {
      case KeyAction.toggleCtrl:
        setState(() => _ctrl = !_ctrl);
        break;
      case KeyAction.ctrlChar:
        widget.terminal.charInput(def.text!.codeUnitAt(0), ctrl: true);
        _clearCtrl();
        break;
      case KeyAction.sendKey:
        widget.terminal.keyInput(def.key!, ctrl: _ctrl);
        _clearCtrl();
        break;
      case KeyAction.sendChar:
        if (_ctrl) {
          widget.terminal.charInput(def.text!.codeUnitAt(0), ctrl: true);
          _clearCtrl();
        } else {
          widget.terminal.textInput(def.text!);
        }
        break;
      case KeyAction.fontInc:
        widget.onFontIncrease?.call();
        break;
      case KeyAction.fontDec:
        widget.onFontDecrease?.call();
        break;
      case KeyAction.copy:
        widget.onCopy?.call();
        break;
      case KeyAction.paste:
        widget.onPaste?.call();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Construye la lista de teclas visibles según la configuración
    final keys = <Widget>[];
    for (final item in widget.config) {
      if (!item.visible) continue;
      final def = KeyCatalog.byId(item.id);
      if (def == null) continue;
      final isCtrlToggle = def.action == KeyAction.toggleCtrl;
      final isFont = def.action == KeyAction.fontInc || def.action == KeyAction.fontDec;
      keys.add(_key(
        def.label,
        onTap: () => _handle(def),
        accent: def.accent,
        highlight: isFont,
        active: isCtrlToggle && _ctrl,
        icon: def.icon,
      ));
    }

    return Container(
      height: 44,
      color: const Color(0xFF1A1A1A),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        children: [
          // ⋮ menú SIEMPRE fijo a la izquierda (no configurable)
          _key('⋮', onTap: () => widget.onMenu?.call(), highlight: true),
          _sep(),
          ...keys,
        ],
      ),
    );
  }

  Widget _sep() => Container(
        width: 1,
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        color: Colors.white24,
      );

  Widget _key(String label, {required VoidCallback onTap, bool accent = false, bool highlight = false, bool active = false, IconData? icon}) {
    final Color bg = active
        ? Colors.green.shade700
        : highlight
            ? const Color(0xFF1E4620)
            : accent
                ? const Color(0xFF2A3F5F)
                : const Color(0xFF333333);
    final Color fg = active
        ? Colors.white
        : highlight
            ? Colors.lightGreenAccent
            : accent
                ? Colors.lightBlueAccent
                : Colors.greenAccent;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 42),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            child: icon != null
                ? Icon(icon, size: 17, color: fg)
                : Text(label, style: TextStyle(color: fg, fontFamily: 'monospace', fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    );
  }
}
