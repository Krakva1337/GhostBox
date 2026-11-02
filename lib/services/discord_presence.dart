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
      _sendActivity(null, null);
      await _close();
      return;
    }
    if (connected) {
      _connectedAt ??= DateTime.now().subtract(connectedFor);
    } else {
      _connectedAt = null;
    }
    _lastDetails = status;
    _lastActivityState = connected ? '$speed · Telegram' : 'Telegram';
    _lastActivityKey = '$status\n${_lastActivityState ?? ''}\n$_connectedAt';
    if (_lastActivityKey == _lastSentActivityKey && _socket != null) return;
    if (_connecting) return;

    _connecting = true;
    try {
      if (_socket == null) await _connect();
      _sendActivity(_lastDetails, _lastActivityState);
      _lastSentActivityKey = _lastActivityKey;
      _retryTimer?.cancel();
      _retryTimer = null;
    } on Object {
      await _close();
      _scheduleRetry();
    } finally {
      _connecting = false;
    }
  }

  String? _lastSentActivityKey;

  Future<void> dispose() async {
    _enabled = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _sendActivity(null, null);
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
          _socketSubscription = socket.listen(
            (_) {},
            onDone: () => _onSocketClosed(socket),
            onError: (Object _) => _onSocketClosed(socket),
            cancelOnError: true,
          );
          _sendFrame(0, {'v': 1, 'client_id': clientId.trim()});
          return;
        } on Object catch (error) {
          lastError = error;
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

  void _sendActivity(String? details, String? state) {
    if (_socket == null) return;
    final activity = details == null
        ? null
        : <String, Object?>{
            'name': 'GhostBox',
            'type': 0,
            'details': details,
            'details_url': 'https://github.com/Krakva1337/GhostBox',
            if (state != null) 'state': state,
            'state_url': 'https://t.me/GhostBoxVPN',
            if (_connectedAt != null)
              'timestamps': {'start': _connectedAt!.millisecondsSinceEpoch},
          };
    _sendFrame(1, {
      'cmd': 'SET_ACTIVITY',
      'args': {'pid': pid, 'activity': activity},
      'nonce': DateTime.now().microsecondsSinceEpoch.toString(),
    });
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
      unawaited(_retry());
    });
  }

  Future<void> _retry() async {
    if (!_enabled || _lastDetails == null || _connecting) return;
    _connecting = true;
    try {
      if (_socket == null) await _connect();
      _sendActivity(_lastDetails, _lastActivityState);
      _lastSentActivityKey = _lastActivityKey;
      _retryTimer?.cancel();
      _retryTimer = null;
    } on Object {
      await _close();
      _scheduleRetry();
    } finally {
      _connecting = false;
    }
  }

  Future<void> _close() async {
    final subscription = _socketSubscription;
    final socket = _socket;
    _socketSubscription = null;
    _socket = null;
    _lastSentActivityKey = null;
    await subscription?.cancel();
    socket?.destroy();
  }
}
