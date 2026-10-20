import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/core_process.dart';
import '../core/vpn_backend.dart';
import '../models/core_settings.dart';
import '../models/server_profile.dart';

/// Android must use the OS VpnService API; Android does not allow launching
/// the desktop sing-box executable as a child process.
class AndroidVpnBackend implements VpnBackend {
  static const _channel = MethodChannel('app.ghostbox.ghostbox/vpn');
  late CoreProcessBackend _configBuilder;

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
      final coreName = settings.core == 'xray' ? 'xray' : 'sing-box';
      if (coreName == 'xray') {
        await _connectXrayThroughSingBox(profile);
        return;
      }
      _configBuilder = CoreProcessBackend(
        name: coreName,
        executable: '',
        configPath: 'vendor/config/$coreName.json',
      );
      _configBuilder.settings = settings.copyWith(
        core: coreName,
        // Android's VPN permission is granted through VpnService and the
        // system tunnel is mandatory for device-wide routing.
        connectionMode: 'tun',
      );
      final config = _configBuilder.makeConfig(profile);
      if (coreName == 'xray') {
        final inbounds =
            (config['inbounds'] as List).cast<Map<String, dynamic>>();
        final local =
            inbounds.firstWhere((inbound) => inbound['tag'] == 'local');
        // Android's active tunnel has a small HTTP proxy for Proxy GET checks.
        local['protocol'] = 'http';
        local['settings'] = {'allowTransparent': false};
      }
      // VpnService protects the core's outbound sockets; sing-box's automatic
      // desktop interface picker has no Android interface index to discover.
      final route = config['route'];
      if (route is Map<String, dynamic>) route.remove('auto_detect_interface');
      await _channel.invokeMethod<void>('startVpn', {
        'config': const JsonEncoder.withIndent('  ').convert(config),
        'profileName': profile.name,
        'memoryMb': settings.memoryMb,
        'core': coreName,
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
        message: '$coreName did not start within 12 seconds',
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

  Future<void> _connectXrayThroughSingBox(ServerProfile profile) async {
    final socksReservation =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final socksPort = socksReservation.port;
    await socksReservation.close();

    final xrayBuilder = CoreProcessBackend(
      name: 'xray',
      executable: '',
      configPath: 'vendor/config/xray-android-upstream.json',
    )..settings = settings.copyWith(
        core: 'xray',
        connectionMode: 'proxy',
        localPort: settings.localPort,
      );
    final xrayConfig = xrayBuilder.makeConfig(profile);
    final xrayInbounds =
        (xrayConfig['inbounds'] as List).cast<Map<String, dynamic>>();
    final localInbound = xrayInbounds.firstWhere(
      (inbound) => inbound['tag'] == 'local',
      orElse: () => throw const FormatException(
        'Xray config is missing its local proxy inbound',
      ),
    );
    // Keep the HTTP listener used by Android Proxy GET and add a separate
    // SOCKS listener for the sing-box TUN router.
    localInbound['protocol'] = 'http';
    localInbound['settings'] = {'allowTransparent': false};
    xrayInbounds.add({
      'tag': 'tun-bridge-socks',
      'listen': '127.0.0.1',
      'port': socksPort,
      'protocol': 'socks',
      'settings': {'auth': 'noauth', 'udp': true},
      'sniffing': {
        'enabled': settings.sniffingEnabled,
        'destOverride': ['http', 'tls', 'quic'],
        'routeOnly': true,
      },
    });

    try {
      await _channel.invokeMethod<void>('startVpn', {
        'config': const JsonEncoder.withIndent('  ').convert(xrayConfig),
        'profileName': profile.name,
        'memoryMb': settings.memoryMb,
        'core': 'xray',
        'proxyOnly': true,
      });
      await _waitForXrayProxy();

      final bridgeProfile = ServerProfile(
        id: 'ghostbox-android-xray-bridge',
        name: 'GhostBox Xray upstream',
        protocol: 'socks',
        address: '127.0.0.1',
        port: socksPort,
        raw: const {'_tunBridge': true},
      );
      final singBoxBuilder = CoreProcessBackend(
        name: 'sing-box',
        executable: '',
        configPath: 'vendor/config/sing-box-android-tun.json',
      )..settings = settings.copyWith(
          core: 'sing-box',
          connectionMode: 'tun',
        );
      final singBoxConfig = singBoxBuilder.makeConfig(bridgeProfile);
      final route = singBoxConfig['route'];
      if (route is Map<String, dynamic>) route.remove('auto_detect_interface');
      await _channel.invokeMethod<void>('startVpn', {
        'config': const JsonEncoder.withIndent('  ').convert(singBoxConfig),
        'profileName': profile.name,
        'memoryMb': settings.memoryMb,
        'core': 'sing-box',
        'keepXray': true,
      });
      await _waitForSingBoxTun();
    } on Object {
      await _channel.invokeMethod<void>('stopVpn').catchError((_) {});
      rethrow;
    }
  }

  Future<void> _waitForXrayProxy() async {
    for (var attempt = 0; attempt < 150; attempt++) {
      final nativeState = await _channel.invokeMethod<String>('xrayProxyState');
      if (nativeState == 'connected') return;
      if (nativeState == 'error') {
        throw PlatformException(
          code: 'xray_start_failed',
          message: await _channel.invokeMethod<String>('xrayProxyError') ??
              'Xray could not start the Android upstream proxy',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw PlatformException(
      code: 'xray_start_timeout',
      message: 'Xray upstream did not start within 30 seconds',
    );
  }

  Future<void> _waitForSingBoxTun() async {
    for (var attempt = 0; attempt < 150; attempt++) {
      final nativeState = await _channel.invokeMethod<String>('vpnState');
      if (nativeState == 'connected') {
        state = VpnState.connected;
        return;
      }
      if (nativeState == 'error') {
        throw PlatformException(
          code: 'core_start_failed',
          message: await _channel.invokeMethod<String>('vpnError') ??
              'sing-box could not start the Android TUN router',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw PlatformException(
      code: 'start_timeout',
      message: 'sing-box did not start the Android TUN within 30 seconds',
    );
  }

  @override
  Future<void> disconnect() async {
    await _channel.invokeMethod<void>('stopVpn');
    state = VpnState.disconnected;
    _readLogCount = 0;
  }
}
