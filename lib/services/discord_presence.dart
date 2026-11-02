import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Optional Linux/macOS Rich Presence over Discord's local IPC socket.
/// No profile names, addresses or IPs are sent.
class DiscordPresence {
  DiscordPresence._();

  static final DiscordPresence instance = DiscordPresence._();

  static const String clientId =
      String.fromEnvironment('GHOSTBOX_DISCORD_CLIENT_ID');

  Socket? _socket;
  StreamSubscription<List<int>>? _socketSubscription;
  String? _lastDetails;
  String? _lastActivityState;
  String? _lastActivityKey;
  DateTime? _connectedAt;
  Timer? _retryTimer;
  bool _connecting = false;
  bool _enabled = false;
  Completer<void>? _ready;
  final Map<String, Completer<void>> _requests = {};
  final List<int> _incoming = [];
  Timer? _publishTimer;
  DateTime? _lastSentAt;
  static const _publishInterval = Duration(seconds: 5);

  static bool get supported =>
      !kIsWeb && (Platform.isLinux || Platform.isMacOS);

  static bool get configured => clientId.trim().isNotEmpty;

  Future<void> update({
    required bool enabled,
    required bool connected,
    required String status,
    required String speed,
    required Duration connectedFor,
  }) async {
    _enabled = enabled && supported && configured;
    if (!_enabled) {
      _retryTimer?.cancel();
      _retryTimer = null;
      _publishTimer?.cancel();
      _publishTimer = null;
      await _sendActivity(null, null).catchError((Object _) {});
      await _close();
      return;
    }
    if (connected) {
      _connectedAt ??= DateTime.now().subtract(connectedFor);
    } else {
      _connectedAt = null;
    }
    _lastDetails = status;
    _lastActivityState = connected ? speed : null;
    _lastActivityKey = '$status\n${_lastActivityState ?? ''}\n$_connectedAt';
    await _retry();
  }

  String? _lastSentActivityKey;

  Future<void> dispose() async {
    _enabled = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _publishTimer?.cancel();
    _publishTimer = null;
    await _sendActivity(null, null).catchError((Object _) {});
    await _close();
  }

  Future<void> _connect() async {
    Object? lastError;
    for (final directory in _socketDirectories()) {
      for (var index = 0; index < 10; index++) {
        final path = '$directory/discord-ipc-$index';
        try {
          final socket = await Socket.connect(
            InternetAddress(path, type: InternetAddressType.unix),
            0,
            timeout: const Duration(milliseconds: 350),
          );
          _socket = socket;
          _incoming.clear();
          final ready = _ready = Completer<void>();
          _socketSubscription = socket.listen(
            _onData,
            onDone: () => _onSocketClosed(socket),
            onError: (Object _) => _onSocketClosed(socket),
            cancelOnError: true,
          );
          _sendFrame(0, {'v': 1, 'client_id': clientId.trim()});
          await ready.future.timeout(const Duration(seconds: 5));
          return;
        } on Object catch (error) {
          lastError = error;
          await _close();
        }
      }
    }
    throw SocketException('Discord IPC is unavailable: $lastError');
  }

  List<String> _socketDirectories() {
    final environment = Platform.environment;
    final directories = <String>[];
    final runtimeDirectory = environment['XDG_RUNTIME_DIR'];
    if (Platform.isLinux &&
        runtimeDirectory != null &&
        runtimeDirectory.isNotEmpty) {
      // Recent Linux Discord builds keep their IPC endpoint in this
      // application-specific runtime directory instead of XDG_RUNTIME_DIR.
      directories.add('$runtimeDirectory/app/com.discordapp.Discord');
    }
    final preferred = <String>[
      environment['XDG_RUNTIME_DIR'] ?? '',
      environment['TMPDIR'] ?? '',
      environment['TMP'] ?? '',
      environment['TEMP'] ?? '',
    ].firstWhere((path) => path.isNotEmpty, orElse: () => '/tmp');
    directories.add(preferred);
    if (preferred != '/tmp') directories.add('/tmp');
    return directories.toSet().toList(growable: false);
  }

