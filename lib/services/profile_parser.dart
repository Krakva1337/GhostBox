import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/server_profile.dart';
import '../models/subscription_metadata.dart';
import 'device_identity.dart';

class ProfileParser {
  List<ServerProfile> parse(String input, {String? source}) {
    final value = input.trim();
    if (value.isEmpty) throw const FormatException('Пустая ссылка или конфиг');
    if (RegExp(r'^(vless|vmess|trojan|ss|socks|http|hysteria2?|tuic|anytls)://',
            caseSensitive: false)
        .hasMatch(value)) {
      return value
          .split(RegExp(r'\s+'))
          .where((line) => line.contains('://'))
          .map((line) => _parseUri(line, source))
          .toList();
    }

    if (value.startsWith('{') || value.startsWith('['))
      return _parseJson(jsonDecode(value), source);
    try {
      return _parseJson(jsonDecode(value), source);
    } catch (_) {/* Try a base64 subscription next. */}
    try {
      return parse(utf8.decode(base64.decode(_normalizeBase64(value))),
          source: source);
    } catch (_) {
      throw const FormatException(
          'Не удалось распознать ссылку, JSON или base64-подписку');
    }
  }

  List<ServerProfile> _parseJson(dynamic value, String? source) {
    if (value is List) {
      return value
          .whereType<Map<String, dynamic>>()
          .map((item) => _fromMap(item, source))
          .toList();
    }
    if (value is Map<String, dynamic>) {
      if (value['outbounds'] is List) {
        final rows = <ServerProfile>[];
        for (final item in value['outbounds'] as List) {
          if (item is! Map) continue;
          final outbound = Map<String, dynamic>.from(item);
          if (outbound['tag'] == 'direct' ||
              outbound['type'] == 'direct' ||
              outbound['protocol'] == 'freedom') continue;
          if (outbound['server'] != null) {
            rows.add(_fromMap({
              ...outbound,
              'name': outbound['tag'] ?? outbound['name'],
              'protocol': outbound['type'] ?? outbound['protocol']
            }, source));
          } else {
            final settings = Map<String, dynamic>.from(
                outbound['settings'] as Map? ?? const {});
            final vnext = (settings['vnext'] as List?)?.firstOrNull;
            if (vnext is Map) {
              final node = Map<String, dynamic>.from(vnext);
              final user =
                  ((node['users'] as List?)?.firstOrNull as Map?) ?? const {};
              rows.add(_fromMap({
                ...outbound,
                'address': node['address'],
                'port': node['port'],
                'uuid': user['id'],
                'scy': user['security'],
                'aid': user['alterId'],
                'flow': user['flow'],
                'encryption': user['encryption'],
                'protocol': outbound['protocol'],
                'name': outbound['tag']
              }, source));
            } else {
              final servers = settings['servers'] as List?;
              final server = (servers?.firstOrNull as Map?) ?? const {};
              if (server['address'] != null && server['port'] != null) {
                rows.add(_fromMap({
                  ...outbound,
                  ...Map<String, dynamic>.from(server),
                  'name': outbound['tag'] ?? server['name'],
                  'protocol': outbound['protocol'],
                  'password': server['password'] ??
                      ((server['users'] as List?)?.firstOrNull
                          as Map?)?['pass'],
                  'method': server['method'] ?? server['cipher'],
                  'username': ((server['users'] as List?)?.firstOrNull
                      as Map?)?['user'],
                }, source));
              }
            }
          }
        }
        if (rows.isEmpty)
          throw const FormatException(
              'JSON не содержит поддерживаемых серверных профилей');
        return rows;
      }
      return [_fromMap(value, source)];
    }
    throw const FormatException('JSON не содержит профилей');
  }

  Future<List<ServerProfile>> parseSource(String source) async {
    return (await parseSourceDetailed(source)).profiles;
  }

