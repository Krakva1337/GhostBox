import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show kProfileMode, kReleaseMode, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoSwitch, CupertinoSlider;
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../backends/sing_box_backend.dart';
import '../../backends/xray_backend.dart';
import '../../backends/core_path.dart';
import '../../core/core_process.dart';
import '../../core/vpn_backend.dart';
import '../../models/server_profile.dart';
import '../../models/core_settings.dart';
import '../../models/subscription_metadata.dart';
import '../../platform/system_proxy.dart';
import '../../services/profile_parser.dart';
import '../../services/device_identity.dart';
import '../../services/dns_ad_blocklist.dart';
import '../../theme/theme_settings_panel.dart';
import '../../widgets/ghost_notice.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final homeScroll = ScrollController();
  final settingsScroll = ScrollController();
  final routingScroll = ScrollController();
  final routeListController = TextEditingController();
  bool refreshingSubscriptions = false;
  DateTime? lastRefresh;
  Timer? subscriptionRefreshTimer;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _subscriptionInfoSurface =>
      Color.alphaBlend(Colors.white.withValues(alpha: .035), _surface);
  Color get _accent => Theme.of(context).colorScheme.primary;
  Color get _line => Theme.of(context).colorScheme.outlineVariant;
  Color get _muted => Theme.of(context).colorScheme.onSurfaceVariant;
  Color get _mint => Color(0xFF77D6B0);
  late final AnimationController glow;
  bool powerHovered = false;
  VpnBackend backend = XrayBackend();
  CoreProcessBackend? tunnelBridgeBackend;
  bool xrayTunnelBridgeActive = false;
  int? activeLocalPort;
  SharedPreferences? prefs;
  List<ServerProfile> profiles = [];
  String? selectedId;
  bool settings = false, routingTab = false, advanced = false;
  int get _tabIndex => settings
      ? 2
      : routingTab
          ? 1
          : 0;
  CoreSettings coreSettings = CoreSettings();
  final DnsAdBlocklist dnsAdBlocklist = DnsAdBlocklist();
  bool loadingAdBlocklist = false;
  final DesktopSystemProxy systemProxy = DesktopSystemProxy();
  bool pendingReconnect = false;
  bool switchingServer = false;
  String? activeProfileId;
  String? connectionIssue;
  final List<String> appLogs = <String>[];
  final List<Map<String, dynamic>> connectionHistory = <Map<String, dynamic>>[];
  Future<void> _logWriteQueue = Future<void>.value();
  String? logFilePath;
  String? subscriptionUrl;
  List<String> subscriptionProfileIds = [];
  List<Map<String, dynamic>> subscriptions = [];
  bool hideProfiles = false;
  final Set<String> collapsedSubscriptions = <String>{};
  final Set<String> collapsedSubscriptionInfo = <String>{};
  bool routeListOpen = false;
  String? routeListMode;
  bool autoRefreshSubscriptions = true;
  int autoRefreshHours = 6;
  Timer? uptimeTicker;
  int? coreMemoryMb;
  bool readingCoreMemory = false;
  int? pingMs;
  List<int> pingSamples = [];
  final Map<String, int> profileLatencies = {};
  bool checkingPing = false;
  bool checkingAll = false;
  int pingAllDone = 0, pingAllTotal = 0;
  final Set<String> failedLatencies = {};
  int _probeGeneration = 0;
  CoreProcessBackend? get process =>
      backend is CoreProcessBackend ? backend as CoreProcessBackend : null;
  ServerProfile? get selected =>
      profiles.where((p) => p.id == selectedId).firstOrNull;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    glow = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2200));
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    if (Platform.isWindows) await systemProxy.restore();
    final saved = p.getString('profiles');
    final rows = saved == null
        ? <ServerProfile>[]
        : (jsonDecode(saved) as List)
            .map((e) =>
                ServerProfile.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
    if (!mounted) return;
    final migrateWindowsProxy =
        Platform.isWindows && p.getBool('windowsProxyDefaultMigrated') != true;
    setState(() {
      prefs = p;
      profiles = rows;
      final savedHistory = p.getString('connectionHistory');
      if (savedHistory != null) {
        try {
          connectionHistory
            ..clear()
            ..addAll((jsonDecode(savedHistory) as List)
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .take(10));
        } on Object {
          connectionHistory.clear();
        }
      }
      autoRefreshSubscriptions = p.getBool('autoRefreshSubscriptions') ?? true;
      final savedRefreshHours = p.getInt('autoRefreshHours') ?? 6;
      autoRefreshHours =
          [1, 6, 12, 24].contains(savedRefreshHours) ? savedRefreshHours : 6;
      selectedId = p.getString('selectedProfile') ?? rows.firstOrNull?.id;
      final rawCore = p.getString('coreSettings');
      coreSettings = rawCore == null
          ? CoreSettings(
              memoryMb: (p.getInt('memoryMb') ?? 128).clamp(64, 256),
              autoConnect: p.getBool('autoConnect') ?? false)
          : CoreSettings.fromJson(
              Map<String, dynamic>.from(jsonDecode(rawCore) as Map));
      if (p.getBool('xrayDefaultMigrated') != true) {
        coreSettings = coreSettings.copyWith(core: 'xray');
      }
      if (p.getBool('tunDefaultMigrated') != true) {
        coreSettings = coreSettings.copyWith(
            connectionMode: Platform.isWindows ? 'system' : 'tun');
      }
      if (migrateWindowsProxy) {
        coreSettings = coreSettings.copyWith(connectionMode: 'system');
      }
      backend = coreSettings.core == 'xray' ? XrayBackend() : SingBoxBackend();
      process?.settings = coreSettings;
      subscriptionUrl = p.getString('subscriptionUrl');
      subscriptionProfileIds = p.getStringList('subscriptionProfileIds') ?? [];
      final rawSubscriptions = p.getString('subscriptions');
      if (rawSubscriptions != null) {
        subscriptions = (jsonDecode(rawSubscriptions) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      } else if (subscriptionUrl != null) {
        subscriptions = [
          {'url': subscriptionUrl, 'ids': subscriptionProfileIds}
        ];
      }
    });
    if (p.getBool('xrayDefaultMigrated') != true ||
        p.getBool('tunDefaultMigrated') != true ||
        migrateWindowsProxy) {
      await p.setString('coreSettings', jsonEncode(coreSettings.toJson()));
      await p.setBool('xrayDefaultMigrated', true);
      await p.setBool('tunDefaultMigrated', true);
    }
    if (migrateWindowsProxy) {
      await p.setBool('windowsProxyDefaultMigrated', true);
    }
    if (p.getBool('proxyGetPingMigrated') != true) {
      if (coreSettings.pingMode == 'tcp') {
        coreSettings = coreSettings.copyWith(pingMode: 'proxy');
        await p.setString('coreSettings', jsonEncode(coreSettings.toJson()));
      }
      await p.setBool('proxyGetPingMigrated', true);
    }
    if (coreSettings.dnsBlacklistMode == 'ads') {
      final cachedDomains = await dnsAdBlocklist.readCache();
      if (mounted && cachedDomains.isNotEmpty) {
        setState(() {
          coreSettings = coreSettings.copyWith(adBlockDomains: cachedDomains);
          process?.settings = coreSettings;
        });
      }
      if (cachedDomains.isEmpty && coreSettings.autoConnect) {
        await _refreshAdBlocklist(silent: true);
      } else {
        unawaited(_refreshAdBlocklist(silent: true));
      }
    }
    _scheduleSubscriptionRefresh();
    if (autoRefreshSubscriptions) {
      unawaited(_refreshAllSubscriptions(quiet: true));
    }
    if (mounted &&
        coreSettings.autoConnect &&
        selected != null &&
        backend.state == VpnState.disconnected) {
      await _toggle();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        autoRefreshSubscriptions &&
        prefs != null &&
        (lastRefresh == null ||
            DateTime.now().difference(lastRefresh!).inHours >=
                autoRefreshHours)) {
      _refreshAllSubscriptions(quiet: true);
    }
  }

  void _scheduleSubscriptionRefresh() {
    subscriptionRefreshTimer?.cancel();
    if (!autoRefreshSubscriptions) return;
    subscriptionRefreshTimer = Timer.periodic(Duration(hours: autoRefreshHours),
        (_) => unawaited(_refreshAllSubscriptions(quiet: true)));
  }

  Future<void> _setAutoRefresh(bool enabled) async {
    setState(() => autoRefreshSubscriptions = enabled);
    final p = prefs ??= await SharedPreferences.getInstance();
    await p.setBool('autoRefreshSubscriptions', enabled);
    _scheduleSubscriptionRefresh();
    if (enabled) unawaited(_refreshAllSubscriptions(quiet: true));
  }

  Future<void> _setAutoRefreshHours(int hours) async {
    setState(() => autoRefreshHours = hours);
    final p = prefs ??= await SharedPreferences.getInstance();
    await p.setInt('autoRefreshHours', hours);
    _scheduleSubscriptionRefresh();
  }

  Future<void> _persist() async {
    final p = prefs ??= await SharedPreferences.getInstance();
    await p.setString(
        'profiles', jsonEncode(profiles.map((e) => e.toJson()).toList()));
    if (selectedId != null) {
      await p.setString('selectedProfile', selectedId!);
    } else {
      await p.remove('selectedProfile');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    GhostNotice.hide();
    homeScroll.dispose();
    settingsScroll.dispose();
    routingScroll.dispose();
    routeListController.dispose();
    subscriptionRefreshTimer?.cancel();
    uptimeTicker?.cancel();
    glow.dispose();
    unawaited(_disconnectActive());
    super.dispose();
  }

  Future<void> _toggle({bool allowDuringSwitch = false}) async {
    if (backend.state == VpnState.connecting ||
        (switchingServer && !allowDuringSwitch)) return;
    if (backend.state == VpnState.connected) {
      _recordAppLog('Отключено');
      glow.stop();
      await _disconnectActive();
      activeProfileId = null;
      pendingReconnect = false;
    } else if (selected != null) {
      final attemptProfile = selected!;
      final attemptStarted = DateTime.now();
      final attemptCore = coreSettings.core;
      final attemptMode = coreSettings.connectionMode;
      glow
        ..stop()
        ..value = 0;
      try {
        connectionIssue = null;
        final runtimeLocalPort = await _chooseLocalPort();
        activeLocalPort = runtimeLocalPort;
        if (coreSettings.autoLocalPort) {
          _recordAppLog(
              'Автоматически выбран локальный порт $runtimeLocalPort');
        }
        if ((coreSettings.connectionMode == 'tun' ||
                coreSettings.connectionMode == 'mixed') &&
            Platform.isLinux &&
            !File('/dev/net/tun').existsSync()) {
          throw const FormatException(
              'В системе не найден /dev/net/tun. Проверьте, что модуль TUN включён и устройство создано. Права на файл ядра это устройство не заменяют.');
        }
        _recordAppLog(
            'Подключение: ${attemptProfile.name} · $attemptCore · $attemptMode');
        _recordAppLog(
            'Профиль: ${attemptProfile.protocol}/${attemptProfile.network}${attemptProfile.security == null ? '' : ' · ${attemptProfile.security}'}');
        final runtimeRouting = await _expandSplitRouteIps(coreSettings);
        final usesXrayTunnelBridge = Platform.isLinux &&
            attemptCore == 'xray' &&
            (attemptMode == 'tun' || attemptMode == 'mixed');
        var runtimeProfile = attemptProfile;
        if (usesXrayTunnelBridge) {
          runtimeProfile = await _resolveXrayTunnelProfile(attemptProfile);
          process?.settings = runtimeRouting.copyWith(
              connectionMode: 'proxy', localPort: runtimeLocalPort);
          _recordAppLog(
              'TUN запускается через sing-box маршрутизатор и Xray upstream');
        } else {
          process?.settings =
              runtimeRouting.copyWith(localPort: runtimeLocalPort);
        }
        runtimeProfile = await _withDeviceMetadata(runtimeProfile);
        final activeCore = process;
        if (activeCore != null) _bindCoreRecoveryNotices(activeCore);
        final connection = backend.connect(jsonEncode(runtimeProfile.toJson()));
        if (mounted) setState(() {});
        await connection;
        _recordAppLog(
            'Процесс ядра запущен; проверяю маршрут и доступность сервера');
        if (usesXrayTunnelBridge) {
          await _startXrayTunnelBridge(runtimeProfile, runtimeRouting);
          xrayTunnelBridgeActive = true;
          _recordAppLog('Системный TUN-маршрут активен через sing-box');
        }
        if (coreSettings.connectionMode == 'tun' ||
            coreSettings.connectionMode == 'mixed') {
          await _waitForTunInterface();
          _recordAppLog('TUN-интерфейс ghostbox0 поднят');
          await _verifyTunRoute('1.1.1.1');
          await _tunHttpsGet(
              Duration(seconds: coreSettings.pingTimeoutSeconds + 2));
          _recordAppLog('HTTPS и TLS-проверка системного маршрута TUN прошла');
        }
        final hasSystemTunnel = coreSettings.connectionMode == 'tun' ||
            coreSettings.connectionMode == 'mixed';
        if (coreSettings.routing != 'direct' && !hasSystemTunnel) {
          await _proxyHttpGet(coreSettings.localPort,
              Duration(seconds: coreSettings.pingTimeoutSeconds + 2));
          _recordAppLog('Проверка HTTPS/TLS через прокси прошла');
        }
        if (coreSettings.connectionMode == 'system') {
          await systemProxy.enable(runtimeLocalPort);
        }
        activeProfileId = attemptProfile.id;
        pendingReconnect = false;
        _recordAppLog(
            'Подключено к ${attemptProfile.name} · $attemptCore · $attemptMode');
        connectionIssue = null;
        await _saveConnectionAttempt(
            profile: attemptProfile.name,
            core: attemptCore,
            mode: attemptMode,
            started: attemptStarted,
            success: true,
            message: 'Подключение установлено');
      } catch (e) {
        _recordAppLog('Диагностика подключения: $e');
        final message = _connectionError(e);
        _recordAppLog('Ошибка подключения: $message');
        await _disconnectActive();
        activeProfileId = null;
        connectionIssue = message;
        await _saveConnectionAttempt(
            profile: attemptProfile.name,
            core: attemptCore,
            mode: attemptMode,
            started: attemptStarted,
            success: false,
            message: message);
        if (mounted) {
          setState(() {});
          _message(message);
        }
      }
    } else if (mounted) {
      _message('Сначала добавьте и выберите сервер');
    }
    if (mounted) setState(() {});
    uptimeTicker?.cancel();
    if (backend.state == VpnState.connected) {
      if (!glow.isAnimating) glow.forward(from: 0);
      uptimeTicker = Timer.periodic(Duration(seconds: 1), (_) {
        if (!mounted) return;
        if ((backend.state == VpnState.error ||
                backend.state == VpnState.disconnected) &&
            activeProfileId != null &&
            !switchingServer) {
          activeProfileId = null;
          glow.stop();
          connectionIssue ??= process?.lastError ??
              'Ядро завершилось после автоматических попыток перезапуска';
          unawaited(_disconnectActive());
          uptimeTicker?.cancel();
        }
        if (xrayTunnelBridgeActive &&
            tunnelBridgeBackend?.state == VpnState.error &&
            activeProfileId != null) {
          connectionIssue = tunnelBridgeBackend?.lastError ??
              'TUN-маршрутизатор sing-box остановился';
          _recordAppLog('Потеряно соединение: $connectionIssue');
          activeProfileId = null;
          glow.stop();
          unawaited(_disconnectActive());
          uptimeTicker?.cancel();
        }
        if (coreSettings.showRamUsage) unawaited(_refreshCoreMemoryUsage());
        setState(() {});
      });
    } else {
      glow.stop();
    }
  }

  void _recordAppLog(String message) {
    final timestamp =
        DateTime.now().toLocal().toIso8601String().replaceFirst('T', ' ');
    final line = '$timestamp  $message';
    appLogs.add(line);
    if (appLogs.length > 100) appLogs.removeAt(0);
    _logWriteQueue = _logWriteQueue.then((_) async {
      try {
        final file = await _resolveLogFile();
        if (await file.exists() && await file.length() > 512 * 1024) {
          final old = await file.readAsString();
          final keepFrom =
              old.length > 256 * 1024 ? old.length - 256 * 1024 : 0;
          await file.writeAsString(old.substring(keepFrom), flush: true);
        }
        await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
      } on Object {
        // Keep the in-app journal available even if the OS denies file access.
      }
    });
  }

  Future<File> _resolveLogFile() async {
    final env = Platform.environment;
    final separator = Platform.pathSeparator;
    String? base;
    if (Platform.isLinux) {
      base = env['XDG_STATE_HOME'];
      if (base == null || base.isEmpty) {
        final home = env['HOME'];
        if (home != null && home.isNotEmpty)
          base = '$home${separator}.local${separator}state';
      }
    } else if (Platform.isWindows) {
      base = env['APPDATA'];
      if (base == null || base.isEmpty) {
        final home = env['USERPROFILE'];
        if (home != null && home.isNotEmpty)
          base = '$home${separator}AppData${separator}Roaming';
      }
    } else {
      base = env['HOME'];
    }
    base ??= Directory.systemTemp.path;
    final directory = Directory('$base${separator}GhostBox${separator}logs');
    await directory.create(recursive: true);
    final file = File('${directory.path}${separator}ghostbox.log');
    logFilePath = file.path;
    return file;
  }

  Future<void> _saveConnectionAttempt({
    required String profile,
    required String core,
    required String mode,
    required DateTime started,
    required bool success,
    required String message,
  }) async {
    connectionHistory.insert(0, {
      'at': started.toIso8601String(),
      'profile': profile,
      'core': core,
      'mode': mode,
      'success': success,
      'durationMs': DateTime.now().difference(started).inMilliseconds,
      'message': message,
    });
    if (connectionHistory.length > 10) {
      connectionHistory.removeRange(10, connectionHistory.length);
    }
    final p = prefs ??= await SharedPreferences.getInstance();
    await p.setString('connectionHistory', jsonEncode(connectionHistory));
  }

  Future<void> _showLogs() async {
    await _logWriteQueue;
    final core = process;
    await core?.flushLogs();
    await tunnelBridgeBackend?.flushLogs();
    final file = await _resolveLogFile();
    final fileLines =
        await file.exists() ? await file.readAsLines() : <String>[];
    final firstVisibleLine =
        (fileLines.length - 500).clamp(0, fileLines.length);
    var entries = <String>[...fileLines.skip(firstVisibleLine)];
    if (!mounted) return;
    showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => StatefulBuilder(
            builder: (context, setSheetState) => DraggableScrollableSheet(
                initialChildSize: .78,
                minChildSize: .45,
                maxChildSize: .94,
                expand: false,
                builder: (context, scrollController) => Container(
                    decoration: BoxDecoration(
                        color: _surface,
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(26)),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: .12))),
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
                    child: Column(children: [
                      Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: .24),
                              borderRadius: BorderRadius.circular(8))),
                      const SizedBox(height: 12),
                      Row(children: [
                        const Expanded(
                            child: Text('Журнал соединения',
                                style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700))),
                        IconButton(
                            tooltip: 'Скопировать журнал',
                            onPressed: () => Clipboard.setData(
                                ClipboardData(text: entries.join('\n'))),
                            icon: const Icon(Icons.copy)),
                        IconButton(
                            tooltip: 'Очистить журнал',
                            onPressed: () async {
                              await _logWriteQueue;
                              await core?.flushLogs();
                              await tunnelBridgeBackend?.flushLogs();
                              await file.writeAsString('', flush: true);
                              appLogs.clear();
                              core?.clearLogBuffer();
                              tunnelBridgeBackend?.clearLogBuffer();
                              setSheetState(() => entries = <String>[]);
                            },
                            icon: const Icon(Icons.delete_sweep_outlined)),
                        IconButton(
                            tooltip: 'Закрыть',
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close)),
                      ]),
                      Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                              '${logFilePath ?? file.path}\n${core?.name ?? coreSettings.core} · ${backend.state.name} · ${core?.executable ?? 'ядро не выбрано'}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: _muted, fontSize: 11))),
                      const SizedBox(height: 10),
                      Expanded(
                          child: entries.isEmpty
                              ? Center(
                                  child: Text('Записей пока нет',
                                      style: TextStyle(color: _muted)))
                              : ListView.separated(
                                  controller: scrollController,
                                  itemCount: entries.length,
                                  separatorBuilder: (_, __) => Divider(
                                      height: 1,
                                      color:
                                          Colors.white.withValues(alpha: .07)),
                                  itemBuilder: (context, index) => Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 8),
                                      child: SelectableText(entries[index],
                                          style: TextStyle(
                                              fontFamily: 'monospace',
                                              fontSize: 11,
                                              height: 1.4,
                                              color: entries[index]
                                                      .toLowerCase()
                                                      .contains('ошибка')
                                                  ? Colors.orangeAccent
                                                  : _muted))))),
                    ])))));
  }

  void _showConnectionHistory() {
    final history = List<Map<String, dynamic>>.of(connectionHistory);
    showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => DraggableScrollableSheet(
            initialChildSize: .68,
            minChildSize: .4,
            maxChildSize: .9,
            expand: false,
            builder: (context, scrollController) => Container(
                decoration: BoxDecoration(
                    color: _surface,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(26)),
                    border:
                        Border.all(color: Colors.white.withValues(alpha: .12))),
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
                child: Column(children: [
                  Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .24),
                          borderRadius: BorderRadius.circular(8))),
                  const SizedBox(height: 12),
                  Row(children: [
                    const Expanded(
                        child: Text('Последние подключения',
                            style: TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w700))),
                    Text('${history.length}/10',
                        style: TextStyle(color: _muted, fontSize: 12)),
                    IconButton(
                        tooltip: 'Закрыть',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close)),
                  ]),
                  Expanded(
                      child: history.isEmpty
                          ? Center(
                              child: Text('Попыток подключения пока нет',
                                  style: TextStyle(color: _muted)))
                          : ListView.separated(
                              controller: scrollController,
                              itemCount: history.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                final item = history[index];
                                final success = item['success'] == true;
                                final date =
                                    DateTime.tryParse('${item['at'] ?? ''}')
                                        ?.toLocal();
                                final dateText = date == null
                                    ? 'Время неизвестно'
                                    : '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year} · ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
                                return Container(
                                    padding: const EdgeInsets.all(13),
                                    decoration: BoxDecoration(
                                        color: Colors.white
                                            .withValues(alpha: .045),
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(
                                            color: Colors.white
                                                .withValues(alpha: .08))),
                                    child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Icon(
                                              success
                                                  ? Icons.check_circle_rounded
                                                  : Icons.error_outline_rounded,
                                              color: success
                                                  ? _mint
                                                  : Colors.orangeAccent,
                                              size: 19),
                                          const SizedBox(width: 10),
                                          Expanded(
                                              child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                Text(
                                                    '${item['profile'] ?? 'Сервер'}',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.w600)),
                                                const SizedBox(height: 3),
                                                Text(
                                                    '$dateText · ${item['core'] ?? ''} · ${item['mode'] ?? ''} · ${item['durationMs'] ?? 0} мс',
                                                    style: TextStyle(
                                                        color: _muted,
                                                        fontSize: 10)),
                                                const SizedBox(height: 4),
                                                Text('${item['message'] ?? ''}',
                                                    maxLines: 3,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                        color: success
                                                            ? _mint
                                                            : _muted,
                                                        fontSize: 11)),
                                              ]))
                                        ]));
                              })),
                ]))));
  }

  Future<void> _waitForTunInterface() async {
    if (!Platform.isLinux) return;
    final tun = Directory('/sys/class/net/ghostbox0');
    for (var attempt = 0; attempt < 60; attempt++) {
      if (await tun.exists()) return;
      if (process?.state != VpnState.connected) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final vendorDir = Platform.environment['GHOSTBOX_VENDOR_DIR'];
    final tunCore = coreSettings.core == 'xray' &&
            (coreSettings.connectionMode == 'tun' ||
                coreSettings.connectionMode == 'mixed')
        ? 'sing-box'
        : coreSettings.core;
    final permissionHint = vendorDir == null || vendorDir.isEmpty
        ? 'Нужны права CAP_NET_ADMIN для $tunCore.'
        : 'Выдайте CAP_NET_ADMIN файлу "$vendorDir/bin/$tunCore".';
    throw FormatException('Ядро не подняло TUN-интерфейс. $permissionHint');
  }

  Future<List<InternetAddress>> _lookupHost(String host) async {
    final literal = InternetAddress.tryParse(host.trim());
    if (literal != null) return [literal];
    final addresses = <InternetAddress>[];
    for (final type in [InternetAddressType.IPv4, InternetAddressType.IPv6]) {
      try {
        addresses.addAll(await InternetAddress.lookup(host, type: type)
            .timeout(const Duration(seconds: 6)));
      } on Object {
        // A host may publish only A or only AAAA records.
      }
    }
    return addresses;
  }

  Future<int> _chooseLocalPort() async {
    try {
      final reservation = await ServerSocket.bind(InternetAddress.loopbackIPv4,
          coreSettings.autoLocalPort ? 0 : coreSettings.localPort);
      final port = reservation.port;
      await reservation.close();
      return port;
    } on SocketException catch (error) {
      if (coreSettings.autoLocalPort) rethrow;
      throw FormatException(
          'Локальный порт ${coreSettings.localPort} уже занят. Включите автовыбор или задайте другой порт. ($error)');
    }
  }

  Future<ServerProfile> _resolveXrayTunnelProfile(ServerProfile profile) async {
    final addresses = await _lookupHost(profile.address);
    if (addresses.isEmpty) {
      throw FormatException(
          'Не удалось разрешить адрес сервера ${profile.address} до включения TUN. Проверьте DNS или выберите Proxy.');
    }
    final ipv4 =
        addresses.where((address) => address.type == InternetAddressType.IPv4);
    final outboundAddress =
        ipv4.isNotEmpty ? ipv4.first.address : addresses.first.address;
    final exclusions = addresses
        .map((address) =>
            '${address.address}/${address.type == InternetAddressType.IPv4 ? 32 : 128}')
        .toSet()
        .toList();
    return ServerProfile(
      id: profile.id,
      name: profile.name,
      protocol: profile.protocol,
      address: outboundAddress,
      port: profile.port,
      uuid: profile.uuid,
      network: profile.network,
      security: profile.security,
      raw: {
        ...profile.raw,
        '_tunExcludeAddresses': exclusions,
      },
    );
  }

  Future<CoreSettings> _expandSplitRouteIps(CoreSettings settings) async {
    if (settings.routing != 'rules' && settings.routing != 'exclude') {
      return settings;
    }
    final entries = settings.routing == 'exclude'
        ? settings.directDomains
        : settings.proxyDomains;
    final hostnames = entries
        .where((entry) =>
            !CoreSettings.isIpRoute(entry) && !entry.startsWith('*.'))
        .toSet()
        .take(64)
        .toList();
    if (hostnames.isEmpty) return settings;

    Future<List<InternetAddress>> lookup(String hostname) async {
      try {
        return await InternetAddress.lookup(hostname)
            .timeout(const Duration(seconds: 4));
      } on Object {
        return const <InternetAddress>[];
      }
    }

    final resolved = await Future.wait(hostnames.map(lookup));
    final addresses = resolved
        .expand((result) => result)
        .map((address) => address.address.toLowerCase())
        .toSet();
    _recordAppLog(
        'Split routing: разрешено доменов ${hostnames.length}, получено IP ${addresses.length}; IP-маршруты будут обновлены на это подключение');
    if (addresses.isEmpty) return settings;

    final merged = {...entries, ...addresses}.toList();
    return settings.routing == 'exclude'
        ? settings.copyWith(directDomains: merged)
        : settings.copyWith(proxyDomains: merged);
  }

  Future<void> _startXrayTunnelBridge(
      ServerProfile profile, CoreSettings routingSettings) async {
    final reservation =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final bridgePort = reservation.port;
    await reservation.close();
    final bridgeProfile = ServerProfile(
      id: 'ghostbox-xray-tun-bridge',
      name: 'GhostBox TUN bridge',
      protocol: 'socks',
      address: '127.0.0.1',
      port: activeLocalPort ?? coreSettings.localPort,
      raw: {
        '_tunBridge': true,
        '_tunExcludeAddresses': profile.raw['_tunExcludeAddresses'] ?? const [],
      },
    );
    final bridge = CoreProcessBackend(
      name: 'sing-box',
      executable: coreExecutable('sing-box', 'vendor'),
      configPath: 'vendor/config/sing-box-tun-bridge.json',
    )..settings = routingSettings.copyWith(
        core: 'sing-box',
        connectionMode: coreSettings.connectionMode,
        localPort: bridgePort,
      );
    _bindCoreRecoveryNotices(bridge);
    tunnelBridgeBackend = bridge;
    await bridge.connect(jsonEncode(bridgeProfile.toJson()));
  }

  Future<void> _verifyTunRoute(String probeIp) async {
    if (!Platform.isLinux) return;
    final result = await Process.run('ip', ['route', 'get', probeIp])
        .timeout(const Duration(seconds: 4));
    if (result.exitCode != 0) {
      throw FormatException(
          'Не удалось проверить маршрут TUN: ${result.stderr.toString().trim()}');
    }
    if (!result.stdout.toString().contains('dev ghostbox0')) {
      throw const FormatException(
          'Интерфейс TUN запущен, но системный маршрут не ведёт через ghostbox0. Трафик пока не защищён.');
    }
  }

  Future<void> _tunHttpsGet(Duration timeout) async {
    final failures = <String>[];
    for (final probe in const [
      ('connectivitycheck.gstatic.com', '/generate_204'),
      ('cp.cloudflare.com', '/generate_204'),
      ('www.google.com', '/generate_204'),
    ]) {
      final client = HttpClient()
        ..connectionTimeout = timeout
        ..idleTimeout = timeout;
      try {
        final request =
            await client.getUrl(Uri.https(probe.$1, probe.$2)).timeout(timeout);
        request.followRedirects = true;
        request.headers.set(HttpHeaders.connectionHeader, 'close');
        final response = await request.close().timeout(timeout);
        await response.drain<void>().timeout(timeout);
        if (response.statusCode < 200 || response.statusCode >= 400) {
          throw HttpException('HTTP ${response.statusCode}');
        }
        return;
      } on Object catch (error) {
        failures.add('${probe.$1}: $error');
      } finally {
        client.close(force: true);
      }
    }
    throw SocketException(
        'HTTPS/TLS через системный TUN не прошёл: ${failures.join(' | ')}');
  }

  String _connectionError(Object error) {
    if (error is FormatException) return error.message;
    if (error is SocketException &&
        (error.message.contains('HTTPS/TLS') ||
            error.message.contains('HTTPS '))) {
      return 'Ядро запущено, но HTTPS-проверка не прошла: ${error.message}';
    }
    if (error is SocketException || error is TimeoutException) {
      return 'Ядро запущено, но сервер не ответил через прокси. Проверьте сервер и доступ к интернету.';
    }
    return 'Не удалось включить подключение: $error';
  }

  Future<void> _disconnectActive() async {
    final bridge = tunnelBridgeBackend;
    tunnelBridgeBackend = null;
    xrayTunnelBridgeActive = false;
    if (bridge != null) await bridge.disconnect();
    await backend.disconnect();
    await systemProxy.restore();
    activeLocalPort = null;
  }

  Future<void> _switchActiveServer() async {
    final target = selected;
    if (switchingServer ||
        backend.state != VpnState.connected ||
        target == null ||
        activeProfileId == target.id) return;
    switchingServer = true;
    pendingReconnect = false;
    connectionIssue = null;
    _recordAppLog('Переключаю сервер на ${target.name}');
    if (mounted) setState(() {});
    try {
      await _disconnectActive();
      activeProfileId = null;
      // The VPN remains active from the user's perspective and reconnects
      // automatically. TUN has a brief traffic pause while its single
      // interface is handed from the old core to the new one.
      if (mounted) setState(() {});
      await _toggle(allowDuringSwitch: true);
    } finally {
      switchingServer = false;
      pendingReconnect = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _setConnectionMode(String mode) async {
    final reconnect = backend.state == VpnState.connected;
    if (backend.state == VpnState.connecting) {
      _message('Подождите завершения подключения');
      return;
    }
    if (reconnect) await _disconnectActive();
    final nextCore = coreSettings.core;
    final next = coreSettings.copyWith(connectionMode: mode, core: nextCore);
    await _saveCore(next);
    if (nextCore != (process?.name ?? coreSettings.core) ||
        backend is! CoreProcessBackend ||
        process?.name != nextCore) {
      setState(() {
        backend = nextCore == 'xray' ? XrayBackend() : SingBoxBackend();
      });
    }
    process?.settings = coreSettings;
    if (reconnect && selected != null) await _toggle();
  }

  Future<List<int>> _probeProfile(ServerProfile profile) async {
    final mode = coreSettings.pingMode;
    final count = coreSettings.pingCount;
    final timeoutSeconds = coreSettings.pingTimeoutSeconds;
    final timeout = Duration(seconds: timeoutSeconds);
    final samples = <int>[];
    CoreProcessBackend? probeBackend;
    var proxyPort = coreSettings.localPort;
    if (mode == 'proxy' &&
        !(backend.state == VpnState.connected &&
            activeProfileId == profile.id &&
            coreSettings.routing != 'direct')) {
      final reservation =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      proxyPort = reservation.port;
      await reservation.close();
      final coreName = coreSettings.core == 'xray' ? 'xray' : 'sing-box';
      probeBackend = CoreProcessBackend(
        name: coreName,
        executable: process?.executable ?? coreExecutable(coreName, 'vendor'),
        configPath: 'vendor/config/$coreName.json',
      )..settings =
          coreSettings.copyWith(localPort: proxyPort, routing: 'proxy');
      await probeBackend.connect(jsonEncode(profile.toJson()));
    }
    try {
      for (var i = 0; i < count; i++) {
        if (mode == 'proxy') {
          final watch = Stopwatch()..start();
          await _proxyHttpGet(proxyPort, timeout);
          watch.stop();
          samples.add(watch.elapsedMilliseconds);
        } else if (mode == 'icmp') {
          final result = await Process.run('ping', [
            '-n',
            '-c',
            '1',
            '-W',
            '$timeoutSeconds',
            profile.address
          ]).timeout(timeout + Duration(seconds: 2));
          if (result.exitCode != 0) throw SocketException('Нет ответа ICMP');
          final match = RegExp(r'time[=<]([0-9]+(?:[.,][0-9]+)?)')
              .firstMatch('${result.stdout}');
          if (match == null)
            throw FormatException('В ответе ping нет задержки');
          samples
              .add(double.parse(match.group(1)!.replaceAll(',', '.')).round());
        } else {
          final watch = Stopwatch()..start();
          final socket = await Socket.connect(profile.address, profile.port,
              timeout: timeout);
          socket.destroy();
          watch.stop();
          samples.add(watch.elapsedMilliseconds);
        }
      }
      samples.sort();
      return samples;
    } finally {
      await probeBackend?.disconnect();
    }
  }

  Future<void> _proxyHttpGet(int localPort, Duration timeout) async {
    final uri = Uri.tryParse(coreSettings.proxyGetUrl.trim());
    if (uri == null ||
        !const ['https', 'http'].contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty) {
      throw const FormatException('Некорректная ссылка Proxy GET');
    }
    try {
      await _proxyHttpGetFrom(localPort, timeout, uri);
    } on Object catch (error) {
      throw SocketException('Проверка через прокси не прошла: $error');
    }
  }

  Future<void> _proxyHttpGetFrom(
      int localPort, Duration timeout, Uri uri) async {
    Socket? socket;
    SecureSocket? tlsSocket;
    _SocketByteReader? reader;
    try {
      final host = uri.host;
      final secure = uri.scheme.toLowerCase() == 'https';
      final port = uri.hasPort ? uri.port : (secure ? 443 : 80);
      socket = await Socket.connect(InternetAddress.loopbackIPv4, localPort,
          timeout: timeout);
      reader = _SocketByteReader(socket);
      socket.add(const [5, 1, 0]);
      await socket.flush();
      final greeting = await reader.read(2).timeout(timeout);
      if (greeting[0] != 5 || greeting[1] != 0) {
        throw const SocketException('SOCKS5 proxy is not ready');
      }

      final domain = utf8.encode(host);
      socket
          .add([5, 1, 0, 3, domain.length, ...domain, port >> 8, port & 0xff]);
      await socket.flush();
      final response = await reader.read(4).timeout(timeout);
      if (response[0] != 5 || response[1] != 0) {
        throw const SocketException('SOCKS5 server rejected the route');
      }
      final addressLength = switch (response[3]) {
        1 => 4,
        4 => 16,
        3 => (await reader.read(1).timeout(timeout))[0],
        _ => throw const SocketException('Invalid SOCKS5 response'),
      };
      await reader.read(addressLength + 2).timeout(timeout);

      await reader.close();
      reader = null;
      Socket requestSocket = socket;
      if (secure) {
        tlsSocket =
            await SecureSocket.secure(socket, host: host).timeout(timeout);
        requestSocket = tlsSocket;
      }
      reader = _SocketByteReader(requestSocket);
      final path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
      final hostHeader = port == (secure ? 443 : 80) ? host : '$host:$port';
      requestSocket.add(utf8.encode(
          'GET ${path.isEmpty ? '/' : path} HTTP/1.1\r\nHost: $hostHeader\r\nUser-Agent: GhostBox-Alpha-v0.1\r\nConnection: close\r\n\r\n'));
      await requestSocket.flush();
      final statusLine = await reader.readLine(256).timeout(timeout);
      if (!RegExp(r'^HTTP/1\.[01] [1-5]\d\d(?: |$)').hasMatch(statusLine)) {
        throw SocketException('$host replied: $statusLine');
      }
    } on Object catch (error) {
      throw SocketException('HTTP GET ${uri.host} failed: $error');
    } finally {
      await reader?.close();
      tlsSocket?.destroy();
      socket?.destroy();
    }
  }

  Future<void> _checkConnection() async {
    final profile = selected;
    if (profile == null) {
      _message('Сначала выберите сервер');
      return;
    }
    if (checkingPing) return;
    final generation = ++_probeGeneration;
    setState(() {
      checkingPing = true;
      pingMs = null;
      pingSamples = [];
    });
    try {
      final samples = await _probeProfile(profile);
      if (mounted && generation == _probeGeneration)
        setState(() {
          pingSamples = samples;
          pingMs = samples[samples.length ~/ 2];
          profileLatencies[profile.id] = pingMs!;
          failedLatencies.remove(profile.id);
        });
    } catch (_) {
      if (mounted && generation == _probeGeneration) {
        setState(() {
          failedLatencies.add(profile.id);
          profileLatencies.remove(profile.id);
        });
        _message(coreSettings.pingMode == 'icmp'
            ? 'ICMP не ответил. Попробуйте TCP в настройках.'
            : 'Сервер не отвечает на выбранном порту.');
      }
    } finally {
      if (mounted && generation == _probeGeneration)
        setState(() => checkingPing = false);
    }
  }

  Future<void> _checkOneProfile(ServerProfile profile) async {
    try {
      final samples = await _probeProfile(profile);
      if (!mounted) return;
      final latency = samples[samples.length ~/ 2];
      setState(() {
        profileLatencies[profile.id] = latency;
        failedLatencies.remove(profile.id);
        if (selectedId == profile.id) {
          pingMs = latency;
          pingSamples = samples;
        }
      });
      _message('${profile.name}: $latency мс');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        profileLatencies.remove(profile.id);
        failedLatencies.add(profile.id);
      });
      _message('${profile.name}: нет ответа');
    }
  }

  Future<void> _checkAllProfiles(List<ServerProfile> targets) async {
    if (checkingAll || targets.isEmpty) {
      if (targets.isEmpty) _message('Нет серверов для проверки');
      return;
    }
    setState(() {
      checkingAll = true;
      pingAllDone = 0;
      pingAllTotal = targets.length;
    });
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < targets.length) {
        final profile = targets[cursor++];
        int? latency;
        try {
          final samples = await _probeProfile(profile);
          latency = samples[samples.length ~/ 2];
        } catch (_) {/* Per-server failure stays visible as a dash. */}
        if (!mounted) return;
        setState(() {
          if (latency == null) {
            failedLatencies.add(profile.id);
            profileLatencies.remove(profile.id);
          } else {
            failedLatencies.remove(profile.id);
            profileLatencies[profile.id] = latency;
            if (selectedId == profile.id) pingMs = latency;
          }
          pingAllDone++;
        });
      }
    }

    await Future.wait(List.generate(
        targets.length < 4 ? targets.length : 4, (_) => worker()));
    if (mounted) {
      setState(() => checkingAll = false);
      _message('Проверено серверов: $pingAllDone из $pingAllTotal');
    }
  }

  String _pingQuality(int value) {
    if (value < 90) return 'Отлично';
    if (value < 180) return 'Хорошо';
    if (value < 300) return 'Средне';
    return 'Высокая задержка';
  }

  String _pingLabel() {
    if (checkingPing) return 'Проверяем…';
    if (pingMs == null) return 'Проверить задержку';
    final type = switch (coreSettings.pingMode) {
      'icmp' => 'ICMP',
      'tcp' => 'TCP',
      _ => 'Proxy GET',
    };
    return switch (coreSettings.pingView) {
      'number' => '$type · $pingMs мс',
      'quality' => _pingQuality(pingMs!),
      _ => '$type · $pingMs мс · ${_pingQuality(pingMs!)}',
    };
  }

  Future<void> _refreshAllSubscriptions({bool quiet = false}) async {
    if (refreshingSubscriptions || subscriptions.isEmpty) return;
    setState(() => refreshingSubscriptions = true);
    lastRefresh = DateTime.now();
    var failed = 0;
    try {
      for (final sub in List<Map<String, dynamic>>.from(subscriptions)) {
        if (!mounted) return;
        if (!await _refreshSubscription(sub['url'] as String, true)) failed++;
      }
    } finally {
      if (mounted) setState(() => refreshingSubscriptions = false);
    }
    if (mounted && (!quiet || failed > 0)) {
      _message(failed == 0
          ? 'Все подписки обновлены'
          : 'Не удалось обновить подписок: $failed. Сохранённые серверы доступны.');
    }
  }

  Future<void> _showAddMenu() async {
    final action = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: _surface,
        showDragHandle: true,
        builder: (context) => SafeArea(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                  leading: Icon(Icons.rss_feed_rounded, color: _accent),
                  title: Text('Добавить подписку'),
                  subtitle: Text('Один или несколько URL'),
                  onTap: () => Navigator.pop(context, 'subscription')),
              ListTile(
                  leading: Icon(Icons.link_rounded, color: _accent),
                  title: Text('Импортировать профиль'),
                  subtitle: Text('Ссылка · JSON-файл · буфер обмена'),
                  onTap: () => Navigator.pop(context, 'profile')),
              SizedBox(height: 10),
            ])));
    if (action == 'subscription') await _addSubscription();
    if (action == 'profile') await _addProfile();
  }

  Future<String?> _showPasteDialog({
    required String title,
    required String description,
    required String hint,
    required TextEditingController controller,
  }) =>
      showDialog<String>(
          context: context,
          builder: (ctx) => Dialog(
              backgroundColor: _surface,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                  side: BorderSide(color: Colors.white.withOpacity(.18))),
              child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: 520),
                  child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Container(
                                  padding: EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                      color: _accent.withOpacity(.15),
                                      borderRadius: BorderRadius.circular(14)),
                                  child: Icon(Icons.add_link_rounded,
                                      color: _accent)),
                              SizedBox(width: 12),
                              Expanded(
                                  child: Text(title,
                                      style: TextStyle(
                                          fontSize: 19,
                                          fontWeight: FontWeight.w700))),
                              IconButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  icon: Icon(Icons.close_rounded)),
                            ]),
                            SizedBox(height: 13),
                            Text(description,
                                style: TextStyle(
                                    color: _muted, fontSize: 13, height: 1.4)),
                            SizedBox(height: 20),
                            TextField(
                              controller: controller,
                              autofocus: true,
                              minLines: 4,
                              maxLines: 8,
                              style: TextStyle(fontSize: 13, height: 1.45),
                              decoration: InputDecoration(
                                  hintText: hint,
                                  filled: true,
                                  fillColor:
                                      Theme.of(context).scaffoldBackgroundColor,
                                  contentPadding: EdgeInsets.all(16),
                                  border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(18))),
                            ),
                            SizedBox(height: 13),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              alignment: WrapAlignment.spaceBetween,
                              children: [
                                TextButton.icon(
                                    onPressed: () async {
                                      final data = await Clipboard.getData(
                                          Clipboard.kTextPlain);
                                      if (!ctx.mounted) return;
                                      if (data?.text?.isNotEmpty == true)
                                        controller.text = data!.text!;
                                    },
                                    icon: Icon(Icons.content_paste_rounded,
                                        size: 18),
                                    label: Text('Из буфера')),
                                TextButton.icon(
                                    onPressed: () async {
                                      try {
                                        final result = await FilePicker.platform
                                            .pickFiles(
                                                type: FileType.custom,
                                                allowedExtensions: const [
                                                  'json'
                                                ],
                                                withData: true);
                                        if (result == null ||
                                            result.files.isEmpty) return;
                                        final bytes = result.files.single.bytes;
                                        if (bytes == null) {
                                          throw const FormatException(
                                              'Не удалось прочитать JSON-файл.');
                                        }
                                        if (!ctx.mounted) return;
                                        controller
                                          ..text = utf8.decode(bytes)
                                          ..selection = TextSelection.collapsed(
                                              offset: controller.text.length);
                                      } catch (error) {
                                        if (ctx.mounted) _message('$error');
                                      }
                                    },
                                    icon:
                                        Icon(Icons.file_open_rounded, size: 18),
                                    label: Text('JSON-файл')),
                                FilledButton.icon(
                                    onPressed: () =>
                                        Navigator.pop(ctx, controller.text),
                                    icon: Icon(Icons.arrow_forward_rounded,
                                        size: 18),
                                    label: Text('Добавить')),
                              ],
                            ),
                          ])))));

  Future<void> _addSubscription() async {
    final urls = TextEditingController();
    final label = TextEditingController();
    final result = await showDialog<(String, String)>(
        context: context,
        builder: (context) => AlertDialog(
              backgroundColor: _surface,
              title: Text('Новая подписка'),
              content: SizedBox(
                  width: 460,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: label,
                        decoration: InputDecoration(
                            labelText: 'Название (необязательно)',
                            hintText: 'Например, Личная подписка')),
                    SizedBox(height: 12),
                    TextField(
                        controller: urls,
                        autofocus: true,
                        minLines: 4,
                        maxLines: 8,
                        decoration: InputDecoration(
                            labelText: 'URL подписки',
                            hintText:
                                'https://…\nМожно добавить несколько URL, по одному на строку')),
                    TextButton.icon(
                        onPressed: () async {
                          final data =
                              await Clipboard.getData(Clipboard.kTextPlain);
                          if (data?.text?.isNotEmpty == true)
                            urls.text = data!.text!;
                        },
                        icon: Icon(Icons.content_paste_rounded),
                        label: Text('Вставить из буфера')),
                  ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('Отмена')),
                FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, (urls.text, label.text)),
                    child: Text('Добавить'))
              ],
            ));
    urls.dispose();
    label.dispose();
    if (result == null) return;
    final sources = result.$1
        .split(RegExp(r'[\r\n]+'))
        .map((s) => s.trim())
        .where((s) => s.startsWith('https://') || s.startsWith('http://'))
        .toList();
    if (sources.isEmpty) {
      _message('Добавь один или несколько URL подписки');
      return;
    }
    var imported = 0;
    for (var i = 0; i < sources.length; i++) {
      final url = sources[i];
      try {
        final parsed = await ProfileParser().parseSourceDetailed(url);
        final fresh = parsed.profiles;
        if (fresh.isEmpty) continue;
        final name = result.$2.trim().isEmpty
            ? (parsed.metadata.title ?? Uri.tryParse(url)?.host ?? 'Подписка')
            : (sources.length == 1
                ? result.$2.trim()
                : '${result.$2.trim()} ${i + 1}');
        setState(() {
          final old = subscriptions.where((s) => s['url'] == url).firstOrNull;
          final oldIds = (old?['ids'] as List? ?? []).cast<String>().toSet();
          profiles = [
            ...profiles.where((p) => !oldIds.contains(p.id)),
            ...fresh
          ];
          subscriptions.removeWhere((s) => s['url'] == url);
          subscriptions.add({
            'url': url,
            'name': name,
            'customName': result.$2.trim().isNotEmpty,
            'metadata': parsed.metadata.toJson(),
            'updatedAt': DateTime.now().toIso8601String(),
            'ids': fresh.map((p) => p.id).toList()
          });
          if (selectedId == null ||
              (oldIds.contains(selectedId) &&
                  !fresh.any((p) => p.id == selectedId)))
            selectedId = fresh.first.id;
        });
        imported += fresh.length;
      } catch (error) {
        _message('Не удалось загрузить $url: $error');
      }
    }
    await _persist();
    await _saveSubscriptions();
    if (mounted)
      _message(imported > 0
          ? 'Добавлено серверов: $imported'
          : 'Не удалось загрузить серверы из подписок');
  }

  Future<void> _saveSubscriptions() async {
    final p = prefs ??= await SharedPreferences.getInstance();
    await p.setString('subscriptions', jsonEncode(subscriptions));
    final ids = subscriptions
        .expand((s) => (s['ids'] as List? ?? []).cast<String>())
        .toSet()
        .toList();
    await p.setStringList('subscriptionProfileIds', ids);
    subscriptionProfileIds = ids;
    if (subscriptions.isNotEmpty) {
      subscriptionUrl = subscriptions.last['url'] as String;
      await p.setString('subscriptionUrl', subscriptionUrl!);
    } else {
      subscriptionUrl = null;
      await p.remove('subscriptionUrl');
      await p.remove('subscriptionProfileIds');
    }
  }

  Future<void> _subscriptionAction(String action, String url) async {
    final sub = subscriptions.where((s) => s['url'] == url).firstOrNull;
    if (sub == null) return;
    switch (action) {
      case 'refresh':
        await _refreshSubscription(url);
        break;
      case 'ping_all':
        final ids = (sub['ids'] as List? ?? []).cast<String>().toSet();
        await _checkAllProfiles(
            profiles.where((p) => ids.contains(p.id)).toList());
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: url));
        _message('URL подписки скопирован');
        break;
      case 'copy_ghostbox':
        await Clipboard.setData(ClipboardData(
            text: 'GhostBox://addserver?${Uri.encodeComponent(url)}'));
        _message('Короткая ссылка GhostBox скопирована');
        break;
      case 'edit_url':
        final controller = TextEditingController(text: url);
        final nextUrl = await showDialog<String>(
            context: context,
            builder: (context) => AlertDialog(
                    backgroundColor: _surface,
                    title: const Text('Путь подписки'),
                    content: TextField(
                        controller: controller,
                        autofocus: true,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                            labelText: 'URL подписки', hintText: 'https://…')),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Отмена')),
                      FilledButton(
                          onPressed: () =>
                              Navigator.pop(context, controller.text.trim()),
                          child: const Text('Обновить'))
                    ]));
        controller.dispose();
        final parsedUrl = Uri.tryParse(nextUrl ?? '');
        if (nextUrl == null || nextUrl == url) break;
        if (parsedUrl == null ||
            !{'http', 'https'}.contains(parsedUrl.scheme) ||
            parsedUrl.host.isEmpty) {
          _message('Укажите корректную HTTP или HTTPS ссылку');
          break;
        }
        setState(() => sub['url'] = nextUrl);
        await _saveSubscriptions();
        if (!await _refreshSubscription(nextUrl)) {
          setState(() => sub['url'] = url);
          await _saveSubscriptions();
        }
        break;
      case 'rename':
        final controller = TextEditingController(text: '${sub['name'] ?? ''}');
        final name = await showDialog<String>(
            context: context,
            builder: (context) => AlertDialog(
                    backgroundColor: _surface,
                    title: Text('Название подписки'),
                    content: TextField(controller: controller, autofocus: true),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text('Отмена')),
                      FilledButton(
                          onPressed: () =>
                              Navigator.pop(context, controller.text.trim()),
                          child: Text('Сохранить'))
                    ]));
        if (name != null && name.isNotEmpty) {
          setState(() => sub['name'] = name);
          await _saveSubscriptions();
        }
        break;
      case 'remove':
        setState(() {
          subscriptions.removeWhere((s) => s['url'] == url);
          subscriptionProfileIds = subscriptions
              .expand((s) => (s['ids'] as List? ?? []).cast<String>())
              .toSet()
              .toList();
        });
        await _saveSubscriptions();
        _message('Подписка удалена; серверы сохранены в «Мои профили»');
        break;
    }
  }

  void _bindCoreRecoveryNotices(CoreProcessBackend core) {
    core.onRecoveryNotice = (message, {bool error = false}) {
      if (!mounted) return;
      GhostNotice.show(
        context,
        message,
        error: error,
        icon: error ? Icons.warning_amber_rounded : Icons.restart_alt_rounded,
      );
    };
  }

  void _message(String text) => GhostNotice.show(context, text,
      error: RegExp('ошиб|не удалось|неверн|нет ответа|не отвечает|не поддерж',
              caseSensitive: false)
          .hasMatch(text));
  Future<void> _addProfile() async {
    final controller = TextEditingController();
    final input = await _showPasteDialog(
      title: 'Добавить сервер',
      description:
          'Вставьте ссылку или JSON-конфиг сервера, либо выберите JSON-файл. Также можно добавить URL подписки.',
      hint: 'vless://…  или  https://…',
      controller: controller,
    );
    controller.dispose();
    if (input == null || input.trim().isEmpty) return;
    try {
      final parsedResult = await ProfileParser().parseSourceDetailed(input);
      final parsed = parsedResult.profiles;
      if (parsed.isEmpty)
        throw FormatException('Подписка не содержит профилей');
      setState(() {
        profiles = [...profiles, ...parsed];
        selectedId = parsed.first.id;
        if (input.startsWith('http://') || input.startsWith('https://')) {
          subscriptionUrl = input;
          subscriptionProfileIds = parsed.map((e) => e.id).toList();
          subscriptions.removeWhere((s) => s['url'] == input);
          subscriptions.add({
            'url': input,
            'name': parsedResult.metadata.title ??
                Uri.tryParse(input)?.host ??
                'Подписка',
            'metadata': parsedResult.metadata.toJson(),
            'updatedAt': DateTime.now().toIso8601String(),
            'ids': subscriptionProfileIds
          });
        }
      });
      await _persist();
      if (input.startsWith('http://') || input.startsWith('https://'))
        await prefs?.setString('subscriptionUrl', input);
      if (input.startsWith('http://') || input.startsWith('https://')) {
        await prefs?.setStringList(
            'subscriptionProfileIds', subscriptionProfileIds);
        await prefs?.setString('subscriptions', jsonEncode(subscriptions));
      }
    } catch (e) {
      if (mounted) _message('$e');
    }
  }

  Future<void> _selectCore(String value) async {
    final next = value == 'Xray' ? 'xray' : 'sing-box';
    if (coreSettings.core == next) return;
    if (backend.state == VpnState.connecting) {
      _message('Подождите завершения подключения');
      return;
    }
    final reconnect = backend.state == VpnState.connected;
    if (reconnect) await _disconnectActive();
    await _saveCore(coreSettings.copyWith(core: next));
    if (!mounted) return;
    setState(() {
      backend = next == 'xray' ? XrayBackend() : SingBoxBackend();
      activeProfileId = null;
      pendingReconnect = false;
      pingMs = null;
    });
    process?.settings = coreSettings;
    if (reconnect && selected != null) await _toggle();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Container(
          decoration: BoxDecoration(
              gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                _surface,
                Theme.of(context).scaffoldBackgroundColor,
                Theme.of(context).scaffoldBackgroundColor
              ])),
          child: SafeArea(
              child: Center(
                  child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: 1000),
                      child: Padding(
                          padding: EdgeInsets.fromLTRB(5, 12, 5, 12),
                          child: Column(children: [
                            _header(),
                            SizedBox(height: 8),
                            Expanded(
                                child: ClipRRect(
                                    borderRadius: BorderRadius.circular(24),
                                    child: AnimatedSwitcher(
                                        duration:
                                            const Duration(milliseconds: 190),
                                        reverseDuration:
                                            const Duration(milliseconds: 80),
                                        switchInCurve: Curves.easeOutCubic,
                                        switchOutCurve: Curves.linear,
                                        layoutBuilder: (current, previous) =>
                                            current ?? SizedBox.shrink(),
                                        transitionBuilder: (child, animation) =>
                                            FadeTransition(
                                                opacity: animation,
                                                child: ScaleTransition(
                                                    scale: Tween<double>(
                                                            begin: .985, end: 1)
                                                        .animate(CurvedAnimation(
                                                            parent: animation,
                                                            curve: Curves
                                                                .easeOutCubic)),
                                                    child: child)),
                                        child: KeyedSubtree(
                                            key: ValueKey(_tabIndex),
                                            child: settings
                                                ? _scrollFrame(
                                                    _settings(), settingsScroll)
                                                : routingTab
                                                    ? _scrollFrame(
                                                        _routingPage(),
                                                        routingScroll)
                                                    : _scrollFrame(_home(),
                                                        homeScroll))))),
                            SizedBox(height: 8),
                            _nav(),
                          ])))))));

  Widget _scrollFrame(
          Widget child, ScrollController controller) =>
      ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
              scrollbars: false,
              physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics())),
          child: Scrollbar(
              controller: controller,
              thumbVisibility: true,
              thickness: 3,
              radius: Radius.circular(8),
              child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: child)));

  Future<void> _openActionsMenu(BuildContext anchorContext) async {
    final anchor = anchorContext.findRenderObject() as RenderBox?;
    final overlay =
        Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
    if (anchor == null || overlay == null || !anchor.hasSize) return;
    final topLeft = anchor.localToGlobal(Offset.zero, ancestor: overlay);
    final rect = topLeft & anchor.size;
    final action = await showMenu<String>(
        context: context,
        position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
        items: [
          _menuItem('ping_all', Icons.speed_rounded, 'Пинговать все'),
          _menuItem('refresh_all', Icons.sync_rounded, 'Обновить подписки'),
          _menuItem('logs', Icons.article_outlined, 'Журнал соединения'),
          _menuItem('history', Icons.history_rounded, 'Последние подключения'),
        ]);
    if (!mounted || action == null) return;
    switch (action) {
      case 'ping_all':
        await _checkAllProfiles(List.of(profiles));
        break;
      case 'refresh_all':
        await _refreshAllSubscriptions();
        break;
      case 'logs':
        await _showLogs();
        break;
      case 'history':
        _showConnectionHistory();
        break;
    }
  }

  bool get _showTunPermissionHelp {
    final error = connectionIssue?.toLowerCase() ?? '';
    return Platform.isLinux &&
        (coreSettings.connectionMode == 'tun' ||
            coreSettings.connectionMode == 'mixed') &&
        (error.contains('cap_net_admin') ||
            error.contains('не получил доступ к tun') ||
            error.contains('operation not permitted'));
  }

  String get _tunCapabilityCommand {
    final dataHome = Platform.environment['XDG_DATA_HOME'] ??
        '${Platform.environment['HOME'] ?? ''}/.local/share';
    final vendorDirectory = Platform.environment['GHOSTBOX_VENDOR_DIR'] ??
        '$dataHome/ghostbox-appimage/vendor';
    final core = coreSettings.core == 'xray' ? 'sing-box' : coreSettings.core;
    return 'sudo setcap cap_net_admin+ep "$vendorDirectory/bin/$core"';
  }

  Widget _tunPermissionHint() => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(4, 4, 4, 10),
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        decoration: BoxDecoration(
          color: _accent.withValues(alpha: .09),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _accent.withValues(alpha: .25)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.admin_panel_settings_outlined, size: 17, color: _accent),
            const SizedBox(width: 8),
            const Expanded(
                child: Text('Один раз разреши TUN',
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
            IconButton(
                tooltip: 'Скопировать команду',
                visualDensity: VisualDensity.compact,
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: _tunCapabilityCommand));
                  if (mounted) _message('Команда скопирована');
                },
                icon:
                    Icon(Icons.content_copy_rounded, size: 16, color: _accent)),
          ]),
          const SizedBox(height: 4),
          SelectableText(_tunCapabilityCommand,
              style: const TextStyle(
                  fontSize: 10, fontFamily: 'monospace', height: 1.45)),
          const SizedBox(height: 5),
          Text(
              'Запусти команду в терминале после первого запуска AppImage. Сам VPN будет работать от твоего пользователя, без sudo.',
              style: TextStyle(fontSize: 10, color: _muted, height: 1.4)),
        ]),
      );

  Widget _header() => SizedBox(
      height: 48,
      child: Stack(alignment: Alignment.center, children: [
        Positioned(
            left: 0,
            child: SizedBox(
                width: 44,
                height: 44,
                child: _topButton(
                    routeListOpen || settings || routingTab
                        ? Icons.arrow_back_ios_new_rounded
                        : Icons.settings_rounded, () {
                  if (routeListOpen) {
                    setState(() => routeListOpen = false);
                  } else {
                    _openTab(settings || routingTab ? 0 : 2);
                  }
                }))),
        Center(
            child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 64),
                child: Text(
                    routeListOpen
                        ? 'Список доменов'
                        : settings
                            ? 'Настройки'
                            : routingTab
                                ? 'Маршрут'
                                : 'GhostBox',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        letterSpacing: .2)))),
        if (refreshingSubscriptions)
          const Positioned(
              right: 50,
              child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5))),
        Positioned(
            right: 0,
            child: SizedBox(
                width: 44,
                height: 44,
                child: Builder(
                    builder: (buttonContext) => IconButton(
                        tooltip: 'Действия',
                        onPressed: () => _openActionsMenu(buttonContext),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                            width: 44, height: 44),
                        icon: const Icon(Icons.more_horiz_rounded,
                            color: Colors.white, size: 25))))),
      ]));

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label) =>
      PopupMenuItem<String>(
          value: value,
          height: 44,
          child: Row(children: [
            Icon(icon, size: 18, color: _accent),
            const SizedBox(width: 12),
            Flexible(
                child:
                    Text(label, maxLines: 1, overflow: TextOverflow.ellipsis))
          ]));

  void _openTab(int index) => setState(() {
        routeListOpen = false;
        settings = index == 2;
        routingTab = index == 1;
      });

  Widget _topButton(IconData icon, VoidCallback onTap) => IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: 25, color: Colors.white),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      style: IconButton.styleFrom(shape: const CircleBorder()));

  Widget _home() => SingleChildScrollView(
      controller: homeScroll,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
            borderRadius: BorderRadius.circular(30),
            child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                    width: double.infinity,
                    padding: EdgeInsets.fromLTRB(18, 12, 18, 16),
                    decoration: BoxDecoration(
                        gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              _accent.withValues(alpha: .10),
                              _surface.withValues(alpha: .1)
                            ]),
                        borderRadius: BorderRadius.circular(30),
                        border:
                            Border.all(color: Colors.white.withOpacity(.12)),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withOpacity(.12),
                              blurRadius: 28,
                              offset: Offset(0, 12))
                        ]),
                    child: Column(children: [
                      _power(),
                      SizedBox(height: 12),
                      _connectionDetails()
                    ])))),
        if (_showTunPermissionHelp) _tunPermissionHint(),
        SizedBox(height: 8),
        Row(children: [
          Tooltip(
              message: pingSamples.isEmpty
                  ? 'Проверка ${coreSettings.pingMode == 'icmp' ? 'ICMP адреса' : coreSettings.pingMode == 'tcp' ? 'TCP порта' : 'HTTP GET через прокси'} выбранного сервера'
                  : '${coreSettings.pingCount} проб · ${pingSamples.first}–${pingSamples.last} мс · медиана $pingMs мс',
              child: TextButton.icon(
                  onPressed: _checkConnection,
                  icon: checkingPing
                      ? SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: _accent))
                      : Icon(
                          pingMs == null
                              ? Icons.speed_rounded
                              : Icons.signal_cellular_alt_rounded,
                          size: 17),
                  label: AnimatedSwitcher(
                      duration: Duration(milliseconds: 260),
                      child: Text(_pingLabel(), key: ValueKey(_pingLabel()))),
                  style: TextButton.styleFrom(
                      foregroundColor: pingMs == null
                          ? _muted
                          : pingMs! < 180
                              ? _mint
                              : pingMs! < 300
                                  ? Color(0xFFFFDA8B)
                                  : Color(0xFFFFA3A3),
                      textStyle: TextStyle(fontSize: 12)))),
          Spacer(),
          if (checkingAll)
            Text('$pingAllDone/$pingAllTotal',
                style: TextStyle(color: _muted, fontSize: 11)),
          TextButton(
              onPressed: () => setState(() => hideProfiles = !hideProfiles),
              style: TextButton.styleFrom(
                  foregroundColor: _muted, textStyle: TextStyle(fontSize: 12)),
              child: Text(hideProfiles ? 'Показать серверы' : 'Скрыть серверы'))
        ]),
        if (pendingReconnect)
          Padding(
              padding: EdgeInsets.only(bottom: 14),
              child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                      color: _accent.withOpacity(.12),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _accent.withOpacity(.3))),
                  child: Row(children: [
                    Icon(Icons.auto_awesome_rounded, size: 17, color: _accent),
                    SizedBox(width: 9),
                    Expanded(
                        child: Text('Новый выбор ждёт переподключения',
                            style: TextStyle(fontSize: 12))),
                    TextButton(
                        onPressed: () async {
                          await _disconnectActive();
                          await _toggle();
                        },
                        child: Text('Применить')),
                  ]))),
        AnimatedSize(
            duration: Duration(milliseconds: 420),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: profiles.isEmpty ? [_empty()] : _profileSections())),
        SizedBox(height: 14),
        SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
                onPressed: _showAddMenu,
                style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.symmetric(vertical: 19),
                    side: BorderSide(color: _line),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(22))),
                icon: Icon(Icons.add_rounded, size: 23),
                label: Text('Добавить подписку или сервер',
                    style: TextStyle(fontSize: 12)))),
        SizedBox(height: 18),
      ]));

  Widget _routingPage() => routeListOpen
      ? _routeListEditor()
      : ListView(
          controller: routingScroll,
          key: const PageStorageKey('routing'),
          padding: const EdgeInsets.only(top: 14, bottom: 24),
          children: [
            Text('Как пускать трафик',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.6)),
            const SizedBox(height: 5),
            Text('Выбери, какие сайты отправлять через сервер',
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted, fontSize: 12)),
            const SizedBox(height: 20),
            _routeOption('Всё через VPN', 'Любые сайты идут через сервер.',
                Icons.shield_rounded, 'proxy'),
            _routeOption(
                'Только сайты из списка',
                'В список — через VPN, всё остальное напрямую.',
                Icons.list_alt_rounded,
                'rules'),
            _routeOption(
                'Всё, кроме списка',
                'Сайты из списка идут напрямую, остальные — через VPN.',
                Icons.alt_route_rounded,
                'exclude'),
            if (coreSettings.routing == 'rules' ||
                coreSettings.routing == 'exclude') ...[
              const SizedBox(height: 14),
              Center(
                  child: _section(coreSettings.routing == 'rules'
                      ? 'САЙТЫ ЧЕРЕЗ VPN'
                      : 'САЙТЫ НАПРЯМУЮ')),
              _row(
                  coreSettings.routing == 'rules'
                      ? Icons.shield_outlined
                      : Icons.public_rounded,
                  coreSettings.routing == 'rules'
                      ? 'Сайты через VPN'
                      : 'Исключения из VPN',
                  '${(coreSettings.routing == 'rules' ? coreSettings.proxyDomains : coreSettings.directDomains).length} правил',
                  IconButton(
                      tooltip: 'Открыть список правил',
                      onPressed: () => _openRouteList(coreSettings.routing),
                      icon: const Icon(Icons.chevron_right_rounded))),
              Padding(
                  padding: const EdgeInsets.only(top: 3, left: 2),
                  child: Text(
                      'Домены (*.ru) и IP-сети (203.0.113.0/24). Для IP-списков маршрутизация работает без TLS sniffing. Принимается JSON Amnezia.',
                      style:
                          TextStyle(color: _muted, fontSize: 11, height: 1.4))),
            ],
            if (pendingReconnect) ...[
              const SizedBox(height: 14),
              _reconnectNotice(),
            ],
          ],
        );

  void _openRouteList(String mode) {
    routeListMode = mode;
    final values = mode == 'rules'
        ? coreSettings.proxyDomains
        : coreSettings.directDomains;
    routeListController.text = values.join('\n');
    setState(() => routeListOpen = true);
  }

  List<String>? _readRouteDomains(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return <String>[];
    List<String>? fromJson(dynamic value) {
      final found = <String>{};
      void collect(dynamic node) {
        if (node is String) {
          for (final token in node.split(RegExp(r'[\s,;]+'))) {
            final candidate = CoreSettings.normalizeRoutePattern(token);
            if (CoreSettings.isValidRoutePattern(candidate))
              found.add(candidate);
          }
        } else if (node is List) {
          for (final entry in node) {
            collect(entry);
          }
        } else if (node is Map) {
          for (final entry in node.entries) {
            final key = entry.key.toString();
            final candidate = CoreSettings.normalizeRoutePattern(key);
            if (CoreSettings.isValidRoutePattern(candidate)) {
              found.add(candidate);
            }
            collect(entry.value);
          }
        }
      }

      collect(value);
      return found.isEmpty ? null : found.toList();
    }

    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      try {
        return fromJson(jsonDecode(trimmed));
      } on FormatException {
        return null;
      }
    }
    return trimmed
        .split(RegExp(r'[\s,;]+'))
        .where((value) => value.isNotEmpty)
        .toList();
  }

  Future<void> _saveRouteList() async {
    final values = _readRouteDomains(routeListController.text);
    if (values == null) {
      _message('JSON должен содержать домены или IP-сети');
      return;
    }
    final normalized = values
        .map(CoreSettings.normalizeRoutePattern)
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList();
    final invalid =
        normalized.where((value) => !CoreSettings.isValidRoutePattern(value));
    if (invalid.isNotEmpty) {
      _message('Неверный домен: ${invalid.first}');
      return;
    }
    final next = routeListMode == 'rules'
        ? coreSettings.copyWith(proxyDomains: normalized)
        : coreSettings.copyWith(directDomains: normalized);
    await _applyRoutingSettings(next);
    if (mounted) setState(() => routeListOpen = false);
  }

  Widget _routeListEditor() => ListView(
        controller: routingScroll,
        key: const PageStorageKey('routing-domains'),
        padding: const EdgeInsets.only(top: 14, bottom: 24),
        children: [
          Text(
              routeListMode == 'rules'
                  ? 'Сайты через VPN'
                  : 'Исключения из VPN',
              style:
                  const TextStyle(fontSize: 23, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
              'Домен, маска или IP-сеть на строку. Подойдут *.ru, 10.0.0.0/8 и JSON-списки Amnezia.',
              style: TextStyle(color: _muted, fontSize: 12)),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
                color: _surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _line.withValues(alpha: .55))),
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: routeListController,
              minLines: 12,
              maxLines: 20,
              autocorrect: false,
              textCapitalization: TextCapitalization.none,
              style: const TextStyle(fontSize: 13, height: 1.5),
              decoration: const InputDecoration(
                  hintText:
                      'example.com\n*.ru\n203.0.113.0/24\n\nили JSON Amnezia',
                  border: InputBorder.none,
                  counterText: ''),
            ),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(
                  text: const JsonEncoder.withIndent('  ').convert(
                      _readRouteDomains(routeListController.text) ??
                          const []))),
              icon: const Icon(Icons.copy_rounded, size: 17),
              label: const Text('Скопировать как JSON')),
          const SizedBox(height: 10),
          SizedBox(
              width: double.infinity,
              child: FilledButton(
                  onPressed: _saveRouteList,
                  child: const Text('Сохранить список'))),
        ],
      );

  Widget _routeOption(
          String title, String description, IconData icon, String value) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () =>
                _applyRoutingSettings(coreSettings.copyWith(routing: value)),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: coreSettings.routing == value
                    ? _accent.withValues(alpha: .15)
                    : _surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: coreSettings.routing == value
                        ? _accent.withValues(alpha: .68)
                        : Colors.white.withValues(alpha: .10)),
              ),
              child: Row(children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _accent.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: _accent, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(description,
                          style: TextStyle(
                              color: _muted, fontSize: 11, height: 1.35)),
                    ])),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: coreSettings.routing == value
                        ? _accent
                        : Colors.transparent,
                    border: Border.all(
                        color: coreSettings.routing == value
                            ? _accent
                            : _muted.withValues(alpha: .55)),
                  ),
                  child: coreSettings.routing == value
                      ? const Icon(Icons.check_rounded,
                          size: 14, color: Colors.white)
                      : null,
                ),
              ]),
            ),
          ),
        ),
      );

  Widget _reconnectNotice() => Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: _accent.withValues(alpha: .13),
          borderRadius: BorderRadius.circular(17),
          border: Border.all(color: _accent.withValues(alpha: .35))),
      child: Row(children: [
        Icon(Icons.info_outline_rounded, color: _accent, size: 19),
        const SizedBox(width: 10),
        const Expanded(
            child: Text('Переподключи ядро, чтобы применить маршрут.',
                style: TextStyle(fontSize: 12))),
        TextButton(
            onPressed: () async {
              await _disconnectActive();
              await _toggle();
            },
            child: const Text('Применить')),
      ]));

  Widget _power() => Column(children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggle,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) {
              if (!powerHovered) setState(() => powerHovered = true);
            },
            onExit: (_) {
              if (powerHovered) setState(() => powerHovered = false);
            },
            child: AnimatedScale(
              scale: powerHovered && backend.state != VpnState.connecting
                  ? 1.035
                  : 1,
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              child: AnimatedBuilder(
                animation: glow,
                builder: (context, child) => Stack(
                  alignment: Alignment.center,
                  children: [
                    CustomPaint(
                      size: const Size(226, 226),
                      painter: _OrbRings(
                        progress: glow.value,
                        color: _accent,
                        active: backend.state == VpnState.connected ||
                            switchingServer,
                        connecting: backend.state == VpnState.connecting ||
                            switchingServer,
                      ),
                    ),
                    child!,
                  ],
                ),
                child: SizedBox(
                  width: 190,
                  height: 190,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 500),
                        width: 178,
                        height: 178,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _accent.withOpacity(.12),
                          border:
                              Border.all(color: Colors.white.withOpacity(.04)),
                        ),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 420),
                        width: 144,
                        height: 144,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _accent.withOpacity(.24),
                          border: Border.all(
                              color: _accent.withOpacity(.35), width: 2),
                          boxShadow: [
                            BoxShadow(
                                color: _accent.withOpacity(.3), blurRadius: 28),
                          ],
                        ),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 520),
                        curve: Curves.easeOutCubic,
                        width: 112,
                        height: 112,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: backend.state == VpnState.error
                                ? const [Color(0xFFFF9FAD), Color(0xFFAB4A67)]
                                : backend.state == VpnState.connected ||
                                        switchingServer
                                    ? const [
                                        Color(0xFF93EAD0),
                                        Color(0xFF279B91)
                                      ]
                                    : [_accent, _accent.withValues(alpha: .55)],
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 120),
                              transitionBuilder: (child, animation) =>
                                  FadeTransition(
                                      opacity: animation, child: child),
                              child: backend.state == VpnState.connecting ||
                                      switchingServer
                                  ? const Icon(Icons.more_horiz_rounded,
                                      key: ValueKey('connecting-or-switching'),
                                      size: 31,
                                      color: Colors.white)
                                  : Icon(
                                      backend.state == VpnState.connected
                                          ? Icons.check_rounded
                                          : Icons.power_settings_new_rounded,
                                      key: ValueKey(backend.state),
                                      size: 31,
                                      color: Colors.white,
                                    ),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              switchingServer
                                  ? 'ПЕРЕКЛЮЧАЕМ'
                                  : backend.state == VpnState.connected
                                      ? _connectedLabel()
                                      : backend.state == VpnState.connecting
                                          ? 'ПОДКЛЮЧАЕМ'
                                          : 'НАЖМИТЕ',
                              style: const TextStyle(
                                  fontSize: 9,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: .5),
                            ),
                            if (backend.state == VpnState.connected &&
                                !switchingServer)
                              Text(_uptimeLabel(),
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 11)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                    position: Tween<Offset>(
                            begin: const Offset(0, .12), end: Offset.zero)
                        .animate(animation),
                    child: child)),
            child: SizedBox(
                key: ValueKey(
                    '${activeProfileId ?? selectedId}:${backend.state}'),
                width: double.infinity,
                child: Text(
                    switchingServer
                        ? (selected?.name ?? 'Переключение сервера')
                        : backend.state == VpnState.connected
                            ? (profiles
                                    .where((p) => p.id == activeProfileId)
                                    .firstOrNull
                                    ?.name ??
                                selected?.name ??
                                'Локальный прокси запущен')
                            : (selected?.name ?? 'Выберите сервер'),
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600))))
      ]);
  String _uptimeLabel() {
    final d = process?.uptime ?? Duration.zero;
    return '${d.inHours.toString().padLeft(2, '0')}:${(d.inMinutes % 60).toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  String _connectedLabel() {
    return switch (coreSettings.connectionMode) {
      'proxy' => 'ПРОКСИ ГОТОВ',
      'system' => 'СИСТЕМНЫЙ ПРОКСИ',
      'tun' => 'TUN АКТИВЕН',
      'mixed' => 'MIXED АКТИВЕН',
      _ => 'ПОДКЛЮЧЕНО',
    };
  }

  Widget _connectionDetails() =>
      Column(mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _tinyStat('ЯДРО', process?.name ?? coreSettings.core,
              choices: const [('xray', 'Xray'), ('sing-box', 'sing-box')],
              onSelected: (value) =>
                  _selectCore(value == 'xray' ? 'Xray' : value)),
          const SizedBox(width: 8),
          _tinyStat('РЕЖИМ', _connectionModeLabel(coreSettings.connectionMode),
              choices: const [
                ('proxy', 'Proxy'),
                ('system', 'System proxy'),
                ('tun', 'TUN'),
                ('mixed', 'Mixed'),
              ],
              onSelected: _setConnectionMode),
        ]),
        if (coreSettings.showRamUsage) ...[
          const SizedBox(height: 7),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: Text(
              key: ValueKey('$coreMemoryMb:${backend.state}'),
              backend.state == VpnState.connected
                  ? 'RAM ядра · ${coreMemoryMb == null ? 'считаю…' : '${coreMemoryMb!} МБ'}'
                  : 'RAM ядра · отключено',
              style: TextStyle(
                  fontSize: 10,
                  color: Colors.white.withValues(alpha: .66),
                  fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ]);

  Future<void> _refreshCoreMemoryUsage() async {
    if (!Platform.isLinux || readingCoreMemory || !coreSettings.showRamUsage) {
      return;
    }
    if (backend.state != VpnState.connected) {
      if (coreMemoryMb != null && mounted) setState(() => coreMemoryMb = null);
      return;
    }
    readingCoreMemory = true;
    try {
      final pids = <int>{
        if (process?.pid != null) process!.pid!,
        if (tunnelBridgeBackend?.pid != null) tunnelBridgeBackend!.pid!,
      };
      var totalKb = 0;
      for (final pid in pids) {
        final status = await File('/proc/$pid/status').readAsLines();
        final line = status.firstWhere((entry) => entry.startsWith('VmRSS:'),
            orElse: () => '');
        final match = RegExp(r'VmRSS:\s+(\d+)\s+kB').firstMatch(line);
        totalKb += int.tryParse(match?.group(1) ?? '') ?? 0;
      }
      final value = pids.isEmpty ? null : (totalKb / 1024).round();
      if (mounted && value != coreMemoryMb) {
        setState(() => coreMemoryMb = value);
      }
    } on Object {
      if (mounted && coreMemoryMb != null) setState(() => coreMemoryMb = null);
    } finally {
      readingCoreMemory = false;
    }
  }

  String _connectionModeLabel(String mode) => switch (mode) {
        'system' => 'System proxy',
        'tun' => 'TUN',
        'mixed' => 'Mixed',
        _ => 'Proxy',
      };
  Widget _tinyStat(String label, String value,
          {required List<(String, String)> choices,
          required ValueChanged<String> onSelected}) =>
      PopupMenuButton<String>(
          tooltip: 'Изменить $label',
          onSelected: onSelected,
          itemBuilder: (_) => [
                for (final choice in choices)
                  PopupMenuItem<String>(
                      value: choice.$1, child: Text(choice.$2)),
              ],
          child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .06),
                  borderRadius: BorderRadius.circular(14),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: .05))),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('$label  ', style: TextStyle(color: _muted, fontSize: 10)),
                Text(value,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
                const SizedBox(width: 4),
                Icon(Icons.expand_more_rounded, color: _muted, size: 14),
              ])));
  Widget _empty() => Container(
      width: double.infinity,
      padding: EdgeInsets.all(30),
      decoration: BoxDecoration(
          color: Color(0x552A2F82),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _line)),
      child: Column(children: [
        Icon(Icons.public_off_rounded, size: 35, color: _muted),
        SizedBox(height: 10),
        Text('Пока нет серверов',
            style: TextStyle(fontWeight: FontWeight.w600)),
        SizedBox(height: 5),
        Text('Добавьте ссылку или подписку, чтобы начать',
            textAlign: TextAlign.center, style: TextStyle(color: _muted)),
      ]));
  List<Widget> _profileSections() {
    final groupedIds = subscriptions
        .expand((s) => (s['ids'] as List? ?? []).cast<String>())
        .toSet();
    final widgets = <Widget>[];
    final local = profiles.where((p) => !groupedIds.contains(p.id)).toList();
    if (local.isNotEmpty) {
      widgets.add(_fadingProfileGroup(
          visible: !hideProfiles,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _section('МОИ ПРОФИЛИ'),
              ...local.map(_profileTile),
            ],
          )));
    }
    for (final sub in subscriptions) {
      final url = sub['url'] as String;
      final ids = (sub['ids'] as List? ?? []).cast<String>().toSet();
      final entries = profiles.where((p) => ids.contains(p.id)).toList();
      final host = Uri.tryParse(url)?.host ?? url;
      final collapsed = collapsedSubscriptions.contains(url);
      widgets.add(ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                  margin: EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                      color: _surface,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: Colors.white.withOpacity(.16)),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withOpacity(.15),
                            blurRadius: 24,
                            offset: Offset(0, 10))
                      ]),
                  child: Column(children: [
                    Padding(
                        padding: EdgeInsets.fromLTRB(15, 8, 8, 5),
                        child: Row(children: [
                          Icon(Icons.layers_rounded, color: _accent, size: 20),
                          SizedBox(width: 8),
                          Expanded(
                              child: Text(
                                  '${sub['name'] ?? (host.isEmpty ? 'Подписка' : host)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white))),
                          Text('${entries.length}',
                              style: TextStyle(color: _muted, fontSize: 11)),
                          IconButton(
                              tooltip: collapsed
                                  ? 'Показать серверы подписки'
                                  : 'Скрыть серверы подписки',
                              onPressed: () => setState(() {
                                    if (collapsed) {
                                      collapsedSubscriptions.remove(url);
                                    } else {
                                      collapsedSubscriptions.add(url);
                                    }
                                  }),
                              icon: AnimatedRotation(
                                  turns: collapsed ? .5 : 0,
                                  duration: const Duration(milliseconds: 220),
                                  child: Icon(Icons.expand_less_rounded,
                                      size: 19, color: Colors.white70))),
                          IconButton(
                              tooltip: 'Обновить подписку',
                              onPressed: () => _refreshSubscription(url),
                              icon: Icon(Icons.sync_rounded,
                                  size: 19, color: Colors.white70)),
                          PopupMenuButton<String>(
                              tooltip: 'Действия с подпиской',
                              icon: Icon(Icons.more_horiz_rounded,
                                  size: 20, color: Colors.white70),
                              onSelected: (action) =>
                                  _subscriptionAction(action, url),
                              itemBuilder: (_) => [
                                    _menuItem('ping_all', Icons.speed_rounded,
                                        'Пинговать все'),
                                    _menuItem('refresh', Icons.sync_rounded,
                                        'Обновить'),
                                    _menuItem('copy', Icons.copy_rounded,
                                        'Скопировать URL'),
                                    _menuItem(
                                        'copy_ghostbox',
                                        Icons.link_rounded,
                                        'Короткая GhostBox-ссылка'),
                                    _menuItem(
                                        'edit_url',
                                        Icons.edit_location_alt_rounded,
                                        'Изменить путь подписки'),
                                    _menuItem('rename', Icons.edit_rounded,
                                        'Переименовать'),
                                    _menuItem('remove', Icons.delete_outline,
                                        'Убрать подписку'),
                                  ]),
                        ])),
                    AnimatedSize(
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topCenter,
                        child: _subscriptionInfo(sub,
                            collapsed:
                                collapsedSubscriptionInfo.contains(url))),
                    _fadingProfileGroup(
                        visible: !hideProfiles && !collapsed,
                        child: Column(
                          children: [
                            for (var i = 0; i < entries.length; i++)
                              _profileTile(entries[i],
                                  grouped: true,
                                  divider: i != entries.length - 1),
                          ],
                        )),
                  ])))));
    }
    return widgets;
  }

  String _formatBytes(int bytes) {
    final gb = bytes / (1024 * 1024 * 1024);
    if (gb >= 1) return '${gb.toStringAsFixed(gb >= 10 ? 0 : 1)} ГБ';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(0)} МБ';
  }

  Widget _fadingProfileGroup({required bool visible, required Widget child}) =>
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 540),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (current, previous) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...previous,
            if (current != null) current,
          ],
        ),
        transitionBuilder: (child, animation) {
          final opacity = CurvedAnimation(
              parent: animation,
              curve: const Interval(.34, 1, curve: Curves.easeInOut));
          final height = CurvedAnimation(
              parent: animation,
              curve: const Interval(0, .32, curve: Curves.easeInOutCubic));
          return ClipRect(
            child: SizeTransition(
              sizeFactor: height,
              axisAlignment: -1,
              child: FadeTransition(opacity: opacity, child: child),
            ),
          );
        },
        child: visible
            ? KeyedSubtree(
                key: const ValueKey('profile-group-visible'), child: child)
            : const SizedBox.shrink(key: ValueKey('profile-group-hidden')),
      );

  String _expiryLabel(DateTime expires) {
    final local = expires.toLocal();
    final remaining = local.difference(DateTime.now());
    if (remaining.isNegative || remaining.inSeconds == 0) return 'Срок истёк';
    final date =
        '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}.${local.year}';
    if (remaining.inDays >= 1) {
      return 'Ещё ${remaining.inDays} дн. · $date';
    }
    if (remaining.inHours >= 1) {
      return 'Истекает сегодня · ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }
    return 'Меньше часа · ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _openProviderUrl(String? value) async {
    final uri = Uri.tryParse(value ?? '');
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      _message('Провайдер не указал корректную ссылку');
      return;
    }
    try {
      final launch =
          await Process.start('xdg-open', [uri.toString()], runInShell: false);
      if (await launch.exitCode != 0 && mounted)
        _message('Не удалось открыть ссылку');
    } catch (_) {
      if (mounted) _message('Не удалось открыть ссылку');
    }
  }

  Widget _subscriptionInfo(Map<String, dynamic> sub,
      {required bool collapsed}) {
    final raw = sub['metadata'];
    final metadata = SubscriptionMetadata.fromJson(
        raw is Map ? Map<String, dynamic>.from(raw) : {});
    final used = metadata.usedBytes;
    final total = metadata.total;
    final expires = metadata.expiresAt;
    final now = DateTime.now();
    final expired = expires != null && expires.isBefore(now);
    final hasInfo = used != null ||
        total != null ||
        expires != null ||
        metadata.deviceLimit != null ||
        metadata.announcement != null ||
        metadata.description != null ||
        metadata.supportUrl != null ||
        metadata.websiteUrl != null;
    final progress = total != null && total > 0 && used != null
        ? (used / total).clamp(0.0, 1.0)
        : null;
    if (collapsed) {
      final summary = total == 0 && used != null
          ? 'Без лимита · ${_formatBytes(used)} использовано'
          : used != null && total != null
              ? '${_formatBytes(used)} из ${_formatBytes(total)}'
              : used != null
                  ? '${_formatBytes(used)} использовано'
                  : 'Данные подписки';
      return Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => setState(() {
                    final url = sub['url'] as String;
                    if (collapsedSubscriptionInfo.contains(url)) {
                      collapsedSubscriptionInfo.remove(url);
                    } else {
                      collapsedSubscriptionInfo.add(url);
                    }
                  }),
              child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                      color: _subscriptionInfoSurface,
                      borderRadius: BorderRadius.circular(17),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: .11))),
                  child: Row(children: [
                    Icon(Icons.data_usage_rounded, color: _accent, size: 15),
                    const SizedBox(width: 7),
                    Expanded(
                        child: Text(summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w600))),
                    if (expires != null) ...[
                      const SizedBox(width: 8),
                      Text(_expiryLabel(expires),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10,
                              color: expired ? Colors.redAccent : _muted)),
                    ],
                    const SizedBox(width: 5),
                    Icon(Icons.expand_more_rounded, color: _muted, size: 18),
                  ]))));
    }
    return Padding(
        padding: EdgeInsets.fromLTRB(14, 0, 14, 11),
        child: Container(
            width: double.infinity,
            padding: EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: _subscriptionInfoSurface,
                borderRadius: BorderRadius.circular(17),
                border: Border.all(color: Colors.white.withOpacity(.11))),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (!hasInfo)
                Text('Провайдер не передал данные о трафике и сроке',
                    style: TextStyle(color: _muted, fontSize: 11)),
              if (used != null || total != null) ...[
                Row(children: [
                  Icon(Icons.data_usage_rounded, color: _accent, size: 17),
                  SizedBox(width: 7),
                  Expanded(
                      child: Text(
                          total == 0
                              ? 'Без лимита · ${_formatBytes(used ?? 0)} использовано'
                              : total != null
                                  ? '${_formatBytes(used ?? 0)} из ${_formatBytes(total)}'
                                  : 'Использовано ${_formatBytes(used ?? 0)}',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600))),
                  if (total != null && total > 0 && used != null)
                    Text('${(progress! * 100).round()}%',
                        style: TextStyle(color: _muted, fontSize: 11)),
                  IconButton(
                      tooltip: 'Свернуть детали',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints.tightFor(width: 30, height: 30),
                      onPressed: () => setState(() =>
                          collapsedSubscriptionInfo.add(sub['url'] as String)),
                      icon: Icon(Icons.expand_less_rounded,
                          size: 19, color: _muted)),
                ]),
                if (progress != null) ...[
                  SizedBox(height: 9),
                  ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 5,
                          backgroundColor: Colors.white.withOpacity(.1),
                          valueColor: AlwaysStoppedAnimation(
                              progress >= .9 ? Color(0xFFFFB087) : _accent))),
                ],
              ],
              if (expires != null ||
                  metadata.deviceLimit != null ||
                  metadata.updateIntervalHours != null) ...[
                SizedBox(height: 11),
                Wrap(spacing: 12, runSpacing: 7, children: [
                  if (expires != null)
                    _metadataBadge(Icons.event_rounded, _expiryLabel(expires),
                        expired ? Color(0xFFFFA3A3) : _muted),
                  if (metadata.deviceLimit != null)
                    _metadataBadge(Icons.devices_rounded,
                        'До ${metadata.deviceLimit} устройств', _muted),
                  if (metadata.updateIntervalHours != null)
                    _metadataBadge(
                        Icons.sync_rounded,
                        'Совет провайдера: ${metadata.updateIntervalHours} ч',
                        _muted),
                ]),
              ],
              if (metadata.description?.isNotEmpty == true) ...[
                SizedBox(height: 10),
                Text(metadata.description!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: _muted, fontSize: 11)),
              ],
              if (metadata.announcement?.isNotEmpty == true) ...[
                SizedBox(height: 10),
                InkWell(
                    onTap: () => showDialog<void>(
                        context: context,
                        builder: (_) => AlertDialog(
                                title: Text('Сообщение провайдера'),
                                content: SelectableText(metadata.announcement!),
                                actions: [
                                  TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: Text('Закрыть'))
                                ])),
                    child: Row(children: [
                      Icon(Icons.campaign_outlined, color: _accent, size: 17),
                      SizedBox(width: 7),
                      Expanded(
                          child: Text(metadata.announcement!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: _accent, fontSize: 11))),
                      Icon(Icons.chevron_right_rounded,
                          color: _accent, size: 16),
                    ])),
              ],
              if (sub['updatedAt'] is String) ...[
                SizedBox(height: 8),
                Text('Обновлено ${_updatedLabel(sub['updatedAt'] as String)}',
                    style: TextStyle(color: _muted, fontSize: 10)),
              ],
              if (metadata.websiteUrl != null ||
                  metadata.supportUrl != null) ...[
                SizedBox(height: 9),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  if (metadata.websiteUrl != null)
                    TextButton.icon(
                        onPressed: () => _openProviderUrl(metadata.websiteUrl),
                        icon: Icon(Icons.language_rounded, size: 16),
                        label: Text('Сайт')),
                  if (metadata.supportUrl != null)
                    TextButton.icon(
                        onPressed: () => _openProviderUrl(metadata.supportUrl),
                        icon: Icon(Icons.support_agent_rounded, size: 16),
                        label: Text('Поддержка')),
                ]),
              ],
            ])));
  }

  String _updatedLabel(String value) {
    final date = DateTime.tryParse(value)?.toLocal();
    if (date == null) return 'недавно';
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')} в ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  Widget _metadataBadge(IconData icon, String text, Color color) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 14),
        SizedBox(width: 5),
        Text(text, style: TextStyle(color: color, fontSize: 10)),
      ]);

  Future<void> _showProfileJson(ServerProfile profile) async {
    final isXrayTun = Platform.isLinux &&
        coreSettings.core == 'xray' &&
        (coreSettings.connectionMode == 'tun' ||
            coreSettings.connectionMode == 'mixed');
    var runtimeProfile = profile;
    if (isXrayTun) {
      try {
        runtimeProfile = await _resolveXrayTunnelProfile(profile);
      } on Object catch (error) {
        _message('Не удалось подготовить TUN-конфиг: $error');
        return;
      }
    }
    runtimeProfile = await _withDeviceMetadata(runtimeProfile);
    final runtimePort = activeLocalPort ?? coreSettings.localPort;
    final xraySettings = coreSettings.copyWith(
        connectionMode:
            Platform.isLinux ? 'proxy' : coreSettings.connectionMode,
        localPort: runtimePort);
    final xrayBackend =
        CoreProcessBackend(name: 'xray', executable: '', configPath: '')
          ..settings = xraySettings;
    final singBoxSettings = coreSettings.copyWith(localPort: runtimePort);
    final singBoxBackend =
        CoreProcessBackend(name: 'sing-box', executable: '', configPath: '')
          ..settings = singBoxSettings;
    final singBoxLabel =
        profile.network == 'xhttp' || profile.network == 'splithttp'
            ? 'sing-box · требуется with_xhttp'
            : 'sing-box · полный конфиг';
    final configs = <String, Map<String, dynamic>>{
      'Профиль': profile.toJson(),
      'Xray · полный конфиг': xrayBackend.makeConfig(runtimeProfile),
      singBoxLabel: singBoxBackend.makeConfig(runtimeProfile),
    };
    if (isXrayTun) {
      final bridgeProfile = ServerProfile(
        id: 'ghostbox-xray-tun-bridge',
        name: 'GhostBox TUN bridge',
        protocol: 'socks',
        address: '127.0.0.1',
        port: runtimePort,
        raw: {
          '_tunBridge': true,
          '_tunExcludeAddresses':
              runtimeProfile.raw['_tunExcludeAddresses'] ?? const [],
        },
      );
      final bridgeBackend =
          CoreProcessBackend(name: 'sing-box', executable: '', configPath: '')
            ..settings = coreSettings.copyWith(
                core: 'sing-box', connectionMode: coreSettings.connectionMode);
      configs['Linux TUN · sing-box'] = bridgeBackend.makeConfig(bridgeProfile);
    }
    var selectedConfig = isXrayTun
        ? 'Xray · полный конфиг'
        : coreSettings.core == 'xray'
            ? 'Xray · полный конфиг'
            : singBoxLabel;
    String configText() =>
        const JsonEncoder.withIndent('  ').convert(configs[selectedConfig]);
    var json = configText();
    await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
              builder: (context, setDialogState) => AlertDialog(
                backgroundColor: _surface,
                title: Text(profile.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                content: SizedBox(
                  width: 620,
                  height: MediaQuery.sizeOf(context).height * .62,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DropdownButton<String>(
                        value: selectedConfig,
                        isExpanded: true,
                        items: configs.keys
                            .map((key) => DropdownMenuItem(
                                value: key,
                                child:
                                    Text(key, overflow: TextOverflow.ellipsis)))
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          setDialogState(() {
                            selectedConfig = value;
                            json = configText();
                          });
                        },
                      ),
                      if (selectedConfig == 'Профиль')
                        Text(
                            'Это краткая карточка сервера для хранения и обмена. Для запуска ядру нужен полный конфиг ниже.',
                            style: TextStyle(color: _muted, fontSize: 11)),
                      if (isXrayTun && selectedConfig == 'Xray · полный конфиг')
                        Text(
                            'Xray обслуживает прокси; Linux TUN-маршрут находится во вкладке sing-box ниже.',
                            style: TextStyle(color: _muted, fontSize: 11)),
                      if ((profile.network == 'xhttp' ||
                              profile.network == 'splithttp') &&
                          selectedConfig == singBoxLabel)
                        Text(
                            'Установленный sing-box собран без XHTTP. Для этого транспорта используй Xray или собери sing-box с with_xhttp.',
                            style: TextStyle(color: _muted, fontSize: 11)),
                      const SizedBox(height: 8),
                      Expanded(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: .18),
                              borderRadius: BorderRadius.circular(14)),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(12),
                            child: SelectableText(json,
                                style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    height: 1.45)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: json));
                        if (context.mounted) Navigator.pop(context);
                        _message('Полный JSON скопирован');
                      },
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text('Копировать')),
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Готово')),
                ],
              ),
            ));
  }

  Future<ServerProfile> _withDeviceMetadata(ServerProfile profile) async {
    final headers = await DeviceIdentity.transportHeaders;
    return ServerProfile(
      id: profile.id,
      name: profile.name,
      protocol: profile.protocol,
      address: profile.address,
      port: profile.port,
      uuid: profile.uuid,
      network: profile.network,
      security: profile.security,
      raw: {...profile.raw, '_ghostboxHeaders': headers},
    );
  }

  Future<void> _copyProfileLink(ServerProfile profile) async {
    final compactJson = jsonEncode(profile.toJson());
    final payload =
        base64Url.encode(utf8.encode(compactJson)).replaceAll('=', '');
    final link = 'GhostBox://addserver?b64=$payload';
    await Clipboard.setData(ClipboardData(text: link));
    _message('GhostBox-ссылка сервера скопирована');
  }

  Widget _profileTile(ServerProfile profile,
      {bool grouped = false, bool divider = false}) {
    final selectedServer = selectedId == profile.id;
    final tile = InkWell(
        borderRadius: BorderRadius.circular(15),
        onTap: () async {
          final shouldSwitch = backend.state == VpnState.connected &&
              activeProfileId != profile.id;
          setState(() {
            selectedId = profile.id;
            _probeGeneration++;
            checkingPing = false;
            if (shouldSwitch) pendingReconnect = true;
            pingMs = null;
            pingSamples = [];
          });
          await _persist();
          if (shouldSwitch) {
            await _switchActiveServer();
          } else if (coreSettings.autoPing && mounted) {
            _checkConnection();
          }
        },
        child: Padding(
            padding: EdgeInsets.symmetric(vertical: 1),
            child: AnimatedContainer(
              duration: Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              margin: EdgeInsets.all(selectedServer ? 5 : 0),
              padding: const EdgeInsets.fromLTRB(9, 9, 5, 9),
              decoration: BoxDecoration(
                  color: selectedServer
                      ? Colors.white.withOpacity(.10)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(15)),
              child: Row(children: [
                _countryBadge(profile),
                SizedBox(width: 10),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(profile.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                              fontSize: 13)),
                      SizedBox(height: 2),
                      Text(
                          '${profile.protocol.toUpperCase()} · ${_transportLabel(profile.network)}${profile.security == 'reality' ? ' · REALITY' : profile.security == 'tls' ? ' · TLS' : ''}',
                          style: TextStyle(
                              color: _muted, fontSize: 10, letterSpacing: .4)),
                    ])),
                if (failedLatencies.contains(profile.id))
                  Text('—', style: TextStyle(color: _muted, fontSize: 12)),
                if (profileLatencies[profile.id] != null)
                  Text('${profileLatencies[profile.id]} мс',
                      style: TextStyle(
                          color: profileLatencies[profile.id]! < 180
                              ? _mint
                              : _muted,
                          fontSize: 11)),
                PopupMenuButton<String>(
                    tooltip: 'Действия с сервером',
                    icon: Icon(Icons.more_horiz_rounded, color: Colors.white70),
                    onSelected: (value) async {
                      if (value == 'ping') {
                        await _checkOneProfile(profile);
                        return;
                      }
                      if (value == 'json') {
                        await _showProfileJson(profile);
                        return;
                      }
                      if (value == 'share') {
                        await _copyProfileLink(profile);
                        return;
                      }
                      if (value == 'delete') {
                        if (backend.state != VpnState.disconnected) {
                          _message('Сначала отключите ядро');
                          return;
                        }
                        setState(() =>
                            profiles.removeWhere((p) => p.id == profile.id));
                        if (selectedId == profile.id)
                          selectedId = profiles.firstOrNull?.id;
                        await _persist();
                      }
                    },
                    itemBuilder: (_) => [
                          PopupMenuItem(
                              value: 'ping',
                              child: Row(children: [
                                Icon(Icons.speed_rounded,
                                    size: 18, color: _accent),
                                const SizedBox(width: 12),
                                const Text('Проверить задержку')
                              ])),
                          PopupMenuItem(
                              value: 'json',
                              child: Row(children: [
                                Icon(Icons.data_object_rounded,
                                    size: 18, color: _accent),
                                const SizedBox(width: 12),
                                const Text('Посмотреть JSON')
                              ])),
                          PopupMenuItem(
                              value: 'share',
                              child: Row(children: [
                                Icon(Icons.link_rounded,
                                    size: 18, color: _accent),
                                const SizedBox(width: 12),
                                const Text('Скопировать GhostBox-ссылку')
                              ])),
                          PopupMenuItem(
                              value: 'delete',
                              child: Row(children: [
                                Icon(Icons.delete_outline_rounded,
                                    size: 18, color: _muted),
                                const SizedBox(width: 12),
                                const Text('Удалить сервер')
                              ]))
                        ]),
              ]),
            )));
    if (grouped)
      return ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            tile,
            if (divider)
              Padding(
                  padding: EdgeInsets.only(left: 56),
                  child:
                      Divider(height: 1, color: Colors.white.withOpacity(.07)))
          ]));
    return ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: AnimatedContainer(
                duration: Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
                margin: EdgeInsets.only(bottom: 7),
                decoration: BoxDecoration(
                    color: selectedServer
                        ? _accent.withValues(alpha: .15)
                        : _surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                        color: selectedServer
                            ? Color(0xAA8BCBFF)
                            : Colors.white.withOpacity(.12)),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withOpacity(.1),
                          blurRadius: 18,
                          offset: Offset(0, 8))
                    ]),
                child: tile)));
  }

  Widget _countryBadge(ServerProfile profile) {
    final name = profile.name;
    String code = '';
    final runes = name.runes.take(2).toList();
    if (runes.length == 2 && runes.every((r) => r >= 0x1F1E6 && r <= 0x1F1FF)) {
      code = String.fromCharCodes(runes.map((r) => r - 127397));
    }
    final value = name.toLowerCase();
    final countries = {
      'нидер': 'NL',
      'netherlands': 'NL',
      'nl': 'NL',
      'герман': 'DE',
      'german': 'DE',
      'de': 'DE',
      'швец': 'SE',
      'swed': 'SE',
      'se': 'SE',
      'финлян': 'FI',
      'finland': 'FI',
      'fi': 'FI',
      'сша': 'US',
      'usa': 'US',
      'us': 'US',
      'эстон': 'EE',
      'estonia': 'EE',
      'ee': 'EE',
      'латв': 'LV',
      'latvia': 'LV',
      'lv': 'LV',
      'франц': 'FR',
      'france': 'FR',
      'fr': 'FR',
      'япон': 'JP',
      'japan': 'JP',
      'jp': 'JP',
      'британ': 'GB',
      'kingdom': 'GB',
      'gb': 'GB',
      'польш': 'PL',
      'poland': 'PL',
      'pl': 'PL',
      'турц': 'TR',
      'turkey': 'TR',
      'tr': 'TR',
      'росс': 'RU',
      'russia': 'RU',
      'ru': 'RU',
      'канада': 'CA',
      'canada': 'CA',
      'ca': 'CA',
    };
    if (code.isEmpty) {
      for (final entry in countries.entries) {
        final words = value.toUpperCase().split(RegExp(r'[^A-Z]+'));
        if (entry.key.length > 2
            ? value.contains(entry.key)
            : words.contains(entry.key.toUpperCase())) {
          code = entry.value;
          break;
        }
      }
    }
    final isCountry = code.isNotEmpty;
    final colors = {
      'NL': Color(0xFFEF8F9B),
      'DE': Color(0xFFE5B86D),
      'SE': Color(0xFF73B9F5),
      'FI': Color(0xFF91C9FF),
      'US': Color(0xFFB5A4FF),
      'EE': Color(0xFF83D5D2),
      'LV': Color(0xFFE6A3B6),
      'FR': Color(0xFF9DA8FF),
      'JP': Color(0xFFF39B9B),
      'GB': Color(0xFF9B9FFF),
      'PL': Color(0xFFFFAAB0),
      'TR': Color(0xFFE9808D),
      'RU': Color(0xFF9BA8FF),
      'CA': Color(0xFFFF9B9B),
    };
    final tint = colors[code] ?? _accent;
    return Container(
        width: 34,
        height: 27,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [tint.withOpacity(.42), tint.withOpacity(.12)]),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: tint.withOpacity(.5))),
        child: isCountry
            ? Text(code,
                style: TextStyle(
                    fontSize: 10,
                    letterSpacing: .4,
                    color: Colors.white,
                    fontWeight: FontWeight.w800))
            : Icon(_serverIcon(profile.protocol),
                color: Colors.white, size: 15));
  }

  IconData _serverIcon(String protocol) => switch (protocol.toLowerCase()) {
        'vless' => Icons.hub_rounded,
        'vmess' => Icons.bolt_rounded,
        'trojan' => Icons.shield_rounded,
        'shadowsocks' => Icons.lock_rounded,
        'hysteria' || 'hysteria2' || 'tuic' => Icons.waves_rounded,
        _ => Icons.dns_rounded,
      };

  String _transportLabel(String network) => switch (network) {
        'xhttp' || 'splithttp' => 'XHTTP',
        'grpc' => 'gRPC',
        'ws' || 'websocket' => 'WS',
        'httpupgrade' => 'HTTP Upgrade',
        'kcp' || 'mkcp' => 'mKCP',
        'quic' => 'QUIC',
        'http' => 'HTTP',
        _ => 'TCP',
      };

  Future<void> _saveCore(CoreSettings value,
      {bool requiresReconnect = true}) async {
    setState(() {
      if (value.pingMode != coreSettings.pingMode ||
          value.pingCount != coreSettings.pingCount ||
          value.pingTimeoutSeconds != coreSettings.pingTimeoutSeconds) {
        _probeGeneration++;
        pingMs = null;
        pingSamples = [];
        checkingPing = false;
      }
      coreSettings = value;
      if (requiresReconnect && backend.state == VpnState.connected)
        pendingReconnect = true;
    });
    final p = prefs ??= await SharedPreferences.getInstance();
    await p.setString('coreSettings', jsonEncode(value.toJson()));
  }

  Future<void> _applyRoutingSettings(CoreSettings value) async {
    if (backend.state == VpnState.connecting) {
      _message('Подождите завершения подключения');
      return;
    }
    final reconnect = backend.state == VpnState.connected;
    if (reconnect) {
      switchingServer = true;
      if (mounted) setState(() {});
    }
    try {
      if (reconnect) await _disconnectActive();
      await _saveCore(value);
      process?.settings = coreSettings;
      if (reconnect && selected != null) {
        await _toggle(allowDuringSwitch: true);
      }
    } finally {
      if (reconnect) {
        switchingServer = false;
        pendingReconnect = false;
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> _selectDnsResolver(String choice) async {
    if (choice != 'custom') {
      await _saveCore(coreSettings.copyWith(dns: choice));
      return;
    }
    final controller =
        TextEditingController(text: coreSettings.customDnsResolver);
    final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              backgroundColor: _surface,
              title: const Text('Свой DNS-резолвер'),
              content: TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'IP или URL резолвера',
                  hintText: '1.1.1.1 · https://dns.example/dns-query',
                  helperText: 'IP = UDP · также tcp:// и DNS-over-HTTPS',
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Отмена')),
                FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, controller.text.trim()),
                    child: const Text('Сохранить')),
              ],
            ));
    controller.dispose();
    if (value == null) return;
    if (!_validDnsResolver(value)) {
      _message('Укажите IP, IP:порт или URL DNS-over-HTTPS');
      return;
    }
    await _saveCore(
        coreSettings.copyWith(dns: 'custom', customDnsResolver: value.trim()));
  }

  Future<void> _editProxyGetUrl() async {
    final controller = TextEditingController(text: coreSettings.proxyGetUrl);
    final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              backgroundColor: _surface,
              title: const Text('Ссылка для Proxy GET'),
              content: TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  hintText: 'https://httpbin.org/status/404',
                  helperText:
                      'Любой HTTP-ответ считается успехом. По умолчанию сервер отвечает 404.',
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Отмена')),
                FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, controller.text.trim()),
                    child: const Text('Сохранить')),
              ],
            ));
    controller.dispose();
    if (value == null) return;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !const ['http', 'https'].contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      _message('Введи полную ссылку, начинающуюся с http:// или https://');
      return;
    }
    await _saveCore(coreSettings.copyWith(proxyGetUrl: uri.toString()),
        requiresReconnect: false);
  }

  bool _validDnsResolver(String value) {
    final input = value.trim();
    if (InternetAddress.tryParse(input) != null) return true;
    final uri = Uri.tryParse(input.contains('://') ? input : 'udp://$input');
    if (uri == null || uri.host.isEmpty) return false;
    if (input.contains('://') &&
        !{'https', 'tcp', 'udp'}.contains(uri.scheme.toLowerCase())) {
      return false;
    }
    return InternetAddress.tryParse(uri.host) != null ||
        CoreSettings.isValidDomain(uri.host);
  }

  Future<void> _setDnsBlacklistMode(String mode) async {
    if (mode != 'ads') {
      await _saveCore(coreSettings.copyWith(
          dnsBlacklistMode: mode, blocklistEnabled: mode != 'none'));
      return;
    }
    if (loadingAdBlocklist) return;
    setState(() => loadingAdBlocklist = true);
    var refreshCache = false;
    try {
      var domains = await dnsAdBlocklist.readCache();
      final fromCache = domains.isNotEmpty;
      if (!fromCache) domains = await dnsAdBlocklist.update();
      if (domains.isEmpty) {
        throw const FormatException('DNS-список не содержит доменов');
      }
      await _saveCore(coreSettings.copyWith(
          dnsBlacklistMode: 'ads',
          blocklistEnabled: true,
          adBlockDomains: domains));
      refreshCache = fromCache;
      if (mounted) {
        _message(fromCache
            ? 'Блок рекламы включён · ${domains.length} доменов из кэша'
            : 'Блок рекламы включён · ${domains.length} доменов');
      }
    } on Object catch (error) {
      if (mounted) {
        _message('Не удалось загрузить список рекламы: $error');
      }
    } finally {
      if (mounted) {
        setState(() => loadingAdBlocklist = false);
        if (refreshCache) unawaited(_refreshAdBlocklist(silent: true));
      }
    }
  }

  Future<void> _refreshAdBlocklist({bool silent = false}) async {
    if (loadingAdBlocklist) return;
    if (mounted) setState(() => loadingAdBlocklist = true);
    try {
      final domains = await dnsAdBlocklist.update();
      if (!mounted || coreSettings.dnsBlacklistMode != 'ads') return;
      final changed = !listEquals(coreSettings.adBlockDomains, domains);
      if (changed) {
        await _saveCore(coreSettings.copyWith(adBlockDomains: domains));
      }
      if (!silent && mounted) {
        _message(changed
            ? 'Список рекламы обновлён · ${domains.length} доменов'
            : 'Список рекламы актуален · ${domains.length} доменов');
      }
    } on Object catch (error) {
      if (!silent && mounted) {
        _message('Не удалось обновить список рекламы: $error');
      }
    } finally {
      if (mounted) setState(() => loadingAdBlocklist = false);
    }
  }

  Future<void> _editDomains(String title, List<String> current,
      CoreSettings Function(List<String>) update) async {
    final controller = TextEditingController(text: current.join('\n'));
    final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                backgroundColor: _surface,
                title: Text(title),
                content: SizedBox(
                    width: 440,
                    child: TextField(
                        controller: controller,
                        autofocus: true,
                        minLines: 5,
                        maxLines: 10,
                        decoration: InputDecoration(
                            hintText: 'example.com\ntracker.example.org',
                            helperText:
                                'Один домен на строку · действует и для поддоменов'))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text('Отмена')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, controller.text),
                      child: Text('Сохранить'))
                ]));
    controller.dispose();
    if (result == null) return;
    final values = result
        .split(RegExp(r'[\s,;]+'))
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();
    final invalid =
        values.where((e) => !CoreSettings.isValidDomain(e)).toList();
    if (invalid.isNotEmpty) {
      _message('Неверный домен: ${invalid.first}');
      return;
    }
    await _saveCore(update(values.toSet().toList()));
  }

  Widget _settings() => ListView(
          controller: settingsScroll,
          key: PageStorageKey('settings'),
          padding: EdgeInsets.only(bottom: 24),
          children: [
            SizedBox(height: 12),
            Text('Настройки',
                style: TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.7)),
            SizedBox(height: 5),
            Text('Управление локальным прокси и ядром',
                style: TextStyle(color: _muted, fontSize: 13)),
            SizedBox(height: 24),
            Container(
                padding: EdgeInsets.all(4),
                decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.065),
                    borderRadius: BorderRadius.circular(17),
                    border: Border.all(color: Colors.white.withOpacity(.09))),
                child: Row(children: [
                  _segment('Основные', !advanced,
                      () => setState(() => advanced = false)),
                  _segment('Для профи', advanced,
                      () => setState(() => advanced = true)),
                ])),
            if (pendingReconnect) ...[
              SizedBox(height: 16),
              Container(
                  padding: EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color: _accent.withOpacity(.13),
                      borderRadius: BorderRadius.circular(17),
                      border: Border.all(color: _accent.withOpacity(.35))),
                  child: Row(children: [
                    Icon(Icons.info_outline_rounded, color: _accent, size: 19),
                    SizedBox(width: 10),
                    Expanded(
                        child: Text(
                            'Изменения вступят в силу после переподключения',
                            style: TextStyle(fontSize: 12))),
                    TextButton(
                        onPressed: () async {
                          await _disconnectActive();
                          await _toggle();
                        },
                        child: Text('Применить')),
                  ])),
            ],
            SizedBox(height: 22),
            AnimatedSwitcher(
                duration: Duration(milliseconds: 280),
                transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SizeTransition(sizeFactor: animation, child: child)),
                child: advanced ? _advancedSettings() : _basicSettings()),
            SizedBox(height: 18),
            _section('GHOSTBOX'),
            InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: _showAbout,
                child: _row(
                    Icons.info_outline_rounded,
                    'О приложении',
                    'Сборка, ядра и устройство',
                    const Icon(Icons.chevron_right_rounded))),
          ]);

  Future<String> _coreVersion(String name) async {
    try {
      final executable = coreExecutable(name, 'vendor');
      if (!File(executable).existsSync()) return 'Не найдено';
      final result = await Process.run(executable, ['version'])
          .timeout(const Duration(seconds: 3));
      final output = '${result.stdout}\n${result.stderr}'
          .split('\n')
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty, orElse: () => 'Неизвестно');
      return result.exitCode == 0 ? output : 'Недоступно';
    } on Object {
      return 'Недоступно';
    }
  }

  Future<void> _showAbout() async {
    final model = await DeviceIdentity.deviceModel;
    final installId = await DeviceIdentity.installationId;
    final xray = await _coreVersion('xray');
    final singBox = await _coreVersion('sing-box');
    if (!mounted) return;

    const appVersion = '0.1.0-alpha.1';
    const buildNumber = '1';
    final buildMode = kReleaseMode
        ? 'Release'
        : kProfileMode
            ? 'Profile'
            : 'Debug';
    final dartVersion =
        RegExp(r'^\d+\.\d+\.\d+').firstMatch(Platform.version)?.group(0) ??
            'Неизвестно';
    final details = <(String, String)>[
      ('GhostBox', 'Alpha v$appVersion'),
      ('Номер сборки', buildNumber),
      ('Тип сборки', buildMode),
      (
        'Платформа сборки',
        '${Platform.operatingSystem} · ${DeviceIdentity.architecture}'
      ),
      ('Dart', dartVersion),
      ('Xray-core', xray),
      ('sing-box', singBox),
      ('Устройство', model),
      ('Операционная система', Platform.operatingSystem),
      ('Версия ОС', Platform.operatingSystemVersion),
      ('Архитектура', DeviceIdentity.architecture),
      ('ID устройства', installId),
    ];
    final report = details.map((item) => '${item.$1}: ${item.$2}').join('\n');

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
        backgroundColor: _surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 680),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: _accent.withOpacity(.14),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(Icons.shield_rounded, color: _accent),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('О GhostBox',
                            style: TextStyle(
                                fontSize: 19, fontWeight: FontWeight.w700)),
                        SizedBox(height: 2),
                        Text('Информация о сборке и устройстве',
                            style: TextStyle(fontSize: 11)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.pop(dialogContext),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ]),
                const SizedBox(height: 14),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      _section('СБОРКА'),
                      for (final item in details.take(5))
                        _aboutDetail(item.$1, item.$2),
                      const SizedBox(height: 10),
                      _section('ЯДРА'),
                      for (final item in details.skip(5).take(2))
                        _aboutDetail(item.$1, item.$2),
                      const SizedBox(height: 10),
                      _section('УСТРОЙСТВО'),
                      for (final item in details.skip(7))
                        _aboutDetail(item.$1, item.$2),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: report));
                      if (dialogContext.mounted) Navigator.pop(dialogContext);
                      _message('Сведения скопированы');
                    },
                    icon: const Icon(Icons.copy_rounded, size: 17),
                    label: const Text('Скопировать сведения'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _aboutDetail(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.045),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withOpacity(.055)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 4,
                child:
                    Text(label, style: TextStyle(color: _muted, fontSize: 11)),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 6,
                child: SelectableText(value,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      );

  Widget _basicSettings() => Column(
          key: ValueKey('basic'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ThemeSettingsPanel(),
            SizedBox(height: 24),
            _section('СОЕДИНЕНИЕ'),
            _row(
                Icons.settings_rounded,
                'Движок подключения',
                coreSettings.core == 'xray'
                    ? 'Xray · REALITY / XHTTP'
                    : 'sing-box',
                _menu(
                    coreSettings.core,
                    {'xray': 'Xray', 'sing-box': 'sing-box'},
                    (v) => _selectCore(v == 'xray' ? 'Xray' : 'sing-box'))),
            _row(
                Icons.power_rounded,
                'Способ подключения',
                switch (coreSettings.connectionMode) {
                  'system' => Platform.isWindows
                      ? 'Прокси Windows для поддерживаемых приложений'
                      : 'Системный прокси для приложений окружения',
                  'tun' => 'Весь трафик · нужны права сети',
                  'mixed' => 'TUN + локальный SOCKS/HTTP',
                  _ => 'Локальный SOCKS/HTTP прокси',
                },
                _menu(
                    coreSettings.connectionMode,
                    {
                      'proxy': 'Локальный прокси',
                      'system': 'Системный прокси',
                      'tun': 'TUN · весь трафик',
                      'mixed': 'Mixed · TUN + прокси',
                    },
                    _setConnectionMode)),
            _row(
                Icons.lan_rounded,
                'Локальный порт',
                coreSettings.autoLocalPort
                    ? 'Автоматически · ${activeLocalPort ?? "при подключении"}'
                    : '127.0.0.1:${coreSettings.localPort}',
                Row(mainAxisSize: MainAxisSize.min, children: [
                  _menu(
                      coreSettings.autoLocalPort ? 'auto' : 'manual',
                      const {'auto': 'Автовыбор', 'manual': 'Выбрать вручную'},
                      (value) => _saveCore(coreSettings.copyWith(
                          autoLocalPort: value == 'auto'))),
                  if (!coreSettings.autoLocalPort)
                    IconButton(
                        tooltip: 'Выбрать порт',
                        onPressed: _editPort,
                        icon: const Icon(Icons.edit_outlined)),
                ])),
            _row(
                Icons.alt_route_rounded,
                'Маршрутизация',
                _routingLabel(),
                IconButton(
                    tooltip: 'Открыть маршрутизацию',
                    onPressed: () => _openTab(1),
                    icon: const Icon(Icons.chevron_right_rounded))),
            _row(
                Icons.language_rounded,
                'Поиск адресов (DNS)',
                _dnsLabel(),
                _menu(
                    coreSettings.dns,
                    {
                      'system': 'Системный',
                      'cloudflare': 'Cloudflare',
                      'google': 'Google',
                      'combined': 'Cloudflare + Google',
                      'custom': 'Свой резолвер',
                    },
                    _selectDnsResolver)),
            if (coreSettings.dns == 'custom')
              _row(
                  Icons.dns_outlined,
                  'Адрес резолвера',
                  coreSettings.customDnsResolver,
                  IconButton(
                      tooltip: 'Изменить DNS-резолвер',
                      onPressed: () => _selectDnsResolver('custom'),
                      icon: const Icon(Icons.edit_outlined))),
            _row(
                Icons.shield_outlined,
                'DNS blacklist',
                _dnsBlacklistLabel(),
                _menu(
                    coreSettings.dnsBlacklistMode,
                    const {
                      'none': 'Нет',
                      'ads': 'Блок рекламы',
                      'custom': 'Кастом',
                    },
                    _setDnsBlacklistMode)),
            if (coreSettings.dnsBlacklistMode == 'custom')
              _row(
                  Icons.list_alt_rounded,
                  'Домены для блокировки',
                  '${coreSettings.blockedDomains.length} доменов',
                  IconButton(
                      tooltip: 'Изменить список',
                      onPressed: () => _editDomains(
                          'Домены для блокировки',
                          coreSettings.blockedDomains,
                          (v) => coreSettings.copyWith(blockedDomains: v)),
                      icon: const Icon(Icons.chevron_right_rounded))),
            if (coreSettings.dnsBlacklistMode == 'ads')
              _row(
                  Icons.ads_click_rounded,
                  'Список рекламы',
                  loadingAdBlocklist
                      ? 'Обновляется…'
                      : '${coreSettings.adBlockDomains.length} доменов · HaGeZi',
                  IconButton(
                      tooltip: 'Обновить список рекламы',
                      onPressed: loadingAdBlocklist
                          ? null
                          : () => _refreshAdBlocklist(),
                      icon: loadingAdBlocklist
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.refresh_rounded))),
            SizedBox(height: 14),
            _section('ПРИЛОЖЕНИЕ'),
            _row(
                Icons.power_rounded,
                'Автоподключение',
                'К выбранному серверу при открытии',
                _compactSwitch(
                    value: coreSettings.autoConnect,
                    onChanged: (v) => _saveCore(
                        coreSettings.copyWith(autoConnect: v),
                        requiresReconnect: false))),
            _row(
                Icons.memory_rounded,
                'Память ядра',
                'Мягкий бюджет · ${coreSettings.memoryMb} МБ',
                SizedBox(
                    width: 145,
                    child: _compactSlider(
                        value: coreSettings.memoryMb.toDouble(),
                        min: 64,
                        max: 256,
                        divisions: 12,
                        onChanged: (v) => _saveCore(
                            coreSettings.copyWith(memoryMb: v.round()))))),
            if (Platform.isLinux)
              _row(
                  Icons.monitor_heart_rounded,
                  'Показывать расход RAM',
                  'Текущая память Xray / sing-box на главном экране',
                  _compactSwitch(
                      value: coreSettings.showRamUsage,
                      onChanged: (value) {
                        if (!value) coreMemoryMb = null;
                        _saveCore(coreSettings.copyWith(showRamUsage: value),
                            requiresReconnect: false);
                        if (value) unawaited(_refreshCoreMemoryUsage());
                      })),
            SizedBox(height: 14),
            SizedBox(height: 14),
            _section('ПРОВЕРКА СЕРВЕРА'),
            _row(
                Icons.speed_rounded,
                'Как проверять',
                switch (coreSettings.pingMode) {
                  'icmp' => 'ICMP · проверка адреса',
                  'tcp' => 'TCP · проверка порта сервера',
                  _ => 'Proxy GET · ответ через туннель',
                },
                _menu(
                    coreSettings.pingMode,
                    {
                      'proxy': 'Proxy GET · через прокси',
                      'tcp': 'TCP · порт',
                      'icmp': 'ICMP · адрес'
                    },
                    (v) => _saveCore(coreSettings.copyWith(pingMode: v),
                        requiresReconnect: false))),
            _row(
                Icons.visibility_outlined,
                'Показывать результат',
                coreSettings.pingView == 'full'
                    ? 'Время и оценку'
                    : coreSettings.pingView == 'number'
                        ? 'Только миллисекунды'
                        : 'Только оценку',
                _menu(
                    coreSettings.pingView,
                    {
                      'full': 'Время и оценка',
                      'number': 'Миллисекунды',
                      'quality': 'Оценка'
                    },
                    (v) => _saveCore(coreSettings.copyWith(pingView: v),
                        requiresReconnect: false))),
            _row(
                Icons.repeat_rounded,
                'Число проб',
                '${coreSettings.pingCount} · показываем медиану',
                _menu(
                    '${coreSettings.pingCount}',
                    {'1': '1', '3': '3', '5': '5'},
                    (v) => _saveCore(
                        coreSettings.copyWith(pingCount: int.parse(v)),
                        requiresReconnect: false))),
            SizedBox(height: 14),
            _section('ПОДПИСКИ'),
            _row(
                Icons.rss_feed_rounded,
                'Источники',
                '${subscriptions.length} подписок',
                IconButton(
                    tooltip: 'Добавить подписку',
                    onPressed: _showAddMenu,
                    icon: Icon(Icons.add_rounded))),
            _row(
                Icons.sync_rounded,
                'Обновить все',
                'Перезагрузить профили из URL',
                IconButton(
                    tooltip: 'Обновить все',
                    onPressed:
                        subscriptions.isEmpty ? null : _refreshAllSubscriptions,
                    icon: Icon(Icons.refresh_rounded))),
            _row(
                Icons.autorenew_rounded,
                'Автообновление',
                autoRefreshSubscriptions
                    ? 'При запуске и каждые $autoRefreshHours ч'
                    : 'Выключено',
                _compactSwitch(
                    value: autoRefreshSubscriptions,
                    onChanged: _setAutoRefresh)),
            if (autoRefreshSubscriptions)
              _row(
                  Icons.schedule_rounded,
                  'Интервал',
                  'Обновлять подписки раз в $autoRefreshHours ч',
                  _menu(
                      '$autoRefreshHours',
                      {
                        '1': 'Каждый час',
                        '6': 'Каждые 6 ч',
                        '12': 'Каждые 12 ч',
                        '24': 'Раз в сутки'
                      },
                      (value) => _setAutoRefreshHours(int.parse(value)))),
          ]);

  Widget _advancedSettings() => Column(
          key: ValueKey('advanced'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _section('ЯДРО'),
            Row(children: [
              _choice('sing-box', process?.name == 'sing-box',
                  () => _selectCore('sing-box')),
              _choice(
                  'Xray', process?.name == 'xray', () => _selectCore('Xray')),
            ]),
            SizedBox(height: 12),
            _section('XHTTP · ДЛЯ ПРОФИ'),
            _row(
                Icons.cleaning_services_rounded,
                'Быстрее закрывать соединения',
                'Раньше очищает простаивающие XHTTP-сессии; может увеличить переподключения и расход батареи.',
                _compactSwitch(
                    value: coreSettings.aggressiveXhttpCleanup,
                    onChanged: (v) => _saveCore(
                        coreSettings.copyWith(aggressiveXhttpCleanup: v)))),
            _row(
                Icons.memory_rounded,
                'Память ядра',
                '${coreSettings.memoryMb} МБ · 64–256 МБ',
                SizedBox(
                    width: 145,
                    child: _compactSlider(
                        value: coreSettings.memoryMb.toDouble(),
                        min: 64,
                        max: 256,
                        divisions: 12,
                        onChanged: (v) => _saveCore(
                            coreSettings.copyWith(memoryMb: v.round()))))),
            _row(
                Icons.notes_rounded,
                'Уровень журнала',
                'Диагностика ядра',
                _menu(
                    coreSettings.logLevel,
                    {
                      'error': 'Ошибки',
                      'warning': 'Предупреждения',
                      'info': 'Подробно'
                    },
                    (v) => _saveCore(coreSettings.copyWith(logLevel: v)))),
            _row(
                Icons.lan_rounded,
                'Локальный порт',
                coreSettings.autoLocalPort
                    ? 'Автовыбор · ${activeLocalPort ?? "при подключении"}'
                    : '127.0.0.1:${coreSettings.localPort}',
                Row(mainAxisSize: MainAxisSize.min, children: [
                  _menu(
                      coreSettings.autoLocalPort ? 'auto' : 'manual',
                      const {'auto': 'Автовыбор', 'manual': 'Вручную'},
                      (value) => _saveCore(coreSettings.copyWith(
                          autoLocalPort: value == 'auto'))),
                  if (!coreSettings.autoLocalPort)
                    IconButton(
                        tooltip: 'Изменить порт',
                        onPressed: _editPort,
                        icon: const Icon(Icons.edit_outlined)),
                ])),
            SizedBox(height: 15),
            _section('ПРАВИЛА МАРШРУТИЗАЦИИ'),
            _row(
                Icons.alt_route_rounded,
                'Режим',
                _routingLabel(),
                _menu(
                    coreSettings.routing,
                    {
                      'proxy': 'Всё через VPN',
                      'rules': 'Только из списка',
                      'exclude': 'Всё, кроме списка'
                    },
                    (v) => _applyRoutingSettings(
                        coreSettings.copyWith(routing: v)))),
            _row(
                coreSettings.routing == 'rules'
                    ? Icons.shield_outlined
                    : Icons.public_rounded,
                coreSettings.routing == 'rules'
                    ? 'Сайты через VPN'
                    : 'Исключения из VPN',
                '${(coreSettings.routing == 'rules' ? coreSettings.proxyDomains : coreSettings.directDomains).length} правил',
                IconButton(
                    onPressed: () {
                      _openTab(1);
                      _openRouteList(coreSettings.routing == 'rules'
                          ? 'rules'
                          : 'exclude');
                    },
                    icon: const Icon(Icons.chevron_right_rounded))),
            SizedBox(height: 15),
            _section('DNS И ФИЛЬТРАЦИЯ'),
            _row(
                Icons.dns_rounded,
                'Резолвер',
                _dnsLabel(),
                _menu(
                    coreSettings.dns,
                    {
                      'system': 'Системный',
                      'cloudflare': 'Cloudflare DoH',
                      'google': 'Google DoH',
                      'combined': 'Cloudflare + Google',
                      'custom': 'Свой резолвер',
                    },
                    _selectDnsResolver)),
            if (coreSettings.dns == 'custom')
              _row(
                  Icons.dns_outlined,
                  'Адрес резолвера',
                  coreSettings.customDnsResolver,
                  IconButton(
                      tooltip: 'Изменить DNS-резолвер',
                      onPressed: () => _selectDnsResolver('custom'),
                      icon: const Icon(Icons.edit_outlined))),
            _row(
                Icons.lock_outline_rounded,
                'DoH через прокси',
                'Использовать прокси для DNS-запросов',
                _compactSwitch(
                    value: coreSettings.dnsThroughProxy,
                    onChanged: coreSettings.dns == 'system'
                        ? null
                        : (v) => _saveCore(
                            coreSettings.copyWith(dnsThroughProxy: v)))),
            _row(
                Icons.shield_outlined,
                'DNS blacklist',
                _dnsBlacklistLabel(),
                _menu(
                    coreSettings.dnsBlacklistMode,
                    const {
                      'none': 'Нет',
                      'ads': 'Блок рекламы',
                      'custom': 'Кастом',
                    },
                    _setDnsBlacklistMode)),
            if (coreSettings.dnsBlacklistMode == 'custom')
              _row(
                  Icons.block_rounded,
                  'Заблокированные домены',
                  '${coreSettings.blockedDomains.length} доменов',
                  IconButton(
                      tooltip: 'Изменить список',
                      onPressed: () => _editDomains(
                          'Домены для блокировки',
                          coreSettings.blockedDomains,
                          (v) => coreSettings.copyWith(blockedDomains: v)),
                      icon: const Icon(Icons.chevron_right_rounded))),
            if (coreSettings.dnsBlacklistMode == 'ads')
              _row(
                  Icons.ads_click_rounded,
                  'Список рекламы',
                  loadingAdBlocklist
                      ? 'Обновляется…'
                      : '${coreSettings.adBlockDomains.length} доменов · HaGeZi',
                  IconButton(
                      tooltip: 'Обновить список рекламы',
                      onPressed: loadingAdBlocklist
                          ? null
                          : () => _refreshAdBlocklist(),
                      icon: loadingAdBlocklist
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.refresh_rounded))),
            SizedBox(height: 15),
            _section('ПРОВЕРКА ЗАДЕРЖКИ'),
            _row(
                Icons.speed_rounded,
                'Тип проверки',
                switch (coreSettings.pingMode) {
                  'icmp' => 'ICMP · проверка адреса',
                  'tcp' => 'TCP · проверка порта',
                  _ => 'Proxy GET · ответ через туннель',
                },
                _menu(
                    coreSettings.pingMode,
                    {'proxy': 'Proxy GET', 'tcp': 'TCP', 'icmp': 'ICMP'},
                    (v) => _saveCore(coreSettings.copyWith(pingMode: v),
                        requiresReconnect: false))),
            if (coreSettings.pingMode == 'proxy')
              _row(
                  Icons.link_rounded,
                  'Ссылка для GET',
                  coreSettings.proxyGetUrl,
                  IconButton(
                      tooltip: 'Изменить ссылку проверки',
                      onPressed: _editProxyGetUrl,
                      icon: const Icon(Icons.edit_outlined))),
            _row(
                Icons.timer_outlined,
                'Таймаут',
                '${coreSettings.pingTimeoutSeconds} секунды на пробу',
                _menu(
                    '${coreSettings.pingTimeoutSeconds}',
                    {'2': '2 секунды', '4': '4 секунды', '8': '8 секунд'},
                    (v) => _saveCore(
                        coreSettings.copyWith(pingTimeoutSeconds: int.parse(v)),
                        requiresReconnect: false))),
            _row(
                Icons.repeat_rounded,
                'Число проб',
                '${coreSettings.pingCount} · медианное значение',
                _menu(
                    '${coreSettings.pingCount}',
                    {'1': '1', '3': '3', '5': '5'},
                    (v) => _saveCore(
                        coreSettings.copyWith(pingCount: int.parse(v)),
                        requiresReconnect: false))),
            SizedBox(height: 15),
            _section('ДИАГНОСТИКА'),
            Container(
                width: double.infinity,
                padding: EdgeInsets.all(18),
                decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.055),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withOpacity(.1))),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          process?.executableAvailable == true
                              ? '● Ядро найдено'
                              : '● Ядро не найдено',
                          style: TextStyle(
                              color: process?.executableAvailable == true
                                  ? _mint
                                  : Colors.orangeAccent,
                              fontSize: 12)),
                      SizedBox(height: 8),
                      Text(
                          process?.lastError ??
                              'Локальный SOCKS/HTTP прокси. Системный TUN не включён.',
                          style: TextStyle(color: _muted, fontSize: 11)),
                      const SizedBox(height: 8),
                      Row(children: [
                        TextButton.icon(
                            onPressed: _showConnectionHistory,
                            icon: const Icon(Icons.history_rounded, size: 16),
                            label: Text(
                                'Подключения ${connectionHistory.length}/10')),
                        const Spacer(),
                        TextButton.icon(
                            onPressed: _showLogs,
                            icon: const Icon(Icons.article_outlined, size: 16),
                            label: const Text('Файл журнала')),
                      ]),
                      if (process?.logs.isNotEmpty == true) ...[
                        SizedBox(height: 12),
                        for (final line in process!.logs.reversed.take(5))
                          Padding(
                              padding: EdgeInsets.only(bottom: 4),
                              child: Text(line,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      TextStyle(color: _muted, fontSize: 10))),
                      ],
                    ])),
          ]);

  String _routingLabel() => switch (coreSettings.routing) {
        'rules' => 'Только домены из списка через VPN',
        'exclude' => 'Всё через VPN, кроме списка',
        _ => 'Весь трафик через VPN',
      };
  String _dnsLabel() => switch (coreSettings.dns) {
        'cloudflare' => 'Cloudflare · DoH',
        'google' => 'Google · DoH',
        'combined' => 'Cloudflare + Google',
        'custom' => coreSettings.customDnsResolver,
        _ => 'Системный DNS',
      };

  String _dnsBlacklistLabel() => switch (coreSettings.dnsBlacklistMode) {
        'ads' => loadingAdBlocklist
            ? 'Обновляется…'
            : 'Блок рекламы · ${coreSettings.adBlockDomains.length}',
        'custom' => 'Кастом · ${coreSettings.blockedDomains.length} доменов',
        _ => 'Нет',
      };
  Widget _menu(String value, Map<String, String> choices,
          ValueChanged<String> onChanged) =>
      PopupMenuButton<String>(
          tooltip: 'Выбрать',
          onSelected: onChanged,
          icon: Icon(Icons.unfold_more_rounded, size: 20, color: _accent),
          itemBuilder: (_) => choices.entries
              .map((e) => PopupMenuItem(value: e.key, child: Text(e.value)))
              .toList());

  Future<void> _editPort() async {
    final controller = TextEditingController(text: '${coreSettings.localPort}');
    final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                backgroundColor: _surface,
                title: Text('Локальный порт'),
                content: TextField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration:
                        InputDecoration(helperText: 'От 1024 до 65535')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text('Отмена')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, controller.text),
                      child: Text('Сохранить'))
                ]));
    controller.dispose();
    if (result == null) return;
    final value = int.tryParse(result);
    if (value == null || value < 1024 || value > 65535) {
      _message('Порт должен быть от 1024 до 65535');
      return;
    }
    await _saveCore(
        coreSettings.copyWith(localPort: value, autoLocalPort: false));
  }

  Future<bool> _refreshSubscription(
      [String? sourceUrl, bool silent = false]) async {
    final url = sourceUrl ?? subscriptionUrl;
    if (url == null) return false;
    try {
      final parsed = await ProfileParser().parseSourceDetailed(url);
      final fresh = parsed.profiles;
      if (fresh.isEmpty) throw FormatException('Профиль не найден');
      if (!mounted) return false;
      setState(() {
        final group = subscriptions.firstWhere((s) => s['url'] == url,
            orElse: () => {'url': url, 'ids': subscriptionProfileIds});
        final oldIds = (group['ids'] as List? ?? []).cast<String>().toSet();
        final previousActive =
            profiles.where((p) => p.id == activeProfileId).firstOrNull;
        final refreshedActive =
            fresh.where((p) => p.id == activeProfileId).firstOrNull;
        if (backend.state == VpnState.connected &&
            previousActive != null &&
            refreshedActive != null &&
            jsonEncode(previousActive.toJson()) !=
                jsonEncode(refreshedActive.toJson())) {
          pendingReconnect = true;
        }
        profiles = [...profiles.where((e) => !oldIds.contains(e.id)), ...fresh];
        group['ids'] = fresh.map((e) => e.id).toList();
        group['metadata'] = parsed.metadata.toJson();
        group['updatedAt'] = DateTime.now().toIso8601String();
        if (group['customName'] != true && parsed.metadata.title != null)
          group['name'] = parsed.metadata.title;
        if (!subscriptions.any((s) => s['url'] == url))
          subscriptions.add(group);
        subscriptionProfileIds = subscriptions
            .expand((s) => (s['ids'] as List? ?? []).cast<String>())
            .toSet()
            .toList();
        if (selectedId == null ||
            (oldIds.contains(selectedId) &&
                !fresh.any((p) => p.id == selectedId))) {
          selectedId = fresh.first.id;
          if (backend.state == VpnState.connected) pendingReconnect = true;
        }
      });
      await _persist();
      await prefs?.setStringList(
          'subscriptionProfileIds', subscriptionProfileIds);
      await prefs?.setString('subscriptions', jsonEncode(subscriptions));
      if (mounted && !silent)
        _message('Подписка обновлена: ${fresh.length} серверов');
      return true;
    } catch (e) {
      if (mounted && !silent)
        _message(
            'Ошибка обновления подписки. Проверьте подключение и повторите.');
      return false;
    }
  }

  Widget _section(String text) => Padding(
      padding: EdgeInsets.only(bottom: 10),
      child: Text(text.toUpperCase(),
          style: TextStyle(
              color: _muted,
              fontSize: 10,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w700)));
  Widget _choice(String name, bool active, VoidCallback onTap) => Expanded(
      child: Padding(
          padding: EdgeInsets.only(right: 8),
          child: OutlinedButton(
              onPressed: onTap,
              style: OutlinedButton.styleFrom(
                  backgroundColor: active ? _accent.withOpacity(.17) : _surface,
                  foregroundColor: active ? Colors.white : _muted,
                  side: BorderSide(color: active ? _accent : _line),
                  padding: EdgeInsets.all(17)),
              child: Text(name))));
  Widget _row(IconData icon, String title, String subtitle, Widget trailing) =>
      Container(
          margin: EdgeInsets.only(bottom: 8),
          padding: EdgeInsets.symmetric(horizontal: 15, vertical: 12),
          decoration: BoxDecoration(
              color: _surface, borderRadius: BorderRadius.circular(16)),
          child: Row(children: [
            Icon(icon, color: _accent),
            SizedBox(width: 13),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(title),
                  Text(subtitle, style: TextStyle(color: _muted, fontSize: 11))
                ])),
            trailing
          ]));

  Widget _compactSwitch(
          {required bool value, required ValueChanged<bool>? onChanged}) =>
      Transform.scale(
          scale: .86,
          alignment: Alignment.centerRight,
          child: CupertinoSwitch(value: value, onChanged: onChanged));

  Widget _compactSlider({
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double>? onChanged,
  }) =>
      TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: value, end: value),
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOutCubic,
          builder: (context, animatedValue, _) => Transform.scale(
              scaleY: .78,
              child: CupertinoSlider(
                  value: animatedValue.clamp(min, max).toDouble(),
                  min: min,
                  max: max,
                  divisions: divisions,
                  onChanged: onChanged)));
  Widget _nav() => Container(
      height: 84,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(27),
          border: Border.all(color: Colors.white.withOpacity(.15)),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(.2),
                blurRadius: 28,
                offset: const Offset(0, 12))
          ]),
      child: LayoutBuilder(builder: (context, bounds) {
        final itemWidth = bounds.maxWidth / 3;
        return Stack(children: [
          AnimatedPositioned(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              left: itemWidth * _tabIndex,
              top: 0,
              bottom: 0,
              width: itemWidth,
              child: Container(
                  decoration: BoxDecoration(
                      gradient: LinearGradient(
                          colors: [_accent.withValues(alpha: .20), _surface]),
                      borderRadius: BorderRadius.circular(21),
                      border: Border.all(color: _accent.withOpacity(.4)),
                      boxShadow: [
                    BoxShadow(color: _accent.withOpacity(.14), blurRadius: 18)
                  ]))),
          Row(children: [
            _navItem(Icons.shield_outlined, 'Подключение', 0),
            _navItem(Icons.alt_route_rounded, 'Маршрут', 1),
            _navItem(Icons.tune_rounded, 'Настройки', 2),
          ]),
        ]);
      }));
  Widget _navItem(IconData icon, String label, int index) => Expanded(
      child: GestureDetector(
          onTap: () => _openTab(index),
          child: AnimatedContainer(
              duration: Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              margin: EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(20)),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AnimatedScale(
                        scale: _tabIndex == index ? 1.08 : 1,
                        duration: Duration(milliseconds: 250),
                        child: Icon(icon,
                            size: 24,
                            color: _tabIndex == index ? Colors.white : _muted)),
                    SizedBox(height: 5),
                    Text(label,
                        style: TextStyle(
                            color: _tabIndex == index ? Colors.white : _muted,
                            fontSize: 11,
                            fontWeight: _tabIndex == index
                                ? FontWeight.w600
                                : FontWeight.w400))
                  ]))));
  Widget _segment(String label, bool active, VoidCallback onTap) => Expanded(
      child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
              duration: Duration(milliseconds: 250),
              padding: EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(
                  color: active ? _line : Colors.transparent,
                  borderRadius: BorderRadius.circular(13)),
              alignment: Alignment.center,
              child: Text(label,
                  style: TextStyle(
                      color: active ? Colors.white : _muted,
                      fontWeight:
                          active ? FontWeight.w600 : FontWeight.normal)))));
}

