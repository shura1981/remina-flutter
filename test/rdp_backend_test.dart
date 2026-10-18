import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remina/models/remmina_profile.dart';
import 'package:remina/services/rdp_backend.dart';

RemminaProfile profile([Map<String, String> settings = const {}]) =>
    RemminaProfile(
      id: 'fixture',
      values: {
        'name': 'Synthetic connection',
        'protocol': 'RDP',
        'server': 'desktop.example.invalid:3390',
        'username': 'synthetic-user',
        ...settings,
      },
    );

void main() {
  group('bundled engine discovery', () {
    test(
      'missing bundle asks for a complete app, never a separate install',
      () {
        for (final system in ['linux', 'macos']) {
          final help = RdpBackend.installationHelp(operatingSystem: system);
          expect(help, contains('paquete completo'));
          expect(help, isNot(contains('brew')));
          expect(help, isNot(contains('apt-get')));
          expect(help, contains('todavía no se ha enviado'));
        }
      },
    );

    test('discovers a relocated bundled engine without PATH or HOME', () async {
      final temporary = await Directory.systemTemp.createTemp('remina bundle ');
      try {
        for (final system in ['linux', 'macos']) {
          final app = system == 'macos'
              ? '${temporary.path}/Remina.app/Contents/MacOS/Remina'
              : '${temporary.path}/linux/remina.bin';
          final directory = File(app).parent.path;
          final path = system == 'macos'
              ? '$directory/remina-rdp'
              : '$directory/rdp/bin/remina-rdp';
          final file = File(path);
          await file.parent.create(recursive: true);
          await file.writeAsString('#!/bin/sh\nexit 0\n');
          await Process.run('chmod', ['700', path]);
          expect(
            await RdpBackend.findExecutable(
              appExecutablePath: app,
              operatingSystem: system,
              environment: {'HOME': '/nonexistent', 'PATH': ''},
            ),
            path,
          );
          await Process.run('chmod', ['600', path]);
          expect(
            await RdpBackend.findExecutable(
              appExecutablePath: app,
              operatingSystem: system,
            ),
            isNull,
          );
        }
      } finally {
        await temporary.delete(recursive: true);
      }
    }, skip: !Platform.isLinux && !Platform.isMacOS);

    test(
      'never falls back to a host engine when the bundle is incomplete',
      () async {
        expect(
          await RdpBackend.findExecutable(
            appExecutablePath: '/nonexistent/remina',
            operatingSystem: 'linux',
            environment: {
              'HOME': Platform.environment['HOME'] ?? '',
              'PATH': Platform.environment['PATH'] ?? '',
            },
          ),
          isNull,
        );
      },
    );
  });

  group('Remmina to FreeRDP argument mapping', () {
    test('custom, client and initial resolutions remain distinct', () {
      final cases = {
        '0': '/size:1366x768',
        '1': '/size:100%',
        '2': '/size:90%',
      };
      for (final entry in cases.entries) {
        final arguments = RdpBackend.arguments(
          profile({
            'resolution_mode': entry.key,
            'resolution_width': '1366',
            'resolution_height': '768',
          }),
        );
        expect(arguments.where((arg) => arg.startsWith('/size:')), [
          entry.value,
        ]);
        expect(arguments, isNot(contains('+dynamic-resolution')));
      }
    });

    test('dynamic resize follows scale 2 independently of initial size', () {
      for (final resolution in ['0', '1', '2']) {
        for (final scale in ['0', '1', '2']) {
          final arguments = RdpBackend.arguments(
            profile({
              'resolution_mode': resolution,
              'resolution_width': '1280',
              'resolution_height': '720',
              'scale': scale,
            }),
          );
          expect(arguments.contains('+dynamic-resolution'), scale == '2');
        }
      }
    });

    test('invalid custom dimensions fall back to a usable window', () {
      for (final dimensions in [
        {'resolution_width': '0', 'resolution_height': '900'},
        {'resolution_width': '-1', 'resolution_height': '900'},
        {'resolution_width': '900', 'resolution_height': 'invalid'},
      ]) {
        final arguments = RdpBackend.arguments(
          profile({'resolution_mode': '0', ...dimensions}),
        );
        expect(arguments, contains('/size:90%'));
      }
    });

    test('gateway, desktop and device settings map without stored secrets', () {
      final arguments = RdpBackend.arguments(
        profile({
          'domain': 'DESKTOP-DOMAIN',
          'gateway_server': 'gateway.example.invalid:443',
          'gateway_username': 'gateway-user',
          'gateway_domain': 'GATEWAY-DOMAIN',
          'password': 'opaque-desktop-secret',
          'gateway_password': 'opaque-gateway-secret',
          'ssh_tunnel_password': 'opaque-tunnel-secret',
          'unknown_plugin_argument': '/p:do-not-forward',
          'cert_ignore': '1',
          'disableclipboard': '1',
          'security': 'nla',
          'colordepth': '32',
          'console': '1',
          'multimon': '1',
          'span': '1',
          'sound': 'remote',
          'shareprinter': '1',
          'sharefolder': '/tmp/synthetic share',
          'rdp_reconnect_attempts': '5',
        }),
      );
      expect(
        arguments,
        containsAll([
          '/d:DESKTOP-DOMAIN',
          '/g:gateway.example.invalid:443',
          '/gu:gateway-user',
          '/gd:GATEWAY-DOMAIN',
          '/from-stdin:force',
          '/cert:ignore',
          '-clipboard',
          '/sec:nla',
          '/bpp:32',
          '/admin',
          '/multimon',
          '/span',
          '/audio-mode:1',
          '/printer',
          '/drive:Compartido,/tmp/synthetic share',
          '/auto-reconnect-max-retries:5',
        ]),
      );
      final joined = arguments.join('\n');
      for (final forbidden in [
        'opaque-desktop-secret',
        'opaque-gateway-secret',
        'opaque-tunnel-secret',
        'do-not-forward',
      ]) {
        expect(joined, isNot(contains(forbidden)));
      }
      expect(
        arguments.any((arg) => RegExp(r'^/(p|gp|password):').hasMatch(arg)),
        isFalse,
      );
    });

    test('safe defaults include certificate verification and clipboard', () {
      final arguments = RdpBackend.arguments(profile());
      expect(
        arguments,
        containsAll([
          '/cert:deny',
          '+clipboard',
          '+auto-reconnect',
          '/audio-mode:2',
        ]),
      );
      final reconnectDisabled = RdpBackend.arguments(
        profile({'disableautoreconnect': '1', 'rdp_reconnect_attempts': '3'}),
      );
      expect(reconnectDisabled, contains('-auto-reconnect'));
      expect(
        reconnectDisabled.any(
          (arg) => arg.startsWith('/auto-reconnect-max-retries:'),
        ),
        isFalse,
      );
    });

    test('recognizes ignore-tls-errors from modern Remmina profiles', () {
      final arguments = RdpBackend.arguments(
        profile({'ignore-tls-errors': '1'}),
      );
      expect(arguments, contains('/cert:ignore'));
    });


    test(
      'gateway explicitly reuses desktop username when no gateway user is set',
      () {
        final arguments = RdpBackend.arguments(
          profile({'gateway_server': 'gateway.example.invalid'}),
        );
        expect(arguments, contains('/gu:synthetic-user'));
      },
    );

    test(
      'unsupported tunnels and hooks fail instead of silently connecting',
      () {
        for (final unsupported in [
          {'ssh_tunnel_enabled': '1'},
          {'precommand': 'synthetic-command'},
          {'postcommand': 'synthetic-command'},
        ]) {
          expect(
            () => RdpBackend.arguments(profile(unsupported)),
            throwsFormatException,
          );
        }
      },
    );

    test(
      'requires a server and username and rejects argument control characters',
      () {
        for (final bad in [
          {'server': ''},
          {'username': '  '},
          {'server': 'desktop\n/p:injection'},
          {'name': 'bad\rtitle'},
          {'domain': 'bad\x00domain'},
          {'gateway_server': 'bad\ngateway'},
          {'sharefolder': '/tmp/a,b'},
        ]) {
          expect(
            () => RdpBackend.arguments(profile(bad)),
            throwsFormatException,
          );
        }
      },
    );
  });

  group('real process credential transport', () {
    late Directory temporary;
    late File executable;

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp(
        'remina backend fixture ',
      );
      executable = File('${temporary.path}/synthetic freerdp');
      await executable.writeAsString('''#!/bin/sh
fixture_directory=\$(dirname "\$0")
printf '%s\\000' "\$@" > "\$fixture_directory/arguments.bin"
cat > "\$fixture_directory/stdin.bin"
printf 'fixture-completed'
''');
      final permissions = await Process.run('chmod', ['700', executable.path]);
      expect(permissions.exitCode, 0);
    });

    tearDown(() async {
      await temporary.delete(recursive: true);
    });

    Future<List<String>> readArguments() async {
      final raw = await File('${temporary.path}/arguments.bin').readAsString();
      final arguments = raw.split('\x00');
      expect(arguments.removeLast(), '');
      return arguments;
    }

    Future<String> finish(Process process) async {
      final output = process.stdout.transform(utf8.decoder).join();
      final errors = process.stderr.transform(utf8.decoder).join();
      expect(await process.exitCode, 0);
      expect(await errors, isEmpty);
      return output;
    }

    test(
      'passes credentials only through stdin and keeps shell syntax literal',
      () async {
        final marker = File('${temporary.path}/injected');
        final shellSyntax = '\$(touch "${marker.path}")';
        final connection = profile({
          'name': 'Synthetic $shellSyntax; exit 9',
          'server': 'desktop.example.invalid $shellSyntax',
          'password': 'opaque-profile-secret',
          'unknown_plugin_argument': '/p:unknown-secret',
        });
        final process = await RdpBackend.start(
          profile: connection,
          password: 'explicit desktop secret with spaces',
          executable: executable.path,
        );
        expect(await finish(process), 'fixture-completed');
        expect(await readArguments(), RdpBackend.arguments(connection));
        expect(
          await File('${temporary.path}/stdin.bin').readAsString(),
          'explicit desktop secret with spaces\n',
        );
        expect(await marker.exists(), isFalse);
        final argv = (await readArguments()).join('\n');
        expect(argv, isNot(contains('explicit desktop secret')));
        expect(argv, isNot(contains('opaque-profile-secret')));
        expect(argv, isNot(contains('unknown-secret')));
      },
    );

    test(
      'sends desktop then separate gateway password through stdin',
      () async {
        final process = await RdpBackend.start(
          profile: profile({'gateway_server': 'gateway.example.invalid'}),
          password: 'desktop-only-secret',
          gatewayPassword: 'gateway-only-secret',
          executable: executable.path,
        );
        await finish(process);
        expect(
          await File('${temporary.path}/stdin.bin').readAsString(),
          'desktop-only-secret\ngateway-only-secret\n',
        );
        final argv = (await readArguments()).join('\n');
        expect(argv, isNot(contains('desktop-only-secret')));
        expect(argv, isNot(contains('gateway-only-secret')));
      },
    );

    test(
      'gateway uses desktop secret when no separate secret is supplied',
      () async {
        final process = await RdpBackend.start(
          profile: profile({'gateway_server': 'gateway.example.invalid'}),
          password: 'shared-secret',
          executable: executable.path,
        );
        await finish(process);
        expect(
          await File('${temporary.path}/stdin.bin').readAsString(),
          'shared-secret\nshared-secret\n',
        );
      },
    );

    test('permits the 511 UTF-8 byte boundary', () async {
      final password = '${List.filled(255, 'é').join()}x';
      expect(utf8.encode(password), hasLength(511));
      final process = await RdpBackend.start(
        profile: profile(),
        password: password,
        executable: executable.path,
      );
      await finish(process);
      expect(
        await File('${temporary.path}/stdin.bin').readAsBytes(),
        utf8.encode('$password\n'),
      );
    });

    test(
      'rejects multiline, NUL and oversized secrets before process creation',
      () async {
        for (final password in [
          'secret\nsecond',
          'secret\rsecond',
          'secret\x00second',
          List.filled(512, 'x').join(),
          List.filled(256, 'é').join(),
        ]) {
          await expectLater(
            RdpBackend.start(
              profile: profile(),
              password: password,
              executable: executable.path,
            ),
            throwsFormatException,
          );
        }
        await expectLater(
          RdpBackend.start(
            profile: profile({'gateway_server': 'gateway.example.invalid'}),
            password: 'valid',
            gatewayPassword: 'bad\ngateway',
            executable: executable.path,
          ),
          throwsFormatException,
        );
        expect(await File('${temporary.path}/arguments.bin').exists(), isFalse);
        expect(await File('${temporary.path}/stdin.bin').exists(), isFalse);
      },
    );

    test('rejects unsupported profile before creating a process', () async {
      await expectLater(
        RdpBackend.start(
          profile: profile({'ssh_tunnel_enabled': '1'}),
          password: 'unused-secret',
          executable: executable.path,
        ),
        throwsFormatException,
      );
      expect(await File('${temporary.path}/arguments.bin').exists(), isFalse);
    });
  }, skip: !Platform.isLinux && !Platform.isMacOS);
}
