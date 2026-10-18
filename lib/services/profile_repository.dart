import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import '../models/remmina_profile.dart';

/// Stores application-owned copies only; source Remmina files are never edited.
class ProfileRepository {
  ProfileRepository(this.directory);

  final Directory directory;
  Future<void> _pending = Future.value();

  static Future<ProfileRepository> open() async {
    final support = await getApplicationSupportDirectory();
    final repository = ProfileRepository(Directory('${support.path}/profiles'));
    await repository.directory.create(recursive: true);
    return repository;
  }

  Future<List<RemminaProfile>> load() async {
    await _pending;
    await directory.create(recursive: true);
    final profiles = <RemminaProfile>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.remmina')) continue;
      final filename = entity.uri.pathSegments.last;
      profiles.add(
        RemminaProfile.parse(
          await entity.readAsString(),
          id: filename.substring(0, filename.length - '.remmina'.length),
          sourcePath: entity.path,
        ),
      );
    }
    profiles.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return profiles;
  }

  Future<void> save(RemminaProfile profile) => _serial(() async {
    if (profile.hasNewStoredSecrets) {
      throw const FormatException(
        'Las contraseñas nuevas se solicitan al conectar; no se guardan en el perfil.',
      );
    }
    await _write(profile);
  });

  Future<void> delete(RemminaProfile profile) => _serial(() async {
    final file = _file(profile.id);
    if (await file.exists()) await file.delete();
  });

  Future<List<RemminaProfile>> importFiles(List<File> files) =>
      _serial(() async {
        await directory.create(recursive: true);
        final existing = <String, RemminaProfile>{};
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is File && entity.path.endsWith('.remmina')) {
            final content = await entity.readAsString();
            final filename = entity.uri.pathSegments.last;
            existing[content] = RemminaProfile.parse(
              content,
              id: filename.substring(0, filename.length - 8),
              sourcePath: entity.path,
            );
          }
        }
        // Validate the complete selection before writing any profile.
        final selected = <RemminaProfile>[];
        for (final file in files) {
          final content = await file.readAsString();
          final previous = existing[content];
          if (previous != null) {
            if (!selected.any((profile) => profile.id == previous.id)) {
              selected.add(previous);
            }
            continue;
          }
          final id = _newId();
          final profile = RemminaProfile.parse(
            content,
            id: id,
            sourcePath: _file(id).path,
          );
          existing[content] = profile;
          selected.add(profile);
        }
        for (final profile in selected) {
          if (!await _file(profile.id).exists()) await _write(profile);
        }
        return selected;
      });

  Future<void> exportProfile(RemminaProfile profile, File destination) async {
    if (profile.hasNewStoredSecrets) {
      throw const FormatException(
        'No se pueden exportar contraseñas nuevas en texto plano.',
      );
    }
    if (profile.sourcePath != null) {
      final source = File(profile.sourcePath!);
      final sourcePath = await source.exists()
          ? await source.resolveSymbolicLinks()
          : source.absolute.path;
      final destinationPath = await destination.exists()
          ? await destination.resolveSymbolicLinks()
          : destination.absolute.path;
      if (sourcePath == destinationPath) {
        throw const FileSystemException(
          'Elige otro archivo para conservar el original.',
        );
      }
    }
    await _atomicWrite(destination, profile.serialize());
  }

  Future<void> _write(RemminaProfile profile) async {
    await directory.create(recursive: true);
    await _atomicWrite(_file(profile.id), profile.serialize());
  }

  File _file(String id) {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      throw const FormatException('Identificador de perfil inválido.');
    }
    return File('${directory.path}/$id.remmina');
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32).toRadixString(16)}';

  static Future<void> _atomicWrite(File destination, String content) async {
    await destination.parent.create(recursive: true);
    final temporary = File('${destination.path}.${_newId()}.tmp');
    try {
      await temporary.create(exclusive: true);
      // Linux/macOS profile permissions also protect imported opaque secrets.
      if (Platform.isLinux || Platform.isMacOS) {
        final result = await Process.run('chmod', ['600', temporary.path]);
        if (result.exitCode != 0) {
          throw const FileSystemException(
            'No se pudieron proteger los permisos del perfil.',
          );
        }
      }
      await temporary.writeAsString(content, flush: true);
      await temporary.rename(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
