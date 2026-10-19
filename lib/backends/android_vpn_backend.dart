import 'dart:convert';

import 'package:flutter/services.dart';

import '../core/core_process.dart';
import '../core/vpn_backend.dart';
import '../models/core_settings.dart';
import '../models/server_profile.dart';

/// Android must use the OS VpnService API; Android does not allow launching
/// the desktop sing-box executable as a child process.
class AndroidVpnBackend implements VpnBackend {
  static const _channel = MethodChannel('app.ghostbox.ghostbox/vpn');
  final CoreProcessBackend _configBuilder = CoreProcessBackend(
    name: 'sing-box',
    executable: '',
    configPath: '',
  );

  @override
  VpnState state = VpnState.disconnected;

  String? lastError;
  CoreSettings settings = const CoreSettings();
  int _readLogCount = 0;

  Future<void> refreshState() async {
    final nativeState = await _channel.invokeMethod<String>('vpnState');
    state = switch (nativeState) {
      'connecting' => VpnState.connecting,
      'connected' => VpnState.connected,
      'error' => VpnState.error,
      _ => VpnState.disconnected,
    };
    if (state == VpnState.error) {
      lastError = await _channel.invokeMethod<String>('vpnError');
    }
  }

  Future<List<String>> readNewLogs() async {
    final lines = await _channel.invokeMethod<List<dynamic>>('vpnLogs') ??
        const <dynamic>[];
    if (_readLogCount > lines.length) _readLogCount = 0;
    final result =
        lines.skip(_readLogCount).map((line) => line.toString()).toList();
    _readLogCount = lines.length;
    return result;
  }

  Future<void> clearLogs() async {
    await _channel.invokeMethod<void>('clearVpnLogs');
    _readLogCount = 0;
  }

  Future<int?> readMemoryMb() async =>
      _channel.invokeMethod<int>('vpnMemoryMb');

  @override
  Future<void> connect(String profileJson) async {
    if (state == VpnState.connected || state == VpnState.connecting) return;
    state = VpnState.connecting;
    lastError = null;
    try {
      final profile = ServerProfile.fromJson(
        Map<String, dynamic>.from(jsonDecode(profileJson) as Map),
      );
      _configBuilder.settings = settings.copyWith(
        core: 'sing-box',
        // Android's VPN permission is granted through VpnService and the
        // system tunnel is mandatory for device-wide routing.
        connectionMode: 'tun',
      );
      final config = _configBuilder.makeConfig(profile);
      // VpnService protects sing-box's own sockets; the proxy's default
      // interface picker has no desktop interface index to discover here.
      (config['route'] as Map<String, dynamic>).remove('auto_detect_interface');
      await _channel.invokeMethod<void>('startVpn', {
        'config': const JsonEncoder.withIndent('  ').convert(config),
        'profileName': profile.name,
        'memoryMb': settings.memoryMb,
      });
      for (var attempt = 0; attempt < 80; attempt++) {
        final nativeState = await _channel.invokeMethod<String>('vpnState');
        if (nativeState == 'connected') {
          state = VpnState.connected;
          return;
        }
        if (nativeState == 'error') {
          throw PlatformException(
            code: 'core_start_failed',
            message: await _channel.invokeMethod<String>('vpnError') ??
                'sing-box could not start the Android VPN',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      throw PlatformException(
        code: 'start_timeout',
        message: 'sing-box did not start within 12 seconds',
      );
    } on PlatformException catch (error) {
      lastError = error.message ?? error.code;
      state = VpnState.error;
      rethrow;
    } on Object catch (error) {
      lastError = error.toString();
      state = VpnState.error;
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    await _channel.invokeMethod<void>('stopVpn');
    state = VpnState.disconnected;
    _readLogCount = 0;
  }
}
