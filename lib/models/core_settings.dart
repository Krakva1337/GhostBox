import 'dart:io';

class CoreSettings {
  const CoreSettings({
    this.core = 'xray',
    this.connectionMode = 'tun',
    this.routing = 'proxy',
    this.dns = 'system',
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
    this.pingMode = 'proxy',
    this.proxyGetUrl = 'https://example.com/ghostbox-probe-404',
    this.pingView = 'full',
    this.pingCount = 3,
    this.pingTimeoutSeconds = 4,
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
  final bool killSwitchEnabled;
  final String killSwitchEndpoint, killSwitchProfileId;
  final bool showRamUsage;
  final bool aggressiveXhttpCleanup, autoLocalPort;
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
          int? pingTimeoutSeconds}) =>
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
          pingTimeoutSeconds: pingTimeoutSeconds ?? this.pingTimeoutSeconds);

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
          ['system', 'cloudflare', 'google', 'combined', 'custom'], 'system'),
      customDnsResolver:
          data['customDnsResolver'] as String? ?? 'https://1.1.1.1/dns-query',
      logLevel: choice('logLevel', ['error', 'warning', 'info'], 'warning'),
      dnsThroughProxy: data['dnsThroughProxy'] == true,
      dnsBlacklistMode: blacklistMode,
      blocklistEnabled: blacklistMode != 'none',
      autoConnect: data['autoConnect'] == true,
      autoPing: data['autoPing'] == true,
      killSwitchEnabled: data['killSwitchEnabled'] == true,
      killSwitchEndpoint: data['killSwitchEndpoint'] as String? ?? '',
      killSwitchProfileId: data['killSwitchProfileId'] as String? ?? '',
      aggressiveXhttpCleanup: data['aggressiveXhttpCleanup'] == true,
      pingMode: choice('pingMode', ['proxy', 'tcp', 'icmp'], 'proxy'),
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
        'pingMode': pingMode,
        'proxyGetUrl': proxyGetUrl,
        'pingView': pingView,
        'pingCount': pingCount,
        'pingTimeoutSeconds': pingTimeoutSeconds,
      };

  static bool isValidDomain(String value) => RegExp(
          r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$')
      .hasMatch(value.trim().toLowerCase());

  /// Route lists accept DNS suffix patterns such as `*.ru`, IP addresses and
  /// CIDR networks. Core routing engines receive DNS suffixes without `*.`.
  static String normalizeRoutePattern(String value) =>
      value.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), '');

  static bool isValidRoutePattern(String value) {
    final pattern = normalizeRoutePattern(value);
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
    final parts = value.split('/');
    if (parts.length > 2) return false;
    final address = InternetAddress.tryParse(parts.first);
    if (address == null) return false;
    if (parts.length == 1) return true;
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
