import 'dart:io';

/// Applies the per-user GNOME/GTK proxy preference and restores its exact
/// previous values when the VPN stops. This does not claim to proxy apps that
/// ignore the desktop proxy setting; TUN is the full-device mode.
class LinuxSystemProxy {
  Map<String, String>? _previous;

  static const _values = <String, (String, String)>{
    // gsettings expects quoted GVariant strings, and prints them quoted too.
    'mode': ('org.gnome.system.proxy', "'manual'"),
    'use-same-proxy': ('org.gnome.system.proxy', 'true'),
    'socks.host': ('org.gnome.system.proxy.socks', "'127.0.0.1'"),
    'socks.port': ('org.gnome.system.proxy.socks', '2080'),
  };

  Future<void> enable(int port) async {
    if (!Platform.isLinux) {
      throw const ProcessException('gsettings', [],
          'System proxy integration is currently available on Linux.');
    }
    const schema = 'org.gnome.system.proxy';
    final schemas = await Process.run('gsettings', ['list-schemas']);
    if (schemas.exitCode != 0 ||
        !('${schemas.stdout}'.split('\n').contains(schema))) {
      throw const ProcessException(
          'gsettings', [], 'GNOME/GTK system proxy settings are unavailable.');
    }
    if (_previous == null) {
      final snapshot = <String, String>{};
      for (final entry in _values.entries) {
        final result = await Process.run(
            'gsettings', ['get', entry.value.$1, entry.key.split('.').last]);
        if (result.exitCode != 0) {
          throw ProcessException('gsettings',
              [entry.value.$1, entry.key.split('.').last], '${result.stderr}');
        }
        snapshot[entry.key] = '${result.stdout}'.trim();
      }
      _previous = snapshot;
    }

    final values = Map<String, (String, String)>.from(_values)
      ..['socks.port'] = ('org.gnome.system.proxy.socks', '$port');
    try {
      for (final entry in values.entries) {
        final key = entry.key.split('.').last;
        final result = await Process.run(
            'gsettings', ['set', entry.value.$1, key, entry.value.$2]);
        if (result.exitCode != 0) {
          throw ProcessException(
              'gsettings', [entry.value.$1, key], '${result.stderr}');
        }
        final readBack =
            await Process.run('gsettings', ['get', entry.value.$1, key]);
        if (readBack.exitCode != 0 ||
            !_sameVariant('${readBack.stdout}', entry.value.$2)) {
          throw ProcessException('gsettings', ['get', entry.value.$1, key],
              'System proxy preference did not persist. ${readBack.stderr}');
        }
      }
    } on Object {
      await restore();
      rethrow;
    }
  }

  bool _sameVariant(String actual, String expected) {
    String canonical(String value) {
      final trimmed = value.trim();
      if (trimmed.startsWith("'") && trimmed.endsWith("'")) {
        return trimmed.substring(1, trimmed.length - 1).replaceAll("\\'", "'");
      }
      return trimmed;
    }

    return canonical(actual) == canonical(expected);
  }

  Future<void> restore() async {
    final previous = _previous;
    _previous = null;
    if (previous == null || !Platform.isLinux) return;
    for (final entry in previous.entries.toList().reversed) {
      final parts = entry.key.split('.');
      final schema = parts.length == 1
          ? 'org.gnome.system.proxy'
          : 'org.gnome.system.proxy.${parts.first}';
      await Process.run('gsettings', ['set', schema, parts.last, entry.value]);
    }
  }
}
