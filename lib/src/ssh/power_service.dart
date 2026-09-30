// lib/src/ssh/power_service.dart
//
// v2.8.0: gestion de energia remota.
// - Apagar / reiniciar por SSH con sudo -n (sin password si el host fue
//   "preparado": sudoers NOPASSWD para poweroff/reboot/shutdown).
// - Preparar apagado sin contraseña: instala /etc/sudoers.d/termxtr-power
//   usando la contraseña UNA vez (mismo patron que la identidad SSH).
// - Wake-on-LAN: magic packet UDP (6xFF + 16xMAC) por broadcast o IP
//   dirigida. Requiere la MAC del equipo guardada en su perfil.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../storage/app_paths.dart';
import 'identity_service.dart';
import 'ssh_credentials_store.dart';
import 'ssh_host.dart';

class PowerResult {
  final bool ok;
  final String message;
  PowerResult.ok(this.message) : ok = true;
  PowerResult.fail(this.message) : ok = false;
}

class PowerService {
  /// Ejecuta un comando con sudo sin password (sudo -n).
  /// Devuelve el resultado; si el host se apaga, la conexion cae y lo
  /// tratamos como exito probable.
  static Future<PowerResult> _sudo(SshHost host, String cmd,
      {String? sudoPassword}) async {
    SSHSocket? socket;
    try {
      socket = await SSHSocket.connect(host.hostname, host.port)
          .timeout(const Duration(seconds: 12));
      List<SSHKeyPair>? identities;
      final keyPath = host.keyPath;
      if (keyPath != null && keyPath.trim().isNotEmpty) {
        final keyFile = await AppPaths.resolveKey(keyPath.trim());
        if (keyFile != null) {
          identities = SSHKeyPair.fromPem(await keyFile.readAsString());
        }
      }
      String? pwd;
      if (identities == null) {
        identities = await IdentityService.loadIdentity();
        pwd = await SshCredentialsStore.readPassword(host.id);
      }
      final client = SSHClient(
        socket,
        username: host.username,
        identities: identities,
        onPasswordRequest: () async => pwd,
        onUserInfoRequest: (req) async => req.prompts
            .map((p) => p.promptText.toLowerCase().contains('password') &&
                    pwd != null
                ? pwd
                : '')
            .toList(),
        onVerifyHostKey: (t, f) async => true,
        handshakeTimeout: const Duration(seconds: 12),
        authTimeout: const Duration(seconds: 12),
      );
      // Intenta sudo -n; si falla y hay password de sudo, reintenta con -S.
      var full = 'sudo -n $cmd';
      var res = await client
          .run(full)
          .timeout(const Duration(seconds: 20));
      var out = utf8.decode(res, allowMalformed: true).trim();
      if (out.isNotEmpty) {
        final sp = sudoPassword ?? pwd;
        if (sp != null && sp.isNotEmpty) {
          full = "echo '$sp' | sudo -S -p '' $cmd";
          try {
            res = await client
                .run(full)
                .timeout(const Duration(seconds: 20));
            out = utf8.decode(res, allowMalformed: true).trim();
          } catch (_) {
            // la conexion puede caer si el comando apago el equipo
          }
        }
      }
      client.close();
      unawaited(socket.close());
      if (out.isNotEmpty &&
          (out.toLowerCase().contains('password') ||
              out.toLowerCase().contains('sorry'))) {
        return PowerResult.fail(
            'sudo pide contraseña: usa "Preparar apagado sin contraseña" una vez');
      }
      return PowerResult.ok(out.isEmpty ? 'OK' : out);
    } on SSHAuthFailError {
      return PowerResult.fail('Autenticacion fallida');
    } catch (e) {
      // Conexion cortada: el equipo probablemente se apago/reinicio
      try {
        socket?.close();
      } catch (_) {}
      return PowerResult.ok('Comando enviado (conexion cerrada por el host)');
    }
  }

  static Future<PowerResult> shutdown(SshHost host) => _sudo(
      host,
      '/sbin/poweroff 2>/dev/null || /usr/sbin/poweroff 2>/dev/null || '
      '/sbin/shutdown -h now 2>/dev/null || systemctl poweroff');

  static Future<PowerResult> reboot(SshHost host) => _sudo(
      host,
      '/sbin/reboot 2>/dev/null || /usr/sbin/reboot 2>/dev/null || '
      '/sbin/shutdown -r now 2>/dev/null || systemctl reboot');

  /// Instala la regla sudoers NOPASSWD para apagado/reinicio usando la
  /// contraseña del host una sola vez. Idempotente.
  static Future<PowerResult> preparePasswordless(SshHost host,
      {required String password}) async {
    final rule = '${host.username} ALL=(ALL) NOPASSWD: '
        '/sbin/poweroff, /usr/sbin/poweroff, /sbin/reboot, '
        '/usr/sbin/reboot, /sbin/shutdown, /usr/sbin/shutdown';
    return _sudo(
        host,
        "echo '$rule' | tee /etc/sudoers.d/termxtr-power >/dev/null && "
        "chmod 440 /etc/sudoers.d/termxtr-power",
        sudoPassword: password);
  }

  /// Magic packet Wake-on-LAN. [ip] dirigida o broadcast si es null.
  /// Solo funciona en la LAN del equipo (misma red o con reenvio).
  static Future<bool> wakeOnLan(String mac, {String? ip}) async {
    final m = mac.replaceAll(RegExp('[^0-9A-Fa-f]'), '');
    if (m.length != 12) return false;
    final bytes = <int>[];
    for (var i = 0; i < 6; i++) {
      bytes.add(int.parse(m.substring(i * 2, i * 2 + 2), radix: 16));
    }
    final packet = <int>[
      ...List.filled(6, 0xFF),
      ...List.filled(16, bytes).expand((e) => e),
    ];
    RawDatagramSocket? udp;
    try {
      udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final target = ip != null && ip.isNotEmpty
          ? InternetAddress(ip)
          : InternetAddress('255.255.255.255');
      udp.send(Uint8List.fromList(packet), target, 9);
      await Future.delayed(const Duration(milliseconds: 200));
      udp.send(Uint8List.fromList(packet), target, 9);
      return true;
    } catch (_) {
      return false;
    } finally {
      udp?.close();
    }
  }
}
