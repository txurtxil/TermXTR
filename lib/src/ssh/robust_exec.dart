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
