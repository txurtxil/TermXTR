import 'package:flutter/material.dart';

import '../services/storage_service.dart';

/// Ajustes: tema oscuro/claro y tamano de fuente del editor.
/// El tamano de fuente del terminal ya se ajusta en vivo con +/- desde su toolbar.
class SettingsScreen extends StatefulWidget {
  final ValueNotifier<AppSettings> notifier;
  const SettingsScreen({super.key, required this.notifier});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _s;

  @override
  void initState() {
    super.initState();
    _s = widget.notifier.value;
  }

  Future<void> _update(AppSettings s) async {
    setState(() => _s = s);
    widget.notifier.value = s;
    await StorageService.instance.saveSettings(s);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(
        children: [
          SwitchListTile(
            secondary: Icon(
                _s.darkTheme ? Icons.dark_mode : Icons.light_mode),
            title: const Text('Tema oscuro'),
            subtitle: Text(_s.darkTheme ? 'Oscuro' : 'Claro'),
            value: _s.darkTheme,
            onChanged: (v) => _update(_s.copyWith(darkTheme: v)),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.format_size),
            title: const Text('Tamano de fuente del editor'),
            subtitle: Slider(
              value: _s.terminalFontSize,
              min: 10,
              max: 24,
              divisions: 14,
              label: _s.terminalFontSize.toStringAsFixed(0),
              onChanged: (v) =>
                  _update(_s.copyWith(terminalFontSize: v)),
            ),
            trailing: Text(_s.terminalFontSize.toStringAsFixed(0)),
          ),
          const Divider(),
          const ListTile(
            leading: Icon(Icons.info),
            title: Text('TermXTR'),
            subtitle: Text(
                'Terminal SSH/SFTp para Android\nv1.1.0'),
          ),
        ],
      ),
    );
  }
}
