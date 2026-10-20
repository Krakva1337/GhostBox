import 'dart:convert';
import 'dart:io';

import '../models/core_settings.dart';

/// Downloads HaGeZi's domain lists and keeps a local copy for offline starts.
class DnsAdBlocklist {
  static const sources = [
    'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.txt',
    'https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/popupads.txt',
  ];

  Future<List<String>> readCache() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return const [];
      return _domainsFromText(await file.readAsString());
    } on Object {
      return const [];
    }
  }

  Future<List<String>> update(
      {List<String> additionalSources = const []}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 30);
    try {
      final allSources = [...sources, ...additionalSources];
      final lists = await Future.wait(allSources.map((url) async {
        if (!isValidSourceUrl(url)) {
          throw FormatException('Некорректная ссылка DNS-листа: $url');
        }
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set(HttpHeaders.userAgentHeader, 'GhostBox/1.0');
        final response =
            await request.close().timeout(const Duration(seconds: 45));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException(
              'HTTP ${response.statusCode} при загрузке DNS-листа');
        }
        return response.transform(utf8.decoder).join().timeout(
              const Duration(seconds: 60),
            );
      }));
      final domains = <String>{};
      for (final text in lists) {
        domains.addAll(_domainsFromText(text));
      }
      if (domains.isEmpty) throw const FormatException('DNS-листы пустые');
      final sorted = domains.toList()..sort();
      final cache = await _cacheFile();
      await cache.parent.create(recursive: true);
      await cache.writeAsString('${sorted.join('\n')}\n', flush: true);
      return sorted;
    } finally {
      client.close(force: true);
    }
  }

  static bool isValidSourceUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
        uri.scheme.toLowerCase() == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        uri.path.toLowerCase().endsWith('.txt');
  }

  List<String> _domainsFromText(String text) {
    final domains = <String>{};
    for (final raw in const LineSplitter().convert(text)) {
      var value = raw.trim();
      if (value.isEmpty || value.startsWith('#') || value.startsWith('!'))
        continue;
      final fields = value.split(RegExp(r'\s+'));
      if (fields.length > 1 &&
          (InternetAddress.tryParse(fields.first) != null ||
              fields.first == '0.0.0.0' ||
              fields.first == '127.0.0.1')) {
        value = fields.last;
      }
      value = value
          .replaceFirst(RegExp(r'^\|\|'), '')
          .replaceFirst(RegExp(r'\^.*$'), '')
          .replaceFirst(RegExp(r'^\*\.'), '')
          .replaceFirst(RegExp(r'^\.'), '')
          .replaceFirst(RegExp(r'\.$'), '')
          .toLowerCase();
      if (CoreSettings.isValidDomain(value)) domains.add(value);
    }
    return domains.toList();
  }

  Future<File> _cacheFile() async {
    final env = Platform.environment;
    late final String base;
    if (Platform.isLinux) {
      base = env['XDG_CACHE_HOME']?.trim().isNotEmpty == true
          ? env['XDG_CACHE_HOME']!.trim()
          : '${env['HOME'] ?? Directory.systemTemp.path}${Platform.pathSeparator}.cache';
    } else if (Platform.isWindows) {
      base = env['LOCALAPPDATA'] ?? env['APPDATA'] ?? Directory.systemTemp.path;
    } else if (Platform.isMacOS) {
      base =
          '${env['HOME'] ?? Directory.systemTemp.path}${Platform.pathSeparator}Library${Platform.pathSeparator}Caches';
    } else {
      base = Directory.systemTemp.path;
    }
    return File(
        '$base${Platform.pathSeparator}GhostBox${Platform.pathSeparator}dns-ad-blocklist.txt');
  }
}
