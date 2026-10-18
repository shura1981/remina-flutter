import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remina/models/remmina_profile.dart';
import 'package:remina/sessions/ssh_session.dart';

void main() {
  test('SSH endpoints handle IPv6 and explicit ports', () {
    final hostname = SshEndpoint.parse('example.test:2222');
    expect(hostname.host, 'example.test');
    expect(hostname.port, 2222);
    final ipv6 = SshEndpoint.parse('[2001:db8::1]:2200');
    expect(ipv6.host, '2001:db8::1');
    expect(ipv6.port, 2200);
    expect(SshEndpoint.parse('2001:db8::2').port, 22);
    expect(SshEndpoint.parse('example.test').port, 22);
    for (final invalid in ['', 'host:0', 'host:65536', '[::1', 'user@host']) {
      expect(() => SshEndpoint.parse(invalid), throwsA(isA<Exception>()));
    }
  });

  testWidgets('tunnel-dependent profiles are blocked before any socket opens', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SshSessionView(
            profile: RemminaProfile(
              id: 'test',
              values: {
                'protocol': 'SSH',
                'server': 'example.test',
                'username': 'test',
                'ssh_tunnel_enabled': '1',
              },
            ),
            password: '',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('requiere un túnel SSH'), findsOneWidget);
    expect(find.text('Reconectar'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('connection hooks require user review before connecting', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SshSessionView(
            profile: RemminaProfile(
              id: 'test',
              values: {
                'protocol': 'SSH',
                'server': 'example.test',
                'username': 'test',
                'precommand': 'do-not-execute',
              },
            ),
            password: '',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('contiene comandos de proxy'), findsOneWidget);
    expect(find.text('Reconectar'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