class _OrbRings extends CustomPainter {
  const _OrbRings(
      {required this.progress,
      required this.color,
      required this.active,
      required this.connecting});
  final double progress;
  final Color color;
  final bool active, connecting;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final quiet = !active || connecting;
    for (var i = 0; i < 3; i++) {
      final phase = (progress + i / 3) % 1;
      final radius = quiet ? 91.0 + i * 8 : 75.0 + i * 9 + phase * 12;
      final alpha = quiet ? .055 : .09 + (1 - phase) * .06;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = quiet ? 1 : 1.5
        ..color = color.withValues(alpha: alpha);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _OrbRings old) =>
      old.progress != progress ||
      old.active != active ||
      old.connecting != connecting;
}

class _SocketByteReader {
  _SocketByteReader(Socket socket)
      : _iterator = StreamIterator<List<int>>(socket);

  final StreamIterator<List<int>> _iterator;
  final List<int> _buffer = [];

  Future<List<int>> read(int count) async {
    while (_buffer.length < count) {
      if (!await _iterator.moveNext()) {
        throw const SocketException('Proxy closed before replying');
      }
      _buffer.addAll(_iterator.current);
    }
    final result = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return result;
  }

  Future<String> readLine(int maxBytes) async {
    final bytes = <int>[];
    while (bytes.length < maxBytes) {
      final byte = (await read(1)).single;
      if (byte == 10) break;
      bytes.add(byte);
    }
    return ascii.decode(bytes, allowInvalid: true).trim();
  }

  Future<void> close() => _iterator.cancel();
}
