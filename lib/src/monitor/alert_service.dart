// lib/src/monitor/alert_service.dart
// v2.21.0: alertas por umbral — compara cada snapshot del Monitor con el
// estado anterior y lanza NOTIFICACION LOCAL en las transiciones a mal
// estado: disco >= 90%, unidad auditada caida, instancia Oracle down.
// Antispam: solo alerta al entrar en mal estado (o tras cooldown de 30 min)
// y avisa tambien cuando se recupera. Estado persistido en JSON por host.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../storage/app_paths.dart';
import 'monitor_models.dart';

class AlertService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static Map<String, dynamic> _state = {};

  static File get _stateFile => File('${AppPaths.base}/alert_state.json');

  static const int _cooldownMs = 30 * 60 * 1000;

  static Future<void> init() async {
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _plugin.initialize(const InitializationSettings(android: android));
      _ready = true;
      try {
        await _plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      } catch (_) {}
      try {
        if (await _stateFile.exists()) {
          _state = jsonDecode(await _stateFile.readAsString());
        }
      } catch (_) {}
    } catch (_) {}
  }

  static Future<void> _save() async {
    try {
      await _stateFile.writeAsString(jsonEncode(_state), flush: true);
    } catch (_) {}
  }

  static Future<void> check(String hostId, String hostName, MonitorSnapshot s,
      List<String> units) async {
    if (!_ready) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final alerts = <String>[];

    for (final f in s.fs) {
      if (f.pct >= 90) {
        alerts.add('Disco ${f.mount} al ${f.pct.toStringAsFixed(0)}%');
      }
    }
    for (final e in s.unitStates.entries) {
      if (units.contains(e.key) && e.value != 'active') {
        alerts.add('Servicio ${e.key}: ${e.value}');
      }
    }
    if (s.oracle.present && !s.oracle.up) {
      alerts.add('Instancia Oracle DOWN');
    }

    _state[hostId] ??= <String, dynamic>{};
    final st = _state[hostId] as Map<String, dynamic>;
    final prevBad = (st['bad'] as bool?) ?? false;
    final lastTs = (st['ts'] as int?) ?? 0;

    if (alerts.isNotEmpty) {
      if (!prevBad || (now - lastTs) > _cooldownMs) {
        await _notify(hostName, alerts.join(' · '));
        st['bad'] = true;
        st['ts'] = now;
        await _save();
      }
    } else if (prevBad) {
      st['bad'] = false;
      await _save();
      await _notify(hostName, 'Recuperado: todo OK', recovery: true);
    }
  }

  static Future<void> _notify(String host, String body,
      {bool recovery = false}) async {
    try {
      const android = AndroidNotificationDetails(
        'termxtr_alerts',
        'Alertas de sistemas',
        channelDescription: 'Umbrales de discos, servicios y Oracle',
        importance: Importance.high,
        priority: Priority.high,
      );
      await _plugin.show(
        host.hashCode & 0x7fffffff,
        recovery ? 'TermXTR — $host recuperado' : 'ALERTA — $host',
        body,
        const NotificationDetails(android: android),
      );
    } catch (_) {}
  }
}
