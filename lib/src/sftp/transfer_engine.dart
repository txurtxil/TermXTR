// lib/src/sftp/transfer_engine.dart
//
// v2.6.0: transferencias de ficheros ENTRE equipos (store-and-forward por
// la app, en streaming por chunks) con cola, cancelacion y telemetria real:
// velocidad actual (ventana de ~3 s), velocidad media, %, ETA y transcurrido.

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../ssh/identity_service.dart';
import '../ssh/ssh_credentials_store.dart';
import '../ssh/ssh_host.dart';
import '../ssh/ssh_hosts_service.dart';
import '../storage/app_paths.dart';

enum TransferStatus { queued, running, done, error, cancelled }

class TransferSample {
  final int t; // epoch millis
  final int bytes; // acumulados
  TransferSample(this.t, this.bytes);
}

class TransferJob {
  final String id;
  final String fileName;
  final String sourceHostId;
  final String sourceHostName;
  final String sourcePath;
  final String targetHostId;
  final String targetHostName;
  final String targetDir;
  final int size; // si es 0, el motor lo averigua con stat()
  TransferJob({
    required this.id,
    required this.fileName,
    required this.sourceHostId,
    required this.sourceHostName,
    required this.sourcePath,
    required this.targetHostId,
    required this.targetHostName,
    required this.targetDir,
    required this.size,
  });

  int bytes = 0;
  TransferStatus status = TransferStatus.queued;
  String? error;
  final DateTime startedAt = DateTime.now();
  final samples = <TransferSample>[];
  bool _cancel = false;
  int _lastNotify = 0;

  void cancel() => _cancel = true;

  double get progress => size > 0 ? bytes / size : 0;

  /// bytes/s de la ventana reciente (ultimas muestras, ~3 s)
  double get currentSpeed {
    if (samples.length < 2) return 0;
    final last = samples.last;
    final first = samples.first;
    final dt = (last.t - first.t) / 1000.0;
    if (dt <= 0) return 0;
    return (last.bytes - first.bytes) / dt;
  }

  double get avgSpeed {
    final dt = DateTime.now().difference(startedAt).inMilliseconds / 1000.0;
    if (dt <= 0) return 0;
    return bytes / dt;
  }

  Duration? get eta {
    final s = avgSpeed;
    if (s <= 0 || size <= 0 || bytes >= size) return null;
    return Duration(seconds: ((size - bytes) / s).ceil());
  }

  bool get finished =>
      status == TransferStatus.done ||
      status == TransferStatus.error ||
      status == TransferStatus.cancelled;
}

class _Cancelled implements Exception {}

class TransferEngine {
  static final TransferEngine instance = TransferEngine._();
  TransferEngine._();

  final jobs = ValueNotifier<List<TransferJob>>([]);
  bool _pumping = false;

  void enqueue(TransferJob job) {
    jobs.value = [...jobs.value, job];
    unawaited(_pump());
  }

  void cancel(String id) {
    for (final j in jobs.value) {
      if (j.id == id) {
        j.cancel();
        if (j.status == TransferStatus.queued) {
          j.status = TransferStatus.cancelled;
        }
      }
    }
    jobs.value = [...jobs.value];
  }

  void clearFinished() {
    jobs.value = jobs.value.where((j) => !j.finished).toList();
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        TransferJob? next;
        for (final j in jobs.value) {
          if (j.status == TransferStatus.queued) {
            next = j;
            break;
          }
        }
        if (next == null) break;
        await _run(next);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<SSHClient> _connect(SshHost host) async {
if (host.jumpHostId != null && host.jumpHostId!.isNotEmpty) throw StateError('${host.name} usa ProxyJump: usalo desde la terminal');
          final socket = await SSHSocket.connect(host.hostname, host.port)
        .timeout(const Duration(seconds: 12));
    List<SSHKeyPair>? identities;
    final keyPath = host.keyPath;
    if (keyPath != null && keyPath.trim().isNotEmpty) {
      final keyFile = await AppPaths.resolveKey(keyPath.trim());
      if (keyFile != null) {
        identities = SSHKeyPair.fromPem(await keyFile.readAsString());
      }
    }
    String? pwd;
    if (identities == null) {
      identities = await IdentityService.loadIdentity();
      pwd = await SshCredentialsStore.readPassword(host.id);
    }
    return SSHClient(
      socket,
      username: host.username,
      identities: identities,
      onPasswordRequest: () async => pwd,
      onUserInfoRequest: (req) async => req.prompts
          .map((p) =>
              p.promptText.toLowerCase().contains('password') && pwd != null
                  ? pwd
                  : '')
          .toList(),
      onVerifyHostKey: (type, fingerprint) async => true,
      keepAliveInterval: const Duration(seconds: 15),
      handshakeTimeout: const Duration(seconds: 12),
      authTimeout: const Duration(seconds: 12),
    );
  }

  void _notifyThrottled(TransferJob job) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - job._lastNotify > 300 || job.finished) {
      job._lastNotify = now;
      jobs.value = [...jobs.value];
    }
  }

  Future<void> _run(TransferJob job) async {
    job.status = TransferStatus.running;
    jobs.value = [...jobs.value];
    SSHClient? src;
    SSHClient? dst;
    try {
      await SshHostsService.instance.loadFrom(AppPaths.base);
      final hosts = SshHostsService.instance.hosts;
      SshHost? byId(String id) {
        for (final h in hosts) {
          if (h.id == id) return h;
        }
        return null;
      }

      final sh = byId(job.sourceHostId);
      final th = byId(job.targetHostId);
      if (sh == null || th == null) {
        throw StateError('El host origen o destino ya no existe');
      }

      src = await _connect(sh);
      dst = await _connect(th);
      final srcSftp = await src.sftp();
      final dstSftp = await dst.sftp();

      final srcFile = await srcSftp.open(job.sourcePath);
      var size = job.size;
      if (size <= 0) size = (await srcFile.stat()).size ?? 0;
      final dstPath = job.targetDir.endsWith('/')
          ? '${job.targetDir}${job.fileName}'
          : '${job.targetDir}/${job.fileName}';
      final dstFile = await dstSftp.open(
        dstPath,
        mode: SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );

      const chunk = 256 * 1024;
      var pos = 0;
      while (pos < size) {
        if (job._cancel) throw _Cancelled();
        final n = (size - pos) < chunk ? size - pos : chunk;
        final data = await srcFile.readBytes(offset: pos, length: n);
        if (data.isEmpty) break;
        await dstFile.writeBytes(data, offset: pos);
        pos += data.length;
        job.bytes = pos;
        job.samples.add(TransferSample(
            DateTime.now().millisecondsSinceEpoch, pos));
        if (job.samples.length > 30) job.samples.removeAt(0);
        _notifyThrottled(job);
      }
      await srcFile.close();
      await dstFile.close();
      job.bytes = pos;
      job.status = TransferStatus.done;
    } on _Cancelled {
      job.status = TransferStatus.cancelled;
    } catch (e) {
      job.error = e.toString();
      job.status = TransferStatus.error;
    } finally {
      try {
        src?.close();
      } catch (_) {}
      try {
        dst?.close();
      } catch (_) {}
      jobs.value = [...jobs.value];
    }
  }
}
