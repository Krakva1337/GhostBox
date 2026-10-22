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
          'exclude' => settings.directDomains,
          'rules' => settings.proxyDomains,
          _ => const <String>[],
        }),
        blocked = RouteTargets.parse(settings.effectiveBlockedDomains);

  final String finalOutbound;
  final String matchedOutbound;
  final RouteTargets targets;
  final RouteTargets blocked;

  List<Map<String, dynamic>> get singBoxRules => [
        if (blocked.hasDomains) {...blocked.singBoxDomains, 'action': 'reject'},
        if (targets.hasDomains)
          {
            ...targets.singBoxDomains,
            'action': 'route',
            'outbound': matchedOutbound,
          },
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
  const RouteTargets._(this.exact, this.suffixes, this.subdomains, this.cidrs);

  factory RouteTargets.parse(Iterable<String> entries) {
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
      if (CoreSettings.isIpRoute(value)) {
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
    return RouteTargets._(
        sorted(exact), sorted(suffixes), sorted(subdomains), sorted(cidrs));
  }

  final List<String> exact;
  final List<String> suffixes;
  final List<String> subdomains;
  final List<String> cidrs;
  bool get hasDomains =>
      exact.isNotEmpty || suffixes.isNotEmpty || subdomains.isNotEmpty;

  Map<String, dynamic> get singBoxDomains => {
        if (exact.isNotEmpty) 'domain': exact,
        if (suffixes.isNotEmpty || subdomains.isNotEmpty)
          'domain_suffix': [...suffixes, ...subdomains.map((e) => '.$e')],
      };

  List<String> get xrayDomains => [
        ...exact.map((e) => 'full:$e'),
        ...suffixes.map((e) => 'domain:$e'),
        ...subdomains.map((e) => 'regexp:^.+\\.${RegExp.escape(e)}\$'),
      ];
}
