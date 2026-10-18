import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AppPreferences {
  AppPreferences({File? file}) : _fileOverride = file;

  final File? _fileOverride;
  Future<void> _pending = Future.value();
  static int _temporarySequence = 0;

  bool dark = true;
  String freerdpPath = '';
  final Map<String, String> lastUsed = {};

  Future<File> get _file async =>
      _fileOverride ??
      File('${(await getApplicationSupportDirectory()).path}/preferences.json');

  Future<void> load() async {
    await _pending;
    final file = await _file;
    if (!await file.exists()) return;
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    dark = data['dark'] as bool? ?? true;
    freerdpPath = data['freerdpPath'] as String? ?? '';
    lastUsed
      ..clear()
      ..addAll(Map<String, String>.from(data['lastUsed'] as Map? ?? {}));
  }

  Future<void> save() {
    // Capture before awaiting: later toggles must not change an earlier save.
    final snapshot = jsonEncode({
      'dark': dark,
      'freerdpPath': freerdpPath,
      'lastUsed': lastUsed,
    });
    final result = _pending.then((_) async {
      final file = await _file;
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.${pid}_${_temporarySequence++}.tmp');
      try {
        await temp.create(exclusive: true);
        await temp.writeAsString(snapshot, flush: true);
        await temp.rename(file.path);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    });
    // A failed write is still reported to its caller and permits later retries.
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
