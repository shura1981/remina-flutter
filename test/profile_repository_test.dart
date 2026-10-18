import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remina/models/remmina_profile.dart';
import 'package:remina/services/profile_repository.dart';

void main() {
  late Directory temporary;
  late ProfileRepository repository;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('remina_profiles_test_');
    repository = ProfileRepository(Directory('${temporary.path}/store'));
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  test('imports copies, deduplicates contents and keeps source intact', () async {
    const content =
        '[remmina]\nname=Office\nserver=example.invalid\npassword=.\n[plugin]\ncustom=keep\n';
    final source = await File('${temporary.path}/original.remmina')
        .writeAsString(content);
    final duplicate = await File('${temporary.path}/duplicate.remmina')
        .writeAsString(content);
    final profiles = await repository.importFiles([source, duplicate]);
    expect(profiles, hasLength(1));
    expect(profiles.single.sourcePath, isNot(source.path));
    expect(await repository.importFiles([source]), hasLength(1));
    expect(await repository.load(), hasLength(1));
    await repository.save(
      profiles.single.copyWith(
        values: {...profiles.single.values, 'name': 'Edited'},
      ),
    );
    expect((await repository.load()).single.name, 'Edited');
    expect(await source.readAsString(), content);
    await repository.delete(profiles.single);
    expect(await repository.load(), isEmpty);
    expect(await source.readAsString(), content);
  });

  test('validates a complete import before writing files', () async {
    final good = await File('${temporary.path}/good.remmina')
        .writeAsString('[remmina]\nname=Good\n');
    final bad = await File('${temporary.path}/bad.remmina')
        .writeAsString('not a key file');
    await expectLater(
      repository.importFiles([good, bad]),
      throwsFormatException,
    );
    expect(await repository.load(), isEmpty);
  });

  test(
    'writes atomically with no temporary residue and restricts permissions',
    () async {
      await repository.save(RemminaProfile(id: 'a', values: {'name': 'First'}));
      await Future.wait([
        repository.save(RemminaProfile(id: 'a', values: {'name': 'Second'})),
        repository.save(RemminaProfile(id: 'a', values: {'name': 'Third'})),
      ]);
      expect((await repository.load()).single.name, 'Third');
      expect(await repository.directory.list().toList(), hasLength(1));
      if (Platform.isLinux || Platform.isMacOS) {
        final stat = await File('${repository.directory.path}/a.remmina')
            .stat();
        expect(stat.mode & 0x1ff, 0x180); // 0600
      }
    },
  );

  test(
    'rejects new secrets and path traversal without poisoning later saves',
    () async {
      await expectLater(
        repository.save(
          RemminaProfile(id: 'bad', values: {'password': 'secret'}),
        ),
        throwsFormatException,
      );
      await expectLater(
        repository.save(
          RemminaProfile(id: '../outside', values: {'name': 'Bad'}),
        ),
        throwsFormatException,
      );
      await repository.save(
        RemminaProfile(id: 'valid', values: {'name': 'Valid', 'password': '.'}),
      );
      expect((await repository.load()).single.name, 'Valid');
    },
  );

  test('allows disablepasswordstoring while rejecting new passwords', () async {
    await repository.save(
      RemminaProfile(
        id: 'no_stored_password',
        values: {'name': 'Synthetic', 'disablepasswordstoring': '1'},
      ),
    );
    expect((await repository.load()).single.get('disablepasswordstoring'), '1');
    await expectLater(
      repository.save(
        RemminaProfile(
          id: 'no_stored_password',
          values: {
            'name': 'Synthetic',
            'disablepasswordstoring': '1',
            'password': 'new-plaintext-secret',
          },
        ),
      ),
      throwsFormatException,
    );
    expect((await repository.load()).single.get('password'), isEmpty);
  });

  test(
    'export preserves compatibility and refuses overwriting original source',
    () async {
      final source = await File('${temporary.path}/source.remmina')
          .writeAsString('[remmina]\nname=Office\n');
      final profile = RemminaProfile.parse(
        await source.readAsString(),
        id: 'a',
        sourcePath: source.path,
      );
      await expectLater(
        repository.exportProfile(profile, source),
        throwsA(isA<FileSystemException>()),
      );
      final exported = File('${temporary.path}/export.remmina');
      await repository.exportProfile(profile, exported);
      expect(await exported.readAsString(), await source.readAsString());
    },
  );
}
