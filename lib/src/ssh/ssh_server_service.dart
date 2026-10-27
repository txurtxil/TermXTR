// lib/src/ssh/ssh_server_service.dart
//
// v2.16.0: SERVIDOR SSH EN LA APP (opcion B, hito 1).
// TermXTR embebe dropbear (compilado estatico para Android: arm64/armv7/
// x86_64, API 28) y lo lanza como subproceso para exponer un sshd en el
// telefono: puerto configurable (2222 por defecto), SOLO auth por clave
// (la identidad Ed25519 de la app escrita en authorized_keys), sin
// password (-s), sin forwarding de ningun tipo.
//
// Parche TermXTR sobre dropbear 2024.86 (ver dropbear_android_passwd.patch):
// getpwnam() sintetico — en Android no-root el /system/etc/passwd solo
// resuelve root/shell y el setuid posterior moriria. Con el parche, CUALQUIER
// usuario cuya clave este en authorized_keys aterriza como el uid de la app,
// con HOME controlado y shell /system/bin/sh.
//
// Limitacion v2.16.0: el servidor vive mientras la app vive. El servicio en
// primer plano (notificacion persistente) es hito posterior.

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import '../storage/app_paths.dart';
import 'identity_service.dart';

class SshServerService {
  SshServerService._();
  static final SshServerService instance = SshServerService._();

  Process? _process;
  int _port = 2222;
  final StringBuffer _log = StringBuffer();
  final List<String> _logLines = [];

  bool get isRunning => _process != null;
  int get port => _port;

  String get log {
    final s = _logLines.join('\n');
    return s.length > 4000 ? s.substring(s.length - 4000) : s;
  }

  void _appendLog(String line) {
    _logLines.addAll(line.split('\n').where((l) => l.trim().isNotEmpty));
    while (_logLines.length > 120) {
      _logLines.removeAt(0);
    }
  }

  static String abiName() {
    switch (Abi.current()) {
      case Abi.androidArm64:
        return 'arm64';
      case Abi.androidArm:
        return 'armv7';
      case Abi.androidX64:
        return 'x86_64';
      default:
        throw StateError('ABI sin binario dropbear: ${Abi.current()}');
    }
  }

  Future<Directory> _serverDir() async {
    final dir = Directory('${AppPaths.base}/sshserver');
    if (!await dir.exists()) await dir.create(recursive: true);
    final sshDir = Directory('${dir.path}/.ssh');
    if (!await sshDir.exists()) await sshDir.create();
    return dir;
  }

  // Extrae el binario del asset al filesDir la primera vez (y si cambia
  // de version). assets/ssh/dropbear-<abi>.
  Future<String> _ensureBinary(Directory dir) async {
    final name = 'dropbear-${abiName()}';
    final dest = File('${dir.path}/$name');
    final data = await rootBundle.load('assets/ssh/$name');
    final bytes = data.buffer.asUint8List();
    final needWrite = !await dest.exists() ||
        (await dest.length()) != bytes.length;
    if (needWrite) {
      await dest.writeAsBytes(bytes, flush: true);
    }
    // Ejecutable para el propietario (app).
    await Process.run('chmod', ['700', dest.path]);
    final chk = await Process.run(dest.path, ['-V']);
    if (chk.exitCode != 0 || !(chk.stdout as String).contains('dropbear')) {
      throw StateError('El binario dropbear no arranca en este dispositivo '
          '(ABI ${abiName()}). Detalle: ${chk.stderr}');
    }
    return dest.path;
  }

  // Host key Ed25519 persistente generada con dropbearkey la primera vez.
  Future<String> _ensureHostKey(Directory dir) async {
    final keyFile = File('${dir.path}/ssh_host_ed25519_key');
    if (await keyFile.exists()) return keyFile.path;
    final keyBin = File('${dir.path}/dropbearkey');
    if (!await keyBin.exists()) {
      final data = await rootBundle.load('assets/ssh/dropbearkey-${abiName()}');
      await keyBin.writeAsBytes(data.buffer.asUint8List(), flush: true);
      await Process.run('chmod', ['700', keyBin.path]);
    }
    final gen = await Process.run(
        keyBin.path, ['-t', 'ed25519', '-f', keyFile.path]);
    if (gen.exitCode != 0) {
      throw StateError('dropbearkey fallo: ${gen.stderr}');
    }
    await Process.run('chmod', ['600', keyFile.path]);
    return keyFile.path;
  }

  // authorized_keys = identidad publica de la app. Sin clave valida no hay
  // login posible (password auth va desactivado con -s).
  Future<void> _ensureAuthorizedKeys(Directory dir) async {
    final pub = await IdentityService.ensureIdentity();
    await File('${dir.path}/.ssh/authorized_keys')
        .writeAsString('$pub\n', flush: true);
    await Process.run('chmod', ['600', '${dir.path}/.ssh/authorized_keys']);
  }

  Future<void> start({int port = 2222}) async {
    if (_process != null) return;
    _port = port;
    final dir = await _serverDir();
    final bin = await _ensureBinary(dir);
    final hostKey = await _ensureHostKey(dir);
    await _ensureAuthorizedKeys(dir);
    _appendLog('arrancando dropbear en 0.0.0.0:$port...');
    // -F foreground, -E log a stderr, -s sin password, -r host key,
    // -P pidfile. HOME propio: el parche getpwnam lo usa como pw_dir.
    final proc = await Process.start(
      bin,
      ['-F', '-E', '-s', '-r', hostKey, '-p', '$port', '-P', '${dir.path}/dropbear.pid'],
      environment: {
        'HOME': dir.path,
        'PATH': '/system/bin:/system/xbin',
        'TERM': 'xterm-256color',
      },
      workingDirectory: dir.path,
    );
    _process = proc;
    proc.stderr.transform(const SystemEncoding().decoder).listen((chunk) {
      _appendLog(chunk.trimRight());
    });
    proc.exitCode.then((code) {
      _appendLog('dropbear termino con codigo $code');
      if (_process == proc) _process = null;
    });
    // Un instante para que falle rapido si algo va mal (puerto ocupado...).
    await Future.delayed(const Duration(milliseconds: 700));
    if (_process == null) {
      throw StateError('dropbear murio al arrancar: $_port ocupado?');
    }
  }

  Future<void> stop() async {
    final proc = _process;
    if (proc == null) return;
    _process = null;
    proc.kill(ProcessSignal.sigterm);
    await proc.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      return -9;
    });
    _appendLog('dropbear detenido');
  }
}
