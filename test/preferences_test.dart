import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remina/services/preferences.dart';

void main() {
  late Directory temporary;
  late File file;
  late AppPreferences preferences;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'remina_preferences_test_',
    );
    file = File('${temporary.path}/preferences.json');
    preferences = AppPreferences(file: file);
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  test('captures a snapshot before subsequent UI mutations', () async {
    preferences
      ..dark = false
      ..freerdpPath = '/synthetic/first';
    preferences.lastUsed['profile'] = 'first';
    final pending = preferences.save();
    preferences
      ..dark = true
      ..freerdpPath = '/synthetic/second';
    preferences.lastUsed['profile'] = 'second';
    await pending;
    expect(jsonDecode(await file.readAsString()), {
      'dark': false,
      'freerdpPath': '/synthetic/first',
      'lastUsed': {'profile': 'first'},
    });
  });

  test(
    'serializes rapid saves and persists the last requested state',
    () async {
      final saves = <Future<void>>[];
      for (var i = 0; i < 25; i++) {
        preferences
          ..dark = i.isEven
          ..freerdpPath = '/synthetic/$i';
        preferences.lastUsed['profile'] = '$i';
        saves.add(preferences.save());
      }
      await Future.wait(saves);
      expect(jsonDecode(await file.readAsString()), {
        'dark': true,
        'freerdpPath': '/synthetic/24',
        'lastUsed': {'profile': '24'},
      });
      expect(await temporary.list().toList(), hasLength(1));
    },
  );

  test('a failed write permits a later retry', () async {
    final blocker = await File('${temporary.path}/blocked')
        .writeAsString('block');
    final retryFile = File('${blocker.path}/preferences.json');
    final retryPreferences = AppPreferences(file: retryFile);
    await expectLater(
      retryPreferences.save(),
      throwsA(isA<FileSystemException>()),
    );
    await blocker.delete();
    retryPreferences.dark = false;
    await retryPreferences.save();
    expect(
      (jsonDecode(await retryFile.readAsString()) as Map)['dark'],
      isFalse,
    );
  });

  test(
    'load waits for writes and replaces stale in-memory recent entries',
    () async {
      preferences.lastUsed['current'] = '2026-01-01';
      final save = preferences.save();
      preferences.lastUsed['stale'] = '2020-01-01';
      await preferences.load();
      await save;
      expect(preferences.lastUsed, {'current': '2026-01-01'});
      final reloaded = AppPreferences(file: file);
      await reloaded.load();
      expect(reloaded.lastUsed, preferences.lastUsed);
      expect(reloaded.dark, preferences.dark);
    },
  );
}
