import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xterm/xterm.dart';

/// Tipo de acción de una tecla de la barra.
enum KeyAction { sendKey, sendChar, ctrlChar, toggleCtrl, fontInc, fontDec, copy, paste }

/// Definición de una tecla del catálogo (qué es y qué hace).
class KeyDef {
  final String id;
  final String label;
  final KeyAction action;
  final TerminalKey? key;     // para sendKey
  final String? text;         // para sendChar / ctrlChar
  final bool accent;          // estilo azul (controles)
  final IconData? icon;       // si se da, se pinta icono en vez de texto
  const KeyDef(this.id, this.label, this.action, {this.key, this.text, this.accent = false, this.icon});
}

/// Catálogo completo de teclas disponibles (incluye F1-F12 y extras nuevos).
class KeyCatalog {
  static const List<KeyDef> all = [
    KeyDef('esc', 'Esc', KeyAction.sendKey, key: TerminalKey.escape),
    KeyDef('tab', 'Tab', KeyAction.sendKey, key: TerminalKey.tab),
    KeyDef('ctrl', 'Ctrl', KeyAction.toggleCtrl),
    KeyDef('ctrlC', '^C', KeyAction.ctrlChar, text: 'c', accent: true),
    KeyDef('ctrlX', '^X', KeyAction.ctrlChar, text: 'x', accent: true),
    KeyDef('ctrlZ', '^Z', KeyAction.ctrlChar, text: 'z', accent: true),
    KeyDef('ctrlR', '^R', KeyAction.ctrlChar, text: 'r', accent: true),
    KeyDef('ctrlD', '^D', KeyAction.ctrlChar, text: 'd', accent: true),
    KeyDef('ctrlL', '^L', KeyAction.ctrlChar, text: 'l', accent: true),
    KeyDef('ctrlA', '^A', KeyAction.ctrlChar, text: 'a', accent: true),
    KeyDef('ctrlE', '^E', KeyAction.ctrlChar, text: 'e', accent: true),
    KeyDef('ctrlK', '^K', KeyAction.ctrlChar, text: 'k', accent: true),
    KeyDef('ctrlW', '^W', KeyAction.ctrlChar, text: 'w', accent: true),
    KeyDef('ctrlU', '^U', KeyAction.ctrlChar, text: 'u', accent: true),
    KeyDef('up', '↑', KeyAction.sendKey, key: TerminalKey.arrowUp),
    KeyDef('down', '↓', KeyAction.sendKey, key: TerminalKey.arrowDown),
    KeyDef('left', '←', KeyAction.sendKey, key: TerminalKey.arrowLeft),
    KeyDef('right', '→', KeyAction.sendKey, key: TerminalKey.arrowRight),
    KeyDef('home', 'Home', KeyAction.sendKey, key: TerminalKey.home),
    KeyDef('end', 'End', KeyAction.sendKey, key: TerminalKey.end),
    KeyDef('pgup', 'PgUp', KeyAction.sendKey, key: TerminalKey.pageUp),
    KeyDef('pgdn', 'PgDn', KeyAction.sendKey, key: TerminalKey.pageDown),
    KeyDef('del', 'Del', KeyAction.sendKey, key: TerminalKey.delete),
    KeyDef('ins', 'Ins', KeyAction.sendKey, key: TerminalKey.insert),
    KeyDef('pipe', '|', KeyAction.sendChar, text: '|'),
    KeyDef('copy', 'Copiar', KeyAction.copy, icon: Icons.copy_outlined, accent: true),
    KeyDef('paste', 'Pegar', KeyAction.paste, icon: Icons.paste_outlined, accent: true),
    KeyDef('slash', '/', KeyAction.sendChar, text: '/'),
    KeyDef('dash', '-', KeyAction.sendChar, text: '-'),
    KeyDef('tilde', '~', KeyAction.sendChar, text: '~'),
    KeyDef('backslash', '\\', KeyAction.sendChar, text: '\\'),
    KeyDef('star', '*', KeyAction.sendChar, text: '*'),
    KeyDef('amp', '&', KeyAction.sendChar, text: '&'),
    KeyDef('dollar', '\$', KeyAction.sendChar, text: '\$'),
    KeyDef('hash', '#', KeyAction.sendChar, text: '#'),
    KeyDef('grave', '`', KeyAction.sendChar, text: '`'),
    KeyDef('f1', 'F1', KeyAction.sendKey, key: TerminalKey.f1),
    KeyDef('f2', 'F2', KeyAction.sendKey, key: TerminalKey.f2),
    KeyDef('f3', 'F3', KeyAction.sendKey, key: TerminalKey.f3),
    KeyDef('f4', 'F4', KeyAction.sendKey, key: TerminalKey.f4),
    KeyDef('f5', 'F5', KeyAction.sendKey, key: TerminalKey.f5),
    KeyDef('f6', 'F6', KeyAction.sendKey, key: TerminalKey.f6),
    KeyDef('f7', 'F7', KeyAction.sendKey, key: TerminalKey.f7),
    KeyDef('f8', 'F8', KeyAction.sendKey, key: TerminalKey.f8),
    KeyDef('f9', 'F9', KeyAction.sendKey, key: TerminalKey.f9),
    KeyDef('f10', 'F10', KeyAction.sendKey, key: TerminalKey.f10),
    KeyDef('f11', 'F11', KeyAction.sendKey, key: TerminalKey.f11),
    KeyDef('f12', 'F12', KeyAction.sendKey, key: TerminalKey.f12),
    KeyDef('fontDec', 'A−', KeyAction.fontDec),
    KeyDef('fontInc', 'A+', KeyAction.fontInc),
  ];

