import 'dart:convert';
import 'dart:io';

/// Uses the desktop's per-user proxy setting and restores it on disconnect.
class DesktopSystemProxy {
  final LinuxSystemProxy _linux = LinuxSystemProxy();
  final WindowsSystemProxy _windows = WindowsSystemProxy();

  Future<void> enable(int port) async {
    if (Platform.isLinux) return _linux.enable(port);
    if (Platform.isWindows) return _windows.enable(port);
    throw const ProcessException(
        'system proxy', [], 'System proxy integration is unavailable.');
  }

  Future<void> restore() async {
    if (Platform.isLinux) return _linux.restore();
    if (Platform.isWindows) return _windows.restore();
  }
}

/// Applies the per-user GNOME/GTK proxy preference and restores its exact
/// previous values when the VPN stops. This does not claim to proxy apps that
/// ignore the desktop proxy setting; TUN is the full-device mode.
class LinuxSystemProxy {
  Map<String, String>? _previous;

  File? get _snapshotFile {
    final env = Platform.environment;
    final root = env['XDG_CONFIG_HOME']?.trim().isNotEmpty == true
        ? env['XDG_CONFIG_HOME']!.trim()
        : '${env['HOME'] ?? Directory.systemTemp.path}${Platform.pathSeparator}.config';
    return File(
        '$root${Platform.pathSeparator}GhostBox${Platform.pathSeparator}linux-proxy-restore.json');
  }

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
      _previous = await _readPrevious() ?? await _readCurrentValues();
      await _persistPrevious(_previous!);
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
      try {
        await restore();
      } on Object {
        // Preserve the original failure; the durable snapshot lets the next
        // launch retry restoration if the desktop settings service is busy.
      }
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
    final previous = _previous ?? await _readPrevious();
    _previous = null;
    if (previous == null || !Platform.isLinux) return;
    for (final entry in previous.entries.toList().reversed) {
      final parts = entry.key.split('.');
      final schema = parts.length == 1
          ? 'org.gnome.system.proxy'
          : 'org.gnome.system.proxy.${parts.first}';
      final result = await Process.run(
          'gsettings', ['set', schema, parts.last, entry.value]);
      if (result.exitCode != 0) {
        throw ProcessException('gsettings', ['set', schema, parts.last],
            '${result.stderr} ${result.stdout}');
      }
    }
    final snapshot = _snapshotFile;
    if (snapshot != null && await snapshot.exists()) {
      await snapshot.delete();
    }
  }

  Future<Map<String, String>> _readCurrentValues() async {
    final snapshot = <String, String>{};
    for (final entry in _values.entries) {
      final key = entry.key.split('.').last;
      final result =
          await Process.run('gsettings', ['get', entry.value.$1, key]);
      if (result.exitCode != 0) {
        throw ProcessException(
            'gsettings', ['get', entry.value.$1, key], '${result.stderr}');
      }
      snapshot[entry.key] = '${result.stdout}'.trim();
    }
    return snapshot;
  }

  Future<void> _persistPrevious(Map<String, String> previous) async {
    final file = _snapshotFile;
    if (file == null) return;
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(previous), flush: true);
  }

  Future<Map<String, String>?> _readPrevious() async {
    final file = _snapshotFile;
    if (file == null || !await file.exists()) return null;
    try {
      final decoded = Map<String, dynamic>.from(
          jsonDecode(await file.readAsString()) as Map);
      return {
        for (final key in _values.keys)
          if (decoded[key] is String) key: decoded[key] as String,
      };
    } on Object {
      return null;
    }
  }
}

/// Configures only the current Windows user's WinINET proxy values.
class WindowsSystemProxy {
  static const _key =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  static const _values = ['ProxyEnable', 'ProxyServer', 'ProxyOverride'];
  Map<String, (String, String)?>? _previous;

  File? get _snapshotFile {
    final root = Platform.environment['APPDATA'];
    if (root == null || root.isEmpty) return null;
    return File(
        '$root${Platform.pathSeparator}GhostBox${Platform.pathSeparator}proxy-restore.json');
  }

