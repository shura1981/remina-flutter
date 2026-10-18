// Run on Linux under xvfb-run, or on macOS with a graphical session.
// Only a closed, ephemeral loopback port is used. No RDP login is attempted.
import 'dart:convert';
import 'dart:io';

import 'package:remina/models/remmina_profile.dart';
import 'package:remina/services/rdp_backend.dart';

Future<void> main(List<String> args) async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  final profile = RemminaProfile(
    id: 'local-fixture',
    values: {
      'name': 'Remina local validation',
      'server': '127.0.0.1:$port',
      'username': 'fixture',
      'protocol': 'RDP',
      'disableautoreconnect': '1',
      'scale': '2',
      'resolution_mode': '2',
      'sound': 'off',
    },
  );
  final process = await RdpBackend.start(
    profile: profile,
    password: 'fixture-only-password',
    executable: args.firstOrNull,
  );
  final stdoutText = process.stdout.transform(utf8.decoder).join();
  final stderrText = process.stderr.transform(utf8.decoder).join();
  final code = await process.exitCode.timeout(
    const Duration(seconds: 15),
    onTimeout: () {
      process.kill();
      return -999;
    },
  );
  final logs = '${await stdoutText}\n${await stderrText}';
  if (code == -999 ||
      logs.contains('COMMAND_LINE_ERROR') ||
      (!logs.contains('ERRCONNECT_CONNECT_FAILED') &&
          !logs.contains('failed to connect'))) {
    stderr.writeln('No se pudo verificar el motor (código $code).');
    stderr.writeln(logs);
    exitCode = 1;
    return;
  }
  stdout.writeln(
    'PASS: el motor aceptó los argumentos y recibió credenciales por stdin. '
    'Solo intentó conectar a un puerto local cerrado. No prueba autenticación RDP.',
  );
}
