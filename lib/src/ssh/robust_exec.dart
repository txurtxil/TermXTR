// lib/src/ssh/robust_exec.dart
//
// exec robusto sobre dartssh2: NO usa client.run() (que espera al cierre
// del canal: si el servidor deja el canal abierto, cuelga forever).
// Abre un canal execute(), acumula stdout+stderr y completa al:
//   1) aparecer [sentinel] en la salida (cierre explicito incluido), o
//   2) cerrarse el canal (onDone/onError), o
//   3) timeout total, o
//   4) silencio tras recibir datos (idleTimeout; para CLIs interactivos
//      que imprimen y se quedan en prompt sin cerrar).
// El canal se cierra SIEMPRE desde el cliente al completar.

import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

class RobustResult {
  final String output;
  final bool closedByServer;
  final bool timedOut;
  RobustResult(this.output, this.closedByServer, this.timedOut);
}

Future<RobustResult> robustExec(
  SSHClient client,
  String command, {
  String? sentinel,
  Duration timeout = const Duration(seconds: 30),
  Duration idleTimeout = const Duration(seconds: 4),
}) async {
  final session = await client.execute(command);
  final buf = StringBuffer();
  var gotData = false;
  String? streamError;
  final completer = Completer<void>();
  Timer? totalTimer;
  Timer? idleTimer;

  void finish() {
    totalTimer?.cancel();
    idleTimer?.cancel();
    if (!completer.isCompleted) completer.complete();
  }

  void kickIdle() {
    idleTimer?.cancel();
    if (gotData) {
      idleTimer = Timer(idleTimeout, finish);
    }
  }

  void onData(List<int> d) {
    gotData = true;
    buf.write(utf8.decode(d, allowMalformed: true));
    if (sentinel != null && buf.toString().contains(sentinel)) {
      finish();
      return;
    }
    kickIdle();
  }

  StreamSubscription? subOut;
  StreamSubscription? subErr;
  subOut = session.stdout.listen(
    onData,
    onError: (e) { streamError ??= e.toString(); finish(); },
    onDone: finish,
  );
  subErr = session.stderr.listen(
    onData,
    onError: (e) { streamError ??= e.toString(); finish(); },
    onDone: () {},
  );
  totalTimer = Timer(timeout, finish);

  var closedByServer = false;
  await completer.future.then((_) => closedByServer = true);
  // Cierre proactivo: no esperamos a que el servidor corte el canal.
  try { session.close(); } catch (_) {}
  await subOut.cancel();
  await subErr.cancel();

  var out = buf.toString();
  if (streamError != null) out += '\n[stderr] $streamError';
  final timedOut = !closedByServer;
  return RobustResult(out.trim(), closedByServer, timedOut);
}

/// Limpia salida cruda de CLIs que "pintan la pantalla": secuencias ANSI,
/// reescritura de lineas con \r y espacios de relleno. Sin esto la salida
/// de algunos CLIs de router se ve como un bloque gris ilegible.
String sanitizeCliOutput(String raw, {int maxLines = 500}) {
  var s = raw.replaceAll(RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]'), '');
  s = s.replaceAll('\x1B(B', '').replaceAll('\x1B)0', '').replaceAll('\x0F', '');
  final lines = s
      .split('\n')
      .map((l) {
        final i = l.lastIndexOf('\r');
        return (i >= 0 ? l.substring(i + 1) : l).trimRight();
      })
      .where((l) => l.trim().isNotEmpty)
      .toList();
  if (lines.length > maxLines) {
    return '${lines.take(maxLines).join('\n')}\n… (${lines.length - maxLines} líneas más)';
  }
  return lines.join('\n');
}