  static KeyDef? byId(String id) {
    for (final k in all) {
      if (k.id == id) return k;
    }
    return null;
  }

  /// Configuración por defecto: orden e ítems visibles inicialmente.
  static List<KeyConfigItem> get defaultConfig => const [
        KeyConfigItem('esc', true),
        KeyConfigItem('ctrl', true),
        KeyConfigItem('tab', true),
        KeyConfigItem('ctrlC', true),
        KeyConfigItem('ctrlX', true),
        KeyConfigItem('ctrlZ', true),
        KeyConfigItem('ctrlR', true),
        KeyConfigItem('ctrlL', true),
        KeyConfigItem('up', true),
        KeyConfigItem('down', true),
        KeyConfigItem('left', true),
        KeyConfigItem('right', true),
        KeyConfigItem('home', true),
        KeyConfigItem('end', true),
        KeyConfigItem('pgup', true),
        KeyConfigItem('pgdn', true),
        KeyConfigItem('pipe', true),
        KeyConfigItem('copy', true),
        KeyConfigItem('paste', true),
        KeyConfigItem('slash', true),
        KeyConfigItem('dash', true),
        KeyConfigItem('tilde', true),
        KeyConfigItem('fontDec', true),
        KeyConfigItem('fontInc', true),
        // El resto del catálogo, oculto por defecto:
        KeyConfigItem('ctrlD', false),
        KeyConfigItem('ctrlA', false),
        KeyConfigItem('ctrlE', false),
        KeyConfigItem('ctrlK', false),
        KeyConfigItem('ctrlW', false),
        KeyConfigItem('ctrlU', false),
        KeyConfigItem('del', false),
        KeyConfigItem('ins', false),
        KeyConfigItem('backslash', false),
        KeyConfigItem('star', false),
        KeyConfigItem('amp', false),
        KeyConfigItem('dollar', false),
        KeyConfigItem('hash', false),
        KeyConfigItem('grave', false),
        KeyConfigItem('f1', false),
        KeyConfigItem('f2', false),
        KeyConfigItem('f3', false),
        KeyConfigItem('f4', false),
        KeyConfigItem('f5', false),
        KeyConfigItem('f6', false),
        KeyConfigItem('f7', false),
        KeyConfigItem('f8', false),
        KeyConfigItem('f9', false),
        KeyConfigItem('f10', false),
        KeyConfigItem('f11', false),
        KeyConfigItem('f12', false),
      ];
}

/// Un ítem de la configuración: una tecla (por id) y si está visible.
class KeyConfigItem {
  final String id;
  final bool visible;
  const KeyConfigItem(this.id, this.visible);

  Map<String, dynamic> toJson() => {'id': id, 'visible': visible};
  factory KeyConfigItem.fromJson(Map<String, dynamic> j) => KeyConfigItem(j['id'] as String, j['visible'] as bool);
}

/// Carga y guarda la configuración del teclado en un fichero JSON propio.
class KeybarConfig {
  static const _fileName = 'keybar_layout.json';

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Carga la configuración guardada, o la por defecto si no existe.
  /// Reconcilia con el catálogo: añade teclas nuevas que no estuvieran guardadas.
  static Future<List<KeyConfigItem>> load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final raw = jsonDecode(await f.readAsString()) as List;
        final saved = raw.map((e) => KeyConfigItem.fromJson(e as Map<String, dynamic>)).toList();
        // Reconciliar: mantener guardados válidos + añadir ids nuevos del catálogo
        final savedIds = saved.map((e) => e.id).toSet();
        final validSaved = saved.where((e) => KeyCatalog.byId(e.id) != null).toList();
        // Visibilidad por defecto de cada id (para las teclas nuevas que
        // aparezcan en futuras versiones del catálogo).
        final defaultVis = {for (final it in KeyCatalog.defaultConfig) it.id: it.visible};
        for (final k in KeyCatalog.all) {
          if (!savedIds.contains(k.id)) {
            // tecla nueva en el catálogo: se añade con la visibilidad que
            // marque la config por defecto (no siempre oculta).
            validSaved.add(KeyConfigItem(k.id, defaultVis[k.id] ?? false));
          }
        }
        return validSaved;
      }
    } catch (_) {}
    return KeyCatalog.defaultConfig;
  }

  static Future<void> save(List<KeyConfigItem> config) async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(config.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  static Future<void> reset() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
