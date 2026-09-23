import 'package:flutter/material.dart';
import 'src/terminal/terminal_view.dart';

void main() {
  runApp(const TermXTRApp());
}

class TermXTRApp extends StatelessWidget {
  const TermXTRApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TermXTR',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
      ),
      home: const TerminalScreen(),
    );
  }
}
