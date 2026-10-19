import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/server_profile.dart';
import '../models/core_settings.dart';

import 'vpn_backend.dart';

/// Small process adapter shared by xray-core and sing-box.
///
/// The core is deliberately kept separate from the OS tunnel. Later, a
/// platform adapter can add TUN setup before [start] and tear it down after
/// [stop].
class CoreProcessBackend implements VpnBackend {
  CoreProcessBackend({
    required this.name,
    required this.executable,
    required this.configPath,
  });

  final String name;
  final String executable;
  final String configPath;
  Process? _process;
  VpnState _state = VpnState.disconnected;
  StreamSubscription<String>? _stderr;
  StreamSubscription<String>? _stdout;
  DateTime? _startedAt;
  File? _runtimeConfig;
  Directory? _runtimeDirectory;
  bool _shouldStayConnected = false;
  bool _initializing = false;
  bool _recoveryInProgress = false;
  int _restartCount = 0;
  CoreSettings settings = const CoreSettings();
  String? _lastError;
  final List<String> _logs = <String>[];
  Future<void> _coreLogWriteQueue = Future<void>.value();
  void Function(String message, {bool error})? onRecoveryNotice;

  @override
  VpnState get state => _state;
  DateTime? get startedAt => _startedAt;
  int? get pid => _process?.pid;
  String? get lastError => _lastError;
  List<String> get logs => List.unmodifiable(_logs);
  Future<void> flushLogs() => _coreLogWriteQueue;
  void clearLogBuffer() {
    _logs.clear();
    _lastError = null;
  }

  bool get executableAvailable => File(executable).existsSync();
  Duration get uptime => _startedAt == null
      ? Duration.zero
      : DateTime.now().difference(_startedAt!);

