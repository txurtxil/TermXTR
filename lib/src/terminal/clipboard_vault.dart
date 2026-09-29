// lib/src/terminal/clipboard_vault.dart
//
// El portapapeles del sistema en Android va por Binder (IPC entre procesos):
// tiene un techo práctico de ~1 MB por transacción y algunas capas de
// fabricante (el panel de portapapeles de Samsung, por ejemplo) añaden más
// límites encima. Pegar un log de Gradle de 3 MB con Clipboard.setData no es
// "lento", es candidato a TransactionTooLargeException según el dispositivo.
//
// Por eso esto no es "un wrapper de Clipboard.setData": toda copia entra
// SIEMPRE en el historial de aquí (sin límite real, vive en RAM + disco),
// y solo si es razonablemente pequeña se empuja también al portapapeles
// del sistema para que un "pegar" normal en cualquier otra app funcione.
// Para lo grande, la salida es exportar/compartir el fichero, no forzar
// el pegado.
//
// El historial de copias SÍ es global (un ChangeNotifier singleton): tiene
// sentido tener un único "lo que he copiado" cruzando pestañas. Lo que NO
// es global es de qué sesión sale cada copia — cada método que toca la
// grabación de una terminal recibe el TerminalRecorder de la pestaña activa
// como parámetro; nunca asume cuál es.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'terminal_recorder.dart';

class ClipboardEntry {
  final String id;
  final DateTime at;
  final String label;
  final String text;
  bool pinned;
  bool inSystemClipboard;

  ClipboardEntry({
    required this.id,
    required this.at,
    required this.label,
    required this.text,
    this.pinned = false,
    this.inSystemClipboard = false,
  });

  int get bytes => utf8.encode(text).length;

  String get preview {
    final oneLine = text.replaceAll('\n', '  ').trim();
    return oneLine.length > 100 ? '${oneLine.substring(0, 100)}…' : oneLine;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'at': at.toIso8601String(),
        'label': label,
        'pinned': pinned,
        'bytes': bytes,
        // Solo se persiste el texto completo si es razonablemente pequeño.
        // Las capturas grandes ya viven íntegras en el log de sesión de
        // TerminalRecorder; no tiene sentido duplicarlas en el jsonl.
        if (bytes <= 64 * 1024) 'text': text,
      };

  static ClipboardEntry? fromJson(Map<String, dynamic> j) {
    final text = j['text'] as String?;
    if (text == null) return null; // entrada grande no persistida: se omite
    return ClipboardEntry(
      id: j['id'] as String,
      at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now(),
      label: j['label'] as String? ?? 'Copia',
      text: text,
      pinned: j['pinned'] as bool? ?? false,
    );
  }
}

class ClipboardVault extends ChangeNotifier {
  static final ClipboardVault instance = ClipboardVault._();
  ClipboardVault._();

  // Margen deliberadamente bajo respecto al límite real de Binder (~1 MB):
  // hay overhead del propio JSON de la transacción y de capas de fabricante
  // que no se controlan desde aquí.
  static const int systemClipboardSafeBytes = 200 * 1024;
  static const int _maxHistory = 60;
  static const String _historyFileRel = '/clipboard_history.jsonl';

  final List<ClipboardEntry> _history = [];
  List<ClipboardEntry> get history => List.unmodifiable(_history);

  String? _rootfsPath;
  int _seq = 0;

  // Marcador: offset + el recorder exacto contra el que se marcó, para no
  // aplicar "desde marcador" sobre la sesión equivocada si se cambia de
  // pestaña entre medias.
  int? _bookmarkOffset;
  TerminalRecorder? _bookmarkRecorder;

  String _newId() => '${DateTime.now().microsecondsSinceEpoch}_${_seq++}';

  // ── Carga / persistencia ────────────────────────────────────────────────

