import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:remina/main.dart';
import 'package:remina/models/remmina_profile.dart';
import 'package:remina/services/preferences.dart';
import 'package:remina/services/profile_repository.dart';
import 'package:remina/sessions/ssh_session.dart';

class MemoryPreferences extends AppPreferences {
  @override
  Future<void> load() async {}
  @override
  Future<void> save() async {}
}

class MemoryRepository extends ProfileRepository {
  MemoryRepository() : super(Directory('/unused-memory-repository'));

  final Map<String, RemminaProfile> profiles = {};

  @override
  Future<List<RemminaProfile>> load() async =>
      profiles.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  @override
  Future<void> save(RemminaProfile profile) async {
    profiles[profile.id] = profile;
  }

  @override
  Future<void> delete(RemminaProfile profile) async {
    profiles.remove(profile.id);
  }

  @override
  Future<List<RemminaProfile>> importFiles(List<File> files) async =>
      throw UnsupportedError('Native file selection is outside widget tests.');

  @override
  Future<void> exportProfile(RemminaProfile profile, File destination) async =>
      throw UnsupportedError('Native file selection is outside widget tests.');

  @override
  Future<int> exportAll(
    List<RemminaProfile> profiles,
    Directory destination,
  ) async => profiles.length;

  @override
  Future<List<RemminaProfile>> importDirectory(Directory dir) async =>
      throw UnsupportedError('Native file selection is outside widget tests.');
}

