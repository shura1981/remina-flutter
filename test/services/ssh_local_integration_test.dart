import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remina/models/remmina_profile.dart';
import 'package:remina/sessions/ssh_session.dart';
import 'package:xterm/xterm.dart';

/// Opt in with REMINA_SSH_FIXTURE_PYTHON=/tmp/venv/bin/python where Paramiko is
/// installed. This opens an ephemeral port bound exclusively to 127.0.0.1.
void main() {
  final interpreter = Platform.environment['REMINA_SSH_FIXTURE_PYTHON'];

  testWidgets('local SSH handshake, trust, PTY, input, resize and disposal', (
    tester,
  ) async {
    late Process fixture;
    late Directory directory;
    late StreamIterator<String> events;
    late int port;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('remina_ssh_e2e_');
      fixture = await Process.start(interpreter!, [
        'test/fixtures/ssh_echo_server.py',
      ]);
      events = StreamIterator(
        fixture.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      await events.moveNext().timeout(const Duration(seconds: 10));
      port =
          (jsonDecode(events.current) as Map<String, dynamic>)['port'] as int;
    });
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => directory.path,
    );
    addTearDown(() async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
      fixture.kill();
      await fixture.exitCode;
      await events.cancel();
      await directory.delete(recursive: true);
    });

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 200; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (condition()) return;
      }
      fail('Local SSH fixture did not reach expected state.');
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SshSessionView(
            profile: RemminaProfile(
              id: 'local-fixture',
              values: {
                'name': 'Loopback fixture',
                'protocol': 'SSH',
                'server': '127.0.0.1:$port',
                'username': 'fixture',
              },
            ),
            password: 'fixture-password',
          ),
        ),
      ),
    );
    await until(() => find.text('Primera conexión SSH').evaluate().isNotEmpty);
    expect(find.textContaining('SHA256:'), findsOneWidget);
    await tester.tap(find.text('Confiar y conectar'));
    await until(() => find.textContaining('· Conectado').evaluate().isNotEmpty);
    final terminal = tester
        .widget<TerminalView>(find.byType(TerminalView))
        .terminal;
    await until(() => terminal.buffer.getText().contains('fixture-ready'));
    expect(
      await tester.runAsync(
        () => File('${directory.path}/ssh_host_keys.json').exists(),
      ),
      isTrue,
    );

    terminal.textInput('probe\r');
    await until(() => terminal.buffer.getText().contains('fixture-echo:probe'));
    terminal.resize(100, 40);
    await until(
      () => terminal.buffer.getText().contains('fixture-size=100x40'),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      expect(
        await events.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(jsonDecode(events.current)['disconnected'], isTrue);
    });
    expect(tester.takeException(), isNull);

    // A second connection reuses the saved host identity and tests the actual
    // keyboard-interactive dialog through its exit animation.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SshSessionView(
            profile: RemminaProfile(
              id: 'interactive-fixture',
              values: {
                'name': 'MFA fixture',
                'protocol': 'SSH',
                'server': '127.0.0.1:$port',
                'username': 'interactive',
              },
            ),
            password: '',
          ),
        ),
      ),
    );
    await until(() => find.text('Autenticación SSH').evaluate().isNotEmpty);
    expect(find.text('Primera conexión SSH'), findsNothing);
    final passwordField = tester.widget<TextField>(find.byType(TextField));
    expect(passwordField.obscureText, isTrue);
    await tester.enterText(find.byType(TextField), 'fixture-password');
    await tester.tap(find.text('Continuar'));
    await until(() => find.textContaining('· Conectado').evaluate().isNotEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      expect(
        await events.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(jsonDecode(events.current)['disconnected'], isTrue);
    });
    expect(tester.takeException(), isNull);

    // Closing just the session while its trust route is open must remove that
    // route and close the socket, without recording an unconfirmed host key.
    await tester.runAsync(
      () => File('${directory.path}/ssh_host_keys.json').delete(),
    );
    final visible = ValueNotifier(true);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (context, show, child) => Scaffold(
            body: show
                ? SshSessionView(
                    profile: RemminaProfile(
                      id: 'cancelled-fixture',
                      values: {
                        'server': '127.0.0.1:$port',
                        'username': 'fixture',
                      },
                    ),
                    password: 'fixture-password',
                  )
                : const SizedBox(),
          ),
        ),
      ),
    );
    await until(() => find.text('Primera conexión SSH').evaluate().isNotEmpty);
    visible.value = false;
    await tester.pump();
    await until(() => find.text('Primera conexión SSH').evaluate().isEmpty);
    await tester.runAsync(() async {
      expect(
        await events.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(jsonDecode(events.current)['disconnected'], isTrue);
      expect(
        await File('${directory.path}/ssh_host_keys.json').exists(),
        isFalse,
      );
    });
    await tester.pumpWidget(const SizedBox());
    visible.dispose();
    expect(tester.takeException(), isNull);
  }, skip: interpreter == null);
}
