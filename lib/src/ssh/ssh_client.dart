import 'package:ssh/ssh.dart';
import 'host_config.dart';

/// Cliente SSH para conectar a un host remoto.
class SshClient {
  final HostConfig config;

  SshClient(this.config);

  /// Abre una conexión SSH al host.
  Future<Ssh> connect({bool ignoreKnownHosts = false}) async {
    final ssh = SshHost(
      host: config.host,
      port: config.port,
      username: config.user,
    );

    ssh.onAuthRequired = (auth) async {
      if (config.password != null && config.password!.isNotEmpty) {
        auth.password(config.password!);
      }
    };

    await ssh.connect(ignoreHostKey: ignoreKnownHosts);
    return ssh;
  }

  /// Cierra la conexión.
  void dispose() {
    // ssh.close();
  }
}
