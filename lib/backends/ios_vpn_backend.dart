import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../core/core_process.dart';
import '../core/vpn_backend.dart';
import '../models/core_settings.dart';
import '../models/server_profile.dart';

/// iOS runs sing-box inside Apple's Packet Tunnel extension, never as a
/// Flutter child process. The host app only sends config and observes NE state.
class IosVpnBackend implements VpnBackend {
  static const _channel = MethodChannel('app.ghostbox.ghostbox/vpn');

  VpnState _state = VpnState.disconnected;
  CoreSettings settings = const CoreSettings(
    core: 'sing-box',
    connectionMode: 'tun',
  );
  DateTime? _connectedAt;
  String? lastError;
  String? activeProfileName;
  int _generation = 0;
  Future<void>? _starting;

  @override
  VpnState get state => _state;

  Duration get uptime => _state != VpnState.connected || _connectedAt == null
      ? Duration.zero
      : DateTime.now().difference(_connectedAt!);

  Future<void> refreshState() async {
    final snapshot =
        await _channel.invokeMapMethod<String, dynamic>('vpnSnapshot');
    final value = snapshot?['state'];
    _state = switch (value) {
      'connecting' => VpnState.connecting,
      'connected' => VpnState.connected,
      // Disconnecting remains an active operation until stopVpn completes.
      'disconnecting' => VpnState.connecting,
      'error' => VpnState.error,
      _ => VpnState.disconnected,
    };
    activeProfileName = snapshot?['profileName'] as String?;
    final stamp = snapshot?['connectedAt'] as int?;
    _connectedAt = _state == VpnState.connected && stamp != null
        ? DateTime.fromMillisecondsSinceEpoch(stamp)
        : null;
    lastError = snapshot?['error'] as String?;
  }

  @override
  Future<void> connect(String profileJson) async {
    if (_state == VpnState.connected || _state == VpnState.connecting) return;
    final generation = ++_generation;
    _state = VpnState.connecting;
    lastError = null;
    try {
      final decoded = jsonDecode(profileJson);
      if (decoded is! Map) {
        throw const FormatException('iOS VPN profile is not an object');
      }
      final profile = ServerProfile.fromJson(
        decoded.map<String, dynamic>(
          (key, value) => MapEntry(key.toString(), value),
        ),
      );
      final builder = CoreProcessBackend(
        name: 'sing-box',
        executable: '',
        configPath: 'vendor/config/sing-box.json',
      )..settings = settings.copyWith(
          core: 'sing-box',
          connectionMode: 'tun',
        );
      final config = builder.makeConfig(profile);
      final route = config['route'];
      if (route is Map) {
        route.remove('auto_detect_interface');
      }
      final starting = _channel.invokeMethod<void>('startVpn', {
        'config': const JsonEncoder.withIndent('  ').convert(config),
        'profileName': profile.name,
      }).timeout(const Duration(seconds: 60));
      _starting = starting;
      await starting;
      if (generation != _generation) return;

      for (var attempt = 0; attempt < 120; attempt++) {
        if (generation != _generation) return;
        await refreshState();
        if (generation != _generation) return;
        if (_state == VpnState.connected) return;
        if (_state == VpnState.error ||
            (_state == VpnState.disconnected && attempt >= 8)) {
          throw PlatformException(
            code: 'packet_tunnel_failed',
            message: lastError ?? 'iOS Packet Tunnel could not start',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      throw PlatformException(
        code: 'packet_tunnel_timeout',
        message: 'iOS VPN extension did not connect within 30 seconds',
      );
    } on Object catch (error) {
      if (generation != _generation) return;
      lastError = error.toString();
      _state = VpnState.error;
      _connectedAt = null;
      try {
        await _channel.invokeMethod<void>('stopVpn');
      } on Object {
        // Preserve the original startup error if cleanup cannot reach iOS.
      }
      rethrow;
    } finally {
      if (generation == _generation) _starting = null;
    }
  }

  @override
  Future<void> disconnect() async {
    ++_generation;
    final starting = _starting;
    if (starting != null) {
      try {
        await starting;
      } on Object {
        // A failed start still needs its native tunnel stopped.
      }
      _starting = null;
    }
    try {
      await _channel.invokeMethod<void>('stopVpn').timeout(
            const Duration(seconds: 25),
          );
      _state = VpnState.disconnected;
      _connectedAt = null;
      lastError = null;
      activeProfileName = null;
    } on Object catch (error) {
      lastError = error.toString();
      _state = VpnState.error;
      rethrow;
    }
  }
}
