import 'package:flutter/material.dart';

import 'screens/hosts_screen.dart';
import 'screens/local_files_screen.dart';
import 'screens/settings_screen.dart';
import 'services/storage_service.dart';
import 'src/terminal/terminal_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await StorageService.instance.loadSettings();
  runApp(TermXtrApp(settings: settings));
}

class TermXtrApp extends StatefulWidget {
  final AppSettings settings;
  const TermXtrApp({super.key, required this.settings});

  @override
  State<TermXtrApp> createState() => _TermXtrAppState();
}

class _TermXtrAppState extends State<TermXtrApp> {
  late final ValueNotifier<AppSettings> _settings;

  @override
  void initState() {
    super.initState();
    _settings = ValueNotifier(widget.settings);
  }

  @override
  void dispose() {
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppSettings>(
      valueListenable: _settings,
      builder: (_, s, __) => MaterialApp(
        title: 'TermXTR',
        debugShowCheckedModeBanner: false,
        themeMode: s.darkTheme ? ThemeMode.dark : ThemeMode.light,
        theme: ThemeData(
          colorSchemeSeed: Colors.teal,
          brightness: Brightness.light,
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.teal,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: HomeShell(settings: _settings),
      ),
    );
  }
}

/// Navegacion principal: Terminal / Hosts / Archivos / Ajustes.
class HomeShell extends StatefulWidget {
  final ValueNotifier<AppSettings> settings;
  const HomeShell({super.key, required this.settings});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      const TerminalScreen(),
      const HostsScreen(),
      const LocalFilesScreen(),
      SettingsScreen(notifier: widget.settings),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.terminal), label: 'Terminal'),
          NavigationDestination(icon: Icon(Icons.dns), label: 'Hosts'),
          NavigationDestination(
              icon: Icon(Icons.folder), label: 'Archivos'),
          NavigationDestination(
              icon: Icon(Icons.settings), label: 'Ajustes'),
        ],
      ),
    );
  }
}
