import 'package:flutter/material.dart';
import 'src/terminal/terminal_view.dart';

void main() {
  runApp(const TermXtrApp());
}

/// TermXTR v2.0.0 - terminal SSH/SFTP (base: LinuxContainer 1.3.0 mejorada).
/// Sin shell local: todas las sesiones son SSH a hosts gestionados.
class TermXtrApp extends StatelessWidget {
  const TermXtrApp({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      brightness: Brightness.dark,
      colorSchemeSeed: Colors.teal,
      useMaterial3: true,
    );
    return MaterialApp(
      title: 'TermXTR',
      debugShowCheckedModeBanner: false,
      theme: theme,
      darkTheme: theme,
      home: const TerminalScreen(),
    );
  }
}