void main() {
  late MemoryRepository repository;
  setUp(() {
    repository = MemoryRepository();
  });

  Future<void> openLibrary(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ReminaApp(repository: repository, preferences: MemoryPreferences()),
    );
    await tester.pumpAndSettle();
  }

  for (final size in const [
    Size(1040, 680),
    Size(1040, 720),
    Size(1280, 800),
  ]) {
    testWidgets('empty library and editor fit ${size.width}×${size.height}', (
      tester,
    ) async {
      await openLibrary(tester, size);
      expect(find.text('Tu próxima conexión empieza aquí'), findsOneWidget);
      expect(find.text('Importar Remmina de este equipo'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Nueva conexión'));
      await tester.pumpAndSettle();
      expect(find.text('Guardar conexión'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'search and protocol filter operate on stored profiles at minimum size',
    (tester) async {
      await repository.save(
        RemminaProfile(
          id: 'rdp',
          values: {
            'name': 'Oficina demo',
            'server': 'desktop.example.invalid',
            'protocol': 'RDP',
            'group': 'Trabajo',
          },
        ),
      );
      await repository.save(
        RemminaProfile(
          id: 'ssh',
          values: {
            'name': 'Terminal demo',
            'server': 'ssh.example.invalid',
            'protocol': 'SSH',
            'username': 'demo',
          },
        ),
      );
      await openLibrary(tester, const Size(1040, 720));
      expect(find.text('Oficina demo'), findsOneWidget);
      expect(find.text('Terminal demo'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'ssh.example');
      await tester.pumpAndSettle();
      expect(find.text('Oficina demo'), findsNothing);
      expect(find.text('Terminal demo'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField).last, '');
      await tester.tap(find.text('Escritorio RDP'));
      await tester.pumpAndSettle();
      expect(find.text('Oficina demo'), findsOneWidget);
      expect(find.text('Terminal demo'), findsNothing);
    },
  );

  testWidgets('closing an empty library confirms and shares pending requests', (
    tester,
  ) async {
    await openLibrary(tester, const Size(1280, 800));
    final first = tester.binding.handleRequestAppExit();
    final repeated = tester.binding.handleRequestAppExit();
    await tester.pumpAndSettle();
    expect(find.text('Salir de Remina Desktop'), findsOneWidget);
    expect(find.text('¿Quieres salir de Remina Desktop?'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(await first, AppExitResponse.cancel);
    expect(await repeated, AppExitResponse.cancel);

    final exiting = tester.binding.handleRequestAppExit();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Salir'));
    await tester.pumpAndSettle();
    expect(await exiting, AppExitResponse.exit);
    expect(tester.takeException(), isNull);
  });

  for (final closeTabFirst in [false, true]) {
    testWidgets(
      'closing the app after opening a session (closed: $closeTabFirst)',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        await repository.save(
          RemminaProfile(
            id: 'exit-test',
            values: {
              'name': 'Salida SSH',
              'server': 'host.example.invalid',
              'protocol': 'SSH',
              'username': 'demo',
              // Fail before network or filesystem work: this is a real session tab
              // that lets the test exercise exit ownership without an SSH server.
              'ssh_tunnel_enabled': '1',
            },
          ),
        );
        await openLibrary(tester, const Size(1280, 800));
        await tester.tap(find.byTooltip('Acciones de Salida SSH'));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Conectar'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Conectar'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(SshSessionView), findsOneWidget);
        expect(
          find.textContaining('Este perfil requiere un túnel SSH.'),
          findsOneWidget,
        );

        if (closeTabFirst) {
          await tester.tap(find.byIcon(Icons.close));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, 'Cerrar sesión'));
          await tester.pumpAndSettle();
          expect(find.byType(SshSessionView), findsNothing);
        }

        final canceled = tester.binding.handleRequestAppExit();
        await tester.pumpAndSettle();
        expect(find.text('Salir de Remina Desktop'), findsOneWidget);
        await tester.tap(find.text('Cancelar'));
        await tester.pumpAndSettle();
        expect(await canceled, AppExitResponse.cancel);
        expect(
          find.byType(SshSessionView),
          closeTabFirst ? findsNothing : findsOneWidget,
        );
        expect(
          find.textContaining('Este perfil requiere un túnel SSH.'),
          closeTabFirst ? findsNothing : findsOneWidget,
        );

        final exiting = tester.binding.handleRequestAppExit();
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(
            FilledButton,
            closeTabFirst ? 'Salir' : 'Cerrar conexiones y salir',
          ),
        );
        await tester.pumpAndSettle();
        expect(await exiting, AppExitResponse.exit);
        expect(find.byType(SshSessionView), findsNothing);
        expect(find.text('1 perfiles · 0 pestañas de sesión'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('opens about and license dialog', (tester) async {
    await openLibrary(tester, const Size(1280, 800));
    await tester.tap(find.text('Acerca de y Licencias'));
    await tester.pumpAndSettle();
    expect(find.text('Versión 1.0.0+1 · Multiplataforma'), findsOneWidget);
    expect(find.textContaining('Licencia del Proyecto'), findsOneWidget);
    expect(find.text('Ver licencias de terceros'), findsOneWidget);
    await tester.tap(find.text('Cerrar'));
    await tester.pumpAndSettle();
    expect(find.text('Versión 1.0.0+1 · Multiplataforma'), findsNothing);
  });

  testWidgets('shows import options dialog with file and folder choices', (
    tester,
  ) async {
    await openLibrary(tester, const Size(1280, 800));
    await tester.tap(find.text('Importar'));
    await tester.pumpAndSettle();
    expect(find.text('Importar conexiones'), findsOneWidget);
    expect(find.text('Seleccionar archivos (.remmina)'), findsOneWidget);
    expect(find.text('Seleccionar carpeta con conexiones'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.text('Importar conexiones'), findsNothing);
  });

  testWidgets('shows export option inside preferences dialog', (tester) async {
    await openLibrary(tester, const Size(1280, 800));
    await tester.tap(find.text('Preferencias'));
    await tester.pumpAndSettle();
    expect(find.text('Migración y Copia de Seguridad'), findsOneWidget);
    expect(find.text('Exportar todas las conexiones'), findsOneWidget);
    await tester.tap(find.text('Cerrar'));
    await tester.pumpAndSettle();
    expect(find.text('Migración y Copia de Seguridad'), findsNothing);
  });
}
