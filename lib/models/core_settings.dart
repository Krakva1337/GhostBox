import 'dart:io';
import 'dart:typed_data';

class CoreSettings {
  const CoreSettings({
    this.core = 'xray',
    this.connectionMode = 'tun',
    this.routing = 'proxy',
    this.dns = 'combined',
    this.customDnsResolver = 'https://1.1.1.1/dns-query',
    this.dnsThroughProxy = true,
    this.dnsBlacklistMode = 'none',
    this.blocklistEnabled = false,
    this.blockedDomains = const [],
    this.adBlockDomains = const [],
    this.directDomains = const [],
    this.proxyDomains = const [],
    this.memoryMb = 128,
    this.showRamUsage = false,
    this.localPort = 2080,
    this.autoLocalPort = true,
    this.logLevel = 'warning',
    this.autoConnect = false,
    this.autoPing = false,
    this.killSwitchEnabled = false,
    this.killSwitchEndpoint = '',
    this.killSwitchProfileId = '',
    this.aggressiveXhttpCleanup = false,
    this.tlsFragmentEnabled = false,
    this.fragmentPackets = 'tlshello',
    this.fragmentLength = '100-200',
    this.fragmentInterval = '10-20',
    this.fragmentRecord = false,
    this.fragmentFallbackDelayMs = 500,
    this.sniffingEnabled = true,
    this.tcpFastOpen = false,
    this.udpFragment = false,
    this.pingMode = 'proxy',
    this.proxyGetUrl = 'https://example.com/ghostbox-probe-404',
    this.pingView = 'full',
    this.pingCount = 3,
    this.pingTimeoutSeconds = 4,
    this.disconnectVpnForPing = false,
  });

  final String core,
      connectionMode,
      routing,
      dns,
      customDnsResolver,
      dnsBlacklistMode,
      logLevel,
      pingMode,
      proxyGetUrl,
      pingView;
  final int pingCount, pingTimeoutSeconds;
  final bool dnsThroughProxy, blocklistEnabled, autoConnect, autoPing;
  final bool disconnectVpnForPing;
  final bool killSwitchEnabled;
  final String killSwitchEndpoint, killSwitchProfileId;
  final bool showRamUsage;
  final bool aggressiveXhttpCleanup, autoLocalPort;
  final bool tlsFragmentEnabled, fragmentRecord, sniffingEnabled;
  final bool tcpFastOpen, udpFragment;
  final String fragmentPackets, fragmentLength, fragmentInterval;
  final int fragmentFallbackDelayMs;
  final List<String> blockedDomains,
      adBlockDomains,
      directDomains,
      proxyDomains;
  final int memoryMb, localPort;

  static int clampMemoryMb(int value) =>
      Platform.isIOS ? value.clamp(25, 50) : value.clamp(64, 256);

  List<String> get effectiveBlockedDomains => switch (dnsBlacklistMode) {
        'ads' => adBlockDomains,
        'custom' => blockedDomains,
        _ => const <String>[],
      };

