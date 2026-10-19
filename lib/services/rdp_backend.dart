import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/remmina_profile.dart';

/// Translates the supported Remmina settings into FreeRDP 3 arguments.
/// Credentials travel through stdin, never through the process argument list.
class RdpBackend {
  static String installationHelp({String? operatingSystem}) {
    return 'Esta copia de Remina Desktop está incompleta: falta el motor RDP incluido '
        'en la aplicación. Vuelve a generar o descargar el paquete completo '
        'para ${operatingSystem ?? Platform.operatingSystem}. '
        'La contraseña todavía no se ha enviado al servidor.';
  }


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
      (profile.flag('cert_ignore') || profile.flag('ignore-tls-errors'))
          ? '/cert:ignore'
          : '/cert:deny',

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

  static Future<String?> findExecutable({
    String? preferred,
    Map<String, String>? environment,
    String? appExecutablePath,
    String? operatingSystem,
  }) async {
    final appDirectory = File(appExecutablePath ?? Platform.resolvedExecutable)
        .absolute
        .parent
        .path;
    final system = operatingSystem ?? Platform.operatingSystem;
    final bundledRoot =
        (environment ?? Platform.environment)['REMINA_BUNDLE_DIR'] ??
        appDirectory;
    final candidates = <String>[
      // Explicit injection is for controlled tests/developer tooling only.
      // The production UI never sets it and never searches PATH or HOME.
      if (preferred != null && preferred.isNotEmpty) preferred,
      if (system == 'macos') '$appDirectory/remina-rdp',
      if (system == 'linux') '$bundledRoot/rdp/bin/remina-rdp',
      if (system == 'windows') '$appDirectory/remina-rdp.exe',
      if (system == 'windows') '$appDirectory/wfreerdp.exe',
      if (system == 'windows') '$bundledRoot/rdp/bin/remina-rdp.exe',
      if (system == 'windows') '$bundledRoot/rdp/bin/wfreerdp.exe',
    ];
    for (final candidate in candidates) {
      final file = File(candidate);
      if (await file.exists()) {
        if (system == 'windows') return candidate;
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
      throw ProcessException('FreeRDP', const [], installationHelp());
    }
    final process = await Process.start(
      path,
      args,
      runInShell: false,
      environment: Platform.isMacOS
          ? {
              'SSL_CERT_FILE':
                  '${File(path).parent.path}/../Resources/rdp-cacert.pem',
              'OPENSSL_MODULES':
                  '${File(path).parent.path}/../Frameworks/ReminaRdp/ossl-modules',
            }
          : null,
    );
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
