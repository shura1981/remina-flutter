import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/remmina_profile.dart';
import '../services/rdp_backend.dart';

class RdpSessionView extends StatefulWidget {
  const RdpSessionView({
    super.key,
    required this.profile,
    required this.password,
    this.gatewayPassword = '',
    this.executable,
  });
  final RemminaProfile profile;
  final String password;
  final String gatewayPassword;
  final String? executable;
  @override
  State<RdpSessionView> createState() => _RdpSessionViewState();
}

class _RdpSessionViewState extends State<RdpSessionView> {
  Process? process;
  StreamSubscription<String>? output;
  StreamSubscription<String>? errors;
  String status = 'Iniciando FreeRDP…';
  String logs = '';
  bool starting = true;
  bool running = false;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      starting = true;
      failed = false;
      logs = '';
      status = 'Iniciando FreeRDP…';
    });
    try {
      final child = await RdpBackend.start(
        profile: widget.profile,
        password: widget.password,
        gatewayPassword: widget.gatewayPassword,
        executable: widget.executable,
      );
      if (!mounted) {
        child.kill();
        return;
      }
      process = child;
      output = child.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(_log);
      errors = child.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(_log);
      setState(() {
        starting = false;
        running = true;
        status = 'FreeRDP en ejecución';
      });
      final code = await child.exitCode;
      await output?.cancel();
      await errors?.cancel();
      if (mounted) {
        setState(() {
          running = false;
          failed = code != 0;
          status = code == 0
              ? 'Sesión finalizada'
              : 'FreeRDP terminó con código $code';
        });
      }
    } on FormatException catch (e) {
      _fail(e.message);
    } on ProcessException catch (e) {
      _fail(e.message);
    } catch (_) {
      _fail(
        'No se pudo iniciar FreeRDP. Revisa el ejecutable en Preferencias.',
      );
    }
  }

  void _fail(String message) {
    if (mounted) {
      setState(() {
        starting = false;
        running = false;
        failed = true;
        status = message;
      });
    }
  }

  void _log(String chunk) {
    for (final secret in [widget.password, widget.gatewayPassword]) {
      if (secret.isNotEmpty) chunk = chunk.replaceAll(secret, '[oculto]');
    }
    // Only expose complete lines; this also avoids leaking a password split across chunks.
    if (mounted) {
      setState(() {
        logs += '$chunk\n';
        if (logs.length > 12000) logs = logs.substring(logs.length - 12000);
      });
    }
  }

  @override
  void dispose() {
    process?.kill();
    output?.cancel();
    errors?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(36),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.desktop_windows_rounded, size: 28),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.profile.name,
                    style: const TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    widget.profile.server,
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (running)
              OutlinedButton.icon(
                onPressed: () => process?.kill(),
                icon: const Icon(Icons.stop, size: 17),
                label: const Text('Desconectar'),
              )
            else if (!starting)
              FilledButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.refresh, size: 17),
                label: const Text('Volver a conectar'),
              ),
          ],
        ),
        const SizedBox(height: 36),
        Row(
          children: [
            if (starting)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                failed
                    ? Icons.error_outline
                    : running
                    ? Icons.open_in_new
                    : Icons.check_circle_outline,
                color: failed
                    ? Theme.of(context).colorScheme.error
                    : const Color(0xff79cfb4),
                size: 20,
              ),
            const SizedBox(width: 12),
            Expanded(child: Text(status)),
          ],
        ),
        const SizedBox(height: 16),
        const Text(
          'El escritorio remoto se muestra en la ventana nativa de FreeRDP. Puedes volver a la biblioteca y abrir otras sesiones.',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        const SizedBox(height: 10),
        const Text(
          'El estado indica si el proceso está activo; la autenticación y el estado de la conexión se muestran en FreeRDP.',
          style: TextStyle(color: Colors.grey, fontSize: 11),
        ),
        const SizedBox(height: 26),
        const Text(
          'DIAGNÓSTICO',
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 1.5,
            color: Colors.grey,
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                logs.isEmpty ? 'Aún no hay mensajes del motor.' : logs,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  height: 1.6,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
