import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/remmina_profile.dart';
import 'services/credentials.dart';
import 'services/preferences.dart';
import 'services/profile_repository.dart';
import 'sessions/rdp_session.dart';
import 'sessions/ssh_session.dart';
import 'ui/profile_editor.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ReminaApp());
}

const accent = Color(0xffb6a2ff);

class ReminaApp extends StatefulWidget {
  const ReminaApp({super.key, this.repository, this.preferences});
  final ProfileRepository? repository;
  final AppPreferences? preferences;
  @override
  State<ReminaApp> createState() => _ReminaAppState();
}

class _ReminaAppState extends State<ReminaApp> {
  final preferences = AppPreferences();
  bool dark = true;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remina',
      debugShowCheckedModeBanner: false,
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: ConnectionLibrary(
        repository: widget.repository,
        preferences: widget.preferences ?? preferences,
        onTheme: (value) => setState(() => dark = value),
      ),
    );
  }

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff8062de),
      brightness: brightness,
    );
    return ThemeData(
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark
          ? const Color(0xff14151c)
          : const Color(0xfff5f5fa),
      fontFamily: Platform.isMacOS ? '.AppleSystemUIFont' : null,
      useMaterial3: true,
      dividerColor: dark ? Colors.white10 : Colors.black12,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xff20212b) : Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 15,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 17),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        ),
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 500),
      ),
    );
  }
}

class _OpenSession {
  _OpenSession(this.profile, this.view);
  final RemminaProfile profile;
  final Widget view;
}

class ConnectionLibrary extends StatefulWidget {
  const ConnectionLibrary({
    super.key,
    this.repository,
    required this.preferences,
    required this.onTheme,
  });
  final ProfileRepository? repository;
  final AppPreferences preferences;
  final ValueChanged<bool> onTheme;
  @override
  State<ConnectionLibrary> createState() => _ConnectionLibraryState();
}

