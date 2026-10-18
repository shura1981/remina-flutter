import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../models/remmina_profile.dart';
import '../services/ssh_host_keys.dart';

/// Passwords and key passphrases belong only to this in-memory session.
class SshSessionView extends StatefulWidget {
  const SshSessionView({
    super.key,
    required this.profile,
    required this.password,
    this.passphrase,
  });

  final RemminaProfile profile;
  final String password;
  final String? passphrase;

  @override
  State<SshSessionView> createState() => _SshSessionViewState();
}

class _SshSessionViewState extends State<SshSessionView> {
  final _terminal = Terminal(maxLines: 10000);
  final _controller = TerminalController();
  final _focusNode = FocusNode();
  final List<StreamSubscription<String>> _subscriptions = [];
  SSHClient? _client;
  SSHSession? _session;
  int _epoch = 0;
  bool _connecting = true;
  bool _connected = false;
  String _status = 'Conectando por SSH…';
  String? _hostKeyFailure;
  DialogRoute<dynamic>? _promptRoute;

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = (data) {
      if (!_connected) return;
      try {
        _session?.write(Uint8List.fromList(utf8.encode(data)));
      } catch (_) {
        _fail('No se pudo enviar información a la sesión SSH.');
      }
    };
    _terminal.onResize = (columns, rows, width, height) {
      if (!_connected) return;
      try {
        _session?.resizeTerminal(columns, rows, width, height);
      } catch (_) {
        _fail('No se pudo actualizar el tamaño del terminal.');
      }
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_connect());
    });
  }

  bool _active(int epoch) => mounted && epoch == _epoch;

  Future<void> _connect() async {
    final epoch = ++_epoch;
    setState(() {
      _connecting = true;
      _connected = false;
      _status = 'Conectando por SSH…';
      _hostKeyFailure = null;
    });
    try {
      if (widget.profile.flag('ssh_tunnel_enabled')) {
        throw const _SessionFailure(
          'Este perfil requiere un túnel SSH. El terminal integrado aún no '
          'admite saltos intermedios; desactiva el túnel o usa un cliente externo.',
        );
      }
      if (widget.profile.get('ssh_proxycommand').trim().isNotEmpty ||
          widget.profile.get('precommand').trim().isNotEmpty ||
          widget.profile.get('postcommand').trim().isNotEmpty) {
        throw const _SessionFailure(
          'El perfil contiene comandos de proxy, previos o posteriores. '
          'El terminal integrado aún no ejecuta estos comandos. '
          'Revisa el perfil antes de conectar.',
        );
      }
      final endpoint = SshEndpoint.parse(widget.profile.server);
      final username = widget.profile.username.trim();
      if (username.isEmpty) {
        throw const _SessionFailure(
          'Configura un usuario para la conexión SSH.',
        );
      }
      final keyPath = widget.profile.get('ssh_privatekey').trim();
      final auth = widget.profile.get('ssh_auth', '0');
      if (auth == '2') {
        throw const _SessionFailure(
          'Este perfil utiliza un agente SSH. Selecciona una clave privada '
          'o cambia el método a contraseña para usar el terminal integrado.',
        );
      }
      List<SSHKeyPair>? identities;
      if (keyPath.isNotEmpty) {
        try {
          final home = Platform.environment['HOME'] ?? '';
          final expanded = keyPath.startsWith('~/') && home.isNotEmpty
              ? '$home/${keyPath.substring(2)}'
              : keyPath;
          identities = SSHKeyPair.fromPem(
            await File(expanded).readAsString(),
            widget.passphrase,
          );
        } catch (_) {
          throw const _SessionFailure(
            'No se pudo leer la clave privada. Comprueba su ruta, '
            'formato y frase de contraseña.',
          );
        }
      }
      if (!_active(epoch)) return;
      final knownHosts = await SshHostKeyStore.applicationStore();
      if (!_active(epoch)) return;
      final socket = await SSHSocket.connect(
        endpoint.host,
        endpoint.port,
        timeout: const Duration(seconds: 15),
      );
      if (!_active(epoch)) {
        socket.close();
        return;
      }
      final client = SSHClient(
        socket,
        username: username,
        identities: identities,
        onPasswordRequest: widget.password.isEmpty
            ? null
            : () => _active(epoch) ? widget.password : null,
        onUserInfoRequest: (request) =>
            _authenticateInteractive(epoch, request),
        handshakeTimeout: const Duration(seconds: 90),
        authTimeout: const Duration(seconds: 120),
        onVerifyHostKey: (type, bytes) async {
          if (!_active(epoch)) return false;
          try {
            return await knownHosts.verify(
              host: endpoint.host,
              port: endpoint.port,
              type: type,
              fingerprint: utf8.decode(bytes),
              confirm: () =>
                  _confirmHost(epoch, endpoint, type, utf8.decode(bytes)),
            );
          } on SshHostKeyChanged {
            if (!_active(epoch)) return false;
            _hostKeyFailure =
                'La identidad SSH del servidor cambió. '
                'Conexión bloqueada. Verifica la huella con su administrador '
                'antes de actualizar el registro de confianza de la aplicación.';
            return false;
          } catch (_) {
            if (!_active(epoch)) return false;
            _hostKeyFailure =
                'No se pudo comprobar o guardar la identidad '
                'SSH del servidor. La conexión se ha bloqueado.';
            return false;
          }
        },
      );
      _client = client;
      unawaited(_watchTransport(client, epoch));
      await client.authenticated;
      if (!_active(epoch)) return;
      final session = await client
          .shell(
            pty: SSHPtyConfig(
              width: _terminal.viewWidth,
              height: _terminal.viewHeight,
            ),
          )
          .timeout(const Duration(seconds: 15));
      if (!_active(epoch)) {
        session.close();
        return;
      }
      _session = session;
      for (final stream in [session.stdout, session.stderr]) {
        _subscriptions.add(
          stream
              .cast<List<int>>()
              .transform(const Utf8Decoder(allowMalformed: true))
              .listen(
                (text) {
                  if (_active(epoch)) _terminal.write(text);
                },
                onError: (Object _) {
                  if (_active(epoch)) _fail('Se interrumpió el flujo SSH.');
                },
              ),
        );
      }
      setState(() {
        _connecting = false;
        _connected = true;
        _status = '${widget.profile.name} · SSH · Conectado';
      });
      _focusNode.requestFocus();
      await session.done;
      if (_active(epoch)) {
        setState(() {
          _connected = false;
          _status = session.exitCode == null
              ? 'La sesión SSH terminó.'
              : 'La sesión SSH terminó (código ${session.exitCode}).';
        });
        await _release();
      }
    } on _SessionFailure catch (failure) {
      if (_active(epoch)) _fail(failure.message);
    } on TimeoutException {
      if (_active(epoch)) _fail('El servidor SSH no respondió a tiempo.');
    } on SocketException {
      if (_active(epoch)) {
        _fail(
          'No se pudo abrir la conexión SSH. Comprueba el servidor, '
          'el puerto y la red.',
        );
      }
    } catch (_) {
      if (_active(epoch)) {
        _fail(
          _hostKeyFailure ??
              'No se pudo establecer la sesión SSH. Comprueba las credenciales, '
                  'la clave privada y los métodos de autenticación del servidor.',
        );
      }
    }
  }

  Future<bool> _confirmHost(
    int epoch,
    SshEndpoint endpoint,
    String type,
    String fingerprint,
  ) async {
    if (!_active(epoch)) return false;
    final accepted = await _showPrompt<bool>(
      (context) => AlertDialog(
        title: const Text('Primera conexión SSH'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Verifica esta huella con el administrador del servidor '
                'antes de confiar en él.',
              ),
              const SizedBox(height: 16),
              SelectableText(
                '${endpoint.host}:${endpoint.port}\n'
                '$type\n$fingerprint',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Rechazar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confiar y conectar'),
          ),
        ],
      ),
    );
    if (!_active(epoch)) return false;
    if (accepted != true) _hostKeyFailure = 'Identidad SSH rechazada.';
    return accepted == true;
  }

  Future<List<String>?> _authenticateInteractive(
    int epoch,
    SSHUserInfoRequest request,
  ) async {
    if (!_active(epoch)) return null;
    if (request.prompts.isEmpty) return [];
    final controllers = request.prompts
        .map((_) => TextEditingController())
        .toList();
    try {
      final answers = await _showPrompt<List<String>>(
        (context) => AlertDialog(
          title: const Text('Autenticación SSH'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (request.instruction.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(request.instruction),
                    ),
                  for (var i = 0; i < request.prompts.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: TextField(
                        controller: controllers[i],
                        autofocus: i == 0,
                        obscureText: !request.prompts[i].echo,
                        enableSuggestions: false,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: request.prompts[i].promptText,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                controllers.map((controller) => controller.text).toList(),
              ),
              child: const Text('Continuar'),
            ),
          ],
        ),
      );
      return _active(epoch) ? answers : null;
    } finally {
      for (final controller in controllers) {
        controller.dispose();
      }
    }
  }

  Future<T?> _showPrompt<T>(WidgetBuilder builder) async {
    final route = DialogRoute<T>(
      context: context,
      barrierDismissible: false,
      builder: builder,
    );
    _promptRoute = route;
    try {
      final result = await Navigator.of(
        context,
        rootNavigator: true,
      ).push(route);
      // The push future completes before the exit animation removes TextFields.
      // Keep their controllers alive until the route has released its overlays.
      await route.completed;
      return result;
    } finally {
      if (identical(_promptRoute, route)) _promptRoute = null;
    }
  }

  Future<void> _watchTransport(SSHClient client, int epoch) async {
    try {
      await client.done;
      // During authentication _connect owns the resulting error message.
      if (_active(epoch) && _connected) {
        _fail('El servidor cerró la conexión SSH.');
      }
    } catch (_) {
      if (_active(epoch) && _connected) {
        _fail('Se perdió la conexión SSH con el servidor.');
      }
    }
  }

  void _fail(String message) {
    ++_epoch;
    if (mounted) {
      setState(() {
        _connecting = false;
        _connected = false;
        _status = message;
      });
    }
    unawaited(_release());
  }

  Future<void> _release() async {
    final prompt = _promptRoute;
    _promptRoute = null;
    if (prompt != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final navigator = prompt.navigator;
        if (prompt.isActive && navigator != null && navigator.mounted) {
          navigator.removeRoute(prompt);
        }
      });
    }
    final subscriptions = List.of(_subscriptions);
    _subscriptions.clear();
    final session = _session;
    final client = _client;
    _session = null;
    _client = null;
    session?.close();
    try {
      // Shut down the transport before awaiting stream cancellation: cancellation
      // can wait for a channel to finish and must not delay closing its socket.
      await client?.close();
    } catch (_) {
      // Closing a disconnected transport requires no further user action.
    }
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (mounted && _connected && data?.text != null) {
      _terminal.paste(data!.text!);
      _focusNode.requestFocus();
    }
  }

  void _copy() {
    final selection = _controller.selection;
    if (selection != null) {
      unawaited(
        Clipboard.setData(
          ClipboardData(text: _terminal.buffer.getText(selection)),
        ),
      );
    }
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    ++_epoch;
    _terminal.onOutput = null;
    _terminal.onResize = null;
    unawaited(_release());
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                Icon(
                  _connected ? Icons.lock_outline : Icons.terminal,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(_status)),
                IconButton(
                  tooltip: 'Copiar selección',
                  onPressed: _copy,
                  icon: const Icon(Icons.copy_outlined, size: 18),
                ),
                IconButton(
                  tooltip: 'Pegar en terminal',
                  onPressed: _connected ? _paste : null,
                  icon: const Icon(Icons.content_paste, size: 18),
                ),
                if (_connected || _connecting)
                  TextButton.icon(
                    onPressed: () => _fail('Sesión SSH desconectada.'),
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    label: const Text('Desconectar'),
                  )
                else
                  TextButton.icon(
                    onPressed: _connect,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Reconectar'),
                  ),
              ],
            ),
          ),
        ),
        if (_connecting) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: TerminalView(
            _terminal,
            controller: _controller,
            focusNode: _focusNode,
            autofocus: true,
            readOnly: !_connected,
            padding: const EdgeInsets.all(12),
            textStyle: const TerminalStyle(fontSize: 14),
          ),
        ),
      ],
    );
  }
}

