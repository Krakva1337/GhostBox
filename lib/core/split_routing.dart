import '../models/core_settings.dart';

/// A single routing contract shared by every native tunnel and proxy adapter.
///
/// A bare domain includes its subdomains for compatibility with saved lists.
/// `full:example.org` is exact; `*.example.org` includes subdomains only.
/// Domain answers remain in the core's session DNS cache, never OS route tables:
/// CDN addresses can be shared by unrelated sites and change while connected.
class SplitRoutingPlan {
  SplitRoutingPlan.fromSettings(CoreSettings settings)
      : finalOutbound = settings.routing == 'rules' ? 'direct' : 'proxy',
        matchedOutbound = settings.routing == 'exclude' ? 'direct' : 'proxy',
        targets = RouteTargets.parse(switch (settings.routing) {
          'exclude' => [
              ...settings.directDomains,
              ...settings.directApps.map((package) => 'app:$package'),
            ],
          'rules' => [
              ...settings.proxyDomains,
              ...settings.proxyApps.map((package) => 'app:$package'),
            ],
          _ => const <String>[],
        }),
        blocked = RouteTargets.parse(settings.effectiveBlockedDomains),
        sniffingEnabled = settings.sniffingEnabled;

  final String finalOutbound;
  final String matchedOutbound;
  final RouteTargets targets;
  final RouteTargets blocked;
  final bool sniffingEnabled;

  // A direct split rule may receive IPv6 destinations from DNS or sniffing.
  // On devices without a native IPv6 route, direct dialing fails immediately
  // and browsers report partial transfers. Keep IPv4 direct and send matching
  // IPv6 through the configured default outbound as a compatibility fallback.
  bool get hasDirectIpv6Fallback =>
      matchedOutbound == 'direct' && finalOutbound == 'proxy';

  List<Map<String, dynamic>> get singBoxRules => [
        // FakeIP's synthetic ranges are resolved during TUN pre-match before
        // any domain selector. This is required by sing-box 1.14.3 for L3
        // FakeIP destinations; it is a lookup step, not a policy rule.
        if (targets.hasDomains)
          {
            'ip_cidr': ['198.18.0.0/15', 'fc00::/18'],
            'action': 'resolve',
          },
        if (blocked.hasDomains) {...blocked.singBoxDomains, 'action': 'reject'},
        // Package identity is available during TUN pre-match and wins over
        // hostname and IP rules, as requested by the shared policy order.
        if (targets.hasApps && hasDirectIpv6Fallback)
          {
            ...targets.singBoxApps,
            'ip_version': 6,
            'action': 'route',
            'outbound': finalOutbound,
          },
        if (targets.hasApps)
          {
            ...targets.singBoxApps,
            'action': 'route',
            'outbound': matchedOutbound,
          },
        if (sniffingEnabled || targets.hasDomains)
          {'action': 'sniff', 'timeout': '300ms'},
        if (targets.hasDomains && hasDirectIpv6Fallback)
          {
            ...targets.singBoxDomains,
            'ip_version': 6,
            'action': 'route',
            'outbound': finalOutbound,
          },
        if (targets.hasDomains) ...targets.singBoxDomainRules(matchedOutbound),
        // Explicit resolution is needed when SOCKS/HTTP supplied a host name
        // but the user's rule is a CIDR. This runs after domain rules so it
        // never changes the result of a more specific domain decision.
        if (targets.cidrs.isNotEmpty) {'action': 'resolve'},
        if (targets.cidrs.isNotEmpty)
          {
            'ip_cidr': targets.cidrs,
            'action': 'route',
            'outbound': matchedOutbound,
          },
      ];

  List<Map<String, dynamic>> get xrayRules => [
        if (targets.hasApps)
          throw const FormatException(
              'app:<package> маршрутизация поддерживается только Sing-box на Android.'),
        if (blocked.hasDomains)
          {
            'type': 'field',
            'domain': blocked.xrayDomains,
            'outboundTag': 'block',
          },
        if (targets.hasDomains)
          {
            'type': 'field',
            'domain': targets.xrayDomains,
            'outboundTag': matchedOutbound,
          },
        if (targets.cidrs.isNotEmpty)
          {
            'type': 'field',
            'ip': targets.cidrs,
            'outboundTag': matchedOutbound,
          },
        {
          'type': 'field',
          'network': 'tcp,udp',
          'outboundTag': finalOutbound,
        },
      ];
}

class RouteTargets {
  const RouteTargets._(
      this.appPackages, this.exact, this.suffixes, this.subdomains, this.cidrs);

  factory RouteTargets.parse(Iterable<String> entries) {
    final appPackages = <String>{};
    final exact = <String>{};
    final suffixes = <String>{};
    final subdomains = <String>{};
    final cidrs = <String>{};
    for (final input in entries) {
      final exactOnly = input.trim().toLowerCase().startsWith('full:');
      final value = CoreSettings.normalizeRoutePattern(
          exactOnly ? input.trim().substring(5) : input);
      if (!CoreSettings.isValidRoutePattern(value)) {
        throw FormatException('Некорректное правило маршрутизации: $input');
      }
      if (value.startsWith('app:')) {
        if (exactOnly) {
          throw FormatException(
              'full: несовместим с селектором приложения: $input');
        }
        appPackages.add(value.substring(4));
      } else if (CoreSettings.isIpRoute(value)) {
        if (exactOnly) {
          throw FormatException('full: применяется только к доменам: $input');
        }
        cidrs.add(CoreSettings.routeIp(value));
      } else if (exactOnly) {
        if (value.startsWith('*.')) {
          throw FormatException('full: несовместим с маской: $input');
        }
        exact.add(value);
      } else if (value.startsWith('*.')) {
        subdomains.add(value.substring(2));
      } else {
        suffixes.add(value);
      }
    }
    List<String> sorted(Set<String> values) =>
        List.unmodifiable(values.toList()..sort());
    return RouteTargets._(sorted(appPackages), sorted(exact), sorted(suffixes),
        sorted(subdomains), sorted(cidrs));
  }

  final List<String> appPackages;
  final List<String> exact;
  final List<String> suffixes;
  final List<String> subdomains;
  final List<String> cidrs;
  bool get hasDomains =>
      exact.isNotEmpty || suffixes.isNotEmpty || subdomains.isNotEmpty;
  bool get hasApps => appPackages.isNotEmpty;

  Map<String, dynamic> get singBoxDomains => {
        if (exact.isNotEmpty) 'domain': exact,
        if (suffixes.isNotEmpty || subdomains.isNotEmpty)
          'domain_suffix': [...suffixes, ...subdomains.map((e) => '.$e')],
      };

  Map<String, dynamic> get singBoxApps =>
      appPackages.isEmpty ? const {} : {'package_name': appPackages};

  List<Map<String, dynamic>> singBoxDomainRules(String outbound) => [
        if (exact.isNotEmpty)
          {
            'domain': exact,
            'action': 'route',
            'outbound': outbound,
          },
        if (suffixes.isNotEmpty)
          {
            'domain_suffix': suffixes,
            'action': 'route',
            'outbound': outbound,
          },
        if (subdomains.isNotEmpty)
          {
            'domain_suffix': subdomains.map((e) => '.$e').toList(),
            'action': 'route',
            'outbound': outbound,
          },
      ];

  List<String> get xrayDomains => [
        ...exact.map((e) => 'full:$e'),
        ...suffixes.map((e) => 'domain:$e'),
        ...subdomains.map((e) => 'regexp:^.+\\.${RegExp.escape(e)}\$'),
      ];
}
