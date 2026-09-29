// lib/src/terminal/terminal_recorder.dart
//
// Registra TODO lo que pasa por UNA terminal, en disco, sin depender del
// buffer de scrollback del widget (xterm, Terminal(maxLines: 10000)). Ese
// buffer vive en RAM con un límite y se pierde si la sesión se reinicia;
// esto no. Es la fuente de verdad para "cópiame la sesión entera" y para
// "cópiame la última salida", venga o no ya cortado por la UI.
//
// UNA INSTANCIA POR SESIÓN, a propósito: TerminalScreen soporta hasta 5
// pestañas simultáneas (_maxSessions), cada una con su propio Pty. Un único
// recorder global mezclaría la salida de las 5 en el mismo fichero. Cada
// TerminalSession crea el suyo.
//
// Vive en el propio rootfs, en /root/.xtr/sessions/ — una ruta normal del
// árbol de Debian, no un bind mount especial. Se puede grep, tail -f o cat
// desde dentro de la propia terminal: es un fichero de verdad.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class TerminalMatch {
  final int lineIndex;
  final String line;
  final String context;
  TerminalMatch({required this.lineIndex, required this.line, required this.context});
}

class TerminalRecorder {
  static const String _sessionsDirRel = '/sessions';
  static const int _maxTotalBytes = 50 * 1024 * 1024; // 50 MB en disco, entre TODAS las sesiones
  static const int _tailBytes = 200 * 1024; // colchón en RAM si el disco falla

  // Limpieza de ANSI pragmática (colores, cursor, títulos OSC) — el parser
  // VT100 completo ya lo hace xterm.dart para el render; aquí solo hace
  // falta texto legible y buscable.
  static final RegExp _ansi =
      RegExp(r'\x1B(\[[0-9;?]*[a-zA-Z]|\][^\x07]*\x07|[()][A-Z0-9])');

  // El PS1 real de este proyecto (rootfs_config.dart):
  //   export PS1='\u@linux:\w\$ '
  // que tras expandirse (y quitar ANSI) queda "usuario@linux:ruta# " o "...$ ",
  // siempre con espacio final. Con esto se recorta "solo la última salida"
  // sin adivinar genéricamente.
  static final RegExp _promptStart =
      RegExp(r'^[\w.\-]+@[\w.\-]+:\S*[#\$] ', multiLine: true);

  final String label;
  TerminalRecorder({this.label = ''});

  IOSink? _sink;
  File? _currentFile;
  final StringBuffer _tail = StringBuffer();
  Timer? _flushTimer;

  bool get isRecording => _sink != null;

  /// Abre un fichero de sesión nuevo. Llamar una vez al arrancar el shell
  /// de esta sesión (TerminalSession.start()).
  Future<void> startSession(String rootfsPath) async {
    await _closeCurrent();
    _tail.clear();

    try {
      final dir = Directory('$rootfsPath$_sessionsDirRel');
      await dir.create(recursive: true);
      final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
      final safeLabel = label.isEmpty ? '' : '${label.replaceAll(RegExp(r'[^\w-]'), '_')}_';
      _currentFile = File('${dir.path}/session_$safeLabel$stamp.log');
      _sink = _currentFile!.openWrite(mode: FileMode.append);
      _flushTimer = Timer.periodic(const Duration(seconds: 3), (_) => _sink?.flush());
      unawaited(_prune(dir));
    } catch (_) {
      // Si el disco falla, seguimos con el colchón en RAM (_tail) en vez de
      // tirar la terminal abajo por un problema de logging.
      _sink = null;
    }
  }

  /// Llamar con cada trozo de texto que llega del pty, en el mismo sitio
  /// donde ya se escribe en el widget de terminal (terminal.write). No
  /// transforma nada más que quitar ANSI; el resto es cosa del renderer.
  void feed(String rawChunk) {
    if (rawChunk.isEmpty) return;
    final clean = rawChunk.replaceAll(_ansi, '');
    if (clean.isEmpty) return;

    try {
      _sink?.add(utf8.encode(clean));
    } catch (_) {}

    _tail.write(clean);
    if (_tail.length > _tailBytes) {
      final s = _tail.toString();
      _tail
        ..clear()
        ..write(s.substring(s.length - _tailBytes));
    }
  }

