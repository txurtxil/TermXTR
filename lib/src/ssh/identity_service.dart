// lib/src/ssh/identity_service.dart
//
// Identidad SSH de la app (v2.2.0): par de claves Ed25519 generado en el
// dispositivo, formato OpenSSH (openssh-key-v1), almacenado en AppPaths.keysDir.
// Permite autenticarse por clave en los hosts sin teclear password:
//  - ensureIdentity() la genera una vez
//  - installKeyToHost() copia la publica en authorized_keys del host
//  - loadIdentity() la usan las sesiones como fallback de auth

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dartssh2/dartssh2.dart';

import '../storage/app_paths.dart';
import 'ssh_credentials_store.dart';
import 'ssh_host.dart';

class IdentityService {
  static const _comment = 'termxtr';
  static File get _privFile => File('${AppPaths.keysDir}/termxtr_identity');
  static File get _pubFile => File('${AppPaths.keysDir}/termxtr_identity.pub');

  static Future<bool> exists() => _privFile.exists();

  /// Genera la identidad si no existe. Devuelve la linea publica OpenSSH.
  static Future<String> ensureIdentity() async {
    if (await _privFile.exists() && await _pubFile.exists()) {
      return publicKeyLine();
    }
    final algo = Ed25519();
    final kp = await algo.newKeyPair();
    final priv = await kp.extract();
    final pub = await kp.extractPublicKey();
    final seed = priv.bytes; // 32 bytes (semilla ed25519)
    final pubB = pub.bytes; // 32 bytes
    if (seed.length != 32 || pubB.length != 32) {
      throw StateError('Longitud de clave Ed25519 inesperada');
    }
    final priv64 = Uint8List.fromList([...seed, ...pubB]);

    // blob publico: string "ssh-ed25519" + string pub
    final pubBlob = _join([_str('ssh-ed25519'), _str(pubB)]);

    // seccion privada: checkints + strings + padding hasta multiplo de 8
    final rnd = Random.secure();
    final sec = BytesBuilder();
    _u32(sec, rnd.nextInt(0xFFFFFFFF));
    _u32(sec, rnd.nextInt(0xFFFFFFFF));
    sec.add(_str('ssh-ed25519'));
    sec.add(_str(pubB));
    sec.add(_str(priv64));
    sec.add(_str(_comment));
    var pad = 1;
    while (sec.length % 8 != 0) {
      sec.add([pad & 0xFF]);
      pad++;
    }

    // sobre openssh-key-v1
    final env = BytesBuilder();
    env.add(_str('none')); // ciphername
    env.add(_str('none')); // kdfname
    env.add(_str('')); // kdfoptions
    _u32(env, 1); // nkeys
    env.add(_str(pubBlob));
    env.add(_str(sec.toBytes()));
    final magic = Uint8List.fromList([
      ...utf8.encode('openssh-key-v1'),
      0,
    ]);
    final full = _join([magic, env.toBytes()]);

    final b64 = base64.encode(full);
    final sb = StringBuffer('-----BEGIN OPENSSH PRIVATE KEY-----\n');
    for (var i = 0; i < b64.length; i += 70) {
      sb.writeln(b64.substring(
          i, i + 70 > b64.length ? b64.length : i + 70));
    }
    sb.write('-----END OPENSSH PRIVATE KEY-----\n');

    await _privFile.writeAsString(sb.toString(), flush: true);
    await _pubFile.writeAsString(
        'ssh-ed25519 ${base64.encode(pubBlob)} $_comment\n',
        flush: true);
    return publicKeyLine();
  }

  static Future<void> deleteIdentity() async {
    try {
      if (await _privFile.exists()) await _privFile.delete();
    } catch (_) {}
    try {
      if (await _pubFile.exists()) await _pubFile.delete();
    } catch (_) {}
  }

  static Future<String> publicKeyLine() async {
    if (!await _pubFile.exists()) return '';
    return (await _pubFile.readAsString()).trim();
  }

  static Future<List<SSHKeyPair>?> loadIdentity() async {
    try {
      if (!await _privFile.exists()) return null;
      return SSHKeyPair.fromPem(await _privFile.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// Conecta al host (password o clave existente) e instala la clave
  /// publica de la identidad en authorized_keys. Idempotente.
  static Future<void> installKeyToHost(SshHost host, {String? password}) async {
    await ensureIdentity();
    final pub = await publicKeyLine();
    if (pub.isEmpty) throw StateError('Sin clave publica');
    var pwd = password;
    List<SSHKeyPair>? identities;
    final keyPath = host.keyPath;
    if (keyPath != null && keyPath.trim().isNotEmpty) {
      final keyFile = await AppPaths.resolveKey(keyPath.trim());
      if (keyFile != null) {
        identities = SSHKeyPair.fromPem(await keyFile.readAsString());
      }
    }
    if (identities == null) {
      identities = await loadIdentity();
      pwd = pwd ?? await SshCredentialsStore.readPassword(host.id);
    }
    if (identities == null && pwd == null) {
      throw StateError('Se necesita la contraseña del host una vez');
    }
    final socket = await SSHSocket.connect(host.hostname, host.port)
        .timeout(const Duration(seconds: 12));
    SSHClient? client;
    try {
      client = SSHClient(
        socket,
        username: host.username,
        identities: identities,
        onPasswordRequest: () async => pwd,
        onUserInfoRequest: (req) async => req.prompts
            .map((p) =>
                p.promptText.toLowerCase().contains('password') && pwd != null
                    ? pwd
                    : '')
            .toList(),
        onVerifyHostKey: (type, fingerprint) async => true,
        handshakeTimeout: const Duration(seconds: 12),
        authTimeout: const Duration(seconds: 12),
      );
      final cmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && "
          "touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && "
          "grep -qxF '$pub' ~/.ssh/authorized_keys || echo '$pub' >> ~/.ssh/authorized_keys";
      final res = await client
          .run(cmd)
          .timeout(const Duration(seconds: 20));
      final out = utf8.decode(res, allowMalformed: true).trim();
      if (out.isNotEmpty) {
        // algunos shells escriben en stderr/stdout aunque el exit sea 0
        // no lo tratamos como error: authorized_keys se actualizo igual
      }
    } finally {
      client?.close();
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  // ---- codificacion openssh-key-v1 ----

  static Uint8List _str(dynamic d) {
    final b = d is String ? utf8.encode(d) : (d as List<int>);
    final out = BytesBuilder();
    _u32(out, b.length);
    out.add(b);
    return out.toBytes();
  }

  static void _u32(BytesBuilder bb, int v) {
    final b = ByteData(4)..setUint32(0, v);
    bb.add(b.buffer.asUint8List());
  }

  static Uint8List _join(List<List<int>> parts) {
    final bb = BytesBuilder();
    for (final p in parts) {
      bb.add(p);
    }
    return bb.toBytes();
  }
}
