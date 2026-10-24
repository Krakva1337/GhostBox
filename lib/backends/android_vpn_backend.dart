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

  Map<String, dynamic> _stringKeyedMap(Object? value) {
    if (value is! Map) {
      throw const FormatException('Android VPN core config is not an object');
    }
    return value.map<String, dynamic>(
      (key, item) => MapEntry(key.toString(), item),
    );
  }

  List<Map<String, dynamic>> _configObjects(Object? value) {
    if (value is! List) {
      throw const FormatException('Android VPN config has no inbound list');
    }
    return value.map(_stringKeyedMap).toList();
  }

  @override
  VpnState state = VpnState.disconnected;

  String? lastError;
  CoreSettings settings = const CoreSettings();
  int _readLogCount = 0;
  DateTime? _connectedAt;
  bool _hasRecentNativeStopAcknowledgement = false;
  int? _xrayBridgeSocksPort;
  ServerProfile? _activeXrayBridgeProfile;
  String? _activeXrayConfig;
  List<String> _activeXrayEndpointExclusions = const [];

  Duration get uptime {
    final startedAt = _connectedAt;
    if (state != VpnState.connected || startedAt == null) return Duration.zero;
    return DateTime.now().difference(startedAt);
  }

  /// Describes the native cores embedded in this Android APK. Android does
  /// not ship vendor/bin CLI files, so checking coreExecutable() is invalid.
  Future<Map<String, Map<String, Object?>>> readEmbeddedCoreInventory() async {
    final inventory = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'androidCoreInventory',
    );
    if (inventory == null) return const <String, Map<String, Object?>>{};
    final result = <String, Map<String, Object?>>{};
    for (final core in const ['xray', 'sing-box']) {
      final value = inventory[core];
      if (value is Map) {
        result[core] = value.map<String, Object?>(
          (key, item) => MapEntry(key.toString(), item),
        );
      }
    }
    final deviceAbis = inventory['deviceAbis'];
    if (deviceAbis is List) {
      result['_device'] = <String, Object?>{
        'abis': deviceAbis.map((abi) => abi.toString()).toList(),
      };
    }
    return result;
  }

  Future<void> refreshState() async {
    final nativeState = await _channel
        .invokeMethod<String>('vpnState')
        .timeout(const Duration(seconds: 3));
    state = switch (nativeState) {
      'connecting' => VpnState.connecting,
      'connected' => VpnState.connected,
      'error' => VpnState.error,
      _ => VpnState.disconnected,
    };
    if (state == VpnState.connected) {
      final timestamp = await _channel
          .invokeMethod<int>('vpnConnectedAt')
          .timeout(const Duration(seconds: 3));
      _connectedAt = timestamp == null
          ? (_connectedAt ?? DateTime.now())
          : DateTime.fromMillisecondsSinceEpoch(timestamp);
    } else {
      _connectedAt = null;
    }
    if (state == VpnState.error) {
      lastError = await _channel
          .invokeMethod<String>('vpnError')
          .timeout(const Duration(seconds: 3));
    }
  }

  Future<List<String>> readNewLogs() async {
    final lines = await _channel
            .invokeMethod<List<dynamic>>('vpnLogs')
            .timeout(const Duration(seconds: 3)) ??
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

  /// Opens Android's VPN settings so the user can enable Always-on VPN and
  /// "Block connections without VPN" (the OS-enforced kill switch).
  /// Ordinary apps cannot toggle lockdown themselves.
  Future<bool> openKillSwitchSettings() async =>
      await _channel.invokeMethod<bool>('openAndroidVpnSettings') ?? false;

  /// Returns the lockdown state last reported by Android's VpnService API.
  /// Android API 29+ exposes this only from inside a running service; before
  /// that (or before the service has started), `lockdownEnabled` is null.
  Future<Map<String, Object?>> readKillSwitchStatus() async {
    final value = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'androidKillSwitchStatus',
    );
    return value?.map<String, Object?>(
          (key, item) => MapEntry(key.toString(), item),
        ) ??
        const <String, Object?>{};
  }

  @override
  Future<void> connect(String profileJson) async {
    if (state == VpnState.connected || state == VpnState.connecting) return;
    // Consume this exactly once. A newly created backend, or a previous stop
    // without a complete native acknowledgement, still performs orphan cleanup.
    final skipCleanup = _hasRecentNativeStopAcknowledgement;
    _hasRecentNativeStopAcknowledgement = false;
    state = VpnState.connecting;
    lastError = null;
    try {
      final profile = ServerProfile.fromJson(
        _stringKeyedMap(jsonDecode(profileJson)),
      );
      if (!skipCleanup) {
        await _channel
            .invokeMethod<void>('cleanupVpnBeforeConnect')
            .timeout(const Duration(seconds: 9));
      }
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
      // VpnService protects the core's outbound sockets; sing-box's automatic
      // desktop interface picker has no Android interface index to discover.
      final routeValue = config['route'];
      if (routeValue is Map) {
        config['route'] = _stringKeyedMap(routeValue)
          ..remove('auto_detect_interface');
      }
      await _channel.invokeMethod<void>('startVpn', {
        'config': const JsonEncoder.withIndent('  ').convert(config),
        'profileName': profile.name,
        'memoryMb': settings.memoryMb,
        'core': coreName,
      }).timeout(const Duration(seconds: 60));
      for (var attempt = 0; attempt < 80; attempt++) {
        final nativeState = await _channel
            .invokeMethod<String>('vpnState')
            .timeout(const Duration(seconds: 3));
        if (nativeState == 'connected') {
          state = VpnState.connected;
          final timestamp = await _channel
              .invokeMethod<int>('vpnConnectedAt')
              .timeout(const Duration(seconds: 3));
          _connectedAt = timestamp == null
              ? DateTime.now()
              : DateTime.fromMillisecondsSinceEpoch(timestamp);
          return;
        }
        if (nativeState == 'error') {
          throw PlatformException(
            code: 'core_start_failed',
            message: await _channel
                    .invokeMethod<String>('vpnError')
                    .timeout(const Duration(seconds: 3)) ??
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
      _connectedAt = null;
      await _stopVpnBestEffort();
      _clearXrayBridgeSession();
      rethrow;
    } on Object catch (error) {
      lastError = error.toString();
      state = VpnState.error;
      _connectedAt = null;
      await _stopVpnBestEffort();
      _clearXrayBridgeSession();
      rethrow;
    }
  }

  bool get canSwitchServerInPlace =>
      state == VpnState.connected &&
      settings.core == 'xray' &&
      _xrayBridgeSocksPort != null &&
      _activeXrayBridgeProfile != null &&
      _activeXrayConfig != null;

  /// Switch an active Android Xray + sing-box bridge without stopping its VPN
  /// service. sing-box keeps the local SOCKS route/TUN alive while Xray swaps
  /// the upstream core instance inside its existing :xray process.
  Future<void> switchServer(String profileJson) async {
    if (!canSwitchServerInPlace) {
      throw StateError(
          'Android Xray bridge is not ready for in-place switching');
    }

    final socksPort = _xrayBridgeSocksPort!;
    final previousProfile = _activeXrayBridgeProfile!;
    final previousXrayConfig = _activeXrayConfig!;
    final previousExclusions = _activeXrayEndpointExclusions;
    final target = ServerProfile.fromJson(
      _stringKeyedMap(jsonDecode(profileJson)),
    );
    final exclusions = await _resolveXrayEndpointExclusions(target);
    final nextXrayConfig = const JsonEncoder.withIndent('  ')
        .convert(_buildXrayProxyConfig(target, socksPort));
    final previousConnectedAt = _connectedAt;
    var singBoxReloadAttempted = false;
    var xrayReloadAttempted = false;

    try {
      singBoxReloadAttempted = true;
      await _reloadXrayBridgeTun(
        target,
        socksPort: socksPort,
        endpointExclusions: exclusions,
        waitTimeout: const Duration(seconds: 12),
      );

      xrayReloadAttempted = true;
      await _queueXrayProxyReload(nextXrayConfig, target.name);
      await _waitForXrayProxy(timeout: const Duration(seconds: 12));

      _activeXrayBridgeProfile = target;
      _activeXrayConfig = nextXrayConfig;
      _activeXrayEndpointExclusions = exclusions;
      state = VpnState.connected;
      lastError = null;
    } on Object catch (error, stackTrace) {
      final rollbackErrors = <Object>[];
      if (xrayReloadAttempted) {
        try {
          await _queueXrayProxyReload(previousXrayConfig, previousProfile.name);
          await _waitForXrayProxy(timeout: const Duration(seconds: 12));
        } on Object catch (rollbackError) {
          rollbackErrors.add(rollbackError);
        }
      }
      if (singBoxReloadAttempted) {
        try {
          await _reloadXrayBridgeTun(
            previousProfile,
            socksPort: socksPort,
            endpointExclusions: previousExclusions,
            waitTimeout: const Duration(seconds: 12),
          );
        } on Object catch (rollbackError) {
          rollbackErrors.add(rollbackError);
        }
      }

      if (rollbackErrors.isEmpty) {
        state = VpnState.connected;
        _connectedAt = previousConnectedAt;
        lastError = error.toString();
      } else {
        state = VpnState.error;
        _connectedAt = null;
        lastError = '$error; Android switch rollback failed: '
            '${rollbackErrors.join(' | ')}';
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _connectXrayThroughSingBox(ServerProfile profile) async {
    final endpointExclusions = await _resolveXrayEndpointExclusions(profile);
    final socksPort = await _ensureXrayBridgeSocksPort();
    final xrayConfig = _buildXrayProxyConfig(profile, socksPort);

    try {
      await _channel.invokeMethod<void>('startVpn', {
        'config': const JsonEncoder.withIndent('  ').convert(xrayConfig),
        'profileName': profile.name,
        'memoryMb': settings.memoryMb,
        'core': 'xray',
        'proxyOnly': true,
      }).timeout(const Duration(seconds: 20));
      await _waitForXrayProxy();

      final singBoxConfig = _buildXrayBridgeTunConfig(
        profile,
        socksPort: socksPort,
        endpointExclusions: endpointExclusions,
      );
      await _channel.invokeMethod<void>('startVpn', {
        'config': const JsonEncoder.withIndent('  ').convert(singBoxConfig),
        'profileName': profile.name,
        'memoryMb': settings.memoryMb,
        'core': 'sing-box',
        'keepXray': true,
      }).timeout(const Duration(seconds: 20));
      await _waitForSingBoxTun();
      _activeXrayBridgeProfile = profile;
      _activeXrayConfig =
          const JsonEncoder.withIndent('  ').convert(xrayConfig);
      _activeXrayEndpointExclusions = endpointExclusions;
    } on Object {
      await _stopVpnBestEffort();
      rethrow;
    }
  }

  Future<List<String>> _resolveXrayEndpointExclusions(
      ServerProfile profile) async {
    // Resolve before replacing the Xray outbound so the TUN router can bypass
    // its current/new server endpoints without changing Xray's SNI hostname.
    final endpointAddresses = await InternetAddress.lookup(profile.address)
        .timeout(const Duration(seconds: 4));
    if (endpointAddresses.isEmpty) {
      throw SocketException(
          'Could not resolve Xray server ${profile.address} before enabling Android TUN');
    }
    return {
      if (profile.raw['_tunExcludeAddresses'] is List)
        ...(profile.raw['_tunExcludeAddresses'] as List)
            .map((value) => value.toString()),
      ...endpointAddresses.map((address) =>
          '${address.address}/${address.type == InternetAddressType.IPv4 ? 32 : 128}'),
    }.toList();
  }

  Future<int> _ensureXrayBridgeSocksPort() async {
    final activePort = _xrayBridgeSocksPort;
    if (activePort != null) return activePort;
    final reservation =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = reservation.port;
    await reservation.close();
    _xrayBridgeSocksPort = port;
    return port;
  }

  Map<String, dynamic> _buildXrayProxyConfig(
      ServerProfile profile, int socksPort) {
    final xrayBuilder = CoreProcessBackend(
      name: 'xray',
      executable: '',
      configPath: 'vendor/config/xray-android-upstream.json',
    )..settings = settings.copyWith(
        core: 'xray',
        connectionMode: 'proxy',
        // Split policy belongs to the sing-box TUN router in this bridge.
        // Keep Xray as the SOCKS -> VLESS/XHTTP upstream and clear Android
        // package selectors (which Xray cannot implement).
        routing: 'proxy',
        directDomains: const [],
        proxyDomains: const [],
        directApps: const [],
        proxyApps: const [],
        localPort: settings.localPort,
      );
    final config = xrayBuilder.makeConfig(profile);
    final inbounds = _configObjects(config['inbounds']);
    config['inbounds'] = inbounds;
    final localInbound = inbounds.firstWhere(
      (inbound) => inbound['tag'] == 'local',
      orElse: () => throw const FormatException(
        'Xray config is missing its local proxy inbound',
      ),
    );
    // Keep the HTTP listener used by Android Proxy GET and use a stable SOCKS
    // port so the live sing-box bridge does not have to change inbounds.
    localInbound['protocol'] = 'http';
    localInbound['settings'] = {'allowTransparent': false};
    inbounds.add({
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
    return config;
  }

  Map<String, dynamic> _buildXrayBridgeTunConfig(
    ServerProfile profile, {
    required int socksPort,
    required List<String> endpointExclusions,
  }) {
    final bridgeProfile = ServerProfile(
      id: 'ghostbox-android-xray-bridge',
      name: 'GhostBox Xray upstream',
      protocol: 'socks',
      address: '127.0.0.1',
      port: socksPort,
      raw: {
        '_tunBridge': true,
        '_tunExcludeAddresses': endpointExclusions,
      },
    );
    final singBoxBuilder = CoreProcessBackend(
      name: 'sing-box',
      executable: '',
      configPath: 'vendor/config/sing-box-android-tun.json',
    )..settings = settings.copyWith(
        core: 'sing-box',
        connectionMode: 'tun',
      );
    final config = singBoxBuilder.makeConfig(bridgeProfile);
    final routeValue = config['route'];
    if (routeValue is Map) {
      config['route'] = _stringKeyedMap(routeValue)
        ..remove('auto_detect_interface');
    }
    return config;
  }

  Future<void> _reloadXrayBridgeTun(
    ServerProfile profile, {
    required int socksPort,
    required List<String> endpointExclusions,
    Duration waitTimeout = const Duration(seconds: 30),
  }) async {
    final config = _buildXrayBridgeTunConfig(
      profile,
      socksPort: socksPort,
      endpointExclusions: endpointExclusions,
    );
    await _channel.invokeMethod<void>('startVpn', {
      'config': const JsonEncoder.withIndent('  ').convert(config),
      'profileName': profile.name,
      'memoryMb': settings.memoryMb,
      'core': 'sing-box',
      'keepXray': true,
    }).timeout(const Duration(seconds: 20));
    await _waitForSingBoxTun(timeout: waitTimeout);
  }

  Future<void> _queueXrayProxyReload(String config, String profileName) async {
    await _channel.invokeMethod<void>('reloadXrayProxy', {
      'config': config,
      'profileName': profileName,
      'memoryMb': settings.memoryMb,
    }).timeout(const Duration(seconds: 10));
  }

  Future<void> _waitForXrayProxy(
      {Duration timeout = const Duration(seconds: 30)}) async {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      final nativeState = await _channel
          .invokeMethod<String>('xrayProxyState')
          .timeout(const Duration(seconds: 1));
      if (nativeState == 'connected') return;
      if (nativeState == 'error') {
        throw PlatformException(
          code: 'xray_start_failed',
          message: await _channel
                  .invokeMethod<String>('xrayProxyError')
                  .timeout(const Duration(seconds: 3)) ??
              'Xray could not start the Android upstream proxy',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw PlatformException(
      code: 'xray_start_timeout',
      message:
          'Xray upstream did not start within ${timeout.inSeconds} seconds',
    );
  }

  Future<void> _waitForSingBoxTun(
      {Duration timeout = const Duration(seconds: 30)}) async {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      final nativeState = await _channel
          .invokeMethod<String>('vpnState')
          .timeout(const Duration(seconds: 1));
      if (nativeState == 'connected') {
        state = VpnState.connected;
        final timestamp = await _channel
            .invokeMethod<int>('vpnConnectedAt')
            .timeout(const Duration(seconds: 3));
        _connectedAt = timestamp == null
            ? DateTime.now()
            : DateTime.fromMillisecondsSinceEpoch(timestamp);
        return;
      }
      if (nativeState == 'error') {
        throw PlatformException(
          code: 'core_start_failed',
          message: await _channel
                  .invokeMethod<String>('vpnError')
                  .timeout(const Duration(seconds: 3)) ??
              'sing-box could not start the Android TUN router',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw PlatformException(
      code: 'start_timeout',
      message:
          'sing-box did not start the Android TUN within ${timeout.inSeconds} seconds',
    );
  }

  @override
  Future<void> disconnect() async {
    await _stopVpnBestEffort(recordReconnectAcknowledgement: true);
    state = VpnState.disconnected;
    lastError = null;
    _connectedAt = null;
    _readLogCount = 0;
    _clearXrayBridgeSession();
  }

  void _clearXrayBridgeSession() {
    _xrayBridgeSocksPort = null;
    _activeXrayBridgeProfile = null;
    _activeXrayConfig = null;
    _activeXrayEndpointExclusions = const [];
  }

  Future<void> _stopVpnBestEffort(
      {bool recordReconnectAcknowledgement = false}) async {
    var fullyAcknowledged = false;
    try {
      await _channel
          .invokeMethod<void>('stopVpn')
          .timeout(const Duration(seconds: 3));
      final stopwatch = Stopwatch()..start();
      while (stopwatch.elapsed < const Duration(seconds: 12)) {
        try {
          final nativeState = await _channel
              .invokeMethod<String>('vpnState')
              .timeout(const Duration(milliseconds: 750));
          final xrayState = await _channel
              .invokeMethod<String>('xrayProxyState')
              .timeout(const Duration(milliseconds: 750));
          final stopComplete = await _channel
                  .invokeMethod<bool>('vpnStopComplete')
                  .timeout(const Duration(milliseconds: 750)) ??
              false;
          if (stopComplete &&
              nativeState == 'disconnected' &&
              xrayState == 'disconnected') {
            fullyAcknowledged = true;
            break;
          }
        } on Object {
          // Keep polling while the Android services finish asynchronous core
          // and TUN cleanup.
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } on Object {
      // Always clear the local spinner even if Android does not acknowledge
      // service shutdown; the native service has its own stop cleanup path.
    } finally {
      if (recordReconnectAcknowledgement) {
        _hasRecentNativeStopAcknowledgement = fullyAcknowledged;
      }
      if (state != VpnState.connected) state = VpnState.disconnected;
      _connectedAt = null;
      _readLogCount = 0;
    }
  }
}
