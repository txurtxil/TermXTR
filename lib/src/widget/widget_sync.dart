// lib/src/widget/widget_sync.dart
//
// Espejo de los favoritos (hosts SSH + rutas SFTP) hacia el widget de
// escritorio Android. Escribe un JSON compacto en SharedPreferences (el
// plugin usa el fichero "FlutterSharedPreferences" con prefijo "flutter.",
// que es exactamente donde lo lee HostsWidgetService.kt) y avisa al lado
// nativo por el canal xtr/widget para que refresque la lista.
//
// Se llama desde SshHostsService y SftpFavoritesService tras cada cambio
// y tras cargar de disco. Nunca lanza: el widget es un extra, no puede
// romper la app.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ssh/ssh_hosts_service.dart';
import '../sftp/sftp_favorites_service.dart';

class WidgetSync {
  static const MethodChannel _ch = MethodChannel('xtr/widget');

  static Future<void> push() async {
    try {
      final hosts = SshHostsService.instance.hosts
          .map((h) => <String, dynamic>{
                'id': h.id,
                'name': h.name,
                'username': h.username,
                'hostname': h.hostname,
                'port': h.port,
                'osTag': h.osTag,
              })
          .toList();

      final hostNames = <String, String>{
        for (final h in SshHostsService.instance.hosts) h.id: h.name,
      };
      final favs = SftpFavoritesService.instance.all
          .map((f) => <String, dynamic>{
                'id': f.id,
                'hostId': f.hostId,
                'hostName': hostNames[f.hostId] ?? '',
                'path': f.path,
                'label': f.label,
              })
          .toList();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('widget_hosts_json', jsonEncode(hosts));
      await prefs.setString('widget_sftp_json', jsonEncode(favs));
      await _ch.invokeMethod('refresh');
    } catch (_) {
      // El widget no esta instalado o el canal aun no existe: se ignora.
    }
  }
}
