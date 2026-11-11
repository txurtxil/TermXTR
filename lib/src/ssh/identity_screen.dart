// lib/src/ssh/identity_screen.dart
//
// Pantalla de identidad SSH de la app (v2.2.0): ver/copiar la clave
// publica y regenerar el par. Una vez instalada en los hosts (menu de la
// lista de hosts) las conexiones no piden contraseña.
//
// v2.17.15: campo editable para el comentario de la clave (feedback owner
// 9-nov-2026). Renombrar no regenera el par: la clave sigue funcionando
// en los hosts instalados; solo cambia la etiqueta que se instala/exporta.

import 'package:flutter/material.dart';
import '../ui/app_theme.dart';
import 'package:flutter/services.dart';

import 'identity_service.dart';


class IdentityScreen extends StatefulWidget {
  const IdentityScreen({super.key});

  @override
  State<IdentityScreen> createState() => _IdentityScreenState();
}

class _IdentityScreenState extends State<IdentityScreen> {
  String _pub = '';
  bool _generating = false;
  String? _error;
  final _commentController = TextEditingController();
  bool _savingComment = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final p = await IdentityService.ensureIdentity();
      final c = await IdentityService.currentComment();
      if (!mounted) return;
      setState(() {
        _pub = p;
        if (_commentController.text.isEmpty) _commentController.text = c;
        _generating = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _generating = false;
      });
    }
  }

  Future<void> _copy() async {
    if (_pub.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _pub));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Clave publica copiada')));
  }

  Future<void> _saveComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;
    setState(() => _savingComment = true);
    try {
      final line = await IdentityService.setComment(text);
      if (!mounted) return;
      setState(() {
        _pub = line;
        _commentController.text =
            line.split(' ').sublist(2).join(' ');
        _savingComment = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Comentario actualizado (la clave no cambia)')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _savingComment = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _regenerate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('¿Regenerar identidad?',
            style: TextStyle(color: AppColors.textHi)),
        content: const Text(
            'La clave actual dejara de funcionar en todos los hosts donde este instalada. Tendras que reinstalarla.',
            style: TextStyle(color: AppColors.textLo)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.err),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Regenerar')),
        ],
      ),
    );
    if (ok != true) return;
    await IdentityService.deleteIdentity();
    _commentController.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textHi),
        title: const Text('Identidad SSH',
            style: TextStyle(color: AppColors.textHi, fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'Regenerar',
            icon: const Icon(Icons.refresh, color: AppColors.textLo),
            onPressed: _generating ? null : _regenerate,
          ),
        ],
      ),
      body: _generating
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.accent))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!,
                        style: const TextStyle(color: AppColors.err)),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Text('Clave publica',
                        style: TextStyle(
                            color: AppColors.textHi,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(height: 6),
                    const Text(
                      'Instalala en los hosts desde el menu de cada host '
                      '(tres puntos > Enviar clave publica). A partir de '
                      'entonces las conexiones usaran esta clave y no '
                      'pediran contraseña.',
                      style: TextStyle(color: AppColors.textLo, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.card,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SelectableText(
                        _pub.isEmpty ? '(sin clave)' : _pub,
                        style: const TextStyle(
                          color: AppColors.textHi,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('Comentario (etiqueta)',
                        style: TextStyle(
                            color: AppColors.textHi,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(height: 6),
                    const Text(
                      'Etiqueta con la que se exporta/instala la clave. '
                      'Por defecto es termxtr-<dispositivo>. Renombrarla '
                      'NO regenera el par: sigue funcionando en los hosts '
                      'ya instalados.',
                      style: TextStyle(color: AppColors.textLo, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _commentController,
                            style: const TextStyle(
                                color: AppColors.textHi, fontSize: 13),
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: AppColors.card,
                              hintText: 'termxtr-mi-dispositivo',
                              hintStyle:
                                  const TextStyle(color: AppColors.textLo),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding:
                                  const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 10),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed:
                              _savingComment ? null : _saveComment,
                          child: _savingComment
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white))
                              : const Text('Guardar'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _pub.isEmpty ? null : _copy,
                      icon: const Icon(Icons.copy),
                      label: const Text('Copiar clave publica'),
                    ),
                  ],
                ),
    );
  }
}