  /// Fetches profiles and any metadata supplied by the subscription server.
  /// Plain text, JSON and pasted links return empty metadata.
  Future<SubscriptionParseResult> parseSourceDetailed(String source) async {
    var value = source.trim();
    // Links can be opened by another process directly from Explorer/browser.
    // Bound input before decoding base64/JSON so a malformed URL cannot make
    // the desktop app allocate unbounded memory while importing it.
    if (value.length > 12 * 1024 * 1024) {
      throw const FormatException(
          'Ссылка или подписка слишком большая (лимит 12 МБ).');
    }
    final appLink = Uri.tryParse(value);
    if (appLink != null &&
        appLink.scheme.toLowerCase() == 'ghostbox' &&
        appLink.host.toLowerCase() == 'addserver') {
      final payload = appLink.queryParameters['url'] ??
          appLink.queryParameters['link'] ??
          appLink.queryParameters['json'] ??
          (appLink.queryParameters['b64'] == null
              ? null
              : utf8.decode(
                  base64.decode(
                      _normalizeBase64(appLink.queryParameters['b64']!)),
                  allowMalformed: false)) ??
          appLink.queryParameters['uri'];
      // Also accept the compact form: GhostBox://addserver?<encoded payload>.
      value = payload ?? Uri.decodeComponent(appLink.query);
      if (value.trim().isEmpty) {
        throw const FormatException(
            'В ссылке GhostBox нет URL или JSON сервера.');
      }
    }
    if (value.startsWith('https://') || value.startsWith('http://')) {
      final uri = Uri.parse(value);
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12)
        ..idleTimeout = const Duration(seconds: 15);
      try {
        final request =
            await client.getUrl(uri).timeout(const Duration(seconds: 15));
        request.headers
            .set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*');
        request.headers.set(
            HttpHeaders.userAgentHeader, DeviceIdentity.subscriptionUserAgent);
        final deviceHeaders = await DeviceIdentity.transportHeaders;
        deviceHeaders
            .forEach((name, value) => request.headers.set(name, value));
        final response =
            await request.close().timeout(const Duration(seconds: 20));
        if (response.statusCode < 200 || response.statusCode >= 300)
          throw FormatException(
              'Сервер подписки вернул HTTP ${response.statusCode}');
        final headers = <String, String>{};
        response.headers.forEach((name, values) {
          final lower = name.toLowerCase();
          if (lower == 'set-cookie' ||
              lower == 'set-cookie2' ||
              lower == 'authorization' ||
              lower == 'proxy-authorization' ||
              lower == 'www-authenticate' ||
              lower == 'proxy-authenticate') return;
          headers[lower] = values.join(', ');
        });
        const maxResponseBytes = 12 * 1024 * 1024;
        final bytes = await response.fold<BytesBuilder>(
          BytesBuilder(copy: false),
          (builder, chunk) {
            if (builder.length + chunk.length > maxResponseBytes) {
              throw const FormatException(
                  'Ответ подписки превышает лимит 12 МБ.');
            }
            builder.add(chunk);
            return builder;
          },
        ).timeout(const Duration(seconds: 30));
        final body = utf8.decode(bytes.takeBytes());
        return SubscriptionParseResult(
            parse(body, source: value), _readMetadata(headers));
      } finally {
        client.close(force: true);
      }
    }
    return SubscriptionParseResult(parse(value), const SubscriptionMetadata());
  }

  SubscriptionMetadata _readMetadata(Map<String, String> headers) {
    String? header(String name) {
      final value = headers[name]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    int? nonNegative(String? value) {
      final number = int.tryParse(value?.trim() ?? '');
      return number != null && number >= 0 ? number : null;
    }

    final usage = <String, String>{};
    for (final part in (header('subscription-userinfo') ?? '').split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      usage[part.substring(0, separator).trim().toLowerCase()] =
          part.substring(separator + 1).trim();
    }

    var expire = nonNegative(usage['expire']);
    // A few subscription panels send milliseconds despite the usual seconds.
    if (expire != null && expire > 32000000000) expire ~/= 1000;

    final rawTitle = _decodeHeaderText(
        header('profile-title') ?? header('subscription-name'));
    final titleLines = rawTitle?.split(RegExp(r'\r?\n')) ?? const <String>[];
    final title = titleLines.isEmpty ? null : titleLines.first.trim();
    final description = _decodeHeaderText(header('profile-description')) ??
        (titleLines.length > 1 ? titleLines.skip(1).join('\n').trim() : null);
    final filename = _filenameFromDisposition(header('content-disposition'));

    int? deviceLimit;
    // This is provider-specific, not part of Subscription-Userinfo. Boolean
    // x-hwid-limit only says enforcement is active and is not a count.
    for (final name in [
      'device-limit',
      'x-device-limit',
      'subscription-device-limit',
      'x-hwid-device-limit',
    ]) {
      deviceLimit = nonNegative(header(name));
      if (deviceLimit != null) break;
    }
    deviceLimit ??= nonNegative(usage['device_limit'] ?? usage['device-limit']);

    return SubscriptionMetadata(
      title: title?.isNotEmpty == true ? title : filename,
      description: description?.isNotEmpty == true ? description : null,
      announcement: _decodeHeaderText(header('announce')),
      supportUrl: _webUrl(header('support-url')),
      websiteUrl: _webUrl(header('profile-web-page-url') ?? header('homepage')),
      upload: nonNegative(usage['upload']),
      download: nonNegative(usage['download']),
      total: nonNegative(usage['total'] ?? usage['totl']),
      expire: expire,
      deviceLimit: deviceLimit,
      updateIntervalHours: nonNegative(header('profile-update-interval')),
      headers: headers,
    );
  }

  String? _decodeHeaderText(String? value) {
    if (value == null) return null;
    var decoded = value;
    if (decoded.toLowerCase().startsWith('base64:')) {
      try {
        decoded = utf8.decode(
            base64.decode(_normalizeBase64(decoded.substring(7))),
            allowMalformed: true);
      } on FormatException {
        return value;
      }
    } else if (decoded.contains('%')) {
      try {
        decoded = Uri.decodeComponent(decoded);
      } on FormatException {
        // Keep the original title if a provider uses a malformed escape.
      }
    }
    return decoded.trim();
  }

  String? _webUrl(String? value) {
    if (value == null) return null;
    final uri = Uri.tryParse(value);
    return uri != null &&
            (uri.scheme == 'https' || uri.scheme == 'http') &&
            uri.host.isNotEmpty
        ? value
        : null;
  }

  String? _filenameFromDisposition(String? value) {
    if (value == null) return null;
    final match =
        RegExp(r'''filename\*?=(?:UTF-8''|"?)([^";]+)''', caseSensitive: false)
            .firstMatch(value);
    if (match == null) return null;
    final name = _decodeHeaderText(match.group(1))?.replaceAll(
        RegExp(r'\.(txt|json|yaml|yml)$', caseSensitive: false), '');
    return name?.isNotEmpty == true ? name : null;
  }

  ServerProfile _fromMap(Map<String, dynamic> map, String? source) {
    final stream =
        Map<String, dynamic>.from(map['streamSettings'] as Map? ?? const {});
    final tls = Map<String, dynamic>.from(map['tls'] as Map? ?? const {});
    final reality = Map<String, dynamic>.from((tls['reality'] as Map?) ??
        (stream['realitySettings'] as Map?) ??
        const {});
    final tlsSettings =
        Map<String, dynamic>.from(stream['tlsSettings'] as Map? ?? const {});
    final transport =
        Map<String, dynamic>.from(map['transport'] as Map? ?? const {});
    final network = _normalizeNetwork(
        (stream['network'] ?? transport['type'] ?? map['network'] ?? 'tcp')
            .toString());
    final ws =
        Map<String, dynamic>.from(stream['wsSettings'] as Map? ?? const {});
    final grpc =
        Map<String, dynamic>.from(stream['grpcSettings'] as Map? ?? const {});
    final xhttp =
        Map<String, dynamic>.from(stream['xhttpSettings'] as Map? ?? const {});
    final httpUpgrade = Map<String, dynamic>.from(
        stream['httpupgradeSettings'] as Map? ?? const {});
    final kcp =
        Map<String, dynamic>.from(stream['kcpSettings'] as Map? ?? const {});
    final quic =
        Map<String, dynamic>.from(stream['quicSettings'] as Map? ?? const {});
    final wsTransport = network == 'ws' ? transport : const <String, dynamic>{};
    final grpcTransport =
        network == 'grpc' ? transport : const <String, dynamic>{};
    final httpTransport =
        network == 'http' ? transport : const <String, dynamic>{};
    final xhttpTransport =
        network == 'xhttp' ? transport : const <String, dynamic>{};
    final upgradeTransport =
        network == 'httpupgrade' ? transport : const <String, dynamic>{};
    final wsHeaders = Map<String, dynamic>.from(
        (wsTransport['headers'] as Map?) ??
            (ws['headers'] as Map?) ??
            const {});
    final utls = Map<String, dynamic>.from(tls['utls'] as Map? ?? const {});
    final realityEnabled =
        stream['security'] == 'reality' || reality['enabled'] == true;
    final tlsEnabled = stream['security'] == 'tls' || tls['enabled'] == true;
    final security = realityEnabled
        ? 'reality'
        : tlsEnabled
            ? 'tls'
            : {'tls', 'reality', 'none'}.contains(map['security'])
                ? map['security']?.toString()
                : null;

    final address =
        (map['address'] ?? map['server'] ?? map['host'])?.toString();
    final port = int.tryParse('${map['port'] ?? map['server_port'] ?? ''}');
    if (address == null || port == null) {
      throw const FormatException('В JSON-профиле нет address/server и port');
    }
    final protocol =
        _normalizeProtocol('${map['protocol'] ?? map['type'] ?? 'vless'}');
    final uuid = (map['uuid'] ?? map['id'])?.toString();
    final raw = <String, dynamic>{...map};
    raw.removeWhere((_, value) => value == null);
    void put(String key, dynamic value) {
      if (value != null) raw[key] = value;
    }

    put(
        'sni',
        tls['server_name'] ??
            reality['serverName'] ??
            tlsSettings['serverName'] ??
            map['sni']);
    put('pbk', reality['public_key'] ?? reality['publicKey'] ?? map['pbk']);
    put('sid', reality['short_id'] ?? reality['shortId'] ?? map['sid']);
    put(
        'fp',
        utls['fingerprint'] ??
            reality['fingerprint'] ??
            tlsSettings['fingerprint'] ??
            map['fp']);
    put('path', wsTransport['path'] ?? ws['path'] ?? map['path']);
    put('host', wsHeaders['Host'] ?? wsHeaders['host'] ?? map['host']);
    put(
        'path',
        xhttpTransport['path'] ??
            xhttp['path'] ??
            upgradeTransport['path'] ??
            httpUpgrade['path'] ??
            httpTransport['path'] ??
            map['path']);
    put(
        'host',
        xhttpTransport['host'] ??
            xhttp['host'] ??
            upgradeTransport['host'] ??
            httpUpgrade['host'] ??
            (httpTransport['host'] is List
                ? (httpTransport['host'] as List).firstOrNull
                : httpTransport['host']) ??
            map['host']);
    put('mode', xhttp['mode'] ?? map['mode']);
    put('extra', xhttp['extra'] ?? map['extra']);
    put('seed', kcp['seed'] ?? map['seed']);
    put('key', quic['key'] ?? map['key']);
    put(
        'headerType',
        kcp['header'] is Map
            ? (kcp['header'] as Map)['type']
            : map['headerType']);
    put('method', map['method'] ?? httpTransport['method']);
    put('username', map['username'] ?? map['user']);
    put('password', map['password'] ?? map['pass'] ?? map['secret']);
    put('cipher', map['cipher']);
    put('obfs', map['obfs']);
    put('obfsPassword', map['obfsPassword'] ?? map['obfs-password']);
    put('congestion_control',
        map['congestion_control'] ?? map['congestionControl']);
    put('udp_relay_mode', map['udp_relay_mode']);
    put('alpn', tls['alpn'] ?? tlsSettings['alpn'] ?? map['alpn']);
    put(
        'allowInsecure',
        tls['insecure'] ??
            tlsSettings['allowInsecure'] ??
            map['allowInsecure']);
    put('insecure', tls['insecure'] ?? map['insecure']);
    put('authority',
        grpcTransport['authority'] ?? grpc['authority'] ?? map['authority']);
    put('maxEarlyData', map['max_early_data'] ?? map['maxEarlyData']);
    put('earlyDataHeaderName',
        map['early_data_header_name'] ?? map['earlyDataHeaderName']);
    put(
        'serviceName',
        grpcTransport['service_name'] ??
            grpc['serviceName'] ??
            map['serviceName']);
    put(
        'serviceName',
        grpcTransport['service_name'] ??
            grpc['serviceName'] ??
            map['serviceName']);
    put('alterId', map['alter_id'] ?? map['alterId'] ?? map['aid']);
    put(
        'scy',
        map['scy'] ??
            (map['security'] != 'tls' && map['security'] != 'reality'
                ? map['security']
                : null));

    return ServerProfile(
      id: _stableId(source, [
        protocol,
        address,
        port,
        uuid,
        network,
        security,
        raw['pbk'],
        raw['path'],
        raw['serviceName']
      ]),
      name: '${map['name'] ?? map['remark'] ?? '$address:$port'}',
      protocol: protocol,
      address: address,
      port: port,
      uuid: uuid,
      network: network,
      security: security ??
          ([
            'trojan',
            'hysteria',
            'hysteria2',
            'tuic'
          ].contains('${map['protocol'] ?? map['type'] ?? ''}'.toLowerCase())
              ? 'tls'
              : null),
      raw: raw,
    );
  }

  ServerProfile _parseUri(String value, String? source) {
    if (value.toLowerCase().startsWith('vmess://')) {
      final data = jsonDecode(
              utf8.decode(base64.decode(_normalizeBase64(value.substring(8)))))
          as Map<String, dynamic>;
      return _fromMap({
        'name': data['ps'],
        'address': data['add'],
        'port': data['port'],
        'uuid': data['id'],
        'protocol': 'vmess',
        'network': data['net'] ?? 'tcp',
        'security': data['tls'] == 'tls' ? 'tls' : null,
        'sni': data['sni'],
        'path': data['path'],
        'host': data['host'],
        'mode': data['mode'],
        'extra': data['extra'],
        'alpn': data['alpn'],
        'fp': data['fp'],
        'allowInsecure': data['allowInsecure']
      }, source);
    }
    if (value.toLowerCase().startsWith('ss://')) {
      return _parseShadowsocksUri(value, source);
    }
    final uri = Uri.parse(value);
    if (uri.host.isEmpty || uri.port == 0) {
      throw const FormatException('Некорректная ссылка сервера');
    }
    final query = uri.queryParameters;
    final protocol = uri.scheme.toLowerCase();
    final userInfo = Uri.decodeComponent(uri.userInfo);
    String? uuid = userInfo.isEmpty ? null : userInfo;
    String? password = query['password'];
    if (protocol == 'tuic') {
      final split = userInfo.split(':');
      uuid = split.firstOrNull;
      password ??= split.length > 1 ? split.skip(1).join(':') : null;
    }
    if ({'trojan', 'hysteria', 'hysteria2', 'anytls'}.contains(protocol)) {
      password ??= userInfo;
    }
    final raw = <String, dynamic>{...query};
    if (password != null) raw['password'] = password;
    return ServerProfile(
      id: _stableId(source, [
        protocol,
        uri.host,
        uri.port,
        uri.userInfo,
        query['type'],
        query['security'],
        query['pbk'],
        query['path'],
        query['serviceName']
      ]),
      name: _decodeName(uri.fragment.isEmpty ? uri.host : uri.fragment),
      protocol: protocol,
      address: uri.host,
      port: uri.port,
      uuid: uuid,
      network: _normalizeNetwork(query['type'] ?? query['net'] ?? 'tcp'),
      security: query['security']?.toLowerCase() ??
          (['trojan', 'hysteria', 'hysteria2', 'tuic'].contains(protocol)
              ? 'tls'
              : null),
      raw: raw,
    );
  }

  String _normalizeNetwork(String value) => switch (value.toLowerCase()) {
        'splithttp' => 'xhttp',
        'websocket' => 'ws',
        'mkcp' => 'kcp',
        'raw' => 'tcp',
        _ => value.toLowerCase(),
      };

  String _normalizeProtocol(String value) => switch (value.toLowerCase()) {
        'ss' => 'shadowsocks',
        'socks5' => 'socks',
        'hy2' => 'hysteria2',
        _ => value.toLowerCase(),
      };

  ServerProfile _parseShadowsocksUri(String value, String? source) {
    final uri = Uri.parse(value);
    final payload = value.substring(5).split('#').first.split('?').first;
    final at = payload.lastIndexOf('@');
    late final String method;
    late final String password;
    late final Uri endpoint;
    if (at >= 0) {
      var credentials = payload.substring(0, at);
      try {
        credentials = utf8.decode(base64.decode(_normalizeBase64(credentials)));
      } on FormatException {
        credentials = Uri.decodeComponent(credentials);
      }
      final separator = credentials.indexOf(':');
      if (separator < 1)
        throw const FormatException('Некорректная ссылка Shadowsocks');
      method = credentials.substring(0, separator);
      password = credentials.substring(separator + 1);
      endpoint = Uri.parse('ss://${payload.substring(at + 1)}');
    } else {
      final decoded = utf8.decode(base64.decode(_normalizeBase64(payload)),
          allowMalformed: true);
      final split = decoded.lastIndexOf('@');
      if (split < 0)
        throw const FormatException('Некорректная ссылка Shadowsocks');
      final credentials = decoded.substring(0, split);
      final separator = credentials.indexOf(':');
      if (separator < 1)
        throw const FormatException('Некорректная ссылка Shadowsocks');
      method = credentials.substring(0, separator);
      password = credentials.substring(separator + 1);
      endpoint = Uri.parse('ss://${decoded.substring(split + 1)}');
    }
    if (endpoint.host.isEmpty || endpoint.port == 0) {
      throw const FormatException('Некорректный сервер Shadowsocks');
    }
    final query = uri.queryParameters;
    return ServerProfile(
      id: _stableId(source,
          ['shadowsocks', endpoint.host, endpoint.port, method, password]),
      name: _decodeName(uri.fragment.isEmpty ? endpoint.host : uri.fragment),
      protocol: 'shadowsocks',
      address: endpoint.host,
      port: endpoint.port,
      network: _normalizeNetwork(query['type'] ?? 'tcp'),
      security: query['security']?.toLowerCase(),
      raw: {'method': method, 'password': password, ...query},
    );
  }

  String _stableId(String? source, List<Object?> parts) {
    final bytes = utf8.encode(jsonEncode([source ?? '', ...parts]));
    int hash(int seed) {
      var value = seed;
      for (final byte in bytes) {
        value = ((value ^ byte) * 0x01000193) & 0xffffffff;
      }
      return value;
    }

    final first = hash(0x811c9dc5).toRadixString(16).padLeft(8, '0');
    final second = hash(0x9e3779b9).toRadixString(16).padLeft(8, '0');
    return 'profile-$first$second';
  }

  String _normalizeBase64(String input) {
    final compact = input
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll('-', '+')
        .replaceAll('_', '/');
    return compact.padRight((compact.length + 3) ~/ 4 * 4, '=');
  }

  String _decodeName(String value) {
    var result = value;
    for (var i = 0; i < 3; i++) {
      final decoded = result
          .replaceAll('+', ' ')
          .replaceAllMapped(RegExp(r'(?:%[0-9A-Fa-f]{2})+'), (match) {
        final bytes = RegExp(r'%([0-9A-Fa-f]{2})')
            .allMatches(match.group(0)!)
            .map((part) => int.parse(part.group(1)!, radix: 16))
            .toList();
        return utf8.decode(bytes, allowMalformed: true);
      });
      if (decoded == result) break;
      result = decoded;
    }
    final runes = result.runes.toList();
    if (runes.length >= 2 &&
        runes.take(2).every((r) => r >= 0x1F1E6 && r <= 0x1F1FF)) {
      return String.fromCharCodes(runes.skip(2)).trimLeft();
    }
    return result;
  }
}
