class HostProfile {
  final String id;
  final String name;
  final String hostname;
  final int port;
  final String username;
  final bool useKey; // true = clave privada PEM, false = password
  final String secret; // password o PEM segun useKey
  final String? notes;
  final int? lastConnected; // epoch millis

  const HostProfile({
    required this.id,
    required this.name,
    required this.hostname,
    required this.port,
    required this.username,
    required this.useKey,
    required this.secret,
    this.notes,
    this.lastConnected,
  });

  String get subtitle => '$username@$hostname:$port';

  HostProfile copyWith({
    String? id,
    String? name,
    String? hostname,
    int? port,
    String? username,
    bool? useKey,
    String? secret,
    String? notes,
    int? lastConnected,
    bool clearNotes = false,
  }) {
    return HostProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      hostname: hostname ?? this.hostname,
      port: port ?? this.port,
      username: username ?? this.username,
      useKey: useKey ?? this.useKey,
      secret: secret ?? this.secret,
      notes: clearNotes ? null : (notes ?? this.notes),
      lastConnected: lastConnected ?? this.lastConnected,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'hostname': hostname,
        'port': port,
        'username': username,
        'useKey': useKey,
        'secret': secret,
        'notes': notes,
        'lastConnected': lastConnected,
      };

  static HostProfile? fromJson(Map<String, dynamic> j) {
    try {
      return HostProfile(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        hostname: (j['hostname'] ?? '').toString(),
        port: (j['port'] is int) ? j['port'] : int.tryParse('${j['port']}') ?? 22,
        username: (j['username'] ?? '').toString(),
        useKey: j['useKey'] == true,
        secret: (j['secret'] ?? '').toString(),
        notes: j['notes']?.toString(),
        lastConnected: j['lastConnected'] is int ? j['lastConnected'] : null,
      );
    } catch (_) {
      return null;
    }
  }
}
