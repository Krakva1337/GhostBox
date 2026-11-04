import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'discord_rpc_connection.dart';

enum DiscordPresencePhase { disabled, connecting, ready, retrying }

class DiscordPresenceStatus {
  const DiscordPresenceStatus(this.phase, {this.error, this.buttons});
  final DiscordPresencePhase phase;
  final String? error;

  /// Number of buttons echoed by Discord, when included in its response.
  final int? buttons;
}

/// Owns one RPC session and publishes only the newest snapshot. The live
/// connection timer belongs to Discord, never to repeatedly published text.
class DiscordPresence {
  DiscordPresence._();
  static final instance = DiscordPresence._();
  static const clientId = String.fromEnvironment(
    'GHOSTBOX_DISCORD_CLIENT_ID',
    defaultValue: '1566838058207412414',
  );
  static bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
  static bool get configured =>
      RegExp(r'^\d{17,20}$').hasMatch(clientId.trim());

  final connectionStatus = ValueNotifier<DiscordPresenceStatus>(
    const DiscordPresenceStatus(DiscordPresencePhase.disabled),
  );
  DiscordRpcConnection? _connection;
  _PresenceSnapshot? _desired;
  String? _sentKey;
  String? _sentSession;
  DateTime? _sessionStart;
  Duration _previousUptime = Duration.zero;
  DateTime? _sentAt;
  DateTime? _retryAt;
  final _publicationTimes = <DateTime>[];
  Future<void>? _worker;
  Timer? _wake;
  bool _enabled = false;
  bool _disposed = false;
  int _failures = 0;

  Future<void> update({
    required bool enabled,
    required bool connected,
    required String status,
    required String version,
    required String traffic,
    required String todayTraffic,
    required Duration connectedFor,
  }) async {
    if (_disposed) return;
    final wasEnabled = _enabled;
    _enabled = enabled && supported && configured;
    if (!_enabled) {
      _desired = null;
      _sessionStart = null;
      _previousUptime = Duration.zero;
      _wake?.cancel();
      _wake = null;
      if (wasEnabled || _connection != null || _worker != null) _kick();
      return;
    }
    if (!wasEnabled) {
      _retryAt = null;
      _failures = 0;
    }
    if (connected) {
      // Detect a core restart even if no disconnected snapshot was observed.
      if (_sessionStart == null ||
          connectedFor + const Duration(seconds: 2) < _previousUptime) {
        final uptime = connectedFor.isNegative ? Duration.zero : connectedFor;
        _sessionStart = DateTime.now().subtract(uptime);
      }
      _previousUptime = connectedFor;
    } else {
      _sessionStart = null;
      _previousUptime = Duration.zero;
    }
    _desired = _PresenceSnapshot(
      details: '$version | $status',
      state: '$traffic | $todayTraffic',
      start: _sessionStart,
    );
    _kick();
  }

  Future<void> dispose() async {
    _disposed = true;
    _enabled = false;
    _desired = null;
    _wake?.cancel();
    _wake = null;
    _kick();
    while (_worker != null) {
      await _worker;
    }
  }

  void _kick() {
    if (_worker != null) return;
    _wake?.cancel();
    _wake = null;
    _worker = _run().whenComplete(() {
      _worker = null;
      // A disable arriving while a publication was in flight must clear it.
      if (!_enabled && _connection != null) _kick();
    });
  }

  void _schedule(Duration delay) {
    if (!_enabled) return;
    _wake?.cancel();
    _wake = Timer(delay > Duration.zero ? delay : Duration.zero, _kick);
  }