  Future<void> enable(int port) async {
    if (!Platform.isWindows) return;
    if (_previous == null) {
      _previous = await _readValues();
      await _persistPrevious(_previous!);
    }
    try {
      await _setDword('ProxyEnable', 1);
      await _setString('ProxyServer', 'socks=127.0.0.1:$port');
      await _setString('ProxyOverride', 'localhost;127.*;<local>');
      await _notifyWinInet();
      final enabled = await _query('ProxyEnable');
      final server = await _query('ProxyServer');
      if (enabled?.$2 != '0x1' || server?.$2 != 'socks=127.0.0.1:$port') {
        throw const ProcessException(
            'reg.exe', [], 'Windows proxy preference did not persist.');
      }
    } on Object {
      await restore();
      rethrow;
    }
  }

  Future<Map<String, (String, String)?>> _readValues() async => {
        for (final name in _values) name: await _query(name),
      };

  Future<(String, String)?> _query(String name) async {
    final result = await Process.run('reg.exe', ['query', _key, '/v', name]);
    if (result.exitCode != 0) return null;
    final match = RegExp(
            '^\\s*${RegExp.escape(name)}' r'\s+(REG_SZ|REG_DWORD)\s+(.*)\s*$',
            multiLine: true)
        .firstMatch('${result.stdout}');
    if (match == null) return null;
    return (match.group(1)!, match.group(2)!.trim());
  }

  Future<void> _setDword(String name, int value) =>
      _set(name, 'REG_DWORD', '$value');

  Future<void> _setString(String name, String value) =>
      _set(name, 'REG_SZ', value);

  Future<void> _set(String name, String type, String value) async {
    final result = await Process.run(
        'reg.exe', ['add', _key, '/v', name, '/t', type, '/d', value, '/f']);
    if (result.exitCode != 0) {
      throw ProcessException(
          'reg.exe', ['add', _key, name], '${result.stderr} ${result.stdout}');
    }
  }

  Future<void> restore() async {
    if (!Platform.isWindows) return;
    final previous = _previous ?? await _readPrevious();
    _previous = null;
    if (previous == null) return;
    for (final name in _values.reversed) {
      final old = previous[name];
      if (old == null) {
        await Process.run('reg.exe', ['delete', _key, '/v', name, '/f']);
      } else {
        await _set(name, old.$1, old.$2);
      }
    }
    await _notifyWinInet();
    final snapshot = _snapshotFile;
    if (snapshot != null && await snapshot.exists()) {
      await snapshot.delete();
    }
  }

  Future<void> _persistPrevious(Map<String, (String, String)?> previous) async {
    final file = _snapshotFile;
    if (file == null) return;
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({
      for (final entry in previous.entries)
        entry.key: entry.value == null
            ? null
            : {'type': entry.value!.$1, 'value': entry.value!.$2},
    }));
  }

  Future<Map<String, (String, String)?>?> _readPrevious() async {
    final file = _snapshotFile;
    if (file == null || !await file.exists()) return null;
    try {
      final saved = Map<String, dynamic>.from(
          jsonDecode(await file.readAsString()) as Map);
      return {
        for (final name in _values)
          name: saved[name] is Map
              ? (
                  (saved[name] as Map)['type'].toString(),
                  (saved[name] as Map)['value'].toString()
                )
              : null,
      };
    } on Object {
      return null;
    }
  }

  Future<void> _notifyWinInet() async {
    const script = r'''
$source = @"
using System;
using System.Runtime.InteropServices;
public static class GhostBoxWinInet {
  [DllImport("wininet.dll", SetLastError=true)]
  public static extern bool InternetSetOption(IntPtr h, int option, IntPtr b, int n);
}
"@
if (-not ('GhostBoxWinInet' -as [type])) { Add-Type -TypeDefinition $source }
[GhostBoxWinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
[GhostBoxWinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
''';
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);
    if (result.exitCode != 0) {
      throw ProcessException('powershell.exe', const ['-Command'],
          '${result.stderr} ${result.stdout}');
    }
  }
}
