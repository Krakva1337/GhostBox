import 'dart:convert';
import 'dart:io';

/// Shared bounded journal for application and core output.
/// Writes are serialized because both the UI and core processes append to it.
class GhostBoxLogStore {
  GhostBoxLogStore._();

  static final instance = GhostBoxLogStore._();
  Future<void> _queue = Future<void>.value();
  int _retainedConnections = 10;
  int _maxBytes = 5 * 1024 * 1024;
  bool _includeCoreOutput = true;

  Future<File> file() async {
    final env = Platform.environment;
    final separator = Platform.pathSeparator;
    String? base;
    if (Platform.isLinux) {
      base = env['XDG_STATE_HOME'];
      if (base == null || base.isEmpty) {
        final home = env['HOME'];
        if (home != null && home.isNotEmpty) {
          base = '$home${separator}.local${separator}state';
        }
      }
    } else if (Platform.isWindows) {
      base = env['APPDATA'];
      if (base == null || base.isEmpty) {
        final home = env['USERPROFILE'];
        if (home != null && home.isNotEmpty) {
          base = '$home${separator}AppData${separator}Roaming';
        }
      }
    } else {
      base = env['HOME'];
    }
    base ??= Directory.systemTemp.path;
    final directory = Directory('$base${separator}GhostBox${separator}logs');
    await directory.create(recursive: true);
    return File('${directory.path}${separator}ghostbox.log');
  }

  Future<void> configure({
    required int retainedConnections,
    required int maxSizeMb,
    required bool includeCoreOutput,
  }) async {
    _retainedConnections = retainedConnections.clamp(1, 100).toInt();
    _maxBytes = maxSizeMb.clamp(1, 50).toInt() * 1024 * 1024;
    _includeCoreOutput = includeCoreOutput;
    await _enqueue(_compact);
  }

  Future<void> append(String line, {bool core = false}) {
    if (core && !_includeCoreOutput) return Future<void>.value();
    return _enqueue(() async {
      final log = await file();
      if (line.contains('  Подключение: ')) {
        final old = await log.exists() ? await log.readAsString() : '';
        final retained = _retainConnectionBlocks(
            old, (_retainedConnections - 1).clamp(0, 100));
        await log.writeAsString(retained, flush: true);
      }
      await log.writeAsString('$line\n', mode: FileMode.append, flush: true);
      final length = await log.length();
      if (length > _maxBytes) {
        final text = await log.readAsString();
        await log.writeAsString(_trimToMaxSize(text), flush: true);
      }
    });
  }

  Future<void> clear() => _enqueue(() async {
        final log = await file();
        await log.writeAsString('', flush: true);
      });

  Future<void> flush() => _queue;

  Future<void> _compact() async {
    final log = await file();
    if (!await log.exists()) return;
    final text = await log.readAsString();
    final retained = _retainConnectionBlocks(text, _retainedConnections);
    await log.writeAsString(_trimToMaxSize(retained), flush: true);
  }

  String _retainConnectionBlocks(String text, int count) {
    if (text.isEmpty) return text;
    final lines = text.split('\n');
    final starts = <int>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].contains('  Подключение: ')) starts.add(i);
    }
    if (starts.length <= count) return text;
    if (count == 0) return '';
    return '${lines.skip(starts[starts.length - count]).join('\n')}';
  }

  String _trimToMaxSize(String text) {
    final lines = text.split('\n');
    var bytes = utf8.encode(text).length;
    var first = 0;
    while (bytes > _maxBytes && first < lines.length - 1) {
      bytes -= utf8.encode('${lines[first]}\n').length;
      first++;
    }
    return lines.skip(first).join('\n');
  }

  Future<void> _enqueue(Future<void> Function() work) {
    _queue = _queue.then((_) async {
      try {
        await work();
      } on Object {
        // Journal I/O must never prevent the VPN core from starting or stopping.
      }
    });
    return _queue;
  }
}
