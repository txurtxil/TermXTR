// lib/src/ssh/ssh_connector.dart
// v2.22 (saneamiento): UNICA puerta de conexion SSH de la app. Sustituye las
// 6 copias del flujo de auth (keyPath -> identidad app -> password) que habia
// dispersas en session/monitor/sftp/identity/multiexec. Migrar caller a
// caller; el que queda fuera por ahora sigue funcionando con su copia.

import 'package:dartssh2/dartssh2.dart';

import '../storage/app_paths.dart';
import 'identity_service.dart';
import 'ssh_credentials_store.dart';
import 'ssh_host.dart';

class SshConn {
  final SSHClient c;
  final SSHSocket s;
  SshConn(this.c, this.s);
  void close() {
    c.close();
    try {
      s.close();
    } catch (_) {}
  }
}

class SshConnector {
  static Future<SshConn> connect(SshHost host,
      {Duration timeout = const Duration(seconds: 12)}) async {
    final socket = await SSHSocket.connect(host.hostname, host.port)
        .timeout(timeout);
    List<SSHKeyPair>? identities;
    final keyPath = host.keyPath;
    if (keyPath != null && keyPath.trim().isNotEmpty) {
      try {
        final keyFile = await AppPaths.resolveKey(keyPath.trim());
        if (keyFile != null) {
          identities = SSHKeyPair.fromPem(await keyFile.readAsString());
        }
      } catch (_) {}
    }
    try {
      final id = await IdentityService.loadIdentity();
      if (id != null && id.isNotEmpty) {
        identities = [...(identities ?? const <SSHKeyPair>[]), ...id];
      }
    } catch (_) {}
    final pwd = await SshCredentialsStore.readPassword(host.id);
    final client = SSHClient(
      socket,
      username: host.username,
      identities: (identities != null && identities.isNotEmpty)
          ? identities
          : null,
      onPasswordRequest: () async => pwd,
      onUserInfoRequest: (req) async => req.prompts
          .map((p) =>
              p.promptText.toLowerCase().contains('password') && pwd != null
                  ? pwd
                  : '')
          .toList(),
      onVerifyHostKey: (type, fingerprint) async => true,
      handshakeTimeout: timeout,
      authTimeout: timeout,
    );
    return SshConn(client, socket);
  }
}
