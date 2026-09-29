import 'dart:convert';

class SshHost {
  final String id;
  String name;
  String hostname;
  int port;
  String username;
  String? keyPath;
  String? initialPath;
  String osTag;
  DateTime? lastUsed;

  SshHost({
    required this.id, required this.name, required this.hostname, this.port = 22,
    required this.username, this.keyPath, this.initialPath, this.osTag = 'generic', this.lastUsed,
  });

  // v14.24: los comandos shell (toSshCommand/sshpass) desaparecen con el
  // contenedor Debian. Las sesiones SSH las gestiona dartssh2 directamente
  // (ver terminal_session.dart); keyPath apunta al almacén de claves de la
  // app: '/keys/<nombre>'.

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'hostname': hostname, 'port': port, 'username': username,
        if (keyPath != null && keyPath!.isNotEmpty) 'keyPath': keyPath,
        if (initialPath != null && initialPath!.isNotEmpty) 'initialPath': initialPath,
        'osTag': osTag, if (lastUsed != null) 'lastUsed': lastUsed!.toIso8601String(),
      };

  static SshHost fromJson(Map<String, dynamic> j) => SshHost(
        id: j['id'] as String,
        name: j['name'] as String? ?? j['hostname'] as String? ?? 'Host',
        hostname: j['hostname'] as String? ?? '',
        port: (j['port'] as num?)?.toInt() ?? 22,
        username: j['username'] as String? ?? 'root',
        keyPath: j['keyPath'] as String?,
        initialPath: j['initialPath'] as String?,
        osTag: j['osTag'] as String? ?? 'generic',
        lastUsed: j['lastUsed'] != null ? DateTime.tryParse(j['lastUsed'] as String) : null,
      );

  SshHost copyWith({
    String? name, String? hostname, int? port, String? username,
    String? keyPath, String? initialPath, String? osTag,
  }) {
    return SshHost(
      id: id, name: name ?? this.name, hostname: hostname ?? this.hostname, port: port ?? this.port,
      username: username ?? this.username, keyPath: keyPath ?? this.keyPath,
      initialPath: initialPath ?? this.initialPath, osTag: osTag ?? this.osTag, lastUsed: lastUsed,
    );
  }
}