  Future<void> _sendActivity(String? details, String? state) async {
    if (_socket == null) return;
    final activity = details == null
        ? null
        : <String, Object?>{
            'name': 'GhostBox',
            'type': 0,
            'details': details,
            if (state != null) 'state': state,
            // Discord hides these buttons when viewing your own presence.
            // They are displayed to other users viewing the activity.
            'buttons': [
              {
                'label': 'GitHub',
                'url': 'https://github.com/Krakva1337/GhostBox',
              },
              {
                'label': 'Telegram',
                'url': 'https://t.me/GhostBoxVPN',
              },
            ],
            if (_connectedAt != null)
              'timestamps': {'start': _connectedAt!.millisecondsSinceEpoch},
          };
    final nonce = DateTime.now().microsecondsSinceEpoch.toString();
    final response = Completer<void>();
    _requests[nonce] = response;
    _sendFrame(1, {
      'cmd': 'SET_ACTIVITY',
      'args': {'pid': pid, 'activity': activity},
      'nonce': nonce,
    });
    try {
      await response.future.timeout(const Duration(seconds: 8));
    } finally {
      _requests.remove(nonce);
    }
  }

  void _sendFrame(int opcode, Map<String, Object?> value) {
    final socket = _socket;
    if (socket == null) return;
    final payload = utf8.encode(jsonEncode(value));
    final header = ByteData(8)
      ..setInt32(0, opcode, Endian.little)
      ..setInt32(4, payload.length, Endian.little);
    socket.add(header.buffer.asUint8List());
    socket.add(payload);
  }

  void _onSocketClosed(Socket socket) {
    if (!identical(socket, _socket)) return;
    unawaited(_close());
    if (_enabled && _lastDetails != null) _scheduleRetry();
  }

  void _scheduleRetry() {
    if (!_enabled) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 30), () {
      _retryTimer = null;
      unawaited(_retry());
    });
  }

  Future<void> _retry() async {
    if (!_enabled ||
        _lastDetails == null ||
        _connecting ||
        _retryTimer?.isActive == true) return;
    if (_socket != null && _lastActivityKey == _lastSentActivityKey) return;
    final sentAt = _lastSentAt;
    if (sentAt != null) {
      final remaining = _publishInterval - DateTime.now().difference(sentAt);
      if (remaining > Duration.zero) {
        _publishTimer ??= Timer(remaining, () {
          _publishTimer = null;
          unawaited(_retry());
        });
        return;
      }
    }
    _connecting = true;
    var succeeded = false;
    try {
      if (_socket == null) await _connect();
      if (!_enabled) return;
      final key = _lastActivityKey;
      await _sendActivity(_lastDetails, _lastActivityState);
      _lastSentActivityKey = key;
      _lastSentAt = DateTime.now();
      _retryTimer?.cancel();
      _retryTimer = null;
      succeeded = true;
    } on Object {
      await _close();
      _scheduleRetry();
    } finally {
      _connecting = false;
    }
    if (succeeded && _lastActivityKey != _lastSentActivityKey) {
      unawaited(_retry());
    }
  }

  void _onData(List<int> bytes) {
    _incoming.addAll(bytes);
    while (_incoming.length >= 8) {
      final header =
          ByteData.sublistView(Uint8List.fromList(_incoming.take(8).toList()));
      final opcode = header.getUint32(0, Endian.little);
      final length = header.getUint32(4, Endian.little);
      if (length > 1024 * 1024) {
        final socket = _socket;
        if (socket != null) _onSocketClosed(socket);
        return;
      }
      if (_incoming.length < 8 + length) return;
      final payload = _incoming.sublist(8, 8 + length);
      _incoming.removeRange(0, 8 + length);
      if (opcode == 3) {
        final pong = ByteData(8)
          ..setUint32(0, 4, Endian.little)
          ..setUint32(4, length, Endian.little);
        _socket?.add(pong.buffer.asUint8List());
        _socket?.add(payload);
        continue;
      }
      try {
        final value = jsonDecode(utf8.decode(payload)) as Map;
        if (opcode == 2) {
          throw StateError('Discord closed RPC: ${value['code']}');
        }
        if (value['evt'] == 'READY') {
          if (_ready?.isCompleted == false) _ready!.complete();
        }
        final request = _requests.remove(value['nonce']);
        if (request != null && !request.isCompleted) {
          if (value['evt'] == 'ERROR') {
            request.completeError(StateError('Discord RPC: ${value['data']}'));
          } else {
            request.complete();
          }
        }
      } on Object {
        final socket = _socket;
        if (socket != null) _onSocketClosed(socket);
        return;
      }
    }
  }

  Future<void> _close() async {
    final subscription = _socketSubscription;
    final socket = _socket;
    _socketSubscription = null;
    _socket = null;
    _lastSentActivityKey = null;
    final error = StateError('Discord RPC disconnected');
    if (_ready?.isCompleted == false) _ready!.completeError(error);
    _ready = null;
    for (final request in _requests.values) {
      if (!request.isCompleted) request.completeError(error);
    }
    _requests.clear();
    _incoming.clear();
    await subscription?.cancel();
    socket?.destroy();
  }
}
