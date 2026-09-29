// lib/src/sftp/sftp_service.dart
//
// Conexión SFTP real, vía dartssh2 — un camino de código TOTALMENTE
// DISTINTO al de SSH/terminal de esta noche. Aquello reutilizaba proot y el
// Pty; esto es una conexión TCP directa desde el propio proceso de la app,
// sin pasar por proot en absoluto. Por eso las rutas de clave (SshHost.keyPath,
// pensadas para el "ssh" de dentro del shell) hay que traducirlas al disco
// real anteponiendo el rootfsPath.
//
// Verificación de host key: propia, en JSON, independiente del
// known_hosts real de OpenSSH (que usa la sesión ssh normal). Primera vez
// que se ve un host, se confía y se recuerda su huella; si cambia después,
// se avisa y se rechaza — mismo espíritu que accept-new en la CLI, pero
// aplicado a esta conexión aparte.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../ssh/ssh_host.dart';
import '../ssh/ssh_credentials_store.dart';

class SftpEntry {
  final String name;
  final bool isDirectory;
  final bool isSymlink;
  final int size;
  final DateTime? modified;

  SftpEntry({
    required this.name,
    required this.isDirectory,
    required this.isSymlink,
    required this.size,
    this.modified,
  });
}

class SftpService {
  static const String _knownHostsRel = '/ssh_known_hosts.json';
  static const String _downloadDirAbs = '/storage/emulated/0/Download/xtr_sftp';

  final SshHost host;
  final String rootfsPath;

  SSHClient? _client;
  SftpClient? _sftp;

  SftpService({required this.host, required this.rootfsPath});

  bool get isConnected => _sftp != null;

  Future<Map<String, String>> _loadKnownHosts() async {
    try {
      final f = File('$rootfsPath$_knownHostsRel');
      if (!await f.exists()) return {};
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return {};
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveKnownHosts(Map<String, String> hosts) async {
    try {
      final f = File('$rootfsPath$_knownHostsRel');
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(hosts));
    } catch (_) {}
  }

  /// [onPasswordRequest] se llama solo si el host no tiene clave configurada.
  /// [onHostKeyChanged] se llama si la huella guardada NO coincide con la
  /// que presenta el servidor ahora — señal de posible suplantación, o de
  /// que el servidor se reinstaló. Devuelve true para confiar de todos
  /// modos (y sobrescribir lo guardado).
  Future<void> connect({
    required Future<String> Function() onPasswordRequest,
    required Future<bool> Function(String fingerprint) onHostKeyChanged,
  }) async {
    if (isConnected) return;

    final socket = await SSHSocket.connect(host.hostname, host.port)
        .timeout(const Duration(seconds: 12));

    List<SSHKeyPair>? identities;
    if (host.keyPath != null && host.keyPath!.trim().isNotEmpty) {
      // keyPath: '/keys/<nombre>' en el almacén de la app; tolerancia a
      // rutas legacy '/root/.ssh/<nombre>' (las migra AppPaths).
      var keyFile = File('$rootfsPath${host.keyPath}');
      if (!await keyFile.exists() && host.keyPath!.startsWith('/root/.ssh/')) {
        keyFile = File('$rootfsPath/keys/${host.keyPath!.split('/').last}');
      }
      if (await keyFile.exists()) {
        identities = SSHKeyPair.fromPem(await keyFile.readAsString());
      }
    }

    final knownHosts = await _loadKnownHosts();
    final hostKey = '${host.hostname}:${host.port}';

    _client = SSHClient(
      socket,
      username: host.username,
      identities: identities,
      onPasswordRequest: identities == null
          ? () async {
              final saved = await SshCredentialsStore.readPassword(host.id);
              if (saved != null && saved.isNotEmpty) return saved;
              return onPasswordRequest();
            }
          : null,
      handshakeTimeout: const Duration(seconds: 15),
      authTimeout: const Duration(seconds: 15),
      onVerifyHostKey: (type, fingerprintBytes) async {
        final fingerprint = '$type:${base64.encode(fingerprintBytes)}';
        final saved = knownHosts[hostKey];
        if (saved == null) {
          knownHosts[hostKey] = fingerprint;
          await _saveKnownHosts(knownHosts);
          return true;
        }
        if (saved == fingerprint) return true;
        final trustAnyway = await onHostKeyChanged(fingerprint);
        if (trustAnyway) {
          knownHosts[hostKey] = fingerprint;
          await _saveKnownHosts(knownHosts);
        }
        return trustAnyway;
      },
    );

    await _client!.authenticated;
    _sftp = await _client!.sftp();
  }

  Future<List<SftpEntry>> list(String path) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('No conectado');
    final items = await sftp.listdir(path);
    return items
        .where((i) => i.filename != '.' && i.filename != '..')
        .map((i) => SftpEntry(
              name: i.filename,
              isDirectory: i.attr.isDirectory,
              isSymlink: i.attr.isSymbolicLink,
              size: i.attr.size ?? 0,
              modified: i.attr.modifyTime != null
                  ? DateTime.fromMillisecondsSinceEpoch(i.attr.modifyTime! * 1000)
                  : null,
            ))
        .toList()
      ..sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  }