  @override
  Future<void> connect(String profile) async {
    if (_process != null || _state == VpnState.connecting) return;
    _shouldStayConnected = true;
    _initializing = true;
    _recoveryInProgress = false;
    _restartCount = 0;
    _state = VpnState.connecting;
    _lastError = null;
    _logs.clear();
    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        await _startProcess(profile);
        _initializing = false;
        return;
      } on Object catch (error) {
        lastError = error;
        _process = null;
        await _cleanupConfig();
        final retryable = error is ProcessException ||
            (error is FormatException &&
                error.message
                    .startsWith('Ядро завершилось сразу после запуска'));
        if (attempt == 3 || !retryable) break;
        _writeLifecycleLog(
            'Ядро $name не запустилось; повторная попытка ${attempt + 1}/3 через ${attempt} сек.');
        await Future<void>.delayed(Duration(seconds: attempt));
      }
    }
    _initializing = false;
    _shouldStayConnected = false;
    _state = VpnState.error;
    _lastError = _formatStartError(lastError);
    throw FormatException(_lastError!);
  }

  Future<void> _startProcess(String profile) async {
    if (!executableAvailable) {
      throw ProcessException(executable, const [],
          'Core binary not found. Run tool/fetch_cores.sh first.');
    }
    final serverProfile = ServerProfile.fromJson(
        Map<String, dynamic>.from(jsonDecode(profile) as Map));
    _validateProfile(serverProfile);
    if (name == 'sing-box' &&
        serverProfile.security == 'tls' &&
        _rawString(serverProfile, 'fp', 'fingerprint') != null) {
      _logs.add(
          'Эта сборка sing-box не поддерживает uTLS. Отпечаток браузера не применяется; для него выберите Xray.');
    }
    final config = makeConfig(serverProfile);
    final splitEntries = settings.routing == 'exclude'
        ? settings.directDomains
        : settings.proxyDomains;
    if (settings.routing == 'exclude' || settings.routing == 'rules') {
      final domainCount =
          splitEntries.where((value) => !CoreSettings.isIpRoute(value)).length;
      final networkCount = splitEntries.where(CoreSettings.isIpRoute).length;
      _logs.add(
          'Split routing: ${settings.routing}, $domainCount domain rules, $networkCount IP/CIDR rules. Domain rules use HTTP/TLS/QUIC sniffing; CIDRs match destination addresses directly.');
    }
    await _cleanupConfig();
    _runtimeDirectory = await Directory.systemTemp.createTemp('ghostbox-core-');
    _runtimeConfig = File('${_runtimeDirectory!.path}/config.json');
    await _runtimeConfig!
        .writeAsString(const JsonEncoder.withIndent('  ').convert(config));
    final check = await Process.run(
        executable,
        name == 'sing-box'
            ? ['check', '-c', _runtimeConfig!.path]
            : ['run', '-test', '-c', _runtimeConfig!.path]);
    if (check.exitCode != 0) {
      throw FormatException(_configError(
        serverProfile,
        '${check.stderr}\n${check.stdout}',
      ));
    }
    _process = await Process.start(
      executable,
      ['run', '-c', _runtimeConfig!.path],
      runInShell: false,
      environment: {'GOMEMLIMIT': '${settings.memoryMb}MiB'},
    );
    _stderr = _process!.stderr
        .transform<String>(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) {
      _captureLog(line, serverProfile, toStderr: true);
    });
    _stdout = _process!.stdout
        .transform<String>(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) {
      _captureLog(line, serverProfile);
    });
    _startedAt = DateTime.now();
    final running = _process!;
    running.exitCode.then((code) async {
      if (_process != running) return;
      _process = null;
      _startedAt = null;
      await _cleanupConfig();
      if (!_shouldStayConnected) {
        _state = VpnState.disconnected;
        return;
      }
      _lastError =
          'Ядро завершилось с кодом $code: ${_logs.isEmpty ? 'см. журнал' : _logs.last}';
      if (_initializing) {
        _state = VpnState.error;
        return;
      }
      if (_recoveryInProgress) return;
      _state = VpnState.connecting;
      _recoveryInProgress = true;
      _writeLifecycleLog(
          'Ядро $name завершилось (код $code); пробую поднять снова');
      onRecoveryNotice?.call(
        'Ядро неожиданно остановилось. Перезапускаю VPN…',
        error: false,
      );
      unawaited(_recoverProcess(profile));
    });
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (_process != running) {
      throw FormatException(_lastError ??
          'Ядро завершилось сразу после запуска. Проверьте журнал и локальный порт.');
    }
    _state = VpnState.connected;
    _lastError = null;
    _restartCount = 0;
  }

  Future<void> _recoverProcess(String profile) async {
    const delays = [500, 1200, 2500];
    for (final delayMs in delays) {
      if (!_shouldStayConnected) break;
      _restartCount++;
      _writeLifecycleLog(
          'Повторный запуск ядра $_restartCount/${delays.length} через ${delayMs}мс');
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      if (!_shouldStayConnected) break;
      try {
        await _startProcess(profile);
        _recoveryInProgress = false;
        return;
      } on Object catch (error) {
        _lastError = _formatStartError(error);
        _writeLifecycleLog(
            'Повторный запуск $_restartCount не удался: $_lastError');
      }
    }
    _recoveryInProgress = false;
    if (_shouldStayConnected) {
      _shouldStayConnected = false;
      _state = VpnState.error;
      _lastError ??= 'Не удалось поднять ядро после трёх попыток.';
      _writeLifecycleLog('Автоперезапуски ядра исчерпаны');
    }
  }

  String _formatStartError(Object? error) => error is FormatException
      ? error.message
      : error is ProcessException
          ? 'Не удалось запустить ядро $name. Проверьте установленный файл ядра.'
          : error?.toString() ?? 'Неизвестная ошибка запуска ядра.';

  void _writeLifecycleLog(String message) {
    _logs.add(message);
    if (_logs.length > 100) _logs.removeAt(0);
    _coreLogWriteQueue =
        _coreLogWriteQueue.then((_) => _appendPersistentLog(message));
  }

  @override
  Future<void> disconnect() async {
    _shouldStayConnected = false;
    _initializing = false;
    final process = _process;
    _process = null;
    await _stderr?.cancel();
    _stderr = null;
    await _stdout?.cancel();
    _stdout = null;
    process?.kill(ProcessSignal.sigterm);
    if (process != null)
      await process.exitCode.timeout(const Duration(seconds: 2), onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      });
    await _cleanupConfig();
    _startedAt = null;
    _state = VpnState.disconnected;
    _recoveryInProgress = false;
  }

  Future<void> _cleanupConfig() async {
    final directory = _runtimeDirectory;
    _runtimeDirectory = null;
    _runtimeConfig = null;
    if (directory != null && await directory.exists())
      await directory.delete(recursive: true);
  }

  void _validateProfile(ServerProfile p) {
    final xrayProtocols = {
      'vless',
      'vmess',
      'trojan',
      'shadowsocks',
      'socks',
      'http'
    };
    final singBoxProtocols = {
      ...xrayProtocols,
      'hysteria',
      'hysteria2',
      'tuic',
      'shadowtls',
      'anytls'
    };
    if (!(name == 'xray' ? xrayProtocols : singBoxProtocols)
        .contains(p.protocol)) {
      throw FormatException(
          'Протокол ${p.protocol.toUpperCase()} не поддерживается ядром $name. Выберите совместимое ядро.');
    }
    if (p.address.trim().isEmpty || p.port < 1 || p.port > 65535) {
      throw const FormatException(
          'У сервера неверный адрес или порт. Проверьте ссылку подписки.');
    }
    if (['vless', 'vmess'].contains(p.protocol) &&
        (p.uuid == null ||
            !RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
                .hasMatch(p.uuid!))) {
      throw const FormatException(
          'В профиле отсутствует корректный UUID. Обновите подписку или ссылку.');
    }
    final xrayNetworks = {
      'tcp',
      'raw',
      'ws',
      'websocket',
      'grpc',
      'xhttp',
      'splithttp',
      'httpupgrade',
      'kcp',
      'mkcp',
      'quic'
    };
    final singBoxNetworks = {
      'tcp',
      'raw',
      'ws',
      'websocket',
      'grpc',
      'httpupgrade',
      'quic',
      'http',
      // Available in sing-box downstream builds compiled with `with_xhttp`.
      'xhttp',
      'splithttp',
    };
    if (!(name == 'xray' ? xrayNetworks : singBoxNetworks)
        .contains(p.network)) {
      throw FormatException(p.network == 'xhttp' || p.network == 'splithttp'
          ? 'XHTTP требует ядро Xray. Переключите ядро на Xray в настройках.'
          : 'Транспорт ${p.network} не поддерживается ядром $name.');
    }
    if (p.security != null &&
        p.security != 'none' &&
        p.security != 'tls' &&
        p.security != 'reality') {
      throw FormatException('Защита ${p.security} пока не поддерживается.');
    }
    if (p.security == 'reality') {
      final key = _rawString(p, 'pbk', 'publicKey');
      if (key == null || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(key)) {
        throw const FormatException(
            'В профиле REALITY нет корректного публичного ключа (pbk). Обновите подписку.');
      }
      if (p.protocol != 'vless') {
        throw const FormatException(
            'REALITY поддерживается здесь только для VLESS.');
      }
      if (_rawString(p, 'sni', 'serverName') == null) {
        throw const FormatException(
            'В профиле REALITY нет имени сервера (SNI). Обновите подписку.');
      }
      final shortId = _rawString(p, 'sid', 'shortId');
      if (shortId != null &&
          !RegExp(r'^(?:[0-9a-fA-F]{2}){1,8}$').hasMatch(shortId)) {
        throw const FormatException(
            'В профиле REALITY неверный short ID. Обновите подписку.');
      }
    }
    if (p.protocol == 'trojan' &&
        _rawString(p, 'password') == null &&
        p.uuid == null) {
      throw const FormatException('В профиле Trojan отсутствует пароль.');
    }
    if (p.protocol == 'shadowsocks' &&
        (_rawString(p, 'method', 'cipher') == null ||
            _rawString(p, 'password', 'secret') == null)) {
      throw const FormatException(
          'Проверьте метод шифрования и пароль Shadowsocks.');
    }
    if (p.network == 'xhttp' || p.network == 'splithttp') {
      if (p.security == 'reality' && p.protocol != 'vless') {
        throw const FormatException(
            'XHTTP + REALITY поддерживается для VLESS.');
      }
      final mode = _rawString(p, 'mode');
      if (mode != null &&
          !{'auto', 'packet-up', 'stream-up', 'stream-one'}.contains(mode)) {
        throw FormatException('Неизвестный режим XHTTP: $mode');
      }
    }
  }

  String? _rawString(ServerProfile p, String primary, [String? fallback]) {
    final value = p.raw[primary] ?? (fallback == null ? null : p.raw[fallback]);
    final result = value?.toString().trim();
    return result == null || result.isEmpty ? null : result;
  }

  String _configError(ServerProfile p, String output) {
    final lower = output.toLowerCase();
    final tunMode =
        settings.connectionMode == 'tun' || settings.connectionMode == 'mixed';
    if (tunMode &&
        (lower.contains('operation not permitted') ||
            lower.contains('permission denied') ||
            lower.contains('/dev/net/tun'))) {
      if (lower.contains('/dev/net/tun') &&
          lower.contains('no such file or directory') &&
          !lower.contains('permission denied') &&
          !lower.contains('operation not permitted')) {
        return 'Не найден /dev/net/tun. Включите TUN в системе и проверьте, что устройство доступно.';
      }
      return '$name не получил доступ к TUN. Проверьте /dev/net/tun и CAP_NET_ADMIN для выбранного ядра.';
    }
    if (name == 'sing-box' &&
        (p.network == 'xhttp' || p.network == 'splithttp') &&
        (lower.contains('xhttp') || lower.contains('transport'))) {
      return 'Эта сборка sing-box не приняла XHTTP. Нужна сборка с тегом with_xhttp; штатная сборка GhostBox этот транспорт не содержит. Пока выберите Xray.';
    }
    if (lower.contains('address already in use') || lower.contains('bind:')) {
      return 'Локальный порт ${settings.localPort} занят. Смените порт в расширенных настройках.';
    }
    if (lower.contains('utls') || lower.contains('with_utls')) {
      return 'Это ядро sing-box собрано без uTLS. Для REALITY выберите Xray.';
    }
    if (lower.contains('reality') || lower.contains('public key')) {
      return 'Проверьте параметры REALITY в профиле: публичный ключ, SNI и short ID.';
    }
    if (lower.contains('invalid') && lower.contains('uuid')) {
      return 'В профиле неверный UUID. Обновите подписку.';
    }
    final detail = output
        .trim()
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .lastOrNull;
    final safeDetail = detail == null ? null : _safeLog(detail, p);
    return 'Ядро $name отклонило конфигурацию ${p.protocol.toUpperCase()}/${p.network}${safeDetail == null ? '' : ': ${safeDetail.length > 220 ? '${safeDetail.substring(0, 220)}…' : safeDetail}'}';
  }

  String _safeLog(String line, ServerProfile p) {
    var safe = line;
    final sensitiveValues = <String?>[
      p.uuid,
      _rawString(p, 'pbk', 'publicKey'),
      _rawString(p, 'password'),
      _rawString(p, 'sid', 'shortId'),
      for (final entry in p.raw.entries)
        if (RegExp(r'(pass|secret|token|auth|uuid|key)', caseSensitive: false)
            .hasMatch(entry.key))
          entry.value?.toString(),
    ];
    for (final value in sensitiveValues) {
      if (value != null && value.isNotEmpty)
        safe = safe.replaceAll(value, '•••');
    }
    return safe;
  }

  void _captureLog(String line, ServerProfile profile,
      {bool toStderr = false}) {
    final safe = _safeLog(line, profile);
    _logs.add(safe);
    if (_logs.length > 100) _logs.removeAt(0);
    if (toStderr) stderr.writeln('[$name] $safe');
    _coreLogWriteQueue =
        _coreLogWriteQueue.then((_) => _appendPersistentLog(safe));
  }

  Future<void> _appendPersistentLog(String line) async {
    try {
      final env = Platform.environment;
      final separator = Platform.pathSeparator;
      String? base;
      if (Platform.isLinux) {
        base = env['XDG_STATE_HOME'];
        if (base == null || base.isEmpty) {
          final home = env['HOME'];
          if (home != null && home.isNotEmpty) {
            base = '$home${separator}.local${separator}state';
          }
        }
      } else if (Platform.isWindows) {
        base = env['APPDATA'];
        if (base == null || base.isEmpty) {
          final home = env['USERPROFILE'];
          if (home != null && home.isNotEmpty) {
            base = '$home${separator}AppData${separator}Roaming';
          }
        }
      } else {
        base = env['HOME'];
      }
      base ??= Directory.systemTemp.path;
      final directory = Directory('$base${separator}GhostBox${separator}logs');
      await directory.create(recursive: true);
      final file = File('${directory.path}${separator}ghostbox.log');
      final timestamp = DateTime.now().toLocal().toIso8601String();
      final existingLength = await file.exists() ? await file.length() : 0;
      if (existingLength > 512 * 1024) {
        final old = await file.readAsString();
        final keepFrom = old.length > 256 * 1024 ? old.length - 256 * 1024 : 0;
        await file.writeAsString(old.substring(keepFrom));
      }
      await file.writeAsString('$timestamp  [$name] $line\n',
          mode: FileMode.append, flush: true);
    } on Object {
      // A read-only or unavailable home directory must not stop the VPN core.
    }
  }

  Map<String, dynamic> makeConfig(ServerProfile p) {
    final q = p.raw.map((k, v) => MapEntry(k, v?.toString()))
      ..removeWhere((_, value) => value == null || value.isEmpty);
    if (name == 'sing-box') {
      final outbound = <String, dynamic>{
        'type': p.protocol,
        'tag': 'proxy',
        'server': p.address,
        'server_port': p.port,
        if (p.uuid != null && ['vless', 'vmess', 'tuic'].contains(p.protocol))
          'uuid': p.uuid
      };
      if (p.protocol == 'vless' && q['flow'] != null) {
        outbound['flow'] = q['flow'];
      }
      if (p.protocol == 'vmess') {
        outbound['security'] = q['scy'] ?? q['security'] ?? 'auto';
        outbound['alter_id'] =
            int.tryParse(q['aid'] ?? q['alterId'] ?? '0') ?? 0;
      }
      if (p.protocol == 'trojan')
        outbound['password'] = q['password'] ?? p.uuid;
      if (p.protocol == 'shadowsocks') {
        outbound['method'] = q['method'] ?? q['cipher'] ?? 'aes-128-gcm';
        outbound['password'] = q['password'] ?? q['secret'] ?? p.uuid ?? '';
      }
      if (p.protocol == 'socks' || p.protocol == 'http') {
        if ((q['username'] ?? q['user']) != null)
          outbound['username'] = q['username'] ?? q['user'];
        if ((q['password'] ?? q['pass']) != null)
          outbound['password'] = q['password'] ?? q['pass'];
      }
      if (p.protocol == 'hysteria2' || p.protocol == 'hysteria') {
        outbound['password'] = q['password'] ?? q['auth'] ?? p.uuid ?? '';
        if ((q['obfs'] ?? q['obfsType']) != null) {
          outbound['obfs'] = {
            'type': q['obfs'] ?? q['obfsType'],
            if ((q['obfsPassword'] ?? q['obfs-password']) != null)
              'password': q['obfsPassword'] ?? q['obfs-password']
          };
        }
      }
      if (p.protocol == 'tuic') {
        outbound['password'] = q['password'] ?? '';
        outbound['congestion_control'] =
            q['congestion_control'] ?? q['congestionControl'] ?? 'bbr';
        outbound['udp_relay_mode'] = q['udp_relay_mode'] ?? 'native';
      }
      if (p.security == 'tls' ||
          p.security == 'reality' ||
          ['hysteria2', 'tuic'].contains(p.protocol)) {
        outbound['tls'] = {
          'enabled': true,
          if ((q['sni'] ?? q['serverName']) != null)
            'server_name': q['sni'] ?? q['serverName'],
          if (q['alpn'] != null)
            'alpn': q['alpn']!
                .split(',')
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toList(),
          if (q['insecure'] == '1' || q['insecure'] == 'true') 'insecure': true,
          if (p.security == 'reality')
            'utls': {
              'enabled': true,
              'fingerprint': q['fp'] ?? q['fingerprint'] ?? 'chrome'
            },
          if (p.security == 'reality')
            'reality': {
              'enabled': true,
              if ((q['pbk'] ?? q['publicKey']) != null)
                'public_key': q['pbk'] ?? q['publicKey'],
              if ((q['sid'] ?? q['shortId']) != null)
                'short_id': q['sid'] ?? q['shortId']
            }
        };
      }
      if (p.network == 'ws' || p.network == 'websocket')
        outbound['transport'] = {
          'type': 'ws',
          if (q['path'] != null) 'path': q['path'],
          if (q['host'] != null) 'headers': {'Host': q['host']},
          if (int.tryParse(q['maxEarlyData'] ?? '') != null)
            'max_early_data': int.parse(q['maxEarlyData']!),
          if (q['earlyDataHeaderName'] != null)
            'early_data_header_name': q['earlyDataHeaderName'],
        };
      if (p.network == 'grpc')
        outbound['transport'] = {
          'type': 'grpc',
          if (q['serviceName'] != null) 'service_name': q['serviceName']
        };
      if (p.network == 'http') {
        outbound['transport'] = {
          'type': 'http',
          if (q['path'] != null) 'path': q['path'],
          if (q['host'] != null) 'host': [q['host']],
          if (q['method'] != null) 'method': q['method'],
        };
      }
      if (p.network == 'xhttp' || p.network == 'splithttp') {
        final headers = <String, String>{};
        final rawHeaders = q['headers'];
        if (rawHeaders != null) {
          try {
            final decoded = jsonDecode(rawHeaders);
            if (decoded is Map) {
              for (final entry in decoded.entries) {
                headers[entry.key.toString()] = entry.value.toString();
              }
            }
          } on FormatException {
            // Share links sometimes carry an opaque headers parameter.
          }
        }
        final clientHeaders = p.raw['_ghostboxHeaders'];
        if (clientHeaders is Map) {
          for (final entry in clientHeaders.entries) {
            headers.putIfAbsent(
                entry.key.toString(), () => entry.value.toString());
          }
        }
        headers.removeWhere((key, _) => key.toLowerCase() == 'host');
        outbound['transport'] = {
          'type': 'xhttp',
          'mode': q['mode'] ?? 'auto',
          'path': q['path'] ?? '/',
          if ((q['host'] ?? q['authority']) != null)
            'host': q['host'] ?? q['authority'],
          if (headers.isNotEmpty) 'headers': headers,
          if (q['xPaddingBytes'] != null) 'x_padding_bytes': q['xPaddingBytes'],
          if (q['noGrpcHeader'] == '1' || q['noGrpcHeader'] == 'true')
            'no_grpc_header': true,
        };
      }
      if (p.network == 'httpupgrade')
        outbound['transport'] = {
          'type': 'httpupgrade',
          if (q['path'] != null) 'path': q['path'],
          if (q['host'] != null) 'host': q['host'],
        };
      if (p.network == 'quic') outbound['transport'] = {'type': 'quic'};
      final blocked = settings.effectiveBlockedDomains;
      final routeDomains = (settings.routing == 'exclude'
              ? settings.directDomains
              : settings.proxyDomains)
          .where((value) => !CoreSettings.isIpRoute(value))
          .map(CoreSettings.routeSuffix)
          .toList();
      final routeIps = (settings.routing == 'exclude'
              ? settings.directDomains
              : settings.proxyDomains)
          .where(CoreSettings.isIpRoute)
          .map(CoreSettings.routeIp)
          .toList();
      final rawExclusions = p.raw['_tunExcludeAddresses'];
      final routeExclusions = rawExclusions is List
          ? rawExclusions.map((value) => value.toString()).toList()
          : <String>[];
      final rules = <Map<String, dynamic>>[
        if (blocked.isNotEmpty) {'domain_suffix': blocked, 'action': 'reject'},
        if (settings.routing == 'exclude' && routeDomains.isNotEmpty)
          {
            'domain_suffix': routeDomains,
            'action': 'route',
            'outbound': 'direct'
          },
        if (settings.routing == 'exclude' && routeIps.isNotEmpty)
          {'ip_cidr': routeIps, 'action': 'route', 'outbound': 'direct'},
        if (settings.routing == 'rules' && routeDomains.isNotEmpty)
          {
            'domain_suffix': routeDomains,
            'action': 'route',
            'outbound': 'proxy'
          },
        if (settings.routing == 'rules' && routeIps.isNotEmpty)
          {'ip_cidr': routeIps, 'action': 'route', 'outbound': 'proxy'},
      ];
      final dnsConfig = _singBoxDnsConfig();
      final hasSplitDnsDomains = (settings.routing == 'exclude'
              ? settings.directDomains
              : settings.proxyDomains)
          .any((value) => !CoreSettings.isIpRoute(value));
      final defaultDnsDetour = hasSplitDnsDomains
          ? (settings.routing == 'rules' ? 'direct' : 'proxy')
          : (settings.dnsThroughProxy ? 'proxy' : 'direct');
      final defaultDnsTag =
          settings.dns == 'combined' ? 'cloudflare' : 'resolver';
      final defaultDnsResolverTag = hasSplitDnsDomains
          ? '$defaultDnsTag-$defaultDnsDetour'
          : defaultDnsTag;
      return {
        'log': {
          'level': settings.logLevel == 'warning' ? 'warn' : settings.logLevel
        },
        'dns': dnsConfig,
        'inbounds': [
          if (settings.connectionMode == 'tun' ||
              settings.connectionMode == 'mixed')
            {
              'type': 'tun',
              'tag': 'tun-in',
              'interface_name': 'ghostbox0',
              'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
              'mtu': 9000,
              'auto_route': true,
              'strict_route': true,
              if (routeExclusions.isNotEmpty)
                'route_exclude_address': routeExclusions,
            },
          if (p.raw['_tunBridge'] != true)
            {
              'type': 'mixed',
              'tag': 'local',
              'listen': '127.0.0.1',
              'listen_port': settings.localPort
            }
        ],
        'outbounds': [
          outbound,
          {'type': 'direct', 'tag': 'direct'}
        ],
        'route': {
          'default_domain_resolver': {'server': defaultDnsResolverTag},
          if (settings.connectionMode == 'tun' ||
              settings.connectionMode == 'mixed')
            'auto_detect_interface': true,
          'rules': [
            if (settings.connectionMode == 'tun' ||
                settings.connectionMode == 'mixed')
              {'protocol': 'dns', 'action': 'hijack-dns'},
            if ((settings.routing == 'rules' && routeDomains.isNotEmpty) ||
                (settings.routing == 'exclude' && routeDomains.isNotEmpty))
              {'action': 'sniff'},
            ...rules,
          ],
          'final': settings.routing == 'rules' ? 'direct' : 'proxy'
        }
      };
    }
    final stream = <String, dynamic>{
      'network': switch (p.network) {
        'raw' => 'tcp',
        'websocket' => 'ws',
        'splithttp' => 'xhttp',
        'mkcp' => 'kcp',
        _ => p.network,
      },
      'security': p.security ?? 'none'
    };
    if (p.security == 'tls') {
      stream['tlsSettings'] = {
        if ((q['sni'] ?? q['serverName']) != null)
          'serverName': q['sni'] ?? q['serverName'],
        if (q['fp'] != null) 'fingerprint': q['fp'],
        if (q['alpn'] != null)
          'alpn': q['alpn']!
              .split(',')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(),
        if (q['allowInsecure'] == '1' ||
            q['allowInsecure'] == 'true' ||
            q['insecure'] == '1')
          'allowInsecure': true,
      };
    }
    if (p.security == 'reality') {
      stream['realitySettings'] = {
        'serverName': q['sni'] ?? q['serverName'] ?? '',
        'publicKey': q['pbk'] ?? q['publicKey'],
        if ((q['sid'] ?? q['shortId']) != null)
          'shortId': q['sid'] ?? q['shortId'],
        if (q['fp'] != null) 'fingerprint': q['fp'],
      };
    }
    if (p.network == 'ws' || p.network == 'websocket')
      stream['wsSettings'] = {
        'path': q['path'] ?? '/',
        if (q['host'] != null) 'headers': {'Host': q['host']},
        if (int.tryParse(q['maxEarlyData'] ?? '') != null)
          'maxEarlyData': int.parse(q['maxEarlyData']!),
        if (q['earlyDataHeaderName'] != null)
          'earlyDataHeaderName': q['earlyDataHeaderName'],
      };
    if (p.network == 'grpc')
      stream['grpcSettings'] = {
        'serviceName': q['serviceName'] ?? '',
        if (q['authority'] != null) 'authority': q['authority'],
        if (q['mode'] == 'multi') 'multiMode': true,
      };
    if (p.network == 'xhttp' || p.network == 'splithttp') {
      final rawExtra = p.raw['extra'] ??
          (p.raw['xhttpSettings'] is Map
              ? (p.raw['xhttpSettings'] as Map)['extra']
              : null);
      dynamic decodedExtra;
      if (rawExtra is String && rawExtra.isNotEmpty) {
        try {
          decodedExtra = jsonDecode(rawExtra);
        } on FormatException {
          throw const FormatException('Параметр XHTTP extra должен быть JSON.');
        }
      } else if (rawExtra is Map || rawExtra is List) {
        decodedExtra = rawExtra;
      }
      if (settings.aggressiveXhttpCleanup) {
        final extra = decodedExtra is Map
            ? Map<String, dynamic>.from(decodedExtra)
            : <String, dynamic>{};
        final xmux = Map<String, dynamic>.from(
            extra['xmux'] as Map? ?? const <String, dynamic>{});
        // Low reuse/lifetime limits retire idle XHTTP sessions sooner. The
        // Xray schema forbids maxConnections alongside maxConcurrency.
        xmux
          ..remove('maxConnections')
          ..addAll({
            'maxConcurrency': '1-4',
            'cMaxReuseTimes': '8-16',
            'hMaxRequestTimes': '100-200',
            'hMaxReusableSecs': '60-120',
            'hKeepAlivePeriod': -1,
          });
        extra['xmux'] = xmux;
        decodedExtra = extra;
      }
      final headers = <String, String>{};
      final rawHeaders = q['headers'];
      if (rawHeaders != null) {
        try {
          final decoded = jsonDecode(rawHeaders);
          if (decoded is Map) {
            for (final entry in decoded.entries) {
              headers[entry.key.toString()] = entry.value.toString();
            }
          }
        } on FormatException {
          // Ignore opaque headers parameters; Xray expects a JSON object.
        }
      }
      final clientHeaders = p.raw['_ghostboxHeaders'];
      if (clientHeaders is Map) {
        for (final entry in clientHeaders.entries) {
          headers.putIfAbsent(
              entry.key.toString(), () => entry.value.toString());
        }
      }
      headers.removeWhere((key, _) => key.toLowerCase() == 'host');
      stream['xhttpSettings'] = {
        if (q['path'] != null) 'path': q['path'],
        if (q['host'] != null) 'host': q['host'],
        if (q['mode'] != null) 'mode': q['mode'],
        if (decodedExtra != null) 'extra': decodedExtra,
        if (headers.isNotEmpty) 'headers': headers,
      };
    }
    if (p.network == 'httpupgrade')
      stream['httpupgradeSettings'] = {
        if (q['path'] != null) 'path': q['path'],
        if (q['host'] != null) 'host': q['host'],
      };
    if (p.network == 'kcp' || p.network == 'mkcp') {
      stream['kcpSettings'] = {
        if (q['seed'] != null) 'seed': q['seed'],
        if (q['headerType'] != null) 'header': {'type': q['headerType']},
      };
    }
    if (p.network == 'quic') {
      stream['quicSettings'] = {
        if (q['key'] != null) 'key': q['key'],
        if (q['headerType'] != null) 'header': {'type': q['headerType']},
      };
    }
    final blocked = settings.effectiveBlockedDomains;
    final routeEntries = settings.routing == 'exclude'
        ? settings.directDomains
        : settings.proxyDomains;
    final routeDomains = routeEntries
        .where((value) => !CoreSettings.isIpRoute(value))
        .map(CoreSettings.routeSuffix)
        .toList();
    final routeIps = routeEntries
        .where(CoreSettings.isIpRoute)
        .map(CoreSettings.routeIp)
        .toList();
    final rules = <Map<String, dynamic>>[
      if (settings.connectionMode == 'tun' ||
          settings.connectionMode == 'mixed')
        {
          'type': 'field',
          'network': 'tcp,udp',
          'port': '53',
          'outboundTag': 'dns-out'
        },
      if (blocked.isNotEmpty)
        {
          'type': 'field',
          'domain': blocked.map((e) => 'domain:$e').toList(),
          'outboundTag': 'block'
        },
      if (settings.routing == 'exclude' && routeDomains.isNotEmpty)
        {
          'type': 'field',
          'domain': routeDomains.map((e) => 'domain:$e').toList(),
          'outboundTag': 'direct'
        },
      if (settings.routing == 'exclude' && routeIps.isNotEmpty)
        {'type': 'field', 'ip': routeIps, 'outboundTag': 'direct'},
      if (settings.routing == 'rules' && routeDomains.isNotEmpty)
        {
          'type': 'field',
          'domain': routeDomains.map((e) => 'domain:$e').toList(),
          'outboundTag': 'proxy'
        },
      if (settings.routing == 'rules' && routeIps.isNotEmpty)
        {'type': 'field', 'ip': routeIps, 'outboundTag': 'proxy'},
      {
        'type': 'field',
        'network': 'tcp,udp',
        'outboundTag': settings.routing == 'rules' ? 'direct' : 'proxy'
      },
    ];
    final dnsServers = _xrayDnsServers();
    return {
      'log': {'loglevel': settings.logLevel},
      'dns': {
        'servers': dnsServers,
        'queryStrategy': 'UseIP',
        if (blocked.isNotEmpty)
          'hosts': {for (final domain in blocked) domain: '0.0.0.0'}
      },
      'inbounds': [
        if (settings.connectionMode == 'tun' ||
            settings.connectionMode == 'mixed')
          {
            'tag': 'tun-in',
            'protocol': 'tun',
            'settings': {
              'name': 'ghostbox0',
              'mtu': 1500,
              'gateway': ['172.19.0.1/30', 'fc00::1/64'],
              'autoSystemRoutingTable': ['0.0.0.0/0', '::/0'],
              'autoOutboundsInterface': 'auto',
            },
            'sniffing': {
              'enabled': true,
              'destOverride': ['http', 'tls', 'quic'],
              // Use the sniffed SNI/Host for routing only. Replacing the
              // original destination can break TLS on CDN/virtual-host sites.
              'routeOnly': true,
            }
          },
        {
          'tag': 'local',
          'listen': '127.0.0.1',
          'port': settings.localPort,
          'protocol': 'socks',
          'settings': {'auth': 'noauth', 'udp': true},
          'sniffing': {
            'enabled': true,
            'destOverride': ['http', 'tls', 'quic'],
            'routeOnly': true,
          }
        }
      ],
      'outbounds': [
        {
          'tag': 'proxy',
          'protocol': p.protocol,
          'settings': p.protocol == 'vless' || p.protocol == 'vmess'
              ? {
                  'vnext': [
                    {
                      'address': p.address,
                      'port': p.port,
                      'users': [
                        {
                          'id': p.uuid ?? '',
                          if (p.protocol == 'vless')
                            'encryption': q['encryption'] ?? 'none',
                          if (p.protocol == 'vmess')
                            'security': q['scy'] ?? q['security'] ?? 'auto',
                          if (p.protocol == 'vmess')
                            'alterId':
                                int.tryParse(q['aid'] ?? q['alterId'] ?? '0') ??
                                    0,
                          if (q['flow'] != null) 'flow': q['flow'],
                          if (p.protocol == 'trojan')
                            'password': q['password'] ?? p.uuid,
                        }
                      ]
                    }
                  ]
                }
              : _xrayLegacySettings(p, q),
          'streamSettings': stream
        },
        {'tag': 'direct', 'protocol': 'freedom'},
        {'tag': 'block', 'protocol': 'blackhole'},
        if (settings.connectionMode == 'tun' ||
            settings.connectionMode == 'mixed')
          {'tag': 'dns-out', 'protocol': 'dns'},
      ],
      'routing': {
        'domainStrategy': routeIps.isNotEmpty ? 'IPIfNonMatch' : 'AsIs',
        'rules': rules,
      }
    };
  }

  Map<String, dynamic> _singBoxDnsConfig() {
    final splitEntries = settings.routing == 'exclude'
        ? settings.directDomains
        : settings.routing == 'rules'
            ? settings.proxyDomains
            : const <String>[];
    final splitDomains =
        splitEntries.where((value) => !CoreSettings.isIpRoute(value)).toList();
    final splitIsProxy = settings.routing == 'rules';
    final hasSplit = splitDomains.isNotEmpty;
    final defaultDetour = hasSplit
        ? (splitIsProxy ? 'direct' : 'proxy')
        : (settings.dnsThroughProxy ? 'proxy' : 'direct');
    final splitDetour = splitIsProxy ? 'proxy' : 'direct';
    String tag(String name, String detour) => hasSplit ? '$name-$detour' : name;

    final servers = <Map<String, dynamic>>[
      ..._singBoxDnsServers(
          detour: defaultDetour, suffix: hasSplit ? '-$defaultDetour' : ''),
      if (hasSplit)
        ..._singBoxDnsServers(detour: splitDetour, suffix: '-$splitDetour'),
    ];
    final dnsRules = <Map<String, dynamic>>[
      if (settings.effectiveBlockedDomains.isNotEmpty)
        {
          'domain_suffix': settings.effectiveBlockedDomains,
          'action': 'predefined',
          'rcode': 'NXDOMAIN'
        },
      if (hasSplit && settings.dns != 'combined')
        {
          'domain_suffix': splitDomains.map(CoreSettings.routeSuffix).toList(),
          'action': 'route',
          'server': tag('resolver', splitDetour),
        },
      if (settings.dns == 'combined' && hasSplit)
        {
          'domain_suffix': splitDomains.map(CoreSettings.routeSuffix).toList(),
          'query_type': [1],
          'action': 'route',
          'server': tag('cloudflare', splitDetour),
        },
      if (settings.dns == 'combined' && hasSplit)
        {
          'domain_suffix': splitDomains.map(CoreSettings.routeSuffix).toList(),
          'query_type': [28],
          'action': 'route',
          'server': tag('google', splitDetour),
        },
      if (settings.dns == 'combined')
        {
          'query_type': [1],
          'action': 'route',
          'server': tag('cloudflare', defaultDetour),
        },
      if (settings.dns == 'combined')
        {
          'query_type': [28],
          'action': 'route',
          'server': tag('google', defaultDetour),
        },
    ];
    return {
      'servers': servers,
      'final': settings.dns == 'combined'
          ? tag('cloudflare', defaultDetour)
          : tag('resolver', defaultDetour),
      if (dnsRules.isNotEmpty) 'rules': dnsRules,
    };
  }

  List<Map<String, dynamic>> _singBoxDnsServers(
      {required String detour, String suffix = ''}) {
    Map<String, dynamic> doh(String name, String server) => {
          'type': 'https',
          'tag': '$name$suffix',
          'server': server,
          'path': '/dns-query',
          if (detour != 'direct') 'detour': detour,
        };

    switch (settings.dns) {
      case 'system':
        return [
          <String, dynamic>{'type': 'local', 'tag': 'resolver$suffix'}
        ];
      case 'cloudflare':
        return [doh('resolver', '1.1.1.1')];
      case 'google':
        return [doh('resolver', '8.8.8.8')];
      case 'combined':
        return [doh('cloudflare', '1.1.1.1'), doh('google', '8.8.8.8')];
      case 'custom':
        return _customSingBoxDns(settings.customDnsResolver, detour,
            'resolver$suffix', 'bootstrap$suffix');
      default:
        return [
          <String, dynamic>{'type': 'local', 'tag': 'resolver$suffix'}
        ];
    }
  }

  List<Map<String, dynamic>> _customSingBoxDns(
      String value, String detour, String resolverTag, String bootstrapTag) {
    final input = value.trim();
    final bareIp = InternetAddress.tryParse(input);
    if (bareIp != null) {
      return [
        {
          'type': 'udp',
          'tag': resolverTag,
          'server': bareIp.address,
          'server_port': 53,
          if (detour != 'direct') 'detour': detour,
        }
      ];
    }
    final parsed = Uri.tryParse(input.contains('://') ? input : 'udp://$input');
    if (parsed == null || parsed.host.isEmpty) {
      throw const FormatException('Укажите IP или URL DNS-резолвера.');
    }
    final scheme = parsed.scheme.toLowerCase();
    final type = switch (scheme) {
      'https' => 'https',
      'tcp' => 'tcp',
      'udp' => 'udp',
      _ => throw const FormatException(
          'DNS поддерживает IP, udp://, tcp:// и https://.'),
    };
    final defaultPort = switch (type) {
      'https' => 443,
      _ => 53,
    };
    final ip = InternetAddress.tryParse(parsed.host);
    return [
      if (ip == null) <String, dynamic>{'type': 'local', 'tag': bootstrapTag},
      {
        'type': type,
        'tag': resolverTag,
        'server': parsed.host,
        'server_port': parsed.hasPort ? parsed.port : defaultPort,
        if (type == 'https')
          'path': parsed.path.isEmpty ? '/dns-query' : parsed.path,
        if (type == 'https' && ip == null) 'domain_resolver': bootstrapTag,
        if (detour != 'direct') 'detour': detour,
      }
    ];
  }

  List<String> _xrayDnsServers() {
    String route(String endpoint) {
      if (settings.dnsThroughProxy) return endpoint;
      if (endpoint.startsWith('https://')) {
        return endpoint.replaceFirst('https://', 'https+local://');
      }
      if (endpoint.startsWith('tcp://')) {
        return endpoint.replaceFirst('tcp://', 'tcp+local://');
      }
      return endpoint;
    }

    switch (settings.dns) {
      case 'cloudflare':
        return [route('https://1.1.1.1/dns-query')];
      case 'google':
        return [route('https://8.8.8.8/dns-query')];
      case 'combined':
        return [
          route('https://1.1.1.1/dns-query'),
          route('https://8.8.8.8/dns-query')
        ];
      case 'custom':
        final value = route(settings.customDnsResolver.trim());
        if (value.toLowerCase().startsWith('udp://')) {
          final uri = Uri.tryParse(value);
          if (uri != null && uri.host.isNotEmpty) {
            final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
            return ['$host:${uri.hasPort ? uri.port : 53}'];
          }
        }
        return [value];
      default:
        return ['localhost'];
    }
  }

  Map<String, dynamic> _xrayLegacySettings(
      ServerProfile p, Map<String, String?> q) {
    if (p.protocol == 'trojan') {
      return {
        'servers': [
          {
            'address': p.address,
            'port': p.port,
            'password': q['password'] ?? p.uuid ?? ''
          }
        ]
      };
    }
    if (p.protocol == 'shadowsocks') {
      return {
        'servers': [
          {
            'address': p.address,
            'port': p.port,
            'method': q['method'] ?? q['cipher'] ?? 'aes-128-gcm',
            'password': q['password'] ?? q['secret'] ?? p.uuid ?? '',
            if (q['uot'] == '1' || q['uot'] == 'true') 'uot': true,
          }
        ]
      };
    }
    if (p.protocol == 'socks' || p.protocol == 'http') {
      return {
        'servers': [
          {
            'address': p.address,
            'port': p.port,
            if ((q['username'] ?? q['user']) != null)
              'users': [
                {
                  'user': q['username'] ?? q['user'],
                  'pass': q['password'] ?? q['pass'] ?? ''
                }
              ],
          }
        ]
      };
    }
    return const {};
  }
}
