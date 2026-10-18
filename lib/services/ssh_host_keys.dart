import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// A changed host identity must be investigated outside the connection dialog.
class SshHostKeyChanged implements Exception {
  const SshHostKeyChanged();
}

/// Trust on first use. Only public host fingerprints are stored here.
class SshHostKeyStore {
  SshHostKeyStore(this.file);

  final File file;
  static final Map<String, Future<void>> _pending = {};

  static Future<SshHostKeyStore> applicationStore() async {
    final directory = await getApplicationSupportDirectory();
    return SshHostKeyStore(File('${directory.path}/ssh_host_keys.json'));
  }

  /// Serializes the read, prompt and write across simultaneous connections.
  Future<bool> verify({
    required String host,
    required int port,
    required String type,
    required String fingerprint,
    required Future<bool> Function() confirm,
  }) async {
    final path = file.absolute.path;
    final previous = _pending[path] ?? Future<void>.value();
    final complete = Completer<void>();
    _pending[path] = complete.future;
    await previous;
    try {
      final records = await _read();
      final key = '[${host.toLowerCase()}]:$port';
      final expected = records[key];
      if (expected != null) {
        if (expected['type'] != type ||
            expected['fingerprint'] != fingerprint) {
          throw const SshHostKeyChanged();
        }
        return true;
      }
      if (!await confirm()) return false;
      records[key] = {'type': type, 'fingerprint': fingerprint};
      await file.parent.create(recursive: true);
      final temporary = File('$path.tmp');
      await temporary.writeAsString(jsonEncode(records), flush: true);
      await temporary.rename(path);
      return true;
    } finally {
      complete.complete();
      if (identical(_pending[path], complete.future)) _pending.remove(path);
    }
  }

  Future<Map<String, dynamic>> _read() async {
    if (!await file.exists()) return {};
    final content = jsonDecode(await file.readAsString());
    if (content is! Map<String, dynamic>) {
      throw const FormatException('Invalid SSH host key store');
    }
    for (final entry in content.values) {
      if (entry is! Map<String, dynamic> ||
          entry['type'] is! String ||
          entry['fingerprint'] is! String) {
        throw const FormatException('Invalid SSH host key entry');
      }
    }
    return content;
  }
}