  /// Descarga a Descargas/xtr_sftp/<host>/<ruta>. Devuelve la ruta local
  /// final. [onProgress] recibe bytes descargados hasta ahora.
  Future<String> download(String remotePath, {void Function(int bytes)? onProgress}) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('No conectado');

    final safeHost = host.name.replaceAll(RegExp(r'[^\w\-]'), '_');
    final fileName = remotePath.split('/').last;
    final dir = Directory('$_downloadDirAbs/$safeHost');
    await dir.create(recursive: true);
    final localPath = '${dir.path}/$fileName';

    final sink = File(localPath).openWrite();
    await sftp.download(remotePath, sink, onProgress: onProgress, closeDestination: true);
    return localPath;
  }

  /// Sube un fichero local al directorio remoto actual. [onProgress] recibe
  /// bytes enviados hasta ahora -- dartssh2 no da el total en el propio
  /// callback, asi que el porcentaje (si se quiere mostrar) hay que
  /// calcularlo fuera comparando con el tamano local ya conocido.
  Future<void> upload(String localPath, String remotePath, {void Function(int bytes)? onProgress}) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('No conectado');

    final localFile = File(localPath);
    if (!await localFile.exists()) {
      throw StateError('El fichero local ya no existe: $localPath');
    }

    // create: por si no existe. truncate: por si ya existe, para no dejar
    // basura del fichero viejo si el nuevo es mas corto.
    final remoteFile = await sftp.open(
      remotePath,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.truncate | SftpFileOpenMode.write,
    );

    try {
      var sent = 0;
      final stream = localFile.openRead().map((chunk) {
        sent += chunk.length;
        onProgress?.call(sent);
        return chunk;
      });
      final uploader = remoteFile.write(stream.cast());
      await uploader.done;
    } finally {
      await remoteFile.close();
    }
  }

  /// Borra un fichero, o una carpeta y TODO su contenido. rmdir() en SFTP
  /// (igual que en cualquier sistema de ficheros POSIX) solo funciona con
  /// carpetas vacias -- por eso hay que vaciarla primero, de dentro hacia
  /// fuera, antes de poder borrar la carpeta en si. [onProgress] recibe el
  /// numero de elementos ya borrados, util para carpetas grandes.
  Future<void> deleteRecursive(String remotePath, {required bool isDirectory, void Function(int count)? onProgress}) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('No conectado');

    var count = 0;
    Future<void> walk(String path, bool isDir) async {
      if (!isDir) {
        await sftp.remove(path);
        count++;
        onProgress?.call(count);
        return;
      }
      final items = await sftp.listdir(path);
      for (final item in items) {
        if (item.filename == '.' || item.filename == '..') continue;
        await walk('$path/${item.filename}', item.attr.isDirectory);
      }
      await sftp.rmdir(path);
      count++;
      onProgress?.call(count);
    }

    await walk(remotePath, isDirectory);
  }

  /// Renombra (o mueve dentro del mismo árbol) un fichero o carpeta.
  Future<void> rename(String oldPath, String newPath) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('No conectado');
    await sftp.rename(oldPath, newPath);
  }

  /// Lee un fichero remoto COMPLETO a memoria. Pensado para el editor de
  /// texto; no usar con ficheros grandes. Mismo camino que download() pero
  /// con un sink en memoria en lugar de un fichero local.
  Future<Uint8List> readFile(String remotePath) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('No conectado');
    final controller = StreamController<List<int>>();
    final builder = BytesBuilder();
    final done = controller.stream.forEach(builder.add);
    await sftp.download(remotePath, controller.sink, closeDestination: true);
    await done;
    return builder.takeBytes();
  }

  /// Sobrescribe un fichero remoto con [bytes], truncando lo que hubiera.
  /// Es el guardado del editor de texto.
  Future<void> writeFile(String remotePath, Uint8List bytes) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('No conectado');
    final remoteFile = await sftp.open(
      remotePath,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.truncate | SftpFileOpenMode.write,
    );
    try {
      final uploader = remoteFile.write(Stream<Uint8List>.value(bytes));
      await uploader.done;
    } finally {
      await remoteFile.close();
    }
  }

  /// Descarga una CARPETA entera replicando su estructura en
  /// Descargas/xtr_sftp/<host>/<ruta>. [onProgress] recibe el número de
  /// ficheros ya descargados (las carpetas vacías no cuentan).
  Future<int> downloadFolder(String remotePath, {void Function(int files)? onProgress}) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('No conectado');

    final safeHost = host.name.replaceAll(RegExp(r'[^\w\-]'), '_');
    final baseLocal = '$_downloadDirAbs/$safeHost';
    var files = 0;

    Future<void> walk(String remote, String local) async {
      final items = await sftp.listdir(remote);
      await Directory(local).create(recursive: true);
      for (final item in items) {
        if (item.filename == '.' || item.filename == '..') continue;
        final r = '$remote/${item.filename}';
        final l = '$local/${item.filename}';
        if (item.attr.isDirectory) {
          await walk(r, l);
        } else {
          final sink = File(l).openWrite();
          await sftp.download(r, sink, closeDestination: true);
          files++;
          onProgress?.call(files);
        }
      }
    }

    await walk(remotePath, '$baseLocal$remotePath');
    return files;
  }

  /// Sube una CARPETA local entera replicando su estructura: el contenido
  /// de [localDirPath] queda en <remoteDir>/<nombreCarpeta>. [onProgress]
  /// recibe el número de ficheros ya subidos. Simétrica de downloadFolder.
  Future<int> uploadFolder(String localDirPath, String remoteDir, {void Function(int files)? onProgress}) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('No conectado');

    var files = 0;
    Future<void> walk(Directory dir, String remote) async {
      // La carpeta remota puede existir ya: mkdir falla y no pasa nada.
      try {
        await sftp.mkdir(remote);
      } catch (_) {}
      await for (final e in dir.list()) {
        final name = e.path.split('/').last;
        if (e is Directory) {
          await walk(e, '$remote/$name');
        } else if (e is File) {
          await upload(e.path, '$remote/$name');
          files++;
          onProgress?.call(files);
        }
      }
    }

    final name = localDirPath.split('/').last;
    final base = remoteDir == '.' ? name : '$remoteDir/$name';
    await walk(Directory(localDirPath), base);
    return files;
  }

  /// Espacio del filesystem remoto que contiene [path]: (total, libre para
  /// un usuario normal) en bytes. Usa la extensión statvfs@openssh.com; si
  /// el servidor no la soporta lanza SftpExtensionError y la UI lo muestra.
  Future<(int total, int free)> statVfs(String path) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('No conectado');
    final st = await sftp.statvfs(path);
    final bs = st.fundamentalBlockSize;
    return (bs * st.totalBlocks, bs * st.freeBlocksForNonRoot);
  }

  Future<void> mkdir(String remotePath) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('No conectado');
    await sftp.mkdir(remotePath);
  }

  Future<void> close() async {
    try {
      _client?.close();
      await _client?.done;
    } catch (_) {}
    _client = null;
    _sftp = null;
  }
}