class _SessionFailure implements Exception {
  const _SessionFailure(this.message);
  final String message;
}

/// A literal IPv6 address uses the default port; custom ports use [IPv6]:port.
class SshEndpoint {
  const SshEndpoint(this.host, this.port);

  final String host;
  final int port;

  static SshEndpoint parse(String server) {
    final value = server.trim();
    if (value.isEmpty || RegExp(r'[\s/@]').hasMatch(value)) {
      throw const _SessionFailure('Configura un servidor SSH válido.');
    }
    var host = value;
    var port = 22;
    if (value.startsWith('[')) {
      final match = RegExp(r'^\[([^\]]+)\](?::([0-9]+))?$').firstMatch(value);
      if (match == null) {
        throw const _SessionFailure(
          'La dirección IPv6 o su puerto no es válido.',
        );
      }
      host = match[1]!;
      if (match[2] != null) port = int.tryParse(match[2]!) ?? 0;
    } else if (':'.allMatches(value).length == 1) {
      final colon = value.indexOf(':');
      host = value.substring(0, colon);
      port = int.tryParse(value.substring(colon + 1)) ?? 0;
    }
    if (host.isEmpty || port < 1 || port > 65535) {
      throw const _SessionFailure('El puerto SSH debe estar entre 1 y 65535.');
    }
    return SshEndpoint(host, port);
  }
}