  CoreSettings copyWith(
          {String? core,
          String? connectionMode,
          String? routing,
          String? dns,
          String? customDnsResolver,
          String? dnsBlacklistMode,
          bool? dnsThroughProxy,
          bool? blocklistEnabled,
          bool? autoConnect,
          bool? autoPing,
          bool? killSwitchEnabled,
          String? killSwitchEndpoint,
          String? killSwitchProfileId,
          bool? aggressiveXhttpCleanup,
          bool? tlsFragmentEnabled,
          String? fragmentPackets,
          String? fragmentLength,
          String? fragmentInterval,
          bool? fragmentRecord,
          int? fragmentFallbackDelayMs,
          bool? sniffingEnabled,
          bool? tcpFastOpen,
          bool? udpFragment,
          List<String>? blockedDomains,
          List<String>? adBlockDomains,
          List<String>? directDomains,
          List<String>? proxyDomains,
          int? memoryMb,
          bool? showRamUsage,
          int? localPort,
          bool? autoLocalPort,
          String? logLevel,
          String? pingMode,
          String? proxyGetUrl,
          String? pingView,
          int? pingCount,
          int? pingTimeoutSeconds,
          bool? disconnectVpnForPing}) =>
      CoreSettings(
          core: core ?? this.core,
          connectionMode: connectionMode ?? this.connectionMode,
          routing: routing ?? this.routing,
          dns: dns ?? this.dns,
          customDnsResolver: customDnsResolver ?? this.customDnsResolver,
          dnsBlacklistMode: dnsBlacklistMode ??
              (blocklistEnabled == null
                  ? this.dnsBlacklistMode
                  : blocklistEnabled
                      ? 'custom'
                      : 'none'),
          dnsThroughProxy: dnsThroughProxy ?? this.dnsThroughProxy,
          blocklistEnabled: dnsBlacklistMode == null
              ? blocklistEnabled ?? this.blocklistEnabled
              : dnsBlacklistMode != 'none',
          autoConnect: autoConnect ?? this.autoConnect,
          autoPing: autoPing ?? this.autoPing,
          killSwitchEnabled: killSwitchEnabled ?? this.killSwitchEnabled,
          killSwitchEndpoint: killSwitchEndpoint ?? this.killSwitchEndpoint,
          killSwitchProfileId: killSwitchProfileId ?? this.killSwitchProfileId,
          aggressiveXhttpCleanup:
              aggressiveXhttpCleanup ?? this.aggressiveXhttpCleanup,
          tlsFragmentEnabled: tlsFragmentEnabled ?? this.tlsFragmentEnabled,
          fragmentPackets: fragmentPackets ?? this.fragmentPackets,
          fragmentLength: fragmentLength ?? this.fragmentLength,
          fragmentInterval: fragmentInterval ?? this.fragmentInterval,
          fragmentRecord: fragmentRecord ?? this.fragmentRecord,
          fragmentFallbackDelayMs:
              (fragmentFallbackDelayMs ?? this.fragmentFallbackDelayMs)
                  .clamp(100, 3000),
          sniffingEnabled: sniffingEnabled ?? this.sniffingEnabled,
          tcpFastOpen: tcpFastOpen ?? this.tcpFastOpen,
          udpFragment: udpFragment ?? this.udpFragment,
          blockedDomains: blockedDomains ?? this.blockedDomains,
          adBlockDomains: adBlockDomains ?? this.adBlockDomains,
          directDomains: directDomains ?? this.directDomains,
          proxyDomains: proxyDomains ?? this.proxyDomains,
          memoryMb: clampMemoryMb(memoryMb ?? this.memoryMb),
          showRamUsage: showRamUsage ?? this.showRamUsage,
          localPort: localPort ?? this.localPort,
          autoLocalPort: autoLocalPort ?? this.autoLocalPort,
          logLevel: logLevel ?? this.logLevel,
          pingMode: pingMode ?? this.pingMode,
          proxyGetUrl: proxyGetUrl ?? this.proxyGetUrl,
          pingView: pingView ?? this.pingView,
          pingCount: pingCount ?? this.pingCount,
          pingTimeoutSeconds: pingTimeoutSeconds ?? this.pingTimeoutSeconds,
          disconnectVpnForPing:
              disconnectVpnForPing ?? this.disconnectVpnForPing);

