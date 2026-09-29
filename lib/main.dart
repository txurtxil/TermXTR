import 'package:flutter/material.dart';
import 'src/terminal/terminal_view.dart';

void main() {
  runApp(const XtrTerminalApp());
}

class XtrTerminalApp extends StatelessWidget {
  const XtrTerminalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XTR Terminal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
      ),
      home: const TerminalScreen(),
    );
  }
}
