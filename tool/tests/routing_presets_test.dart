import 'dart:convert';

import '../../lib/models/core_settings.dart';
import '../../lib/models/routing_presets.dart';
import '../../lib/core/split_routing.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

void main() {
  final builtIns = RoutingPreset.builtIns();
  check(builtIns.length == 3, 'Three built-in presets must ship');
  for (final preset in builtIns) {
    check(preset.domains.toSet().length == preset.domains.length,
        'No duplicates');
    for (final domain in preset.domains.where((e) => !e.startsWith('*.'))) {
      check(
          preset.domains.contains('*.$domain'), 'Missing wildcard for $domain');
    }
    check(preset.domains.every(CoreSettings.isValidRoutePattern),
        'Invalid built-in domain');
  }
  final settings = CoreSettings(
    routing: 'rules',
    proxyDomains: const ['discord.com', 'manual.example'],
    proxyPresetIds: const ['discord', 'custom-list'],
    directPresetIds: const ['roblox'],
    routingPresets: const [
      RoutingPreset(
          id: 'custom-list',
          name: 'My list',
          domains: ['full:exact.example', '203.0.113.0/24', 'discord.com'])
    ],
  );
  check(settings.proxyDomains.contains('*.discord.com'),
      'Enabled preset not merged');
  check(settings.proxyDomains.where((e) => e == 'discord.com').length == 1,
      'Merge duplicates');
  final disabled = settings.copyWith(proxyPresetIds: const []);
  check(disabled.proxyDomains.contains('discord.com'),
      'Manual overlap was deleted');
  check(!disabled.proxyDomains.contains('*.discord.com'),
      'Disabled preset still active');
  check(disabled.directDomains.contains('*.roblox.com'),
      'Other mode was changed');
  final restored = CoreSettings.fromJson(
      jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>);
  check(restored.proxyDomains.join('\n') == settings.proxyDomains.join('\n'),
      'Persistence lost preset rules');
  check(restored.manualProxyDomains.length == 2,
      'Presets leaked into manual rules');
  check(SplitRoutingPlan.fromSettings(restored).targets.hasDomains,
      'Backend did not receive presets');
  check(restored.copyWith(memoryMb: 256).manualProxyDomains.length == 2,
      'copyWith leaked preset rules');
  check(
      CoreSettings.fromJson({
            'proxyDomains': ['legacy.example']
          }).proxyDomains.single ==
          'legacy.example',
      'Legacy settings changed');
  print('Routing preset checks passed.');
}
