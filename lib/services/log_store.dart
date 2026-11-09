import 'dart:async';
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
  final List<String> _pending = <String>[];
  Timer? _flushTimer;
  bool _writing = false;
  int _dropped = 0;

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
    // A malformed core can emit an enormous line; cap both memory and disk cost.
    if (_pending.length >= 512) {
      _pending.removeAt(0);
      _dropped++;
    }
    _pending.add(line.length > 16 * 1024 ? line.substring(0, 16 * 1024) : line);
    if (_pending.length >= 64 && !_writing) return _flushPending();
    _flushTimer ??= Timer(const Duration(milliseconds: 250), () {
      _flushTimer = null;
      _flushPending();
    });
    return Future<void>.value();
  }

  Future<void> clear() async {
    await flush();
    await _enqueue(() async {
      final log = await file();
      await log.writeAsString('', flush: true);
    });
  }

  Future<void> flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    return _queue.then((_) => _flushPending());
  }

  Future<void> _flushPending() {
    if (_writing || _pending.isEmpty) return _queue;
    final batch = <String>[
      if (_dropped > 0)
        '[GhostBox] Skipped $_dropped log lines during output flood',
      ..._pending
    ];
    _dropped = 0;
    _writing = true;
    _pending.clear();
    return _enqueue(() async {
      final log = await file();
      await log.writeAsString('${batch.join('\n')}\n', mode: FileMode.append);
      if (batch.any((line) => line.contains('  Подключение: ')) ||
          await log.length() > _maxBytes) await _compact();
    }).whenComplete(() {
      _writing = false;
      if (_pending.isNotEmpty) {
        _flushTimer ??= Timer(const Duration(milliseconds: 250), () {
          _flushTimer = null;
          _flushPending();
        });
      }
    });
  }

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
