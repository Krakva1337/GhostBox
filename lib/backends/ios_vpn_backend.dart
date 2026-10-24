import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/core_process.dart';
import '../core/vpn_backend.dart';
import '../models/core_settings.dart';
import '../models/server_profile.dart';

/// iOS runs its selected core inside Apple's Packet Tunnel extension, never as
/// a Flutter child process. The host app sends config and observes NE state.
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
      final core = settings.core == 'xray' ? 'xray' : 'sing-box';
      final builder = CoreProcessBackend(
        name: core,
        executable: '',
        configPath: core == 'xray'
            ? 'vendor/config/xray-ios.json'
            : 'vendor/config/sing-box.json',
      )..settings = settings.copyWith(
          core: core,
          connectionMode: 'tun',
          aggressiveXhttpCleanup: core == 'sing-box',
        );
      final config = builder.makeConfig(profile);
      if (core == 'xray') {
        final inbounds = (config['inbounds'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        final tun = inbounds.where((item) => item['tag'] == 'tun-in');
        if (tun.isEmpty) {
          throw const FormatException('Xray config is missing its TUN inbound');
        }
        tun.first['settings'] = {'name': 'utun', 'MTU': 1500};
        config['inbounds'] = inbounds;
      } else {
        final route = config['route'];
        if (route is Map) route.remove('auto_detect_interface');
      }
      final endpointIPs = <String>{};
      try {
        endpointIPs.addAll(
          (await InternetAddress.lookup(profile.address))
              .map((address) => address.address),
        );
      } on SocketException {
        if (core == 'xray') rethrow;
        // The packet tunnel reports a useful core startup error if DNS cannot
        // resolve the selected endpoint while the connection is being made.
      }
      if (core == 'xray' && endpointIPs.isEmpty) {
        throw const SocketException(
            'Could not resolve the Xray server address for tunnel routing');
      }
      final starting = _channel.invokeMethod<void>('startVpn', {
        'config': const JsonEncoder.withIndent('  ').convert(config),
        'profileName': profile.name,
        'oomMemoryLimitMB': settings.memoryMb.clamp(25, 50),
        'core': core,
        'serverEndpointIPs': endpointIPs.toList(),
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
