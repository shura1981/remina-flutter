import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/remmina_profile.dart';

/// Translates the supported Remmina settings into FreeRDP 3 arguments.
/// Credentials travel through stdin, never through the process argument list.
class RdpBackend {
  static List<String> arguments(RemminaProfile profile) {
    if (profile.server.trim().isEmpty || profile.username.trim().isEmpty) {
      throw const FormatException('Completa servidor y usuario en el perfil.');
    }
    if (profile.flag('ssh_tunnel_enabled')) {
      throw const FormatException(
        'Este perfil requiere un túnel SSH. Esta versión aún no lo implementa.',
      );
    }
    if (profile.get('precommand').isNotEmpty ||
        profile.get('postcommand').isNotEmpty) {
      throw const FormatException(
        'El perfil contiene comandos previos o posteriores. Retíralos de la '
        'copia para conectar: esta versión no los ejecuta.',
      );
    }
    final args = <String>[
      '/v:${profile.server}',
      '/u:${profile.username}',
      '/from-stdin:force',
      '/title:${profile.name}',
      '/log-level:WARN',
      profile.flag('disableclipboard') ? '-clipboard' : '+clipboard',
      profile.flag('cert_ignore') ? '/cert:ignore' : '/cert:deny',
    ];
    if (profile.domain.isNotEmpty) args.add('/d:${profile.domain}');
    final mode = profile.get('resolution_mode', '2');
    if (profile.get('scale') == '2') {
      args.add('+dynamic-resolution');
    }
    if (mode == '0') {
      final width = int.tryParse(profile.get('resolution_width'));
      final height = int.tryParse(profile.get('resolution_height'));
      if (width != null && height != null && width > 0 && height > 0) {
        args.add('/size:${width}x$height');
      } else {
        args.add('/size:90%');
      }
    } else if (mode == '1') {
      args.add('/size:100%');
    } else {
      args.add('/size:90%');
    }
    final depth = int.tryParse(profile.get('colordepth'));
    if ([8, 15, 16, 24, 32].contains(depth)) args.add('/bpp:$depth');
    final security = profile.get('security');
    if (['rdp', 'tls', 'nla', 'ext'].contains(security)) {
      args.add('/sec:$security');
    }
    if (profile.flag('console')) args.add('/admin');
    if (profile.flag('multimon')) args.add('/multimon');
    if (profile.flag('span')) args.add('/span');
    if (profile.flag('disableautoreconnect')) {
      args.add('-auto-reconnect');
    } else {
      args.add('+auto-reconnect');
      final attempts = int.tryParse(profile.get('rdp_reconnect_attempts'));
      if (attempts != null && attempts > 0) {
        args.add('/auto-reconnect-max-retries:$attempts');
      }
    }
    final sound = profile.get('sound', 'off');
    if (sound == 'local') args.add('/sound');
    if (sound == 'remote') args.add('/audio-mode:1');
    if (sound == 'off') args.add('/audio-mode:2');
    if (profile.flag('shareprinter')) args.add('/printer');
    final folder = profile.get('sharefolder');
    if (folder.isNotEmpty) {
      if (folder.contains(',') || folder.contains('\n')) {
        throw const FormatException(
          'La carpeta compartida no puede contener comas ni saltos de línea.',
        );
      }
      args.add('/drive:Compartido,$folder');
    }
    if (profile.get('gateway_server').isNotEmpty) {
      // Separate /g /gu /gd options remain supported by FreeRDP 3.
      args.add('/g:${profile.get('gateway_server')}');
      final gatewayUser = profile.get('gateway_username');
      args.add('/gu:${gatewayUser.isEmpty ? profile.username : gatewayUser}');
      if (profile.get('gateway_domain').isNotEmpty) {
        args.add('/gd:${profile.get('gateway_domain')}');
      }
    }
    if (args.any(
      (a) => a.contains('\n') || a.contains('\r') || a.contains('\x00'),
    )) {
      throw const FormatException(
        'El perfil contiene caracteres de control no válidos.',
      );
    }
    return args;
  }

  static Future<String?> findExecutable({String? preferred}) async {
    final candidates = <String>[
      if (preferred != null && preferred.isNotEmpty) preferred,
      if (Platform.environment['REMINA_FREERDP'] case final String path) path,
      if (Platform.isMacOS) ...[
        '/opt/homebrew/bin/sdl-freerdp',
        '/usr/local/bin/sdl-freerdp',
        '/opt/homebrew/bin/sdl-freerdp3',
        '/usr/local/bin/sdl-freerdp3',
      ],
      for (final dir in (Platform.environment['PATH'] ?? '').split(':'))
        for (final name in [
          'sdl-freerdp',
          'sdl-freerdp3',
          'xfreerdp3',
          'xfreerdp',
        ])
          if (dir.isNotEmpty) '$dir/$name',
    ];
    for (final candidate in candidates) {
      final file = File(candidate);
      if (await file.exists()) {
        final stat = await file.stat();
        if (stat.mode & 0x49 != 0) return candidate;
      }
    }
    return null;
  }

  static Future<Process> start({
    required RemminaProfile profile,
    required String password,
    String gatewayPassword = '',
    String? executable,
  }) async {
    for (final value in [password, gatewayPassword]) {
      if (value.contains('\n') ||
          value.contains('\r') ||
          value.contains('\x00') ||
          utf8.encode(value).length > 511) {
        throw const FormatException(
          'La contraseña no es compatible con la entrada de FreeRDP (máximo 511 bytes, sin saltos de línea).',
        );
      }
    }
    final args = arguments(profile);
    final path = await findExecutable(preferred: executable);
    if (path == null) {
      throw const ProcessException(
        'FreeRDP',
        [],
        'Instala FreeRDP 3. En macOS: brew install freerdp. '
            'También puedes indicar su ejecutable en Preferencias.',
      );
    }
    final process = await Process.start(path, args, runInShell: false);
    try {
      process.stdin.writeln(password);
      if (profile.get('gateway_server').isNotEmpty) {
        process.stdin.writeln(
          gatewayPassword.isEmpty ? password : gatewayPassword,
        );
      }
      await process.stdin.flush();
      await process.stdin.close();
      return process;
    } catch (_) {
      process.kill();
      rethrow;
    }
  }
}
