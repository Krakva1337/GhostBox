import 'dart:convert';

import 'core_settings.dart';

/// Shared list importer. Amnezia's hostname is authoritative; its saved DNS
/// answers are a cache and must not become permanent routes to shared CDNs.
class RouteRuleList {
  static List<String> parse(String source) {
    final input = source.trim();
    if (input.isEmpty) return const [];
    final result = <String>{};

    void add(String token) {
      final normalized = CoreSettings.normalizeRoutePattern(token);
      if (!CoreSettings.isValidRoutePattern(normalized)) {
        throw FormatException('Неверное правило маршрутизации: $token');
      }
      result.add(normalized);
    }

    void tokens(String text) {
      for (final line in const LineSplitter().convert(text)) {
        final value = line.trim();
        if (value.isEmpty || value.startsWith('#') || value.startsWith('//')) {
          continue;
        }
        for (final token in value.split(RegExp(r'[\s,;]+'))) {
          if (token.isNotEmpty) add(token);
        }
      }
    }

    void collect(Object? node) {
      if (node is String) {
        tokens(node);
      } else if (node is List) {
        for (final entry in node) {
          collect(entry);
        }
      } else if (node is Map) {
        // Official Amnezia records use hostname + ip (legacy) or ips (array).
        // Keep the hostname, resolving it again through the active VPN DNS.
        final hostname = node['hostname'];
        if (hostname is String && hostname.trim().isNotEmpty) {
          add(hostname);
          return;
        }
        final explicit = node['domain'] ?? node['cidr'] ?? node['ip'];
        if (explicit is String && explicit.trim().isNotEmpty) {
          add(explicit);
          return;
        }
        if (node.containsKey('rules') || node.containsKey('sites')) {
          collect(node['rules'] ?? node['sites']);
          return;
        }
        if (node.isEmpty) return;
        // Also accept a hostname-to-address map, without mining arbitrary
        // description/metadata fields for strings that look like domains.
        if (node.keys.every(
            (key) => key is String && CoreSettings.isValidRoutePattern(key))) {
          for (final key in node.keys) {
            add(key as String);
          }
          return;
        }
        throw const FormatException(
            'JSON: нужны строки или записи hostname, domain, ip, cidr');
      } else {
        throw const FormatException('JSON содержит неподдерживаемое правило');
      }
    }

    if (input.startsWith('{') ||
        (input.startsWith('[') && !CoreSettings.isValidRoutePattern(input))) {
      collect(jsonDecode(input));
    } else {
      tokens(input);
    }
    return result.toList();
  }
}