  Future<void> loadFrom(String rootfsPath) async {
    _rootfsPath = rootfsPath;
    try {
      final f = File('$rootfsPath$_historyFileRel');
      if (!await f.exists()) return;
      final lines = await f.readAsLines();
      _history.clear();
      for (final line in lines.reversed) {
        if (line.trim().isEmpty) continue;
        try {
          final e = ClipboardEntry.fromJson(jsonDecode(line) as Map<String, dynamic>);
          if (e != null) _history.add(e);
        } catch (_) {}
        if (_history.length >= _maxHistory) break;
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _persist(ClipboardEntry e) async {
    if (_rootfsPath == null) return;
    try {
      final f = File('$_rootfsPath$_historyFileRel');
      await f.parent.create(recursive: true);
      await f.writeAsString('${jsonEncode(e.toJson())}\n', mode: FileMode.append);
    } catch (_) {}
  }

  // ── El método central ───────────────────────────────────────────────────

  Future<ClipboardEntry> copy(String text, {String label = 'Copia'}) async {
    final entry = ClipboardEntry(id: _newId(), at: DateTime.now(), label: label, text: text);

    if (entry.bytes <= systemClipboardSafeBytes) {
      try {
        await Clipboard.setData(ClipboardData(text: text));
        entry.inSystemClipboard = true;
      } catch (_) {
        // Se queda igualmente en el historial aunque el sistema lo rechace.
      }
    }

    _push(entry);
    return entry;
  }

  /// Fuerza el intento contra el portapapeles del sistema para una entrada
  /// que no entró automáticamente por ser grande. Puede fallar (es justo lo
  /// que se está evitando por defecto) — se informa, no se oculta.
  Future<bool> forceSystemClipboard(ClipboardEntry e) async {
    try {
      await Clipboard.setData(ClipboardData(text: e.text));
      e.inSystemClipboard = true;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── Acciones sobre la grabación de UNA sesión (recorder explícito) ──────

  Future<ClipboardEntry> copyFullSession(TerminalRecorder recorder) async =>
      copy(await recorder.fullSession(), label: 'Sesión completa');

  Future<ClipboardEntry> copyLastOutput(TerminalRecorder recorder) async =>
      copy(await recorder.lastOutput(), label: 'Última salida');

  /// [visibleText] lo aporta quien llama (el viewport actual del widget de
  /// terminal), porque el vault no conoce la librería de render usada.
  Future<ClipboardEntry> copyVisible(String visibleText) async =>
      copy(visibleText, label: 'Visible');

  /// Heurística de bloque de error: busca el primer marcador típico dentro
  /// de la última salida y recorta desde algo antes de él. No es magia, es
  /// la misma pregunta que os habéis hecho toda la noche con los logs de
  /// Gradle: "¿dónde empieza lo que de verdad importa de este log kilométrico?".
  Future<ClipboardEntry?> copyErrorBlock(TerminalRecorder recorder) async {
    final text = await recorder.lastOutput();
    final markers = RegExp(
      r'(BUILD FAILED|FAILED|Exception|Error:|error:|fatal:|Duplicate class)',
      caseSensitive: false,
    );
    final m = markers.firstMatch(text);
    if (m == null) return null;
    final from = (m.start - 300).clamp(0, text.length);
    return copy(text.substring(from).trim(), label: 'Bloque de error');
  }

  /// Marca la posición actual de [recorder]. "Copiar desde marcador" luego
  /// devuelve exactamente lo que ha pasado desde este instante EN ESA MISMA
  /// sesión — sin tener que acordarte de líneas, horas ni fragmentos de texto,
  /// y sin mezclar con otra pestaña si cambias de foco mientras tanto.
  Future<void> markHere(TerminalRecorder recorder) async {
    _bookmarkOffset = await recorder.currentOffset();
    _bookmarkRecorder = recorder;
  }

  bool hasBookmark(TerminalRecorder recorder) =>
      _bookmarkOffset != null && identical(_bookmarkRecorder, recorder);

  Future<ClipboardEntry> copySinceBookmark(TerminalRecorder recorder) async {
    if (!hasBookmark(recorder)) return copyLastOutput(recorder);
    final text = await recorder.sinceOffset(_bookmarkOffset!);
    return copy(text, label: 'Desde marcador');
  }

  // ── Historial de copias (no de la sesión: de lo que TÚ has copiado) ─────

  List<ClipboardEntry> search(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return history;
    return _history
        .where((e) => e.text.toLowerCase().contains(q) || e.label.toLowerCase().contains(q))
        .toList();
  }

  void pin(String id) {
    final e = _history.where((x) => x.id == id).firstOrNull;
    if (e == null) return;
    e.pinned = !e.pinned;
    notifyListeners();
  }

  void remove(String id) {
    _history.removeWhere((x) => x.id == id);
    notifyListeners();
  }

  void clearUnpinned() {
    _history.removeWhere((x) => !x.pinned);
    notifyListeners();
  }

  void _push(ClipboardEntry e) {
    _history.insert(0, e);
    while (_history.length > _maxHistory) {
      final idx = _history.lastIndexWhere((x) => !x.pinned);
      if (idx == -1) break;
      _history.removeAt(idx);
    }
    notifyListeners();
    unawaited(_persist(e));
  }

  // ── Exportar ─────────────────────────────────────────────────────────────
  //
  // Confirmado en el manifest real: MANAGE_EXTERNAL_STORAGE concedido, así
  // que escribir directamente en el almacenamiento del teléfono desde este
  // proceso (Dart, fuera de proot) no necesita ceremonia de MediaStore. Si
  // algún día se retira ese permiso amplio, esto es lo primero a migrar a
  // un MethodChannel + MediaStore.

  static const String _exportDirAbs = '/storage/emulated/0/Download/xtr_clip';

  Future<String> exportToFile(ClipboardEntry e) async {
    final dir = Directory(_exportDirAbs);
    await dir.create(recursive: true);
    final stamp = e.at.toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final safeLabel = e.label.replaceAll(RegExp(r'[^\w\-]'), '_').toLowerCase();
    final file = File('${dir.path}/${safeLabel}_$stamp.txt');
    await file.writeAsString(e.text);
    return file.path;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
