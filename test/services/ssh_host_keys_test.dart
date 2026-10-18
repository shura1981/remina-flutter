import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remina/services/ssh_host_keys.dart';

void main() {
  late Directory directory;
  late SshHostKeyStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('remina_host_keys_');
    store = SshHostKeyStore(File('${directory.path}/known.json'));
  });

  tearDown(() async => directory.delete(recursive: true));

  Future<bool> verify(
    String fingerprint, {
    bool accepted = true,
    int port = 22,
  }) {
    return store.verify(
      host: 'example.test',
      port: port,
      type: 'ssh-ed25519',
      fingerprint: fingerprint,
      confirm: () async => accepted,
    );
  }

  test('remembered fingerprints need no second prompt', () async {
    expect(await verify('SHA256:one'), isTrue);
    final reopened = SshHostKeyStore(store.file);
    expect(
      await reopened.verify(
        host: 'EXAMPLE.test',
        port: 22,
        type: 'ssh-ed25519',
        fingerprint: 'SHA256:one',
        confirm: () async => throw StateError('Unexpected trust prompt'),
      ),
      isTrue,
    );
  });

  test('changed identity is rejected without replacing trusted key', () async {
    await verify('SHA256:original');
    await expectLater(
      verify('SHA256:changed'),
      throwsA(isA<SshHostKeyChanged>()),
    );
    expect(await verify('SHA256:original'), isTrue);
  });

  test('rejection does not remember the unknown host', () async {
    expect(await verify('SHA256:one', accepted: false), isFalse);
    expect(await store.file.exists(), isFalse);
  });

  test('distinct ports retain independent identities', () async {
    expect(await verify('SHA256:one'), isTrue);
    expect(await verify('SHA256:two', port: 2222), isTrue);
    expect(await verify('SHA256:one'), isTrue);
  });

  test(
    'simultaneous sessions cannot replace a newly trusted identity',
    () async {
      final results = await Future.wait([
        verify('SHA256:one'),
        verify('SHA256:one'),
      ]);
      expect(results, [true, true]);
      await expectLater(
        verify('SHA256:two'),
        throwsA(isA<SshHostKeyChanged>()),
      );
    },
  );

  test('corrupt host database fails closed', () async {
    await store.file.writeAsString('{not json');
    await expectLater(verify('SHA256:one'), throwsFormatException);
    expect(await store.file.readAsString(), '{not json');
  });
}
