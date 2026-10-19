import 'package:flutter/material.dart';

import '../models/remmina_profile.dart';

/// Edits the portable settings in a Remmina profile without dropping plugin keys.
Future<RemminaProfile?> showProfileEditor(
  BuildContext context, {
  RemminaProfile? profile,
}) => showDialog<RemminaProfile>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _ProfileEditor(profile: profile),
);

class _ProfileEditor extends StatefulWidget {
  const _ProfileEditor({this.profile});

  final RemminaProfile? profile;

  @override
  State<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<_ProfileEditor> {
  final _form = GlobalKey<FormState>();
  final _fields = <String, TextEditingController>{};
  late String _protocol;
  late String _sshAuth;
  late String _resolutionMode;
  late String _colorDepth;
  late bool _clipboard;
  late bool _ignoreCertificate;
  late bool _dynamicResolution;

  String _value(String key, [String fallback = '']) =>
      widget.profile?.get(key, fallback) ?? fallback;

  @override
  void initState() {
    super.initState();
    _protocol = _value('protocol', 'RDP').toUpperCase();
    if (_protocol.isEmpty) _protocol = 'RDP';
    _sshAuth = _value('ssh_auth', '0');
    _resolutionMode = _value('resolution_mode', '1');

    _colorDepth = _value('colordepth', '32');
    _clipboard = !(widget.profile?.flag('disableclipboard') ?? false);
    _ignoreCertificate = widget.profile == null
        ? true
        : ((widget.profile?.flag('cert_ignore') ?? false) ||
            (widget.profile?.flag('ignore-tls-errors') ?? false));
    _dynamicResolution = widget.profile == null
        ? true
        : (widget.profile!.values.containsKey('scale')
            ? _value('scale') == '2'
            : true);

    for (final key in [
      'name',
      'group',
      'server',
      'username',
      'domain',
      'notes_text',
      'ssh_privatekey',
      'resolution_width',
      'resolution_height',
      'sharefolder',
      'gateway_server',
      'gateway_username',
      'gateway_domain',
    ]) {
      _fields[key] = TextEditingController(text: _value(key));
    }
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final values = <String, String>{...?widget.profile?.values};
    // Keep every unrecognized field, including secret-store references. Passwords
    // are intentionally neither displayed nor collected by this editor.
    for (final entry in _fields.entries) {
      final text = entry.key == 'notes_text'
          ? entry.value.text
          : entry.value.text.trim();
      if (values.containsKey(entry.key) || text.isNotEmpty) {
        values[entry.key] = text;
      }
    }
    values['protocol'] = _protocol;
    if (_protocol == 'SSH' || _protocol == 'SFTP') {
      values['ssh_auth'] = _sshAuth;
    }
    if (_protocol == 'RDP') {
      values['resolution_mode'] = _resolutionMode;
      values['scale'] = _dynamicResolution
          ? '2'
          : (_value('scale') == '2' ? '0' : _value('scale', '0'));
      values['colordepth'] = _colorDepth;
      values['disableclipboard'] = _clipboard ? '0' : '1';
      values['cert_ignore'] = _ignoreCertificate ? '1' : '0';
      values['ignore-tls-errors'] = _ignoreCertificate ? '1' : '0';

    }
    Navigator.of(context).pop(
      widget.profile?.copyWith(values: values) ??
          RemminaProfile(
            id:
                widget.profile?.id ??
                'profile-${DateTime.now().microsecondsSinceEpoch}',
            values: values,
            sourcePath: widget.profile?.sourcePath,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 820),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 24, 16, 16),
              child: Row(
                children: [
                  const Icon(Icons.desktop_windows_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.profile == null
                          ? 'Nueva conexión'
                          : 'Editar conexión',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Cancelar',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _pair(
                        _text('name', 'Nombre', required: true),
                        _text('group', 'Grupo', hint: 'Trabajo / Servidores'),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: _protocol,
                        decoration: const InputDecoration(
                          labelText: 'Protocolo',
                        ),
                        items: _items({
                          'RDP': 'RDP · Escritorio remoto',
                          'SSH': 'SSH · Terminal segura',
                          'VNC': 'VNC · Escritorio remoto',
                          'SFTP': 'SFTP · Transferencia de archivos',
                        }, _protocol),
                        onChanged: (value) =>
                            setState(() => _protocol = value!),
                      ),
                      const SizedBox(height: 16),
                      _text(
                        'server',
                        'Servidor',
                        hint: _protocol == 'SSH' || _protocol == 'SFTP'
                            ? 'servidor.ejemplo.com:22'
                            : '192.168.1.10:3389',
                        helper: 'Host o IP; puerto opcional. IPv6: [dirección]:puerto.',
                        validator: _validateServer,
                      ),
                      const SizedBox(height: 16),
                      _pair(
                        _text(
                          'username',
                          'Usuario',
                          validator: (value) =>
                              (_protocol == 'SSH' || _protocol == 'SFTP') &&
                                  (value?.trim().isEmpty ?? true)
                              ? 'Escribe el usuario de la conexión.'
                              : null,
                        ),
                        _text('domain', 'Dominio', hint: 'Opcional'),
                      ),
                      const SizedBox(height: 16),
                      _notice(
                        'Las contraseñas se solicitan al conectar. No se guardan '
                        'contraseñas nuevas en el archivo del perfil.',
                        Icons.lock_outline,
                      ),
                      if (_protocol != 'RDP' && _protocol != 'SSH') ...[
                        const SizedBox(height: 12),
                        _notice(
                          'Puedes conservar y editar este perfil. La conexión '
                          '$_protocol todavía no está disponible en esta app.',
                          Icons.info_outline,
                        ),
                      ],
                      if (_protocol == 'SSH' || _protocol == 'SFTP') ...[
                        const SizedBox(height: 24),
                        _section('Autenticación SSH'),
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: _sshAuth,
                          decoration: const InputDecoration(
                            labelText: 'Método de autenticación',
                          ),
                          items: _items({
                            '0': 'Contraseña',
                            '1': 'Clave privada',
                          }, _sshAuth),
                          onChanged: (value) =>
                              setState(() => _sshAuth = value!),
                        ),
                        if (_sshAuth == '1') ...[
                          const SizedBox(height: 16),
                          _text(
                            'ssh_privatekey',
                            'Ruta de la clave privada',
                            hint: '~/.ssh/id_ed25519',
                            required: true,
                          ),
                        ],
                      ],
                      if (_protocol == 'RDP') ...[
                        const SizedBox(height: 24),
                        _section('Pantalla y recursos'),
                        _pair(
                          DropdownButtonFormField<String>(
                            isExpanded: true,
                            initialValue: _resolutionMode,
                            decoration: const InputDecoration(
                              labelText: 'Resolución',
                            ),
                            items: _items({
                              '0': 'Personalizada',
                              '1': 'Tamaño del cliente',
                              '2': 'Tamaño inicial de la ventana',
                            }, _resolutionMode),
                            onChanged: (value) =>
                                setState(() => _resolutionMode = value!),
                          ),
                          DropdownButtonFormField<String>(
                            isExpanded: true,
                            initialValue: _colorDepth,
                            decoration: const InputDecoration(
                              labelText: 'Profundidad de color',
                            ),
                            items: _items({
                              '8': '8 bits',
                              '15': '15 bits',
                              '16': '16 bits',
                              '24': '24 bits',
                              '32': '32 bits',
                              '63': 'GFX RFX (32 bits)',
                              '64': 'GFX H.264 (32 bits)',
                              '65': 'GFX AVC444 (32 bits)',
                            }, _colorDepth),
                            onChanged: (value) =>
                                setState(() => _colorDepth = value!),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Resolución dinámica'),
                          subtitle: const Text(
                            'Ajustar el escritorio al cambiar el tamaño de la ventana.',
                          ),
                          value: _dynamicResolution,
                          onChanged: (value) =>
                              setState(() => _dynamicResolution = value),
                        ),
                        if (_resolutionMode == '0' && !_dynamicResolution) ...[
                          const SizedBox(height: 16),
                          _pair(
                            _text(
                              'resolution_width',
                              'Ancho (px)',
                              validator: _validateDimension,
                            ),
                            _text(
                              'resolution_height',
                              'Alto (px)',
                              validator: _validateDimension,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Compartir portapapeles'),
                          value: _clipboard,
                          onChanged: (value) =>
                              setState(() => _clipboard = value),
                        ),
                        const SizedBox(height: 8),
                        _text(
                          'sharefolder',
                          'Carpeta compartida',
                          hint: 'Ruta local opcional',
                        ),
                        const SizedBox(height: 12),
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            'Omitir validación del certificado',
                          ),
                          subtitle: const Text(
                            'Úsalo solo si confías en el servidor de destino.',
                          ),
                          value: _ignoreCertificate,
                          onChanged: (value) =>
                              setState(() => _ignoreCertificate = value),
                        ),
                        const SizedBox(height: 16),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: const EdgeInsets.only(top: 12),
                          title: const Text('Puerta de enlace RDP'),
                          subtitle: const Text('Opcional'),
                          children: [
                            _text(
                              'gateway_server',
                              'Servidor de la puerta de enlace',
                            ),
                            const SizedBox(height: 16),
                            _pair(
                              _text('gateway_username', 'Usuario'),
                              _text('gateway_domain', 'Dominio'),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 24),
                      _text('notes_text', 'Notas', maxLines: 3),
                      const SizedBox(height: 12),
                      Text(
                        'Los ajustes adicionales del perfil Remmina se conservan '
                        'al guardar. Su disponibilidad depende del cliente instalado.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Guardar conexión'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _text(
    String key,
    String label, {
    String? hint,
    String? helper,
    bool required = false,
    int maxLines = 1,
    String? Function(String?)? validator,
  }) => TextFormField(
    controller: _fields[key],
    maxLines: maxLines,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helper,
      helperMaxLines: 2,
      errorMaxLines: 2,
      alignLabelWithHint: maxLines > 1,
    ),
    validator:
        validator ??
        (required
            ? (value) =>
                  value?.trim().isEmpty ?? true ? 'Completa este campo.' : null
            : null),
  );

  Widget _pair(Widget first, Widget second) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 500) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [first, const SizedBox(height: 16), second],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: first),
          const SizedBox(width: 16),
          Expanded(child: second),
        ],
      );
    },
  );

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );

  Widget _notice(String message, IconData icon) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colors.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  List<DropdownMenuItem<String>> _items(
    Map<String, String> labels,
    String selected,
  ) =>
      {
            ...labels,
            if (!labels.containsKey(selected))
              selected: 'Valor del perfil: $selected',
          }.entries
          .map(
            (entry) => DropdownMenuItem(
              value: entry.key,
              child: Text(entry.value, overflow: TextOverflow.ellipsis),
            ),
          )
          .toList();

  String? _validateDimension(String? value) {
    final size = int.tryParse(value?.trim() ?? '');
    return size == null || size < 200 || size > 16384
        ? 'Usa un valor entre 200 y 16384.'
        : null;
  }

  String? _validateServer(String? value) {
    final server = value?.trim() ?? '';
    if (server.isEmpty) return 'Escribe el host o la IP del servidor.';
    if (RegExp(r'\s|://|[/\\]').hasMatch(server)) {
      return 'Usa un host o una IP, sin URL ni espacios.';
    }
    String? port;
    if (server.startsWith('[')) {
      final end = server.indexOf(']');
      if (end < 2 || !server.substring(1, end).contains(':')) {
        return 'Escribe una dirección IPv6 válida entre corchetes.';
      }
      final suffix = server.substring(end + 1);
      if (suffix.isNotEmpty) {
        if (!suffix.startsWith(':')) return 'Revisa el puerto del servidor.';
        port = suffix.substring(1);
      }
    } else if (':'.allMatches(server).length == 1) {
      final separator = server.indexOf(':');
      if (separator == 0) return 'Escribe el host antes del puerto.';
      port = server.substring(separator + 1);
    }
    if (port != null) {
      final number = int.tryParse(port);
      if (number == null || number < 1 || number > 65535) {
        return 'El puerto debe estar entre 1 y 65535.';
      }
    }
    return null;
  }
}
