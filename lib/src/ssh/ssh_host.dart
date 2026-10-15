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

  /// v2.7.0: id del host salto (ProxyJump). null = conexion directa.
  String? jumpHostId;

  /// v2.8.0: MAC del equipo, para Wake-on-LAN (formato AA:BB:CC:DD:EE:FF).
  String? macAddress;

  /// v2.10.0: grupo de hosts (ej. 'Desarrollo', 'Producción'). null = sin grupo.
  String? group;

  /// v2.11.0: ultimo resultado de "Auditar servicios" (gateway, IP LAN,
  /// vecinos ARP y servicios escuchando). El mapa de hosts lo pinta de
  /// aqui. Se incluye en el backup/export del host.
  Map<String, dynamic>? audit;

  SshHost({
    required this.id, required this.name, required this.hostname, this.port = 22,
    required this.username, this.keyPath, this.initialPath, this.osTag = 'generic', this.lastUsed, this.jumpHostId, this.macAddress, this.group, this.audit,
  });

  // v14.24: los comandos shell (toSshCommand/sshpass) desaparecen con el
  // contenedor Debian. Las sesiones SSH las gestiona dartssh2 directamente
  // (ver terminal_session.dart); keyPath apunta al almacén de claves de la
  // app: '/keys/<nombre>'.

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'hostname': hostname, 'port': port, 'username': username,
        if (keyPath != null && keyPath!.isNotEmpty) 'keyPath': keyPath,
        if (initialPath != null && initialPath!.isNotEmpty) 'initialPath': initialPath,
      if (jumpHostId != null && jumpHostId!.isNotEmpty) 'jumpHostId': jumpHostId,
      if (macAddress != null && macAddress!.isNotEmpty) 'macAddress': macAddress,
        if (group != null && group!.isNotEmpty) 'group': group,
        if (audit != null) 'audit': audit,
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
        jumpHostId: j['jumpHostId'] as String?,
        macAddress: j['macAddress'] as String?,
        group: j['group'] as String?,
        audit: j['audit'] as Map<String, dynamic>?,
      );

  SshHost copyWith({
    String? name, String? hostname, int? port, String? username,
    String? keyPath, String? initialPath, String? osTag, String? jumpHostId, bool clearJump = false, String? macAddress, String? group, bool clearGroup = false,
  }) {
    return SshHost(
      id: id, name: name ?? this.name, hostname: hostname ?? this.hostname, port: port ?? this.port,
      username: username ?? this.username, keyPath: keyPath ?? this.keyPath,
      initialPath: initialPath ?? this.initialPath, osTag: osTag ?? this.osTag, lastUsed: lastUsed,
      jumpHostId: clearJump ? null : (jumpHostId ?? this.jumpHostId),
      macAddress: macAddress ?? this.macAddress,
      group: clearGroup ? null : (group ?? this.group),
    );
  }
}
