// lib/src/sftp/sftp_connection_pool.dart
//
// Guarda las conexiones SFTP vivas por host, FUERA del ciclo de vida de
// SftpBrowserScreen -- para que salir de esa pantalla (volver atras, abrir
// una pestana SSH) no cierre la conexion. Se cierra solo cuando se pide
// explicitamente ("Desconectar" en el menu), o cuando se cierra la app.
//
// Simplificacion consciente: no hay limpieza automatica por inactividad.
// Si abres SFTP a varios hosts y no desconectas ninguno, se quedan todos
// vivos hasta cerrar XTR Terminal del todo. Para el uso normal (uno o dos
// hosts a la vez) esto no pesa nada; si algun dia hace falta, un timeout
// de inactividad seria el siguiente paso.

import '../ssh/ssh_host.dart';
import 'sftp_service.dart';

class SftpConnectionPool {
  static final SftpConnectionPool instance = SftpConnectionPool._();
  SftpConnectionPool._();

  final Map<String, SftpService> _services = {};

  /// Última carpeta visitada por host: al volver a abrir SFTP (integrado en
  /// la terminal o desde Hosts) se entra donde te quedaste, no al origen.
  final Map<String, String> _lastPaths = {};

  /// El servicio para este host: el mismo de siempre si ya existia (vivo o
  /// no), o uno nuevo la primera vez. No conecta por si mismo -- eso lo
  /// hace quien lo use, llamando a .connect().
  SftpService forHost(SshHost host, String rootfsPath) {
    return _services.putIfAbsent(host.id, () => SftpService(host: host, rootfsPath: rootfsPath));
  }

  bool isConnected(String hostId) => _services[hostId]?.isConnected ?? false;

  String? lastPathFor(String hostId) => _lastPaths[hostId];

  void rememberPath(String hostId, String path) => _lastPaths[hostId] = path;

  Future<void> disconnect(String hostId) async {
    final svc = _services.remove(hostId);
    await svc?.close();
  }

  Future<void> disconnectAll() async {
    for (final svc in _services.values) {
      await svc.close();
    }
    _services.clear();
  }
}