class _ConnectionLibraryState extends State<ConnectionLibrary>
    with WidgetsBindingObserver {
  ProfileRepository? repository;
  List<RemminaProfile> profiles = [];
  final sessions = <_OpenSession>[];
  final credentials = CredentialStore();
  final search = TextEditingController();
  final quick = TextEditingController();
  final searchFocus = FocusNode();
  final Set<String> collapsed = {};
  String category = 'all';
  String query = '';
  String quickProtocol = 'RDP';
  String? selectedId;
  String? error;
  bool loading = true;
  bool importing = false;
  bool grouped = true;
  bool sortAscending = true;
  int activeTab = 0;
  bool _exiting = false;
  Future<AppExitResponse>? _exitRequest;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  Future<AppExitResponse> didRequestAppExit() => _exitRequest ??=
      _confirmAppExit().whenComplete(() => _exitRequest = null);

  Future<AppExitResponse> _confirmAppExit() async {
    if (!mounted) return AppExitResponse.exit;
    if (sessions.isEmpty) {
      _exiting = true;
      return AppExitResponse.exit;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Salir de Remina'),
        content: Text(
          'Se cerrarán las ${sessions.length} pestañas de sesión y sus conexiones remotas.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cerrar conexiones y salir'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return AppExitResponse.cancel;
    setState(() {
      _exiting = true;
      sessions.clear();
      activeTab = 0;
    });
    // Session views terminate their SSH clients and native FreeRDP processes in
    // dispose. Complete that frame before allowing the desktop engine to exit.
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
    return AppExitResponse.exit;
  }

  Future<void> _load() async {
    try {
      repository = widget.repository ?? await ProfileRepository.open();
      await widget.preferences.load();
      final loaded = await repository!.load();
      if (!mounted) return;
      widget.onTheme(widget.preferences.dark);
      setState(() {
        profiles = loaded;
        loading = false;
        error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          error = 'No se pudo leer la biblioteca local. Revisa los permisos y el formato de los perfiles.';
          loading = false;
        });
      }
    }
  }

  Future<void> _reload() async {
    final loaded = await repository!.load();
    if (mounted) setState(() => profiles = loaded);
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on FormatException catch (e) {
      _message(e.message);
    } on FileSystemException {
      _message('No se pudo acceder al archivo. Revisa su ruta y permisos.');
    } catch (_) {
      _message(
        'No se pudo completar la operación. Tus perfiles originales siguen intactos.',
      );
    }
  }

  Future<void> _edit([RemminaProfile? profile]) async {
    if (repository == null) return;
    final result = await showProfileEditor(context, profile: profile);
    if (result == null || !mounted || _exiting) return;
    await _guard(() async {
      await repository!.save(result);
      await _reload();
      if (mounted && !_exiting) setState(() => selectedId = result.id);
    });
  }

  Future<void> _import({bool detected = false}) async {
    if (repository == null || importing) return;
    setState(() => importing = true);
    await _guard(() async {
      final files = <File>[];
      if (detected) {
        final home = Platform.environment['HOME'];
        if (home != null) {
          for (final path in ['$home/.local/share/remmina', '$home/.remmina']) {
            final dir = Directory(path);
            if (await dir.exists()) {
              await for (final f in dir.list()) {
                if (f is File && f.path.endsWith('.remmina')) files.add(f);
              }
            }
          }
        }
        if (files.isEmpty) {
          _message(
            'No se encontraron perfiles locales. Usa Importar para elegir archivos .remmina.',
          );
          return;
        }
      } else {
        final picked = await openFiles(
          acceptedTypeGroups: [
            const XTypeGroup(
              label: 'Perfiles Remmina',
              extensions: ['remmina'],
            ),
          ],
        );
        files.addAll(picked.map((f) => File(f.path)));
      }
      if (files.isEmpty) return;
      final imported = await repository!.importFiles(files);
      await _reload();
      _message(
        '${imported.length} perfiles importados. Introduce sus contraseñas al conectar.',
      );
    });
    if (mounted) setState(() => importing = false);
  }

  Future<void> _export(RemminaProfile profile) async {
    await _guard(() async {
      final file = await getSaveLocation(
        suggestedName:
            '${profile.name.replaceAll(RegExp(r'[^\w\- ]'), '_')}.remmina',
        acceptedTypeGroups: [
          const XTypeGroup(label: 'Perfil Remmina', extensions: ['remmina']),
        ],
      );
      if (file == null) return;
      await repository!.exportProfile(profile, File(file.path));
      _message('Perfil exportado. Las contraseñas del llavero no se incluyen.');
    });
  }

  Future<void> _delete(RemminaProfile profile) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar perfil'),
        content: Text(
          'Se eliminará «${profile.name}» de esta biblioteca. El archivo original de Remmina se conserva.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await _guard(() async {
      await repository!.delete(profile);
      try {
        await credentials.delete(profile.id);
      } catch (_) {
        _message(
          'Perfil eliminado; no se pudo borrar su contraseña del llavero.',
        );
      }
      await _reload();
      if (mounted) setState(() => selectedId = null);
    });
  }

  Future<void> _profileAction(String action, RemminaProfile p) async {
    switch (action) {
      case 'connect':
        await _connect(p);
      case 'edit':
        await _edit(p);
      case 'export':
        await _export(p);
      case 'delete':
        await _delete(p);
      case 'favorite':
        await _guard(() async {
          await repository!.save(
            p.copyWith(
              values: {...p.values, 'remina_favorite': p.favorite ? '0' : '1'},
            ),
          );
          await _reload();
        });
      case 'copy':
        await _guard(() async {
          final copy = p.copyWith(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            values: {...p.values, 'name': '${p.name} (copia)'},
          );
          await repository!.save(copy);
          await _reload();
        });
    }
  }

  Future<void> _quickConnect() async {
    final server = quick.text.trim();
    if (server.isEmpty) return;
    await _connect(
      RemminaProfile(
        id: 'quick-${DateTime.now().microsecondsSinceEpoch}',
        values: {
          'name': server,
          'server': server,
          'protocol': quickProtocol,
          'resolution_mode': '2',
          'scale': '2',
        },
      ),
      temporary: true,
    );
  }

  Future<void> _connect(RemminaProfile p, {bool temporary = false}) async {
    if (_exiting) return;
    if (!['RDP', 'SSH'].contains(p.protocol)) {
      _message(
        '${p.protocol}: el perfil se conserva, pero su motor de conexión aún no está implementado.',
      );
      return;
    }
    String saved = '';
    try {
      saved = await credentials.read(p.id) ?? '';
    } catch (_) {
      /* Session-only still works without a keyring. */
    }
    if (!mounted) return;
    final user = TextEditingController(text: p.username);
    final password = TextEditingController(text: saved);
    final passphrase = TextEditingController();
    final gateway = TextEditingController();
    bool remember = saved.isNotEmpty;
    bool obscure = true;
    final form = GlobalKey<FormState>();
    final result =
        await showDialog<
          ({
            String username,
            String password,
            String passphrase,
            String gateway,
            bool remember,
          })
        >(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
              title: Text('Conectar a ${p.name}'),
              content: SizedBox(
                width: 420,
                child: Form(
                  key: form,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          p.server,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 18),
                        TextFormField(
                          controller: user,
                          autofocus: p.username.isEmpty,
                          decoration: const InputDecoration(
                            labelText: 'Usuario',
                          ),
                          validator: (v) => v == null || v.trim().isEmpty
                              ? 'Escribe el usuario'
                              : null,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: password,
                          autofocus: p.username.isNotEmpty,
                          obscureText: obscure,
                          decoration: InputDecoration(
                            labelText: 'Contraseña',
                            suffixIcon: IconButton(
                              tooltip: obscure
                                  ? 'Mostrar contraseña'
                                  : 'Ocultar contraseña',
                              onPressed: () => update(() => obscure = !obscure),
                              icon: Icon(
                                obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                        ),
                        if (p.protocol == 'SSH' &&
                            p.get('ssh_privatekey').isNotEmpty) ...[
                          const SizedBox(height: 14),
                          TextField(
                            controller: passphrase,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: 'Frase de la llave privada (opcional)',
                            ),
                          ),
                        ],
                        if (p.get('gateway_server').isNotEmpty) ...[
                          const SizedBox(height: 14),
                          TextField(
                            controller: gateway,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: 'Contraseña de gateway (vacía: usar la misma)',
                            ),
                          ),
                        ],
                        const SizedBox(height: 10),
                        CheckboxListTile(
                          value: remember,
                          onChanged:
                              temporary || p.flag('disablepasswordstoring')
                              ? null
                              : (v) => update(() => remember = v!),
                          title: const Text(
                            'Guardar en el llavero del sistema',
                            style: TextStyle(fontSize: 13),
                          ),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                        if (p.get('password') == '.')
                          const Text(
                            'La contraseña guardada por Remmina pertenece al llavero de Linux. Introdúcela aquí para este equipo.',
                            style: TextStyle(fontSize: 12),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () {
                    if (form.currentState!.validate()) {
                      Navigator.pop(context, (
                        username: user.text.trim(),
                        password: password.text,
                        passphrase: passphrase.text,
                        gateway: gateway.text,
                        remember: remember,
                      ));
                    }
                  },
                  child: const Text('Conectar'),
                ),
              ],
            ),
          ),
        );
    // TextFields are disposed after the route transition releases their controllers.
    Future<void>.delayed(const Duration(milliseconds: 350), () {
      user.dispose();
      password.dispose();
      passphrase.dispose();
      gateway.dispose();
    });
    if (result == null || !mounted || _exiting) return;
    if (!temporary) {
      try {
        if (result.remember && !p.flag('disablepasswordstoring')) {
          await credentials.write(p.id, result.password);
        } else {
          await credentials.delete(p.id);
        }
      } catch (_) {
        _message(
          'El llavero no está disponible. La contraseña se usará solo en esta sesión.',
        );
      }
      widget.preferences.lastUsed[p.id] = DateTime.now()
          .toUtc()
          .toIso8601String();
      try {
        await widget.preferences.save();
      } catch (_) {
        /* Noncritical history. */
      }
    }
    final sessionProfile = p.copyWith(
      values: {...p.values, 'username': result.username},
    );
    final key = UniqueKey();
    final view = p.protocol == 'SSH'
        ? SshSessionView(
            key: key,
            profile: sessionProfile,
            password: result.password,
            passphrase: result.passphrase,
          )
        : RdpSessionView(
            key: key,
            profile: sessionProfile,
            password: result.password,
            gatewayPassword: result.gateway,
            executable: widget.preferences.freerdpPath,
          );
    if (mounted && !_exiting) {
      setState(() {
        sessions.add(_OpenSession(sessionProfile, view));
        activeTab = sessions.length;
      });
    }
  }

  Future<void> _closeSession(int index) async {
    if (index < 0 || index >= sessions.length) return;
    final session = sessions[index];
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cerrar sesión'),
        content: const Text(
          'La conexión se interrumpirá y se cerrará su pestaña.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cerrar sesión'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      setState(() {
        sessions.remove(session);
        activeTab = 0;
      });
    }
  }

  Future<void> _preferences() async {
    final path = TextEditingController(text: widget.preferences.freerdpPath);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Preferencias'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Motor de escritorio remoto',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              const Text(
                'RDP abre FreeRDP 3 en una ventana nativa. En macOS puedes instalarlo con Homebrew:',
              ),
              const SizedBox(height: 10),
              const SelectableText(
                'brew install freerdp',
                style: TextStyle(fontFamily: 'monospace'),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: path,
                decoration: const InputDecoration(
                  labelText: 'Ruta del ejecutable FreeRDP',
                  hintText: 'Vacío: detectar automáticamente',
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'SSH se ejecuta dentro de la app. Los perfiles VNC, SFTP y otros se conservan al importar, pero todavía no pueden conectarse.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () async {
              widget.preferences.freerdpPath = path.text.trim();
              await _guard(widget.preferences.save);
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 350), path.dispose);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    search.dispose();
    quick.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () =>
            _edit(),
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
            _edit(),
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () =>
            searchFocus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
            searchFocus.requestFocus(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Row(
            children: [
              Container(
                width: 216,
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xff1b1c25) : Colors.white,
                  border: Border(
                    right: BorderSide(color: Theme.of(context).dividerColor),
                  ),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: SafeArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: ListView(
                            padding: EdgeInsets.zero,
                            children: [
                              Padding(
                                padding: EdgeInsets.fromLTRB(24, 30, 24, 30),
                                child: Row(
                                  children: [
                                    Image.asset(
                                      'assets/branding/remina-mark-128.png',
                                      width: 36,
                                      height: 36,
                                      filterQuality: FilterQuality.high,
                                      excludeFromSemantics: true,
                                    ),
                                    const SizedBox(width: 8),
                                    const Flexible(
                                      child: Text(
                                        'remina',
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 25,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: -.8,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Padding(
                                padding: EdgeInsets.only(left: 24, bottom: 12),
                                child: Text(
                                  'ESPACIO DE TRABAJO',
                                  style: TextStyle(
                                    fontSize: 10,
                                    letterSpacing: 1.5,
                                    color: Colors.grey,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              _nav(
                                Icons.dns_outlined,
                                'Todas las conexiones',
                                'all',
                                profiles.length,
                              ),
                              _nav(
                                Icons.star_border_rounded,
                                'Favoritas',
                                'favorites',
                                profiles.where((p) => p.favorite).length,
                              ),
                              _nav(
                                Icons.history_rounded,
                                'Recientes',
                                'recent',
                                profiles
                                    .where(
                                      (p) => widget.preferences.lastUsed
                                          .containsKey(p.id),
                                    )
                                    .length,
                              ),
                              const Padding(
                                padding: EdgeInsets.fromLTRB(24, 28, 24, 10),
                                child: Text(
                                  'PROTOCOLOS',
                                  style: TextStyle(
                                    fontSize: 10,
                                    letterSpacing: 1.5,
                                    color: Colors.grey,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              _nav(
                                Icons.desktop_windows_outlined,
                                'Escritorio RDP',
                                'RDP',
                                profiles
                                    .where((p) => p.protocol == 'RDP')
                                    .length,
                              ),
                              _nav(
                                Icons.terminal_rounded,
                                'Terminal SSH',
                                'SSH',
                                profiles
                                    .where((p) => p.protocol == 'SSH')
                                    .length,
                              ),
                            ],
                          ),
                        ),
                        ListTile(
                          dense: true,
                          leading: Icon(
                            isDark
                                ? Icons.light_mode_outlined
                                : Icons.dark_mode_outlined,
                            size: 20,
                          ),
                          title: Text(isDark ? 'Tema claro' : 'Tema oscuro'),
                          onTap: () async {
                            widget.preferences.dark = !isDark;
                            widget.onTheme(!isDark);
                            await _guard(widget.preferences.save);
                          },
                        ),
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.tune_rounded, size: 20),
                          title: const Text('Preferencias'),
                          onTap: _preferences,
                        ),
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'PERSONAL EDITION  /  1.0',
                            style: TextStyle(
                              fontSize: 9,
                              letterSpacing: 1.2,
                              color: Colors.grey,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: SafeArea(
                  child: Column(
                    children: [
                      SizedBox(
                        height: 49,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            _tab('Biblioteca', Icons.grid_view_rounded, 0),
                            for (var i = 0; i < sessions.length; i++)
                              _tab(
                                sessions[i].profile.name,
                                sessions[i].profile.protocol == 'SSH'
                                    ? Icons.terminal
                                    : Icons.desktop_windows,
                                i + 1,
                              ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: IndexedStack(
                          index: activeTab,
                          children: [
                            _library(),
                            ...sessions.map((s) => s.view),
                          ],
                        ),
                      ),
                      Container(
                        height: 30,
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(
                              color: Theme.of(context).dividerColor,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0xff7ccead),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${profiles.length} perfiles · ${sessions.length} pestañas de sesión',
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.grey,
                              ),
                            ),
                            const Spacer(),
                            const Text(
                              'Flutter 3.47.7  ·  Perfiles .remmina',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nav(IconData icon, String label, String value, int count) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
    child: ListTile(
      dense: true,
      selected: category == value,
      selectedColor: accent,
      selectedTileColor: accent.withValues(alpha: .1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      leading: Icon(icon, size: 19),
      title: Text(label, style: const TextStyle(fontSize: 12)),
      trailing: Text(
        '$count',
        style: const TextStyle(fontSize: 11, color: Colors.grey),
      ),
      onTap: () => setState(() {
        category = value;
        activeTab = 0;
      }),
    ),
  );

  Widget _tab(String label, IconData icon, int index) => InkWell(
    onTap: () => setState(() => activeTab = index),
    child: Container(
      constraints: const BoxConstraints(minWidth: 145, maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: activeTab == index ? accent : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 15,
            color: activeTab == index ? accent : Colors.grey,
          ),
          const SizedBox(width: 9),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: activeTab == index ? accent : Colors.grey,
              ),
            ),
          ),
          if (index > 0) ...[
            const SizedBox(width: 8),
            InkWell(
              onTap: () => _closeSession(index - 1),
              child: const Icon(Icons.close, size: 15),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _library() {
    final filtered =
        profiles.where((p) {
          if (category == 'favorites' && !p.favorite) return false;
          if (category == 'recent' &&
              !widget.preferences.lastUsed.containsKey(p.id)) {
            return false;
          }
          if (['RDP', 'SSH'].contains(category) && p.protocol != category) {
            return false;
          }
          return '${p.name} ${p.server} ${p.username} ${p.group} ${p.notes} ${p.get('labels')}'
              .toLowerCase()
              .contains(query.toLowerCase());
        }).toList()..sort(
          (a, b) => category == 'recent'
              ? (widget.preferences.lastUsed[b.id] ?? '').compareTo(
                  widget.preferences.lastUsed[a.id] ?? '',
                )
              : (sortAscending ? 1 : -1) *
                    a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
    final selected = profiles.where((p) => p.id == selectedId).firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 25, 28, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      switch (category) {
                        'favorites' => 'Favoritas',
                        'recent' => 'Conexiones recientes',
                        'RDP' => 'Escritorios RDP',
                        'SSH' => 'Terminales SSH',
                        _ => 'Tus conexiones',
                      },
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -.6,
                      ),
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      'Un lugar para todos tus equipos remotos.',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: importing ? null : () => _import(),
                icon: const Icon(Icons.file_download_outlined, size: 17),
                label: Text(importing ? 'Importando…' : 'Importar'),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Nueva conexión'),
              ),
            ],
          ),
          const SizedBox(height: 25),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: .06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: accent.withValues(alpha: .16)),
            ),
            child: Row(
              children: [
                const Icon(Icons.bolt_rounded, color: accent, size: 22),
                const SizedBox(width: 12),
                const Text(
                  'Conexión rápida',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 20),
                SizedBox(
                  width: 85,
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: quickProtocol,
                      isDense: true,
                      items: ['RDP', 'SSH']
                          .map(
                            (p) => DropdownMenuItem(
                              value: p,
                              child: Text(
                                p,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => quickProtocol = v!),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: quick,
                    onSubmitted: (_) => _quickConnect(),
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      hintText: 'Servidor, IP o [IPv6]:puerto',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton.filledTonal(
                  tooltip: 'Conectar rápidamente',
                  onPressed: _quickConnect,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: search,
                  focusNode: searchFocus,
                  onChanged: (v) => setState(() => query = v),
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search, size: 19),
                    hintText: 'Buscar nombre, servidor, grupo o etiqueta…',
                    isDense: true,
                    suffixIcon: query.isNotEmpty
                        ? IconButton(
                            tooltip: 'Limpiar búsqueda',
                            onPressed: () {
                              search.clear();
                              setState(() => query = '');
                            },
                            icon: const Icon(Icons.close, size: 16),
                          )
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                tooltip: grouped ? 'Ver lista' : 'Agrupar conexiones',
                onPressed: () => setState(() => grouped = !grouped),
                icon: Icon(
                  grouped
                      ? Icons.account_tree_outlined
                      : Icons.format_list_bulleted,
                  size: 20,
                ),
              ),
              IconButton(
                tooltip: 'Ordenar por nombre',
                onPressed: () => setState(() => sortAscending = !sortAscending),
                icon: Icon(sortAscending ? Icons.north : Icons.south, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (error != null)
            MaterialBanner(
              content: Text(error!),
              actions: [
                TextButton(onPressed: _load, child: const Text('Reintentar')),
              ],
            ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                ? _empty(profiles.isEmpty)
                : LayoutBuilder(
                    builder: (context, box) => Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: _table(filtered)),
                        if (selected != null && box.maxWidth > 850) ...[
                          const SizedBox(width: 22),
                          SizedBox(width: 240, child: _details(selected)),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _empty(bool noProfiles) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Icon(
            noProfiles ? Icons.devices_rounded : Icons.search_off_rounded,
            size: 42,
            color: accent,
          ),
        ),
        const SizedBox(height: 22),
        Text(
          noProfiles ? 'Tu próxima conexión empieza aquí' : 'Sin coincidencias',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        Text(
          noProfiles
              ? 'Trae tus perfiles de Remmina o añade tu primer equipo.'
              : 'Prueba otro nombre, servidor o grupo.',
          style: const TextStyle(color: Colors.grey, fontSize: 12),
        ),
        if (noProfiles) ...[
          const SizedBox(height: 22),
          Wrap(
            spacing: 12,
            children: [
              FilledButton.icon(
                onPressed: importing ? null : () => _import(detected: true),
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('Importar Remmina de este equipo'),
              ),
              TextButton(
                onPressed: () => _edit(),
                child: const Text('Crear un perfil'),
              ),
            ],
          ),
        ],
      ],
    ),
  );

  Widget _table(List<RemminaProfile> items) {
    final groups = <String, List<RemminaProfile>>{};
    for (final p in items) {
      groups.putIfAbsent(grouped ? p.group : '', () => []).add(p);
    }
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(18, 8, 48, 14),
          child: Row(
            children: [
              SizedBox(width: 50),
              Expanded(
                flex: 5,
                child: Text(
                  'NOMBRE',
                  style: TextStyle(
                    fontSize: 9,
                    letterSpacing: 1.4,
                    color: Colors.grey,
                  ),
                ),
              ),
              Expanded(
                flex: 4,
                child: Text(
                  'SERVIDOR',
                  style: TextStyle(
                    fontSize: 9,
                    letterSpacing: 1.4,
                    color: Colors.grey,
                  ),
                ),
              ),
              SizedBox(
                width: 70,
                child: Text(
                  'PROTOCOLO',
                  style: TextStyle(
                    fontSize: 9,
                    letterSpacing: 1.1,
                    color: Colors.grey,
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: [
              for (final entry in groups.entries) ...[
                if (grouped)
                  InkWell(
                    onTap: () => setState(
                      () => collapsed.contains(entry.key)
                          ? collapsed.remove(entry.key)
                          : collapsed.add(entry.key),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 15,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            collapsed.contains(entry.key)
                                ? Icons.chevron_right
                                : Icons.expand_more,
                            size: 17,
                            color: Colors.grey,
                          ),
                          const SizedBox(width: 7),
                          Text(
                            entry.key.isEmpty ? 'Sin grupo' : entry.key,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 9),
                          Text(
                            '${entry.value.length}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (!grouped || !collapsed.contains(entry.key))
                  ...entry.value.map(_row),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(RemminaProfile p) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Material(
      color: p.id == selectedId
          ? accent.withValues(alpha: .12)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () => setState(() => selectedId = p.id),
        onDoubleTap: () => _connect(p),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 13, 7, 13),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color:
                      (p.protocol == 'SSH' ? const Color(0xff79cfb4) : accent)
                          .withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  p.protocol == 'SSH'
                      ? Icons.terminal_rounded
                      : Icons.desktop_windows_outlined,
                  size: 18,
                  color: p.protocol == 'SSH' ? const Color(0xff79cfb4) : accent,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      p.username.isEmpty ? 'Usuario al conectar' : p.username,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 4,
                child: Text(
                  p.server,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.grey,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              Container(
                width: 57,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 5),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  p.protocol,
                  style: const TextStyle(
                    fontSize: 9,
                    color: accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              PopupMenuButton<String>(
                tooltip: 'Acciones de ${p.name}',
                icon: const Icon(Icons.more_horiz, size: 19),
                onSelected: (v) => _profileAction(v, p),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'connect',
                    child: Text('Conectar'),
                  ),
                  const PopupMenuItem(value: 'edit', child: Text('Editar')),
                  PopupMenuItem(
                    value: 'favorite',
                    child: Text(
                      p.favorite ? 'Quitar de favoritas' : 'Añadir a favoritas',
                    ),
                  ),
                  const PopupMenuItem(value: 'copy', child: Text('Duplicar')),
                  const PopupMenuItem(
                    value: 'export',
                    child: Text('Exportar .remmina'),
                  ),
                  const PopupMenuItem(value: 'delete', child: Text('Eliminar')),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _details(RemminaProfile p) => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: accent.withValues(alpha: .035),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Theme.of(context).dividerColor),
    ),
    child: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'DETALLES DEL EQUIPO',
                style: TextStyle(
                  fontSize: 9,
                  letterSpacing: 1,
                  color: Colors.grey,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Favorita',
                onPressed: () => _profileAction('favorite', p),
                icon: Icon(
                  p.favorite ? Icons.star : Icons.star_border,
                  size: 18,
                  color: accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Icon(
            p.protocol == 'SSH'
                ? Icons.terminal
                : Icons.desktop_windows_outlined,
            color: accent,
            size: 32,
          ),
          const SizedBox(height: 15),
          Text(
            p.name,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 25),
          for (final field in {
            'Servidor': p.server,
            'Protocolo': p.protocol,
            'Usuario': p.username,
            'Grupo': p.group,
            'Dominio': p.domain,
          }.entries)
            if (field.value.isNotEmpty) ...[
              Text(
                field.key.toUpperCase(),
                style: const TextStyle(
                  fontSize: 9,
                  color: Colors.grey,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 7),
              SelectableText(field.value, style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 20),
            ],
          if (p.notes.isNotEmpty) ...[
            const Divider(),
            const SizedBox(height: 12),
            Text(p.notes, style: const TextStyle(fontSize: 11, height: 1.7)),
            const SizedBox(height: 20),
          ],
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _connect(p),
              icon: const Icon(Icons.arrow_forward, size: 16),
              label: const Text('Conectar'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => _edit(p),
              child: const Text('Editar perfil'),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Doble clic en un equipo para conectar.',
            style: TextStyle(fontSize: 10, color: Colors.grey),
          ),
        ],
      ),
    ),
  );
}
