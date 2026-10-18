import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remina/models/remmina_profile.dart';
import 'package:remina/ui/profile_editor.dart';

void main() {
  Future<void> openEditor(
    WidgetTester tester, {
    RemminaProfile? profile,
    required ValueChanged<RemminaProfile?> onResult,
  }) async {
    tester.view.physicalSize = const Size(1100, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  onResult(await showProfileEditor(context, profile: profile)),
              child: const Text('Abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
  }

  testWidgets('edits preserve opaque secrets, comments, and plugin sections', (
    tester,
  ) async {
    final original = RemminaProfile.parse(
      '# Perfil original\n[remmina]\nname=Oficina\nserver=host:3389\n'
      'protocol=RDP\npassword=opaque-encrypted-value\ncustom_plugin=keep\n'
      '[plugin]\nsetting=untouched\n',
      id: 'original',
      sourcePath: '/tmp/original.remmina',
    );
    RemminaProfile? saved;
    await openEditor(
      tester,
      profile: original,
      onResult: (value) => saved = value,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Nombre'),
      'Casa',
    );
    await tester.tap(find.text('Guardar conexión'));
    await tester.pumpAndSettle();

    expect(saved?.name, 'Casa');
    expect(saved?.id, 'original');
    expect(saved?.sourcePath, '/tmp/original.remmina');
    expect(saved?.get('custom_plugin'), 'keep');
    expect(saved?.get('password'), 'opaque-encrypted-value');
    expect(saved?.hasNewStoredSecrets, isFalse);
    expect(saved?.serialize(), contains('# Perfil original'));
    expect(saved?.serialize(), contains('[plugin]\nsetting=untouched'));
  });

  testWidgets('validates required host and port before returning a profile', (
    tester,
  ) async {
    RemminaProfile? saved;
    await openEditor(tester, onResult: (value) => saved = value);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Nombre'),
      'Casa',
    );
    await tester.tap(find.text('Guardar conexión'));
    await tester.pumpAndSettle();
    expect(find.text('Escribe el host o la IP del servidor.'), findsOneWidget);
    expect(saved, isNull);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Servidor'),
      'host:70000',
    );
    await tester.tap(find.text('Guardar conexión'));
    await tester.pumpAndSettle();
    expect(find.text('El puerto debe estar entre 1 y 65535.'), findsOneWidget);
    expect(saved, isNull);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Servidor'),
      '[::1]:3389',
    );
    await tester.tap(find.text('Guardar conexión'));
    await tester.pumpAndSettle();
    expect(saved?.server, '[::1]:3389');
  });

  testWidgets('SSH requires a username', (tester) async {
    RemminaProfile? saved;
    await openEditor(
      tester,
      profile: RemminaProfile(
        id: 'ssh',
        values: {'name': 'SSH', 'server': 'localhost', 'protocol': 'SSH'},
      ),
      onResult: (value) => saved = value,
    );
    await tester.tap(find.text('Guardar conexión'));
    await tester.pumpAndSettle();
    expect(find.text('Escribe el usuario de la conexión.'), findsOneWidget);
    expect(saved, isNull);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Usuario'),
      'steven',
    );
    await tester.tap(find.text('Guardar conexión'));
    await tester.pumpAndSettle();
    expect(saved?.username, 'steven');
  });
}