  factory CoreSettings.fromJson(Map<String, dynamic> data) {
    String choice(String key, List<String> allowed, String fallback) =>
        allowed.contains(data[key]) ? data[key] as String : fallback;
    List<String> domains(String key) => (data[key] as List? ?? const [])
        .whereType<String>()
        .map((e) => e.trim().toLowerCase())
        .where(isValidDomain)
        .toSet()
        .toList();
    List<String> routePatterns(String key) => (data[key] as List? ?? const [])
        .whereType<String>()
        .map(normalizeRoutePattern)
        .where(isValidRoutePattern)
        .toSet()
        .toList();
    final blacklistMode = choice('dnsBlacklistMode', ['none', 'ads', 'custom'],
        data['blocklistEnabled'] == true ? 'custom' : 'none');
    return CoreSettings(
      core: choice('core', ['sing-box', 'xray'], 'xray'),
      connectionMode:
          choice('connectionMode', ['proxy', 'system', 'tun', 'mixed'], 'tun'),
      routing: choice('routing', ['proxy', 'rules', 'exclude'], 'proxy'),
      dns: choice('dns',
          ['system', 'cloudflare', 'google', 'combined', 'custom'], 'combined'),
      customDnsResolver:
          data['customDnsResolver'] as String? ?? 'https://1.1.1.1/dns-query',
      logLevel: choice('logLevel', ['error', 'warning', 'info'], 'warning'),
      dnsThroughProxy: data['dnsThroughProxy'] != false,
      dnsBlacklistMode: blacklistMode,
      blocklistEnabled: blacklistMode != 'none',
      autoConnect: data['autoConnect'] == true,
      autoPing: data['autoPing'] == true,
      killSwitchEnabled: data['killSwitchEnabled'] == true,
      killSwitchEndpoint: data['killSwitchEndpoint'] as String? ?? '',
      killSwitchProfileId: data['killSwitchProfileId'] as String? ?? '',
      aggressiveXhttpCleanup: data['aggressiveXhttpCleanup'] == true,
      tlsFragmentEnabled: data['tlsFragmentEnabled'] == true,
      fragmentPackets:
          choice('fragmentPackets', ['tlshello', '1-3'], 'tlshello'),
      fragmentLength:
          choice('fragmentLength', ['50-100', '100-200', '200-300'], '100-200'),
      fragmentInterval: choice(
          'fragmentInterval', ['0-0', '5-10', '10-20', '20-30'], '10-20'),
      fragmentRecord: data['fragmentRecord'] == true,
      fragmentFallbackDelayMs:
          ((data['fragmentFallbackDelayMs'] as num?)?.toInt() ?? 500)
              .clamp(100, 3000),
      sniffingEnabled: data['sniffingEnabled'] != false,
      tcpFastOpen: data['tcpFastOpen'] == true,
      udpFragment: data['udpFragment'] == true,
      pingMode: choice('pingMode', ['proxy', 'tcp', 'icmp'],
          Platform.isAndroid || Platform.isIOS ? 'tcp' : 'proxy'),
      proxyGetUrl: data['proxyGetUrl'] == 'https://httpbin.org/status/404'
          ? 'https://example.com/ghostbox-probe-404'
          : data['proxyGetUrl'] as String? ??
              'https://example.com/ghostbox-probe-404',
      pingView: choice('pingView', ['full', 'number', 'quality'], 'full'),
      pingCount:
          [1, 3, 5].contains(data['pingCount']) ? data['pingCount'] as int : 3,
      pingTimeoutSeconds: [2, 4, 8].contains(data['pingTimeoutSeconds'])
          ? data['pingTimeoutSeconds'] as int
          : 4,
      disconnectVpnForPing: data['disconnectVpnForPing'] == true,
      blockedDomains: domains('blockedDomains'),
      directDomains: routePatterns('directDomains'),
      proxyDomains: routePatterns('proxyDomains'),
      memoryMb: clampMemoryMb(
          (data['memoryMb'] as num?)?.toInt() ?? (Platform.isIOS ? 32 : 128)),
      showRamUsage: data['showRamUsage'] == true,
      localPort:
          ((data['localPort'] as num?)?.toInt() ?? 2080).clamp(1024, 65535),
      autoLocalPort: data['autoLocalPort'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
        'core': core,
        'connectionMode': connectionMode,
        'routing': routing,
        'dns': dns,
        'customDnsResolver': customDnsResolver,
        'dnsThroughProxy': dnsThroughProxy,
        'dnsBlacklistMode': dnsBlacklistMode,
        'blocklistEnabled': blocklistEnabled,
        'blockedDomains': blockedDomains,
        'directDomains': directDomains,
        'proxyDomains': proxyDomains,
        'memoryMb': memoryMb,
        'showRamUsage': showRamUsage,
        'localPort': localPort,
        'autoLocalPort': autoLocalPort,
        'logLevel': logLevel,
        'autoConnect': autoConnect,
        'autoPing': autoPing,
        'killSwitchEnabled': killSwitchEnabled,
        'killSwitchEndpoint': killSwitchEndpoint,
        'killSwitchProfileId': killSwitchProfileId,
        'aggressiveXhttpCleanup': aggressiveXhttpCleanup,
        'tlsFragmentEnabled': tlsFragmentEnabled,
        'fragmentPackets': fragmentPackets,
        'fragmentLength': fragmentLength,
        'fragmentInterval': fragmentInterval,
        'fragmentRecord': fragmentRecord,
        'fragmentFallbackDelayMs': fragmentFallbackDelayMs,
        'sniffingEnabled': sniffingEnabled,
        'tcpFastOpen': tcpFastOpen,
        'udpFragment': udpFragment,
        'pingMode': pingMode,
        'proxyGetUrl': proxyGetUrl,
        'pingView': pingView,
        'pingCount': pingCount,
        'pingTimeoutSeconds': pingTimeoutSeconds,
        'disconnectVpnForPing': disconnectVpnForPing,
      };

  static bool isValidDomain(String value) =>
      _isValidDomainName(value.trim().toLowerCase(), allowSingleLabel: false);

  /// Bare domains include their subdomains. `full:` matches one hostname and
  /// `*.` matches subdomains only. IP networks are stored with host bits cleared.
  static String normalizeRoutePattern(String value) {
    var pattern = value.trim().toLowerCase();
    final exact = pattern.startsWith('full:');
    if (exact) pattern = pattern.substring(5);
    if (pattern.startsWith('domain:')) pattern = pattern.substring(7);
    if (pattern.startsWith('http://') || pattern.startsWith('https://')) {
      final uri = Uri.tryParse(pattern);
      if (uri != null && uri.host.isNotEmpty) pattern = uri.host;
    }
    if (pattern.startsWith('[') && pattern.endsWith(']')) {
      pattern = pattern.substring(1, pattern.length - 1);
    }
    if (_isIpOrCidr(pattern)) {
      final parts = pattern.split('/');
      final address = InternetAddress.tryParse(parts.first)!;
      if (parts.length == 1)
        return exact ? 'full:${address.address}' : address.address;
      final prefix = int.parse(parts.last);
      final bytes = Uint8List.fromList(address.rawAddress);
      for (var index = 0; index < bytes.length; index++) {
        final bits = (prefix - index * 8).clamp(0, 8);
        bytes[index] &= bits == 0 ? 0 : (0xff << (8 - bits)) & 0xff;
      }
      final network = InternetAddress.fromRawAddress(bytes).address;
      return exact ? 'full:$network/$prefix' : '$network/$prefix';
    }
    // Domain lists commonly use `.example.org` as shorthand for every
    // subdomain. Convert that notation to the UI's explicit wildcard format.
    if (pattern.startsWith('.') && !pattern.startsWith('*.')) {
      pattern = '*$pattern';
    }
    pattern = pattern.replaceFirst(RegExp(r'\.$'), '');
    return exact ? 'full:$pattern' : pattern;
  }

  static bool isValidRoutePattern(String value) {
    final pattern = normalizeRoutePattern(value);
    if (pattern.startsWith('full:')) {
      return isValidDomain(pattern.substring(5));
    }
    if (_isIpOrCidr(pattern)) return true;
    if (pattern.startsWith('*.')) {
      final suffix = pattern.substring(2);
      return _isValidDomainName(suffix, allowSingleLabel: true);
    }
    return isValidDomain(pattern);
  }

  static String routeSuffix(String value) =>
      normalizeRoutePattern(value).replaceFirst(RegExp(r'^\*\.'), '');

  static bool isIpRoute(String value) =>
      _isIpOrCidr(normalizeRoutePattern(value));

  static String routeIp(String value) {
    final pattern = normalizeRoutePattern(value);
    if (pattern.contains('/')) return pattern;
    final address = InternetAddress.tryParse(pattern);
    if (address == null) return pattern;
    return '$pattern/${address.type == InternetAddressType.IPv4 ? 32 : 128}';
  }

  static bool _isIpOrCidr(String value) {
    if (value.contains('%')) return false;
    final parts = value.split('/');
    if (parts.length > 2) return false;
    final address = InternetAddress.tryParse(parts.first);
    if (address == null) return false;
    if (parts.length == 1) return true;
    if (!RegExp(r'^\d{1,3}$').hasMatch(parts.last)) return false;
    final prefix = int.tryParse(parts.last);
    if (prefix == null) return false;
    final maxPrefix = address.type == InternetAddressType.IPv4 ? 32 : 128;
    return prefix >= 0 && prefix <= maxPrefix;
  }

  static bool _isValidDomainName(String value,
      {required bool allowSingleLabel}) {
    if (value.isEmpty || value.length > 253) return false;
    final labels = value.split('.');
    if (!allowSingleLabel && labels.length < 2) return false;
    return labels.every((label) =>
        label.length <= 63 &&
        RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label));
  }
}
