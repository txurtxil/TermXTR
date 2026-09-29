// lib/src/terminal/clipboard_vault_sheet.dart
//
// UI del portapapeles. Reutiliza la paleta ya establecida en las tarjetas
// de servicio del dashboard (_C) para que esto no parezca un widget de otro
// sitio pegado con celo — mismo dark theme, mismos radios, mismo acento.
//
// Uso desde terminal_view.dart (dentro de _showMenu(), reemplazando el
// antiguo "Copiar pantalla"):
//
//   showClipboardVault(
//     context,
//     recorder: _active.recorder,
//     sessionLabel: _sessions.length > 1 ? _active.name : null,
//     getVisibleText: _visibleText,
//   );

import 'package:flutter/material.dart';

import 'clipboard_vault.dart';
import 'terminal_recorder.dart';

class _C {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const cardAlt = Color(0xFF242426);
  static const border = Color(0xFF3A3A3C);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const ok = Color(0xFF34C759);
  static const err = Color(0xFFFF453A);
  static const accent = Color(0xFF5E9BD6);
}

Future<void> showClipboardVault(
  BuildContext context, {
  required TerminalRecorder recorder,
  String? sessionLabel,
  String Function()? getVisibleText,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ClipboardVaultSheet(
      recorder: recorder,
      sessionLabel: sessionLabel,
      getVisibleText: getVisibleText,
    ),
  );
}

class _ClipboardVaultSheet extends StatefulWidget {
  final TerminalRecorder recorder;
  final String? sessionLabel;
  final String Function()? getVisibleText;
  const _ClipboardVaultSheet({required this.recorder, this.sessionLabel, this.getVisibleText});

  @override
  State<_ClipboardVaultSheet> createState() => _ClipboardVaultSheetState();
}

class _ClipboardVaultSheetState extends State<_ClipboardVaultSheet> {
  final _vault = ClipboardVault.instance;
  final _searchCtrl = TextEditingController();
  bool _busy = false;
  String? _flash;
  bool _flashIsError = false;

  @override
  void initState() {
    super.initState();
    _vault.addListener(_onChange);
  }

