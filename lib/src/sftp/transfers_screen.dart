// lib/src/sftp/transfers_screen.dart
//
// v2.6.0: cola de transferencias entre equipos con telemetria en vivo.

import 'package:flutter/material.dart';

import 'transfer_engine.dart';

class _C {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const accent = Color(0xFF5E9BD6);
  static const err = Color(0xFFFF453A);
  static const ok = Color(0xFF34C759);
}

class TransfersScreen extends StatelessWidget {
  const TransfersScreen({super.key});

  static String _fmtBytes(double b) {
    if (b < 1024) return '${b.toStringAsFixed(0)} B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  static String _fmtSpeed(double bps) {
    if (bps <= 0) return '--';
    if (bps < 1024 * 1024) return '${(bps / 1024).toStringAsFixed(0)} KB/s';
    return '${(bps / (1024 * 1024)).toStringAsFixed(2)} MB/s';
  }

  static String _fmtDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inHours}h ${d.inMinutes % 60}m';
  }

  String _statusLine(TransferJob j) {
    switch (j.status) {
      case TransferStatus.queued:
        return 'En cola...';
      case TransferStatus.running:
        final eta = j.eta;
        return '${_fmtBytes(j.bytes.toDouble())}/${_fmtBytes(j.size.toDouble())}'
            ' (${(j.progress * 100).toStringAsFixed(0)}%)'
            ' · ${_fmtSpeed(j.currentSpeed)} (media ${_fmtSpeed(j.avgSpeed)})'
            ' · ${_fmtDuration(DateTime.now().difference(j.startedAt))}'
            '${eta != null ? ' · ETA ${_fmtDuration(eta)}' : ''}';
      case TransferStatus.done:
        return 'Completado: ${_fmtBytes(j.bytes.toDouble())} en '
            '${_fmtDuration(DateTime.now().difference(j.startedAt))}';
      case TransferStatus.error:
        return 'Error: ${j.error}';
      case TransferStatus.cancelled:
        return 'Cancelado (${_fmtBytes(j.bytes.toDouble())} transferidos)';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.bg,
      appBar: AppBar(
        backgroundColor: _C.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: _C.textHi),
        title: const Text('Transferencias',
            style: TextStyle(color: _C.textHi, fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'Limpiar terminadas',
            icon: const Icon(Icons.clear_all, color: _C.textLo),
            onPressed: () => TransferEngine.instance.clearFinished(),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<TransferJob>>(
        valueListenable: TransferEngine.instance.jobs,
        builder: (_, jobs, __) {
          if (jobs.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Cola vacía.\n\nDesde el explorador SFTP, mantén pulsado '
                  'un fichero y elige "Enviar a otro equipo...".',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _C.textLo),
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: jobs.length,
            itemBuilder: (_, i) {
              final j = jobs[i];
              final running = j.status == TransferStatus.running;
              final queued = j.status == TransferStatus.queued;
              final okColor = j.status == TransferStatus.done
                  ? _C.ok
                  : (j.status == TransferStatus.error ||
                          j.status == TransferStatus.cancelled
                      ? _C.err
                      : _C.accent);
              return Card(
                color: _C.card,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                              j.status == TransferStatus.done
                                  ? Icons.check_circle
                                  : (j.status == TransferStatus.error ||
                                          j.status ==
                                              TransferStatus.cancelled)
                                      ? Icons.error
                                      : (queued
                                          ? Icons.hourglass_top
                                          : Icons.sync),
                              size: 16,
                              color: okColor),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(j.fileName,
                                style: const TextStyle(
                                    color: _C.textHi,
                                    fontWeight: FontWeight.w500),
                                overflow: TextOverflow.ellipsis),
                          ),
                          if (!j.finished)
                            IconButton(
                              icon: const Icon(Icons.close,
                                  size: 18, color: _C.err),
                              tooltip: 'Cancelar',
                              onPressed: () =>
                                  TransferEngine.instance.cancel(j.id),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      if (j.size > 0 && (running || queued))
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: running ? j.progress : null,
                            minHeight: 4,
                            backgroundColor: _C.bg,
                            valueColor:
                                const AlwaysStoppedAnimation(_C.accent),
                          ),
                        ),
                      if (j.size > 0 && (running || queued))
                        const SizedBox(height: 6),
                      Text(
                        '${j.sourceHostName} → ${j.targetHostName}\n'
                        '${j.sourcePath}',
                        style: const TextStyle(
                            color: _C.textLo,
                            fontSize: 10,
                            fontFamily: 'monospace'),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _statusLine(j),
                        style: TextStyle(
                            color: j.finished ? okColor : _C.textHi,
                            fontSize: 11,
                            fontFamily: 'monospace'),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