  /// La sesión completa, leída del disco. Sin límite de scrollback: si cabe
  /// en el móvil, cabe aquí.
  Future<String> fullSession() async {
    try {
      await _sink?.flush();
      if (_currentFile != null && await _currentFile!.exists()) {
        return await _currentFile!.readAsString();
      }
    } catch (_) {}
    return _tail.toString();
  }

  /// Todo lo que salió después del último prompt con comando, hasta el
  /// siguiente prompt (o hasta el final si el comando sigue corriendo).
  /// "El resultado de lo último que ejecuté" — lo que se pide el 90% de
  /// las veces.
  Future<String> lastOutput() async {
    final full = await fullSession();
    final starts = _promptStart.allMatches(full).toList();
    if (starts.isEmpty) return full.trim();

    final last = starts.last;
    final endOfCommandLine = full.indexOf('\n', last.start);
    if (endOfCommandLine == -1) return ''; // el comando aun no ha devuelto nada

    var result = full.substring(endOfCommandLine + 1);
    final closing = _promptStart.firstMatch(result);
    if (closing != null) {
      result = result.substring(0, closing.start);
    }
    return result.trim();
  }

  /// Busca en la sesión completa. Devuelve cada línea que coincide con su
  /// contexto alrededor, no solo la línea suelta.
  Future<List<TerminalMatch>> search(String query, {int context = 2}) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    final full = await fullSession();
    final lines = full.split('\n');
    final out = <TerminalMatch>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].toLowerCase().contains(q)) {
        final from = (i - context).clamp(0, lines.length);
        final to = (i + context + 1).clamp(0, lines.length);
        out.add(TerminalMatch(
          lineIndex: i,
          line: lines[i],
          context: lines.sublist(from, to).join('\n'),
        ));
      }
    }
    return out;
  }

  /// Posición actual (en bytes) del fichero de sesión. Es el "marca aquí":
  /// un offset es inequívoco, a diferencia de anclar por un fragmento de
  /// texto que podría repetirse en la sesión.
  Future<int> currentOffset() async {
    try {
      await _sink?.flush();
      if (_currentFile != null && await _currentFile!.exists()) {
        return await _currentFile!.length();
      }
    } catch (_) {}
    return 0;
  }

  /// Todo lo que se ha escrito desde el offset devuelto por [currentOffset].
  /// Se trabaja en bytes (no en índices de String) para no desalinearse con
  /// caracteres UTF-8 multibyte cerca del punto de corte.
  Future<String> sinceOffset(int offset) async {
    try {
      await _sink?.flush();
      if (_currentFile != null && await _currentFile!.exists()) {
        final bytes = await _currentFile!.readAsBytes();
        final safe = offset.clamp(0, bytes.length);
        return utf8.decode(bytes.sublist(safe), allowMalformed: true).trim();
      }
    } catch (_) {}
    return _tail.toString();
  }

  Future<void> _closeCurrent() async {
    _flushTimer?.cancel();
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
  }

  /// Llamar desde TerminalSession.dispose() al cerrar la pestaña.
  Future<void> dispose() => _closeCurrent();

  Future<void> _prune(Directory dir) async {
    try {
      final files = await dir.list().where((e) => e is File).cast<File>().toList();
      files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      var total = 0;
      for (final f in files) {
        total += await f.length();
      }
      var i = 0;
      while (total > _maxTotalBytes && i < files.length - 1) {
        // -1: nunca se borra el fichero de la sesion actual, que es el ultimo
        total -= await files[i].length();
        await files[i].delete();
        i++;
      }
    } catch (_) {}
  }
}
