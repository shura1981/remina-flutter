import 'package:flutter_test/flutter_test.dart';
import 'package:remina/models/remmina_profile.dart';

void main() {
  test('unchanged GLib file survives byte-for-byte including other sections', () {
    const source =
        '# conexión\r\n[remmina]\r\nname=Oficina\\scentral\r\nserver=[2001:db8::1]:3390\r\npassword=.\r\nplugin_extension=opaque\\q\r\n[custom]\r\nname=other\r\n';
    final profile = RemminaProfile.parse(source, id: 'a');
    expect(profile.name, 'Oficina central');
    expect(profile.server, '[2001:db8::1]:3390');
    expect(profile.get('plugin_extension'), r'opaque\q');
    expect(profile.serialize(), source);
    expect(profile.hasNewStoredSecrets, isFalse);
  });

  test('editing changes only Remmina values and preserves extension sections', () {
    const source =
        '# preserved\n[remmina]\nname=First\nname=Last\nunknown_option=a=b;c#d\nnotes=one\\ntwo\n[extension]\nname=Untouched\n';
    final profile = RemminaProfile.parse(source, id: 'a');
    expect(profile.name, 'Last');
    expect(profile.notes, 'one\ntwo');
    final edited = profile.copyWith(
      values: {...profile.values, 'name': 'New name', 'group': 'Team / Data'},
    );
    final result = edited.serialize();
    expect(result, contains('# preserved\n'));
    expect(result, contains('unknown_option=a=b;c#d\n'));
    expect(result, contains('[extension]\nname=Untouched\n'));
    final reparsed = RemminaProfile.parse(result, id: 'b');
    expect(reparsed.name, 'New name');
    expect(reparsed.group, 'Team / Data');
    expect(reparsed.notes, 'one\ntwo');
  });

  test('removing a duplicate setting removes every occurrence', () {
    final profile = RemminaProfile.parse(
      '[remmina]\nname=A\nname=B\n',
      id: 'a',
    );
    expect(profile.copyWith(values: {}).serialize(), '[remmina]\n');
  });

  test('editing retains BOM and CRLF line endings', () {
    final profile = RemminaProfile.parse(
      '\uFEFF[remmina]\r\nname=Old\r\n',
      id: 'a',
    );
    expect(
      profile.copyWith(values: {'name': 'New'}).serialize(),
      '\uFEFF[remmina]\r\nname=New\r\n',
    );
  });

  test('new profiles round trip GLib whitespace and literal backslashes', () {
    final profile = RemminaProfile(
      id: 'a',
      values: {
        'name': '  Leading and trailing  ',
        'notes': 'new\nline\tand\rcarriage',
        'path': r'C:\Users\My Files',
      },
    );
    expect(
      RemminaProfile.parse(profile.serialize(), id: 'a').values,
      profile.values,
    );
  });

  test('uses Remmina notes_text with support for legacy notes', () {
    expect(
      RemminaProfile(
        id: 'a',
        values: {'notes_text': 'current', 'notes': 'legacy'},
      ).notes,
      'current',
    );
    expect(
      RemminaProfile(id: 'a', values: {'notes': 'legacy'}).notes,
      'legacy',
    );
  });

  test('rejects missing Remmina section and setting key injection', () {
    expect(
      () => RemminaProfile.parse('[other]\nname=A', id: 'a'),
      throwsFormatException,
    );
    expect(
      () => RemminaProfile(
        id: 'a',
        values: {'name\npassword': 'oops'},
      ).serialize(),
      throwsFormatException,
    );
  });

  test(
    'distinguishes unchanged opaque secrets and new plaintext credentials',
    () {
      final profile = RemminaProfile.parse(
        '[remmina]\npassword=encrypted-data\n',
        id: 'a',
      );
      expect(profile.hasNewStoredSecrets, isFalse);
      expect(
        profile
            .copyWith(values: {...profile.values, 'password': 'plaintext'})
            .hasNewStoredSecrets,
        isTrue,
      );
      expect(
        profile
            .copyWith(values: {...profile.values, 'password': '.'})
            .hasNewStoredSecrets,
        isFalse,
      );
      expect(
        RemminaProfile(
          id: 'a',
          values: {'ssh_tunnel_passphrase': 'secret'},
        ).hasNewStoredSecrets,
        isTrue,
      );
    },
  );
}