  @override
  void dispose() {
    _vault.removeListener(_onChange);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  String _fmtTime(DateTime t) {
    final now = DateTime.now();
    final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return sameDay ? '$hh:$mm' : '${t.day}/${t.month} $hh:$mm';
  }

  void _showFlash(String msg, {bool error = false}) {
    setState(() {
      _flash = msg;
      _flashIsError = error;
    });
  }

  Future<void> _run(Future<ClipboardEntry> Function() action, String label) async {
    setState(() => _busy = true);
    try {
      final e = await action();
      if (e.text.trim().isEmpty) {
        _showFlash('$label: no hay nada que copiar todavía', error: true);
      } else if (e.inSystemClipboard) {
        _showFlash('Copiado — $label · ${_fmtBytes(e.bytes)}');
      } else {
        _showFlash(
          'Guardado en el historial — $label · ${_fmtBytes(e.bytes)}. '
          'Demasiado grande para el portapapeles del sistema: usa Exportar.',
          error: true,
        );
      }
    } catch (err) {
      _showFlash('No se pudo completar: $err', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchCtrl.text;
    final items = _vault.search(query);
    final r = widget.recorder;
    final hasBookmark = _vault.hasBookmark(r);

    return DraggableScrollableSheet(
      initialChildSize: 0.62,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      builder: (context, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: _C.bg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(color: _C.border, borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
              child: Row(
                children: [
                  const Icon(Icons.content_paste_rounded, color: _C.accent, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    widget.sessionLabel == null ? 'Portapapeles' : 'Portapapeles · ${widget.sessionLabel}',
                    style: const TextStyle(color: _C.textHi, fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: _C.textLo, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: _C.textHi, fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Buscar en lo que has copiado…',
                  hintStyle: const TextStyle(color: _C.textLo, fontSize: 13),
                  prefixIcon: const Icon(Icons.search, color: _C.textLo, size: 18),
                  filled: true,
                  fillColor: _C.cardAlt,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _C.border)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _C.border)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: _C.accent)),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _chip('Sesión completa', Icons.description_outlined,
                      () => _run(() => _vault.copyFullSession(r), 'sesión completa')),
                  _chip('Última salida', Icons.subdirectory_arrow_right,
                      () => _run(() => _vault.copyLastOutput(r), 'última salida')),
                  _chip('Bloque de error', Icons.error_outline, () async {
                    setState(() => _busy = true);
                    final e = await _vault.copyErrorBlock(r);
                    setState(() => _busy = false);
                    if (e == null) {
                      _showFlash('No hay ningún error reciente que recortar', error: true);
                    } else {
                      _showFlash(e.inSystemClipboard
                          ? 'Copiado — bloque de error · ${_fmtBytes(e.bytes)}'
                          : 'Guardado en el historial · ${_fmtBytes(e.bytes)} — demasiado grande, usa Exportar');
                    }
                  }),
                  if (widget.getVisibleText != null)
                    _chip('Visible', Icons.crop_free,
                        () => _run(() => _vault.copyVisible(widget.getVisibleText!()), 'visible')),
                  _chip(hasBookmark ? 'Desde marcador' : 'Marcar aquí',
                      hasBookmark ? Icons.flag : Icons.flag_outlined, () async {
                    if (hasBookmark) {
                      await _run(() => _vault.copySinceBookmark(r), 'desde marcador');
                    } else {
                      await _vault.markHere(r);
                      _showFlash('Marcado. Todo lo que pase a partir de ahora se podrá copiar desde aquí.');
                      setState(() {});
                    }
                  }),
                ],
              ),
            ),
            if (_flash != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Text(_flash!,
                    style: TextStyle(color: _flashIsError ? _C.err : _C.ok, fontSize: 11.5)),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 6),
              child: Row(
                children: [
                  Text('HISTORIAL', style: TextStyle(color: _C.textLo, fontSize: 10.5, letterSpacing: 0.6)),
                ],
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Text(
                        query.isEmpty ? 'Nada copiado todavía' : 'Sin resultados para "$query"',
                        style: const TextStyle(color: _C.textLo, fontSize: 12),
                      ),
                    )
                  : ListView.builder(
                      controller: scrollCtrl,
                      itemCount: items.length,
                      itemBuilder: (context, i) => _entryTile(items[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: _busy ? null : onTap,
      borderRadius: BorderRadius.circular(16),
      child: Opacity(
        opacity: _busy ? 0.5 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
              color: _C.cardAlt, borderRadius: BorderRadius.circular(16), border: Border.all(color: _C.border)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: _C.accent),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: _C.textHi, fontSize: 12)),
          ]),
        ),
      ),
    );
  }

  Widget _entryTile(ClipboardEntry e) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(10),
      decoration:
          BoxDecoration(color: _C.card, borderRadius: BorderRadius.circular(10), border: Border.all(color: _C.border)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _vault.pin(e.id)),
            child: Icon(e.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                size: 15, color: e.pinned ? _C.accent : _C.textLo),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _C.textHi, fontSize: 12.5, fontFamily: 'monospace')),
                const SizedBox(height: 3),
                Text(
                  '${e.label} · ${_fmtBytes(e.bytes)} · ${_fmtTime(e.at)}'
                  '${e.inSystemClipboard ? '' : ' · solo aquí'}',
                  style: const TextStyle(color: _C.textLo, fontSize: 10.5),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: _C.textLo, size: 18),
            color: _C.card,
            onSelected: (v) async {
              switch (v) {
                case 'copy':
                  final ok = await _vault.forceSystemClipboard(e);
                  _showFlash(
                    ok ? 'Copiado' : 'Android rechazó el pegado: demasiado grande. Usa Exportar.',
                    error: !ok,
                  );
                  break;
                case 'export':
                  try {
                    final path = await _vault.exportToFile(e);
                    _showFlash('Guardado en Descargas/xtr_clip/\n$path');
                  } catch (err) {
                    _showFlash('No se pudo exportar: $err', error: true);
                  }
                  break;
                case 'delete':
                  _vault.remove(e.id);
                  break;
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'copy', child: Text('Copiar de nuevo')),
              const PopupMenuItem(value: 'export', child: Text('Exportar a .txt')),
              const PopupMenuItem(value: 'delete', child: Text('Eliminar')),
            ],
          ),
        ],
      ),
    );
  }
}
