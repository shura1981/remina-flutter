/// A Remmina GLib key file. Unknown settings and other sections survive edits.
class RemminaProfile {
  RemminaProfile({
    required this.id,
    required Map<String, String> values,
    this.sourcePath,
  }) : values = Map.unmodifiable(values),
       _originalValues = const {},
       _document = null;

  RemminaProfile._(
    this._document,
    this._originalValues, {
    required this.id,
    required Map<String, String> values,
    this.sourcePath,
  }) : values = Map.unmodifiable(values);

  final String id;
  final String? sourcePath;
  final Map<String, String> values;
  final Map<String, String> _originalValues;
  final String? _document;

  String get name => get('name', 'Sin nombre');
  String get server => get('server');
  String get protocol => get('protocol', 'RDP').toUpperCase();
  String get group => get('group');
  String get username => get('username');
  String get domain => get('domain');
  String get notes => get('notes_text', get('notes'));
  bool get favorite => flag('remina_favorite');

  String get(String key, [String fallback = '']) => values[key] ?? fallback;

  bool flag(String key) =>
      const {'1', 'true', 'yes'}.contains(get(key).toLowerCase());

  /// Existing encrypted values remain opaque. A dot is a keyring reference,
  /// never the user's password. The app does not write new plain-text secrets.
  bool get hasNewStoredSecrets => values.entries.any((entry) {
    final key = entry.key.toLowerCase();
    final secret =
        key != 'disablepasswordstoring' &&
        (key.contains('password') || key.contains('passphrase'));
    return secret &&
        entry.value.isNotEmpty &&
        entry.value != '.' &&
        entry.value != _originalValues[entry.key];
  });

  RemminaProfile copyWith({
    String? id,
    Map<String, String>? values,
    String? sourcePath,
  }) {
    if (_document == null) {
      return RemminaProfile(
        id: id ?? this.id,
        values: values ?? this.values,
        sourcePath: sourcePath ?? this.sourcePath,
      );
    }
    return RemminaProfile._(
      _document,
      _originalValues,
      id: id ?? this.id,
      values: values ?? this.values,
      sourcePath: sourcePath ?? this.sourcePath,
    );
  }

  factory RemminaProfile.parse(
    String text, {
    required String id,
    String? sourcePath,
  }) {
    final values = <String, String>{};
    var section = '';
    var found = false;
    for (final line in _lines(text)) {
      final trimmed = line.trim();
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        section = trimmed.substring(1, trimmed.length - 1);
        found |= section == 'remmina';
      } else if (section == 'remmina') {
        final key = _key(line);
        if (key != null) {
          // GLib ignores leading whitespace in values, but trailing whitespace
          // is meaningful. Leading spaces are represented with \s.
          values[key] = _unescape(
            line.substring(line.indexOf('=') + 1).trimLeft(),
          );
        }
      }
    }
    if (!found) {
      throw const FormatException(
        'El archivo no contiene una sección [remmina].',
      );
    }
    return RemminaProfile._(
      text,
      Map.unmodifiable(values),
      id: id,
      values: values,
      sourcePath: sourcePath,
    );
  }

  String serialize() {
    for (final key in values.keys) {
      if (key.isEmpty || RegExp(r'[\r\n=\[\]]').hasMatch(key)) {
        throw FormatException('Nombre de configuración inválido: $key');
      }
    }
    final document = _document;
    if (document == null) {
      return '[remmina]\n${values.entries.map((e) => '${e.key}=${_escape(e.value)}\n').join()}';
    }
    if (_sameValues(values, _originalValues)) return document;
    final lines = _lines(document);
    final lastKeyIndex = <String, int>{};
    var section = '';
    var insertionIndex = 0;
    for (var i = 0; i < lines.length; i++) {
      final trimmed = lines[i].trim();
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        section = trimmed.substring(1, trimmed.length - 1);
      }
      if (section == 'remmina') {
        insertionIndex = i + 1;
        final key = _key(lines[i]);
        if (key != null) lastKeyIndex[key] = i;
      }
    }
    final additions = values.entries
        .where((entry) => !lastKeyIndex.containsKey(entry.key))
        .map((entry) => '${entry.key}=${_escape(entry.value)}');
    final output = <String>[];
    section = '';
    for (var i = 0; i <= lines.length; i++) {
      if (i == insertionIndex) output.addAll(additions);
      if (i == lines.length) break;
      final line = lines[i];
      final trimmed = line.trim();
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        section = trimmed.substring(1, trimmed.length - 1);
      }
      final key = section == 'remmina' ? _key(line) : null;
      if (key != null) {
        if (!values.containsKey(key)) continue;
        if (lastKeyIndex[key] == i && values[key] != _originalValues[key]) {
          output.add('$key=${_escape(values[key]!)}');
          continue;
        }
      }
      output.add(line);
    }
    final newline = document.contains('\r\n') ? '\r\n' : '\n';
    final prefix = document.startsWith('\uFEFF') ? '\uFEFF' : '';
    return '$prefix${output.join(newline)}$newline';
  }

  static List<String> _lines(String text) {
    final lines = text
        .replaceFirst(RegExp(r'^\uFEFF'), '')
        .split(RegExp(r'\r?\n'));
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    return lines;
  }

  static String? _key(String line) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('#') ||
        trimmed.startsWith(';') ||
        trimmed.startsWith('[')) {
      return null;
    }
    final separator = line.indexOf('=');
    if (separator < 1) return null;
    final key = line.substring(0, separator).trim();
    return key.isEmpty ? null : key;
  }

  static bool _sameValues(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length &&
      a.entries.every((entry) => b[entry.key] == entry.value);

  static String _unescape(String value) {
    final result = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      if (value[i] == r'\' && i + 1 < value.length) {
        final next = value[++i];
        result.write(switch (next) {
          's' => ' ',
          'n' => '\n',
          't' => '\t',
          'r' => '\r',
          r'\' => r'\',
          _ => '\\$next',
        });
      } else {
        result.write(value[i]);
      }
    }
    return result.toString();
  }

  static String _escape(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t')
      .replaceAll(' ', r'\s');
}
