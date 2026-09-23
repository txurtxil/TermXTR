import 'dart:convert';

/// Configuración de un host SSH/SFTP (favorito).
class HostConfig {
  final String id;
  final String name;
  final String host;
  final int port;
  final String user;
  final String? password;
  final bool useSshKey;
  final bool favorite;

  HostConfig({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.user,
    this.password,
    this.useSshKey = false,
    this.favorite = false,
  });

  factory HostConfig.fromJson(Map<String, dynamic> json) => HostConfig(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? 'host',
    host: json['host'] as String? ?? 'localhost',
    port: json['port'] as int? ?? 22,
    user: json['user'] as String? ?? 'root',
    password: json['password'] as String?,
    useSshKey: json['useSshKey'] as bool? ?? false,
    favorite: json['favorite'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'user': user,
    'password': password,
    'useSshKey': useSshKey,
    'favorite': favorite,
  };

  String get displayName => ' (@)';
}