  Future<void> _run() async {
    try {
      while (true) {
        if (!_enabled) {
          final connection = _connection;
          _connection = null;
          if (connection != null) {
            try {
              if (!connection.closed) {
                await connection.setActivity(null).timeout(
                      const Duration(seconds: 2),
                    );
              }
            } on Object {
              // Closing IPC also clears presence if Discord cannot acknowledge.
            } finally {
              await connection.close();
            }
          }
          _sentKey = null;
          _sentSession = null;
          _sentAt = null;
          _retryAt = null;
          connectionStatus.value =
              const DiscordPresenceStatus(DiscordPresencePhase.disabled);
          // Re-enabling during clear resumes on this same serialized worker.
          if (_enabled) continue;
          return;
        }
        final now = DateTime.now();
        final retryAt = _retryAt;
        if (retryAt != null && now.isBefore(retryAt)) {
          _schedule(retryAt.difference(now));
          return;
        }
        if (_connection?.closed == true) {
          await _connection!.close();
          _connection = null;
        }
        if (_connection == null) {
          connectionStatus.value =
              const DiscordPresenceStatus(DiscordPresencePhase.connecting);
          _connection = await DiscordRpcConnection.connect(clientId.trim());
          _sentKey = null;
          _sentSession = null;
          _sentAt = null;
          continue; // Re-read desired state after connecting/handshaking.
        }
        final desired = _desired!;
        if (desired.key == _sentKey) {
          // Check the transport periodically even when disconnected/idle.
          _schedule(const Duration(seconds: 5));
          return;
        }
        _publicationTimes.removeWhere(
            (time) => now.difference(time) >= const Duration(seconds: 20));
        var due = now;
        if (desired.session == _sentSession && _sentAt != null) {
          due = _sentAt!.add(const Duration(seconds: 5));
        }
        // Keep within Discord's presence budget, including status transitions.
        if (_publicationTimes.length >= 5) {
          final budgetAt =
              _publicationTimes.first.add(const Duration(seconds: 20));
          if (budgetAt.isAfter(due)) due = budgetAt;
        }
        if (due.isAfter(now)) {
          _schedule(due.difference(now));
          return;
        }
        _publicationTimes.add(now);
        final response = await _connection!.setActivity(desired.activity);
        _sentKey = desired.key;
        _sentSession = desired.session;
        _sentAt = now;
        _retryAt = null;
        _failures = 0;
        final buttons = response?['buttons'];
        connectionStatus.value = DiscordPresenceStatus(
          DiscordPresencePhase.ready,
          buttons: buttons is List ? buttons.length : null,
        );
        // Changes arriving during SET_ACTIVITY replace the snapshot, never queue.
      }
    } on Object catch (error) {
      if (error is! DiscordRpcException || !_enabled) {
        final connection = _connection;
        _connection = null;
        await connection?.close();
        _sentKey = null;
        _sentSession = null;
      }
      if (!_enabled) {
        connectionStatus.value =
            const DiscordPresenceStatus(DiscordPresencePhase.disabled);
        return;
      }
      _failures = (_failures + 1).clamp(1, 6);
      final delay = error is DiscordRpcException
          ? const Duration(seconds: 15)
          : Duration(seconds: 1 << (_failures - 1));
      _retryAt = DateTime.now().add(delay);
      connectionStatus.value = DiscordPresenceStatus(
        DiscordPresencePhase.retrying,
        error: error.toString(),
      );
      debugPrint('Discord RPC: $error');
      _schedule(delay);
    }
  }
}

class _PresenceSnapshot {
  _PresenceSnapshot({required this.details, required this.state, this.start});
  final String details;
  final String state;
  final DateTime? start;

  String get session => '$details\n${start?.millisecondsSinceEpoch}';
  String get key => '$session\n$state';

  Map<String, Object?> get activity => {
        'name': 'GhostBox',
        'type': 0,
        'details': details,
        'state': state,
        if (start != null)
          'timestamps': {'start': start!.millisecondsSinceEpoch ~/ 1000},
        'buttons': [
          {'label': 'GitHub', 'url': 'https://github.com/Krakva1337/GhostBox'},
          {'label': 'Telegram', 'url': 'https://t.me/GhostBoxVPN'},
        ],
      };
}
