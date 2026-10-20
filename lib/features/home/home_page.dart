import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show kProfileMode, kReleaseMode, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:app_links/app_links.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../backends/sing_box_backend.dart';
import '../../backends/android_vpn_backend.dart';
import '../../backends/xray_backend.dart';
import '../../backends/core_path.dart';
import '../../core/core_process.dart';
import '../../core/vpn_backend.dart';
import '../../models/server_profile.dart';
import '../../models/core_settings.dart';
import '../../models/subscription_metadata.dart';
import '../../platform/system_proxy.dart';
import '../../platform/windows_elevation.dart';
import '../../platform/linux_kill_switch.dart';
import '../../services/profile_parser.dart';
import '../../services/device_identity.dart';
import '../../services/dns_ad_blocklist.dart';
import '../../services/github_updater.dart';
import '../../services/log_store.dart';
import '../../services/traffic_stats.dart';
import '../../theme/theme_settings_panel.dart';
import '../../theme/theme_controller.dart';
import '../../theme/brand_icon.dart';
import '../../theme/glass_switch.dart';
import '../../widgets/ghost_notice.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static final Set<String> _countryFlagCodes =
      ('AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW')
          .split(' ')
          .toSet();
  final homeScroll = ScrollController();
  final settingsScroll = ScrollController();
  final routingScroll = ScrollController();
  final routeListController = TextEditingController();
  final routeDomainController = TextEditingController();
  bool refreshingSubscriptions = false;
  Timer? subscriptionRefreshTimer;
  DateTime? subscriptionRetryNotBefore;
  Color get _surface => Theme.of(context).colorScheme.surface;
  Color get _subscriptionInfoSurface =>
      Color.alphaBlend(Colors.white.withValues(alpha: .035), _surface);
  Color get _accent => Theme.of(context).colorScheme.primary;
  Color get _foreground => Theme.of(context).colorScheme.onSurface;
  Color get _line => Theme.of(context).colorScheme.outlineVariant;
  Color get _muted => Theme.of(context).colorScheme.onSurfaceVariant;
  Color get _mint => Color(0xFF77D6B0);
  late final AnimationController glow;
  late final AnimationController ambientMotion;
  bool animatedBackground = true;
  bool english = false;
  bool powerHovered = false;
  VpnBackend backend = XrayBackend();
  CoreProcessBackend? tunnelBridgeBackend;
  bool xrayTunnelBridgeActive = false;
  int? activeLocalPort;
  SharedPreferences? prefs;
  List<ServerProfile> profiles = [];
  String? selectedId;
  bool settings = false, routingTab = false, advanced = false;
  String? settingsSubpage;
  Future<List<(String, String)>>? _aboutDetailsFuture;
  int trafficRangeDays = 7;
  final GlobalKey _settingsModeKey = GlobalKey();
  bool _draggingSettingsMode = false;
  final GlobalKey _bottomNavKey = GlobalKey();
  final GlobalKey _sideNavKey = GlobalKey();
  bool _draggingTabIndicator = false;
  int? _hoveredNavTab;
  bool _headerButtonHovered = false;
  int get _tabIndex => settings
      ? 2
      : routingTab
          ? 1
          : 0;
  CoreSettings coreSettings = CoreSettings(memoryMb: Platform.isIOS ? 32 : 128);
  final DnsAdBlocklist dnsAdBlocklist = DnsAdBlocklist();
  bool loadingAdBlocklist = false;
  List<String> customDnsBlocklistUrls = <String>[];
  final DesktopSystemProxy systemProxy = DesktopSystemProxy();
  bool pendingReconnect = false;
  bool applyingReconnect = false;
  bool switchingServer = false;
  String? activeProfileId;
  String? connectionIssue;
  final List<String> appLogs = <String>[];
  final List<Map<String, dynamic>> connectionHistory = <Map<String, dynamic>>[];
  Future<void> _logWriteQueue = Future<void>.value();
  String? logFilePath;
  int logRetainedConnections = 10;
  int logMaxSizeMb = 5;
  bool logCoreOutput = true;
  String? subscriptionUrl;
  List<String> subscriptionProfileIds = [];
  List<Map<String, dynamic>> subscriptions = [];
  final Map<String, int> subscriptionEndpointPings = <String, int>{};
  final Set<String> checkingSubscriptionPings = <String>{};
  final List<Uri> _pendingAppLinks = <Uri>[];
  final Set<String> _handledAppLinks = <String>{};
  StreamSubscription<Uri>? _appLinkSubscription;
  bool hideProfiles = false;
  final Set<String> collapsedSubscriptions = <String>{};
  final Set<String> collapsedSubscriptionInfo = <String>{};
  bool routeListOpen = false;
  String? routeListMode;
  bool autoRefreshSubscriptions = true;
  bool autoUpdateApp = false;
  bool checkingAppUpdate = false;
  bool installingAppUpdate = false;
  String? appUpdateStatus;
  GhostBoxRelease? availableAppRelease;
  final GitHubUpdater appUpdater = GitHubUpdater();
  final TrafficStats trafficStats = TrafficStats();
  final Set<String> _speedTestProfiles = <String>{};
  final Map<String, double> _profileDownloadSpeeds = <String, double>{};
  static const int _defaultSubscriptionRefreshHours = 12;
  Timer? uptimeTicker;
  int? coreMemoryMb;
  bool readingCoreMemory = false;
  int? pingMs;
  List<int> pingSamples = [];
  final Map<String, int> profileLatencies = {};
  final Map<String, String> latencyErrors = {};
  final Set<String> _checkingProfileIds = <String>{};
  bool checkingPing = false;
  bool checkingAll = false;
  int pingAllDone = 0, pingAllTotal = 0;
  final Set<String> failedLatencies = {};
  int _probeGeneration = 0;
  CoreProcessBackend? get process =>
      backend is CoreProcessBackend ? backend as CoreProcessBackend : null;
  ServerProfile? get selected =>
      profiles.where((p) => p.id == selectedId).firstOrNull;
  String _text(String ru, String en) => english ? en : ru;
  String _localized(String value) => _messageText(value);

  static const _englishLabels = <String, String>{
    'Подключение': 'Connection',
    'Настройки': 'Settings',
    'Маршрут': 'Routing',
    'Список доменов': 'Domain list',
    'Основные': 'Basic',
    'Для профи': 'Advanced',
    'Контакты': 'Contacts',
    'О релизе': 'About this release',
    'О GhostBox': 'About GhostBox',
    'Информация о сборке и устройстве': 'Build and device information',
    'Сведения о сборке, ядрах и устройстве':
        'Build, core and device information',
    'Открыть': 'Open',
    'Управление локальным прокси и ядром': 'Manage the local proxy and core',
    'Соединение': 'Connection',
    'ЯДРО': 'CORE',
    'Движок подключения': 'Core engine',
    'Xray · рекомендуется': 'Xray · recommended',
    'Способ подключения': 'Connection mode',
    'Режим маршрутизации': 'Routing mode',
    'Поиск адресов (DNS)': 'DNS resolver',
    'Системный DNS': 'System DNS',
    'Системный': 'System',
    'Свой резолвер': 'Custom resolver',
    'Блокировка доменов': 'Domain blocking',
    'Список блокировки': 'Block list',
    'Домены и их поддомены': 'Domains and subdomains',
    'ПРИЛОЖЕНИЕ': 'APP',
    'Автоподключение': 'Connect on launch',
    'К выбранному серверу при открытии':
        'Connect to the selected server when opened',
    'Анимированный фон': 'Animated background',
    'Мягкое движение цветового свечения': 'Subtle ambient color animation',
    'Выключен · меньше графической нагрузки': 'Off · lower graphics usage',
    'Язык интерфейса': 'Language',
    'Сканировать QR-код': 'Scan QR code',
    'Сканировать QR': 'Scan QR',
    'Показывать расход RAM': 'Show RAM usage',
    'Память ядра': 'Core memory',
    'Мягкий бюджет': 'Soft memory budget',
    'Низкий бюджет': 'Low memory target',
    'Уровень журнала': 'Log level',
    'ФРАГМЕНТАЦИЯ TLS': 'TLS FRAGMENTATION',
    'Фрагментация TLS ClientHello': 'Fragment TLS ClientHello',
    'Разбивать TLS handshake на части': 'Split TLS handshake into fragments',
    'Тип фрагментации': 'Fragment type',
    'Размер фрагментов': 'Fragment size',
    'Интервал между частями': 'Fragment interval',
    'TLS hello или первые TCP отправки': 'TLS hello or first TCP writes',
    'TLS hello или первые записи TCP': 'TLS hello or first TCP writes',
    'В байтах · Xray': 'Bytes · Xray',
    'В миллисекундах · Xray': 'Milliseconds · Xray',
    'Sing-box · другая стратегия разделения':
        'Sing-box · alternate TLS splitting strategy',
    'TLS hello': 'TLS hello',
    'Первые 3 отправки': 'First 3 writes',
    '200 мс': '200 ms',
    '500 мс': '500 ms',
    '1000 мс': '1000 ms',
    '0': '0',
    '5–10': '5–10',
    '10–20': '10–20',
    '20–30': '20–30',
    '50–100': '50–100',
    '100–200': '100–200',
    '200–300': '200–300',
    'Фрагментация TLS-записей': 'Fragment TLS records',
    'Резервная задержка': 'Fallback delay',
    'РАСШИРЕННЫЕ ПАРАМЕТРЫ ЯДРА': 'ADVANCED CORE OPTIONS',
    'Анализ протоколов': 'Protocol sniffing',
    'Нужен для доменных правил маршрутизации':
        'Required for domain based routing rules',
    'TCP Fast Open': 'TCP Fast Open',
    'Ускоряет TCP handshake, если поддерживается ОС':
        'Can reduce TCP handshake latency when supported by the OS',
    'Фрагментация UDP': 'UDP fragmentation',
    'Может помочь с крупными UDP-пакетами; зависит от ядра и ОС':
        'May help with large UDP packets; support depends on core and OS',
    'Фрагментация отключена': 'Fragmentation is off',
    'Параметры вступят в силу после переподключения':
        'Settings take effect after reconnecting',
    'ПО ДНЯМ · ПОСЛЕДНЯЯ НЕДЕЛЯ': 'DAILY · LAST 7 DAYS',
    'ИСТОРИЯ ТРАФИКА': 'TRAFFIC HISTORY',
    'Скорость сейчас ↓': 'Current download ↓',
    'Скорость сейчас ↑': 'Current upload ↑',
    'Пик за запуск': 'Peak since app launch',
    'Ошибки': 'Errors',
    'Предупреждения': 'Warnings',
    'Подробно': 'Verbose',
    'Локальный порт': 'Local port',
    'Автовыбор': 'Automatic',
    'Вручную': 'Manual',
    'ПРАВИЛА МАРШРУТИЗАЦИИ': 'ROUTING RULES',
    'Всё через VPN': 'All traffic through VPN',
    'Только из списка': 'Only listed domains',
    'Всё, кроме списка': 'Everything except listed domains',
    'Сайты через VPN': 'Domains through VPN',
    'Исключения из VPN': 'VPN exclusions',
    'DNS И ФИЛЬТРАЦИЯ': 'DNS & FILTERING',
    'Резолвер': 'Resolver',
    'Cloudflare DoH': 'Cloudflare DoH',
    'Google DoH': 'Google DoH',
    'Cloudflare + Google': 'Cloudflare + Google',
    'DoH через прокси': 'DoH through proxy',
    'Использовать прокси для DNS-запросов': 'Route DNS requests through proxy',
    'DNS blacklist': 'DNS block list',
    'Нет': 'Off',
    'Блок рекламы': 'Ad blocking',
    'Кастом': 'Custom',
    'Список рекламы': 'Ad block list',
    'ПРОВЕРКА ЗАДЕРЖКИ': 'LATENCY CHECK',
    'Тип проверки': 'Check type',
    'Proxy GET': 'Proxy GET',
    'TCP': 'TCP',
    'ICMP': 'ICMP',
    'Ссылка для GET': 'GET test URL',
    'Таймаут': 'Timeout',
    'Число проб': 'Number of probes',
    'ДИАГНОСТИКА': 'DIAGNOSTICS',
    'Ядро найдено': 'Core found',
    'Ядро не найдено': 'Core not found',
    'Файл журнала': 'Log file',
    'Последние подключения': 'Recent connections',
    '5 подключений': '5 sessions',
    '10 подключений': '10 sessions',
    '25 подключений': '25 sessions',
    '50 подключений': '50 sessions',
    '100 подключений': '100 sessions',
    '1 МБ': '1 MB',
    '2 МБ': '2 MB',
    '5 МБ': '5 MB',
    '10 МБ': '10 MB',
    '25 МБ': '25 MB',
    'ПОДПИСКИ': 'SUBSCRIPTIONS',
    'ЖУРНАЛ': 'JOURNAL',
    'Хранить подключения': 'Keep sessions',
    'Максимальный размер': 'Maximum size',
    'Подробные логи ядра': 'Detailed core logs',
    'В файл записываются сообщения Xray и sing-box':
        'Record Xray and sing-box output to the file',
    'В файле останутся события приложения': 'Keep app events only',
    'Удалить записи из файла журнала': 'Delete journal file records',
    'Принудительная установка': 'Force update',
    'Повторно скачать и установить последнюю версию':
        'Download and reinstall the latest release',
    'Проверить обновления': 'Check for updates',
    'Проверить версию на GitHub': 'Check GitHub for a newer version',
    'Источники': 'Sources',
    'Обновить все': 'Refresh all',
    'Автообновление': 'Auto refresh',
    'ДАННЫЕ ПРИЛОЖЕНИЯ': 'APP DATA',
    'JSON настроек ядра': 'Core settings JSON',
    'Посмотреть или изменить полный набор параметров':
        'View or edit all core parameters',
    'Сбросить настройки': 'Reset settings',
    'Сбросить ядро, тему и поведение приложения':
        'Reset core, theme and app preferences',
    'Вернуть параметры ядра к исходным': 'Restore default core parameters',
    'Удалить все серверы': 'Delete all servers',
    'Очистить серверы и подписки': 'Clear servers and subscriptions',
    'Подписки, серверы из них и отдельные профили будут удалены с этого устройства.':
        'Subscriptions, their servers and standalone profiles will be removed from this device.',
    'Удалить профили и подписки с этого устройства':
        'Remove profiles and subscriptions from this device',
    'Оформление': 'Appearance',
    'Настроить свою тему': 'Customize theme',
    'Поддержка': 'Support',
    'Сайт': 'Website',
    'Сохранить': 'Save',
    'Отмена': 'Cancel',
    'Проверено серверов': 'Servers checked',
    'Скрыть серверы': 'Hide servers',
    'Показать серверы': 'Show servers',
    'Добавить подписку или сервер': 'Add subscription or server',
    'Проверить текущую задержку': 'Check connection',
    'ПЕРЕКЛЮЧАЕМ': 'SWITCHING',
    'ПОДКЛЮЧАЕМ': 'CONNECTING',
    'НАЖМИТЕ': 'TAP TO CONNECT',
    'Переключение сервера': 'Switching server',
    'Локальный прокси запущен': 'Local proxy is running',
    'Выберите сервер': 'Choose a server',
    'Пока нет серверов': 'No servers yet',
    'Добавьте ссылку или подписку, чтобы начать':
        'Add a server link or subscription to get started',
    'Новый выбор ждёт переподключения':
        'Your new server selection is waiting to reconnect',
    'Применить': 'Apply',
    'Домен, маска или IP-сеть на строку. Подойдут *.ru, 10.0.0.0/8 и JSON-списки Amnezia.':
        'One domain pattern or IP network per line. Supports *.ru, 10.0.0.0/8 and Amnezia JSON lists.',
    'ИЗМЕНЕНИЯ': 'CHANGES',
    'СОЕДИНЕНИЕ': 'CONNECTION',
    'ЗАЩИТА ТРАФИКА': 'TRAFFIC PROTECTION',
    'Журнал соединения': 'Connection log',
    'Скопировать журнал': 'Copy log',
    'Экспорт полного журнала': 'Export full journal',
    'Проверка не прошла': 'Probe failed',
    'Очистить журнал': 'Clear journal',
    'Закрыть': 'Close',
    'Записей пока нет': 'No log entries yet',
    'Попыток подключения пока нет': 'No connection attempts yet',
    'Добавить подписку': 'Add subscription',
    'Один или несколько URL': 'One or more URLs',
    'Импортировать профиль': 'Import profile',
    'Ссылка · JSON-файл · буфер обмена': 'Link · JSON file · clipboard',
    'Из буфера': 'From clipboard',
    'JSON-файл': 'JSON file',
    'Добавить': 'Add',
    'Новая подписка': 'New subscription',
    'Название (необязательно)': 'Name (optional)',
    'Например, Личная подписка': 'For example, Personal subscription',
    'URL подписки': 'Subscription URL',
    'Можно добавить несколько URL, по одному на строку':
        'Add multiple URLs, one per line',
    'Вставить из буфера': 'Paste from clipboard',
    'Путь подписки': 'Subscription URL',
    'Обновить': 'Refresh',
    'Название подписки': 'Subscription name',
    'Один раз разреши TUN': 'Allow TUN once',
    'Скопировать как JSON': 'Copy as JSON',
    'Сохранить список': 'Save list',
    'Переподключи ядро, чтобы применить маршрут.':
        'Reconnect the core to apply routing.',
    'Сообщение провайдера': 'Provider message',
    'Готово': 'Done',
    'Копировать': 'Copy',
    'Проверить задержку': 'Check latency',
    'Посмотреть JSON': 'View JSON',
    'Скопировать GhostBox-ссылку': 'Copy GhostBox link',
    'Скопировать IP/домен': 'Copy IP/domain',
    'Скопировать порт': 'Copy port',
    'Скопировать адрес и порт': 'Copy address and port',
    'Скопировано в буфер обмена': 'Copied to clipboard',
    'Порт скопирован': 'Port copied',
    'Пинг все': 'Ping all',
    'Логи': 'Logs',
    'История': 'History',
    'Удалить сервер': 'Delete server',
    'Свой DNS-резолвер': 'Custom DNS resolver',
    'Ссылка для Proxy GET': 'Proxy GET URL',
    'Скопировать сведения': 'Copy information',
    'Скопировать ссылку': 'Copy link',
    'Проверить и применить': 'Validate and apply',
    'Сбросить настройки приложения?': 'Reset app settings?',
    'Вернутся стандартные параметры ядра, тема и поведение приложения. Серверы останутся.':
        'Core settings, theme and app preferences will be reset. Servers will remain.',
    'Сбросить': 'Reset',
    'Удалить серверы и подписки?': 'Delete servers and subscriptions?',
    'Все добавленные серверы, источники подписок и их сведения будут удалены с этого устройства.':
        'All servers, subscription sources and their metadata will be removed from this device.',
    'Удалить всё': 'Delete all',
    'Kill Switch восстановлен; системный трафик вне TUN заблокирован':
        'Kill Switch restored; system traffic outside TUN is blocked',
    'Не удалось восстановить Kill Switch': 'Could not restore Kill Switch',
    'Kill Switch в Linux работает только в режиме TUN или Mixed.':
        'Kill Switch on Linux only works in TUN or Mixed mode.',
    'Kill Switch активен: разрешён TUN и endpoint выбранного VPN':
        'Kill Switch is active: TUN and the selected VPN endpoint are allowed',
    'Kill Switch доступен только в Linux.':
        'Kill Switch is available on Linux only.',
    'Kill Switch требует режим TUN или Mixed.':
        'Kill Switch requires TUN or Mixed mode.',
    'Добавить сервер': 'Add server',
    'Сброс': 'Reset',
    'IP или URL резолвера': 'Resolver IP or URL',
    'IP = UDP · также tcp:// и DNS-over-HTTPS':
        'IP = UDP · tcp:// and DNS-over-HTTPS are also supported',
    'СБОРКА': 'BUILD',
    'ЯДРА': 'CORES',
    'УСТРОЙСТВО': 'DEVICE',
    'XHTTP · ДЛЯ ПРОФИ': 'XHTTP · ADVANCED',
    'Время неизвестно': 'Time unknown',
    'Журнал пока пуст': 'The journal is empty',
    'Отключено': 'Disconnected',
    'Подключение установлено': 'Connection established',
    'HTTP GET через прокси': 'HTTP GET through proxy',
    'Проверка HTTPS/TLS через прокси прошла': 'HTTPS/TLS proxy check passed',
    'HTTPS и TLS-проверка системного маршрута TUN прошла':
        'HTTPS and TLS check through the system TUN route passed',
    'Процесс ядра запущен; проверяю маршрут и доступность сервера':
        'Core process started; checking the route and server availability',
    'Системный TUN-маршрут активен через sing-box':
        'System TUN route is active through sing-box',
    'TUN-интерфейс ghostbox0 поднят': 'TUN interface ghostbox0 is up',
    'TUN-интерфейс utun поднят': 'TUN interface utun is up',
    'Туннельный маршрутизатор sing-box остановился':
        'sing-box tunnel router stopped',
    'Windows не предоставила ядру права администратора для TUN. Закройте GhostBox, запустите его через «Запуск от имени администратора» и подтвердите запрос UAC.':
        'Windows did not grant the core administrator access for TUN. Close GhostBox, run it as administrator, and accept the UAC prompt.',
    'Windows не смогла загрузить sing-box или Wintun. Переустановите полный GhostBox Setup/ZIP: рядом с vendor/bin/sing-box.exe должны быть wintun.dll и библиотеки Visual C++.':
        'Windows could not load sing-box or Wintun. Reinstall the full GhostBox Setup/ZIP; wintun.dll and the Visual C++ runtime must be next to vendor/bin/sing-box.exe.',
    'macOS не разрешила ядру создать TUN. Подтвердите системный запрос администратора и повторите подключение.':
        'macOS did not allow the core to create a TUN interface. Accept the administrator prompt and try connecting again.',
    'Не удалось переподключиться': 'Could not reconnect',
    'Все подписки обновлены': 'All subscriptions updated',
    'Ошибка обновления подписки. Проверьте подключение и повторите.':
        'Subscription refresh failed. Check your connection and try again.',
    'ICMP не ответил. Попробуйте TCP в настройках.':
        'ICMP did not respond. Try TCP in Settings.',
    'Сервер не отвечает на выбранном порту.':
        'The server did not respond on the selected port.',
    'Автообновление приложения': 'App auto-update',
    'Отключи VPN, чтобы установить его.': 'Disconnect the VPN to install it.',
    'Ядро не выбрано': 'Core not selected',
    'RAM приложения': 'App RAM',
    'RAM ядра': 'Core RAM',
    'считаю…': 'measuring…',
    'Закрыть уведомление': 'Dismiss notification',
    'Для Kill Switch сначала выбери сервер.':
        'Select a server before enabling Kill Switch.',
    'Параметры ядра обновлены из JSON': 'Core settings updated from JSON',
    'Не удалось применить JSON': 'Could not apply JSON',
    'Сначала выключи Kill Switch для смены режима':
        'Turn off Kill Switch before changing mode',
    'Применение проверит типы и допустимые значения. Текущие параметры соединения сохранятся.':
        'Values and types will be validated. Current connection parameters will be preserved.',
    'Нужен JSON-объект': 'A JSON object is required',
    'Серверы и подписки удалены': 'Servers and subscriptions deleted',
    'Скопировать команду': 'Copy command',
    'Действия': 'Actions',
    'Открыть список правил': 'Open rules list',
    'Обновить подписку': 'Refresh subscription',
    'Действия с подпиской': 'Subscription actions',
    'Свернуть детали': 'Collapse details',
    'Действия с сервером': 'Server actions',
    'Выбрать порт': 'Select port',
    'Открыть маршрутизацию': 'Open routing',
    'Изменить DNS-резолвер': 'Change DNS resolver',
    'Изменить список': 'Edit list',
    'Обновить список рекламы': 'Refresh ad block list',
    'Изменить порт': 'Change port',
    'Изменить ссылку проверки': 'Change test URL',
    'Открыть JSON': 'Open JSON',
    'Выбрать': 'Select',
    'От 1024 до 65535': 'From 1024 to 65535',
    'Подписка удалена; серверы сохранены в «Мои профили»':
        'Subscription removed; servers remain in My Profiles',
    'Вставьте ссылку или JSON-конфиг сервера, либо выберите JSON-файл. Также можно добавить URL подписки.':
        'Paste a server link or JSON config, choose a JSON file, or add a subscription URL.',
    'Порт должен быть от 1024 до 65535': 'Port must be between 1024 and 65535',
    'Сначала добавьте и выберите сервер': 'Add and select a server first',
    'Сначала выберите сервер': 'Select a server first',
    'Подождите завершения подключения': 'Wait for the connection to finish',
    'Сначала выбери сервер': 'Select a server first',
    'Сначала отключите ядро': 'Stop the core first',
    'Сначала отключи Kill Switch': 'Turn off Kill Switch first',
    'Добавь один или несколько URL подписки':
        'Add one or more subscription URLs',
    'JSON должен содержать домены или IP-сети':
        'JSON must contain domains or IP networks',
    'Android подключает приложения через системный VPN (TUN)':
        'Android routes apps through its system VPN (TUN)',
    'На Android системный TUN работает через sing-box':
        'System TUN on Android uses sing-box',
    'Команда скопирована': 'Command copied',
    'Полный JSON скопирован': 'Full JSON copied',
    'GhostBox-ссылка сервера скопирована': 'GhostBox server link copied',
    'URL подписки скопирован': 'Subscription URL copied',
    'Короткая ссылка GhostBox скопирована': 'GhostBox short link copied',
    'Провайдер не указал корректную ссылку':
        'The provider did not supply a valid URL',
    'Не удалось открыть ссылку': 'Could not open the link',
    'Сведения скопированы': 'Information copied',
    'Настройки ядра сброшены': 'Core settings reset',
    'Укажите корректную HTTP или HTTPS ссылку':
        'Enter a valid HTTP or HTTPS URL',
    'Укажите IP, IP:порт или URL DNS-over-HTTPS':
        'Enter an IP, IP:port, or DNS-over-HTTPS URL',
    'Введи полную ссылку, начинающуюся с http:// или https://':
        'Enter a full URL starting with http:// or https://',
    'Подписка обновлена': 'Subscription updated',
    'Неверный домен': 'Invalid domain',
    'Не удалось применить изменения': 'Could not apply changes',
    'Не удалось переключить сервер': 'Could not switch server',
    'Не удалось подготовить TUN-конфиг': 'Could not prepare TUN config',
    'Не удалось обновить список рекламы': 'Could not refresh ad block list',
    'Не удалось загрузить список рекламы': 'Could not load ad block list',
    'Не удалось загрузить': 'Could not load',
    'Ошибка подключения': 'Connection error',
    'Нет серверов для проверки': 'No servers to check',
    'нет ответа': 'no response',
    'Запуск ядра не удался': 'Core failed to start',
    'Ядро завершилось с кодом': 'Core exited with code',
    'Сервер': 'Server',
    'Проверка через прокси не прошла': 'Proxy check failed',
    'занят. Смените порт в расширенных настройках.':
        'is in use. Choose another port in Advanced settings.',
    'Эта сборка sing-box не приняла XHTTP. Нужна сборка с тегом with_xhttp; штатная сборка GhostBox этот транспорт не содержит. Пока выберите Xray.':
        'This sing-box build rejected XHTTP. A build with the with_xhttp tag is required. Select Xray for now.',
    'Это ядро sing-box собрано без uTLS. Для REALITY выберите Xray.':
        'This sing-box build has no uTLS support. Select Xray for REALITY.',
    'Эта сборка sing-box не поддерживает uTLS. Отпечаток браузера не применяется; для него выберите Xray.':
        'This sing-box build does not support uTLS. The browser fingerprint is not applied; select Xray to use it.',
    'Локальный порт занят. Смените порт в расширенных настройках.':
        'The local port is in use. Choose another port in Advanced settings.',
    'Проверьте параметры REALITY в профиле: публичный ключ, SNI и short ID.':
        'Check the REALITY profile settings: public key, SNI and short ID.',
    'В профиле неверный UUID. Обновите подписку.':
        'The profile UUID is invalid. Refresh the subscription.',
    'TUN-маршрутизатор sing-box остановился': 'sing-box TUN router stopped',
    'Ядро неожиданно остановилось. Перезапускаю VPN…':
        'The core stopped unexpectedly. Restarting the VPN…',
    'Ядро завершилось сразу после запуска. Проверьте журнал и локальный порт.':
        'The core exited immediately after launch. Check the journal and local port.',
    'Автоперезапуски ядра исчерпаны': 'Core restart attempts exhausted',
    'Не удалось поднять ядро после трёх попыток.':
        'Could not start the core after three attempts.',
    'Неизвестная ошибка запуска ядра.': 'Unknown core startup error.',
    'Не удалось запустить ядро': 'Could not start the core',
    'Проверьте установленный файл ядра.':
        'Check that the core binary is installed.',
    'не запустилось; повторная попытка ': 'failed to start; retrying ',
    'Через ': 'In ',
    ' сек.': ' sec.',
    'Повторный запуск ядра ': 'Core restart ',
    ' не удался: ': ' failed: ',
    ' завершилось (код ': ' exited (code ',
    '); пробую поднять снова': '); trying to start it again',
    'Подключение: ': 'Connecting: ',
    'Подключено к ': 'Connected to ',
    'Профиль: ': 'Profile: ',
    'Диагностика подключения: ': 'Connection diagnostics: ',
    'Ошибка подключения: ': 'Connection error: ',
    'Проверяем…': 'Checking…',
    'Отлично': 'Excellent',
    'Хорошо': 'Good',
    'Средне': 'Fair',
    'Высокая задержка': 'High latency',
    'Проверка': 'Check',
    'Номер сборки': 'Build number',
    'Тип сборки': 'Build type',
    'Платформа сборки': 'Build platform',
    'Устройство': 'Device',
    'Операционная система': 'Operating system',
    'Версия ОС': 'OS version',
    'Архитектура': 'Architecture',
    'ID устройства': 'Device ID',
    'Неизвестно': 'Unknown',
    'Не найдено': 'Not found',
    'Версия недоступна': 'Version unavailable',
    'Недоступно': 'Unavailable',
    'недавно': 'recently',
    'Нет ответа ICMP': 'No ICMP response',
    'В ответе ping нет задержки': 'The ping response contains no latency',
    'Некорректная ссылка Proxy GET': 'Invalid Proxy GET URL',
    'Срок истёк': 'Expired',
    'На мобильных устройствах VPN-режим использует sing-box':
        'VPN mode on mobile devices uses sing-box',
    'Для iOS требуются sing-box, системный VPN (TUN) и TCP-проверка задержки.':
        'iOS requires sing-box, the system VPN (TUN), and TCP latency checks.',
    'На macOS доступны локальный прокси и системный прокси':
        'Local proxy and system proxy modes are available on macOS',
    'DNS-список не содержит доменов': 'The DNS list contains no domains',
    'Подписка не содержит профилей': 'The subscription contains no profiles',
    'Запусти команду в терминале после первого запуска AppImage. Сам VPN будет работать от твоего пользователя, без sudo.':
        'Run this command in a terminal after launching the AppImage once. The VPN itself will run as your user without sudo.',
    'Профиль не найден': 'Profile not found',
    'Пустая ссылка или конфиг': 'The link or config is empty',
    'Не удалось распознать ссылку, JSON или base64-подписку':
        'Could not recognize the link, JSON, or Base64 subscription',
    'JSON не содержит поддерживаемых серверных профилей':
        'JSON contains no supported server profiles',
    'JSON не содержит профилей': 'JSON contains no profiles',
    'В ссылке GhostBox нет URL или JSON сервера.':
        'The GhostBox link does not contain a server URL or JSON.',
    'Некорректная ссылка сервера': 'Invalid server link',
    'Некорректная ссылка Shadowsocks': 'Invalid Shadowsocks link',
    'Некорректный сервер Shadowsocks': 'Invalid Shadowsocks server',
    'В JSON-профиле нет address/server и port':
        'The JSON profile is missing address/server and port',
    'Некорректный ответ GitHub': 'Invalid response from GitHub',
    'Некорректный SHA-256': 'Invalid SHA-256 checksum',
    'SHA-256 пакета не совпал': 'Package SHA-256 checksum does not match',
    'DNS-листы пустые': 'DNS block lists are empty',
    'Укажите IP или URL DNS-резолвера.': 'Enter a DNS resolver IP or URL.',
    'Параметр XHTTP extra должен быть JSON.':
        'The XHTTP extra parameter must be JSON.',
    'Не удалось найти IP сервера': 'Could not resolve the server IP',
    'Ядро завершилось сразу после запуска':
        'The core exited immediately after launch',
    'Протокол': 'Protocol',
    'не поддерживается ядром': 'is not supported by the core',
    'Выберите совместимое ядро.': 'Choose a compatible core.',
    'У сервера неверный адрес или порт. Проверьте ссылку подписки.':
        'The server address or port is invalid. Check the subscription link.',
    'В профиле отсутствует корректный UUID. Обновите подписку или ссылку.':
        'The profile has no valid UUID. Refresh the subscription or link.',
    'XHTTP требует ядро Xray. Переключите ядро на Xray в настройках.':
        'XHTTP requires the Xray core. Select Xray in Settings.',
    'Защита': 'Security',
    'пока не поддерживается.': 'is not supported yet.',
    'В профиле REALITY нет корректного публичного ключа (pbk). Обновите подписку.':
        'The profile has no valid REALITY public key (pbk). Refresh the subscription.',
    'REALITY поддерживается здесь только для VLESS.':
        'REALITY is supported here only with VLESS.',
    'В профиле REALITY нет имени сервера (SNI). Обновите подписку.':
        'The REALITY profile has no server name (SNI). Refresh the subscription.',
    'В профиле REALITY неверный short ID. Обновите подписку.':
        'The REALITY short ID is invalid. Refresh the subscription.',
    'В профиле Trojan отсутствует пароль.':
        'The Trojan profile has no password.',
    'Проверьте метод шифрования и пароль Shadowsocks.':
        'Check the Shadowsocks cipher and password.',
    'XHTTP + REALITY поддерживается для VLESS.':
        'XHTTP + REALITY is supported with VLESS.',
    'Неизвестный режим XHTTP': 'Unknown XHTTP mode',
    'Не найден /dev/net/tun. Включите TUN в системе и проверьте, что устройство доступно.':
        'Could not find /dev/net/tun. Enable TUN and check that the device is available.',
    'не получил доступ к TUN. Проверьте /dev/net/tun и CAP_NET_ADMIN для выбранного ядра.':
        'could not access TUN. Check /dev/net/tun and CAP_NET_ADMIN for the selected core.',
    'DNS поддерживает IP, udp://, tcp:// и https://.':
        'DNS supports IP, udp://, tcp:// and https://.',
    'В URL GhostBox нет ссылки подписки или JSON-сервера.':
        'The GhostBox URL has no subscription link or server JSON.',
    'Сервер подписки вернул HTTP': 'Subscription server returned HTTP',
    'Ядро ': 'Core ',
    'завершилось с кодом ': 'exited with code ',
    'отклонило конфигурацию ': 'rejected the configuration ',
    'не получил доступ к TUN. ': 'could not access TUN. ',
    'Протокол ': 'Protocol ',
    'Транспорт ': 'Transport ',
    ' не поддерживается ядром ': ' is not supported by core ',
    'Проверено серверов: ': 'Servers checked: ',
    'Мягкий бюджет · ': 'Soft budget · ',
    ' · отключено': ' · off',
    'Потеряно соединение: ': 'Connection lost: ',
    'Не удалось включить подключение: ': 'Could not connect: ',
    'Не удалось применить изменения: ': 'Could not apply changes: ',
    'Не удалось переключить сервер: ': 'Could not switch server: ',
    'Не удалось восстановить системный прокси: ':
        'Could not restore the system proxy: ',
    'Не удалось восстановить Kill Switch: ': 'Could not restore Kill Switch: ',
    'Не удалось изменить Kill Switch: ': 'Could not change Kill Switch: ',
    'Не удалось проверить маршрут TUN: ': 'Could not verify the TUN route: ',
    'Не удалось подготовить TUN-конфиг: ': 'Could not prepare TUN config: ',
    'Не удалось загрузить ': 'Could not load ',
    'Не удалось обновить подписок: ': 'Could not refresh subscriptions: ',
    'Неверный домен: ': 'Invalid domain: ',
    'Windows запрос прав администратора отменён: ':
        'Windows administrator permission request was cancelled: ',
    'Переключаю сервер на ': 'Switching server to ',
    'Автоматически выбран локальный порт ':
        'Automatically selected local port ',
    'Ядро запущено, но HTTPS-проверка не прошла: ':
        'Core started, but the HTTPS check failed: ',
    'Ядро запущено, но сервер не ответил через прокси.':
        'Core started, but the server did not respond through the proxy.',
    'Интерфейс TUN запущен, но системный маршрут не ведёт через ghostbox0. Трафик пока не защищён.':
        'The TUN interface is up, but the system route does not use ghostbox0. Traffic is not protected yet.',
    'Ядро не подняло TUN-интерфейс. ':
        'The core did not bring up the TUN interface. ',
    'В системе не найден /dev/net/tun. Проверьте, что модуль TUN включён и устройство создано. Права на файл ядра это устройство не заменяют.':
        'Could not find /dev/net/tun. Check that the TUN module is enabled and the device exists. Core file permissions do not grant access to this device.',
    'Нужны права CAP_NET_ADMIN для ': 'CAP_NET_ADMIN is required for ',
    'Выдайте CAP_NET_ADMIN файлу ': 'Grant CAP_NET_ADMIN to ',
    'Не удалось скачать': 'Could not download',
    'Автоустановка не поддерживается на этой платформе':
        'Automatic installation is not supported on this platform',
    'Обновлятор не найден. Переустановите приложение через tool/install_appimage.sh.':
        'Updater not found. Reinstall the app using tool/install_appimage.sh.',
    'GitHub Releases недоступны. Если репозиторий приватный, нужен публичный источник обновлений.':
        'GitHub Releases are unavailable. A public update source is required for private repositories.',
    'HTTP при загрузке DNS-листа': 'HTTP error while downloading the DNS list',
    ' при загрузке DNS-листа': ' while downloading the DNS block list',
    'GitHub API вернул HTTP': 'GitHub API returned HTTP',
    ' при запуске': ' during startup',
    'ICMP адреса': 'ICMP host',
    'TCP порта': 'TCP port',
    'проб · ': 'probes · ',
    ' мс · медиана ': ' ms · median ',
    'отключено': 'off',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    glow = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2200));
    ambientMotion =
        AnimationController(vsync: this, duration: const Duration(seconds: 18))
          ..repeat();
    _appLinkSubscription = AppLinks().uriLinkStream.listen(
          _receiveAppLink,
          onError: (Object error) =>
              _recordAppLog('Ошибка ссылки GhostBox: $error'),
        );
    unawaited(AppLinks().getInitialLink().then((link) {
      if (link != null) _receiveAppLink(link);
    }).catchError((Object error) {
      _recordAppLog('Не удалось прочитать ссылку GhostBox: $error');
    }));
    _load();
  }

  void _receiveAppLink(Uri link) {
    final scheme = link.scheme.toLowerCase();
    if (scheme != 'ghostbox' && scheme != 'http' && scheme != 'https') return;
    if (_handledAppLinks.contains(link.toString()) ||
        _pendingAppLinks.any((queued) => queued == link)) return;
    if (prefs == null) {
      _pendingAppLinks.add(link);
      return;
    }
    unawaited(_importAppLink(link));
  }

  Future<void> _drainPendingAppLinks() async {
    if (prefs == null || _pendingAppLinks.isEmpty) return;
    final pending = List<Uri>.from(_pendingAppLinks);
    _pendingAppLinks.clear();
    for (final link in pending) {
      await _importAppLink(link);
    }
  }

  Future<void> _importAppLink(Uri link) async {
    final linkKey = link.toString();
    if (!_handledAppLinks.add(linkKey)) return;
    String input = linkKey;
    String? subscriptionSource;
    if (link.scheme.toLowerCase() == 'ghostbox' &&
        link.host.toLowerCase() == 'addserver') {
      final query = link.queryParameters;
      final candidate = query['url'] ?? query['link'] ?? query['uri'];
      final decodedQuery = Uri.decodeComponent(link.query);
      final source = candidate ??
          (decodedQuery.startsWith('http://') ||
                  decodedQuery.startsWith('https://')
              ? decodedQuery
              : null);
      if (source != null &&
          (source.startsWith('http://') || source.startsWith('https://'))) {
        input = source;
        subscriptionSource = source;
      }
    } else if (link.scheme.toLowerCase() == 'http' ||
        link.scheme.toLowerCase() == 'https') {
      subscriptionSource = link.toString();
    }

    try {
      final parsed = await ProfileParser().parseSourceDetailed(input);
      if (parsed.profiles.isEmpty) {
        throw const FormatException('Ссылка не содержит серверов');
      }
      final sourceUrl = subscriptionSource;
      final old = sourceUrl == null
          ? null
          : subscriptions.where((item) => item['url'] == sourceUrl).firstOrNull;
      final oldIds = (old?['ids'] as List? ?? []).cast<String>().toSet();
      setState(() {
        profiles = [
          ...profiles.where((profile) => !oldIds.contains(profile.id)),
          ...parsed.profiles,
        ];
        selectedId = parsed.profiles.first.id;
        if (sourceUrl != null) {
          subscriptions.removeWhere((item) => item['url'] == sourceUrl);
          subscriptions.add({
            'url': sourceUrl,
            'name': parsed.metadata.title ??
                Uri.tryParse(sourceUrl)?.host ??
                'Подписка',
            'metadata': parsed.metadata.toJson(),
            'updatedAt': DateTime.now().toIso8601String(),
            'ids': parsed.profiles.map((profile) => profile.id).toList(),
          });
        }
      });
      await _persist();
      if (sourceUrl != null) {
        await _saveSubscriptions();
        _scheduleSubscriptionRefresh();
        unawaited(_checkSubscriptionEndpoint(sourceUrl));
      }
      if (mounted) {
        _message(_text(
          sourceUrl == null
              ? 'Сервер добавлен из ссылки GhostBox'
              : 'Подписка добавлена из ссылки GhostBox',
          sourceUrl == null
              ? 'Server imported from GhostBox link'
              : 'Subscription imported from GhostBox link',
        ));
      }
    } catch (error) {
      _handledAppLinks.remove(linkKey);
      if (mounted) _message('Не удалось открыть ссылку GhostBox: $error');
    }
  }

  Future<void> _load() async {
    if (Platform.isMacOS) await _migrateMacContainerPreferences();
    final p = await SharedPreferences.getInstance();
    final resumeAfterElevation =
        Platform.isWindows && (p.getBool('connectAfterElevation') ?? false);
    if (resumeAfterElevation) await p.setBool('connectAfterElevation', false);
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      try {
        await systemProxy.restore();
      } on Object catch (error) {
        _recordAppLog('Не удалось восстановить системный прокси: $error');
      }
    }
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
    final migrateAutoLocalPortDefault =
        p.getBool('autoLocalPortDefaultMigrated') != true;
    setState(() {
      prefs = p;
      logRetainedConnections = p.getInt('logRetainedConnections') ?? 10;
      logMaxSizeMb = p.getInt('logMaxSizeMb') ?? 5;
      logCoreOutput = p.getBool('logCoreOutput') ?? true;
      animatedBackground = p.getBool('animatedBackground') ?? true;
      customDnsBlocklistUrls =
          p.getStringList('customDnsBlocklistUrls') ?? <String>[];
      english = p.getBool('appEnglish') ?? false;
      profiles = rows;
      final savedHistory = p.getString('connectionHistory');
      if (savedHistory != null) {
        try {
          connectionHistory
            ..clear()
            ..addAll((jsonDecode(savedHistory) as List)
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .take(logRetainedConnections));
        } on Object {
          connectionHistory.clear();
        }
      }
      autoRefreshSubscriptions = p.getBool('autoRefreshSubscriptions') ?? true;
      autoUpdateApp = p.getBool('autoUpdateApp') ?? true;
      selectedId = p.getString('selectedProfile') ?? rows.firstOrNull?.id;
      final rawCore = p.getString('coreSettings');
      coreSettings = rawCore == null
          ? CoreSettings(
              memoryMb: CoreSettings.clampMemoryMb(
                  p.getInt('memoryMb') ?? (Platform.isIOS ? 32 : 128)),
              autoConnect: p.getBool('autoConnect') ?? false)
          : CoreSettings.fromJson(
              Map<String, dynamic>.from(jsonDecode(rawCore) as Map));
      if (p.getBool('xrayDefaultMigrated') != true) {
        coreSettings = coreSettings.copyWith(
            core: Platform.isAndroid || Platform.isIOS ? 'sing-box' : 'xray');
      }
      if (Platform.isAndroid || Platform.isIOS) {
        coreSettings = coreSettings.copyWith(
          core: Platform.isAndroid && coreSettings.core == 'xray'
              ? 'xray'
              : 'sing-box',
          connectionMode: 'tun',
        );
      }
      if (p.getBool('tunDefaultMigrated') != true) {
        coreSettings = coreSettings.copyWith(
            connectionMode: Platform.isWindows ? 'system' : 'tun');
      }
      if (migrateWindowsProxy) {
        coreSettings = coreSettings.copyWith(connectionMode: 'system');
      }
      if (migrateAutoLocalPortDefault) {
        coreSettings = coreSettings.copyWith(autoLocalPort: true);
      }
      backend = Platform.isAndroid
          ? AndroidVpnBackend()
          : coreSettings.core == 'xray'
              ? XrayBackend()
              : SingBoxBackend();
      if (backend is AndroidVpnBackend) {
        (backend as AndroidVpnBackend).settings = coreSettings;
      }
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
    await trafficStats.load(p);
    if (!animatedBackground) {
      ambientMotion.stop();
      ambientMotion.value = .12;
    }
    if (p.getBool('xrayDefaultMigrated') != true ||
        p.getBool('tunDefaultMigrated') != true ||
        migrateWindowsProxy ||
        migrateAutoLocalPortDefault) {
      await p.setString('coreSettings', jsonEncode(coreSettings.toJson()));
      await p.setBool('xrayDefaultMigrated', true);
      await p.setBool('tunDefaultMigrated', true);
    }
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      await p.setString('coreSettings', jsonEncode(coreSettings.toJson()));
    }
    if (migrateWindowsProxy) {
      await p.setBool('windowsProxyDefaultMigrated', true);
    }
    if (migrateAutoLocalPortDefault) {
      await p.setBool('autoLocalPortDefaultMigrated', true);
    }
    await GhostBoxLogStore.instance.configure(
      retainedConnections: logRetainedConnections,
      maxSizeMb: logMaxSizeMb,
      includeCoreOutput: logCoreOutput,
    );
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
    for (final subscription in subscriptions) {
      final url = subscription['url'];
      if (url is String) unawaited(_checkSubscriptionEndpoint(url));
    }
    if (autoRefreshSubscriptions) {
      unawaited(_refreshDueSubscriptions());
    }
    if (Platform.isLinux &&
        coreSettings.killSwitchEnabled &&
        selected != null) {
      try {
        await LinuxKillSwitch.arm(selected!,
            knownEndpoint: coreSettings.killSwitchProfileId == selected!.id
                ? coreSettings.killSwitchEndpoint
                : null);
        _recordAppLog(
            'Kill Switch восстановлен; системный трафик вне TUN заблокирован');
      } on Object catch (error) {
        connectionIssue = 'Не удалось восстановить Kill Switch: $error';
        _recordAppLog(connectionIssue!);
      }
    }
    // Import protocol links before a possible update exits/restarts the app,
    // then let the updater finish before auto-connect brings the VPN up.
    await _drainPendingAppLinks();
    if (mounted && autoUpdateApp) {
      await _checkAppUpdate(silent: true);
    }
    if (mounted &&
        (coreSettings.autoConnect || resumeAfterElevation) &&
        selected != null &&
        backend.state == VpnState.disconnected) {
      await _toggle();
    }
    if (mounted && !autoUpdateApp) {
      unawaited(_checkAppUpdate(silent: true));
    }
  }

  Future<void> _migrateMacContainerPreferences() async {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return;
    const bundleId = 'app.ghostbox.ghostbox';
    final oldPrefs = File(
        '$home/Library/Containers/$bundleId/Data/Library/Preferences/$bundleId.plist');
    final newPrefs = File('$home/Library/Preferences/$bundleId.plist');
    if (await newPrefs.exists() || !await oldPrefs.exists()) return;
    try {
      final imported = await Process.run(
          '/usr/bin/defaults', ['import', bundleId, oldPrefs.path]);
      if (imported.exitCode == 0) {
        _recordAppLog('Перенесены настройки из хранилища Mac App Sandbox');
      }
    } on Object catch (error) {
      _recordAppLog('Не удалось перенести настройки macOS: $error');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        autoRefreshSubscriptions &&
        prefs != null) {
      unawaited(_refreshDueSubscriptions());
    }
  }

  void _scheduleSubscriptionRefresh() {
    subscriptionRefreshTimer?.cancel();
    if (!autoRefreshSubscriptions || subscriptions.isEmpty) return;
    final now = DateTime.now();
    final nextDue = subscriptions.map((subscription) {
      final raw = subscription['updatedAt'];
      final updatedAt = raw is String ? DateTime.tryParse(raw) : null;
      return updatedAt == null
          ? now
          : updatedAt.add(
              Duration(hours: _subscriptionRefreshIntervalHours(subscription)));
    }).reduce((a, b) => a.isBefore(b) ? a : b);
    final wait = nextDue.difference(now);
    final retryWait = subscriptionRetryNotBefore?.difference(now);
    final scheduledWait =
        retryWait != null && retryWait > wait ? retryWait : wait;
    subscriptionRefreshTimer = Timer(
        scheduledWait.isNegative || scheduledWait == Duration.zero
            ? const Duration(milliseconds: 100)
            : scheduledWait, () async {
      subscriptionRetryNotBefore = null;
      await _refreshDueSubscriptions();
      _scheduleSubscriptionRefresh();
    });
  }

  Future<void> _setAutoRefresh(bool enabled) async {
    setState(() => autoRefreshSubscriptions = enabled);
    final p = prefs ??= await SharedPreferences.getInstance();
    await p.setBool('autoRefreshSubscriptions', enabled);
    _scheduleSubscriptionRefresh();
    if (enabled) unawaited(_refreshDueSubscriptions());
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
    routeDomainController.dispose();
    unawaited(_appLinkSubscription?.cancel());
    subscriptionRefreshTimer?.cancel();
    uptimeTicker?.cancel();
    glow.dispose();
    ambientMotion.dispose();
    unawaited(_disconnectActive());
    super.dispose();
  }

  Future<void> _toggle({bool allowDuringSwitch = false}) async {
    if (backend.state == VpnState.connecting ||
        (switchingServer && !allowDuringSwitch)) return;
    if (Platform.isIOS && backend.state != VpnState.connected) {
      _message(_text(
        'Для iOS ещё нужен Network Extension. Сборка приложения и ядра подготовлена, системный VPN-модуль пока не подключён.',
        'iOS still needs a Network Extension. The app and core build is prepared, but the system VPN provider is not integrated yet.',
      ));
      return;
    }
    if (backend.state == VpnState.connected) {
      _recordAppLog('Отключено');
      glow.stop();
      await _disconnectActive();
      activeProfileId = null;
      pendingReconnect = false;
    } else if (selected != null) {
      if (Platform.isWindows &&
          (coreSettings.connectionMode == 'tun' ||
              coreSettings.connectionMode == 'mixed')) {
        try {
          if (!await WindowsElevation.isElevated()) {
            await prefs?.setBool('connectAfterElevation', true);
            await WindowsElevation.relaunchElevated();
            await SystemNavigator.pop();
            return;
          }
        } on Object catch (error) {
          await prefs?.setBool('connectAfterElevation', false);
          _message('Windows запрос прав администратора отменён: $error');
          return;
        }
      }
      final attemptProfile = selected!;
      final attemptStarted = DateTime.now();
      final attemptCore = coreSettings.core;
      final attemptMode =
          Platform.isAndroid ? 'tun' : coreSettings.connectionMode;
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
        if (backend is AndroidVpnBackend) {
          (backend as AndroidVpnBackend).settings = runtimeRouting.copyWith(
            core: attemptCore,
            connectionMode: 'tun',
            localPort: runtimeLocalPort,
          );
        }
        // Xray has no native TUN inbound. On Linux and Windows, run Xray as a
        // loopback SOCKS upstream and let sing-box own the system TUN.
        final usesXrayTunnelBridge =
            (Platform.isLinux || Platform.isWindows || Platform.isMacOS) &&
                attemptCore == 'xray' &&
                (attemptMode == 'tun' || attemptMode == 'mixed');
        var runtimeProfile = attemptProfile;
        if (Platform.isLinux &&
            coreSettings.killSwitchEnabled &&
            coreSettings.killSwitchProfileId == attemptProfile.id &&
            InternetAddress.tryParse(coreSettings.killSwitchEndpoint) != null) {
          runtimeProfile = LinuxKillSwitch.withEndpoint(
              runtimeProfile, coreSettings.killSwitchEndpoint);
        }
        if (usesXrayTunnelBridge) {
          runtimeProfile = await _resolveXrayTunnelProfile(runtimeProfile);
          process?.settings = runtimeRouting.copyWith(
              connectionMode: 'proxy', localPort: runtimeLocalPort);
          _recordAppLog(
              'TUN запускается через sing-box маршрутизатор и Xray upstream');
        } else {
          if (Platform.isWindows &&
              (attemptMode == 'tun' || attemptMode == 'mixed')) {
            runtimeProfile =
                await _addWindowsTunnelEndpointExclusions(runtimeProfile);
          }
          process?.settings =
              runtimeRouting.copyWith(localPort: runtimeLocalPort);
        }
        if (Platform.isLinux && coreSettings.killSwitchEnabled) {
          if (attemptMode != 'tun' && attemptMode != 'mixed') {
            throw const FormatException(
                'Kill Switch в Linux работает только в режиме TUN или Mixed.');
          }
          runtimeProfile = await LinuxKillSwitch.arm(runtimeProfile,
              knownEndpoint:
                  coreSettings.killSwitchProfileId == runtimeProfile.id
                      ? coreSettings.killSwitchEndpoint
                      : null);
          await _saveCore(
              coreSettings.copyWith(
                  killSwitchEndpoint: runtimeProfile.address,
                  killSwitchProfileId: runtimeProfile.id),
              requiresReconnect: false);
          _recordAppLog(
              'Kill Switch активен: разрешён TUN и endpoint выбранного VPN');
        }
        runtimeProfile = await _withDeviceMetadata(runtimeProfile);
        final activeCore = process;
        if (activeCore != null) _bindCoreRecoveryNotices(activeCore);
        final connection = backend.connect(jsonEncode(runtimeProfile.toJson()));
        if (mounted) setState(() {});
        await connection;
        await _collectAndroidCoreLogs();
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
          _recordAppLog(Platform.isMacOS
              ? 'TUN-интерфейс utun поднят'
              : 'TUN-интерфейс ghostbox0 поднят');
          await _verifyTunRoute('1.1.1.1');
          try {
            await _tunHttpsGet(
                Duration(seconds: coreSettings.pingTimeoutSeconds + 2));
            _recordAppLog(
                'HTTPS и TLS-проверка системного маршрута TUN прошла');
          } on Object catch (error) {
            // Captive portals, provider filters and individual HTTPS probe
            // hosts can reject TLS even when Windows installed the TUN route.
            // Keep the tunnel up after the adapter and route have been
            // verified; report the failed probe in the live connection log.
            _recordAppLog(
                'Предупреждение: TUN и маршрут активны, но HTTPS-проверка не прошла: $error');
          }
        }
        final hasSystemTunnel = coreSettings.connectionMode == 'tun' ||
            coreSettings.connectionMode == 'mixed';
        if (coreSettings.routing != 'direct' && !hasSystemTunnel) {
          // The process is configured with the runtime port. This can differ
          // from the saved port when automatic port selection is enabled.
          await _proxyHttpGet(runtimeLocalPort,
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
        if (backend is AndroidVpnBackend) {
          unawaited((backend as AndroidVpnBackend).refreshState());
        }
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
        final storage = prefs;
        if (storage != null) unawaited(trafficStats.sample(storage));
        if (backend is AndroidVpnBackend) {
          unawaited(_collectAndroidCoreLogs());
        }
        setState(() {});
      });
    } else {
      glow.stop();
    }
  }

  Future<void> _applyPendingReconnect() async {
    if (!pendingReconnect || applyingReconnect) return;
    if (backend.state == VpnState.connecting) {
      _message('Подождите завершения подключения');
      return;
    }
    setState(() {
      pendingReconnect = false;
      applyingReconnect = true;
    });
    try {
      if (backend.state == VpnState.connected) await _disconnectActive();
      await _toggle();
      if (backend.state != VpnState.connected) {
        throw StateError(connectionIssue ?? 'Не удалось переподключиться');
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => pendingReconnect = true);
        _message('Не удалось применить изменения: $error');
      }
    } finally {
      if (mounted) setState(() => applyingReconnect = false);
    }
  }

  void _recordAppLog(String message) {
    final timestamp =
        DateTime.now().toLocal().toIso8601String().replaceFirst('T', ' ');
    final line = '$timestamp  $message';
    appLogs.add(line);
    if (appLogs.length > 100) appLogs.removeAt(0);
    _logWriteQueue = GhostBoxLogStore.instance.append(line);
  }

  Future<void> _collectAndroidCoreLogs() async {
    final mobileBackend = backend;
    if (mobileBackend is! AndroidVpnBackend) return;
    for (final line in await mobileBackend.readNewLogs()) {
      _recordAppLog('[sing-box] $line');
    }
  }

  Future<File> _resolveLogFile() async {
    final file = await GhostBoxLogStore.instance.file();
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
    final record = <String, dynamic>{
      'at': started.toIso8601String(),
      'profile': profile,
      'core': core,
      'mode': mode,
      'success': success,
      'durationMs': DateTime.now().difference(started).inMilliseconds,
      'message': message,
    };
    if (connectionHistory.isNotEmpty &&
        _isDuplicateConnectionRecord(connectionHistory.first, record)) {
      return;
    }
    connectionHistory.insert(0, record);
    if (connectionHistory.length > logRetainedConnections) {
      connectionHistory.removeRange(
          logRetainedConnections, connectionHistory.length);
    }
    final p = prefs ??= await SharedPreferences.getInstance();
    await p.setString('connectionHistory', jsonEncode(connectionHistory));
  }

  Future<void> _showLogs() async {
    final file = await _resolveLogFile();
    final core = process;
    Future<List<String>> readRecentEntries() async {
      await _logWriteQueue;
      await process?.flushLogs();
      await tunnelBridgeBackend?.flushLogs();
      await _collectAndroidCoreLogs();
      await GhostBoxLogStore.instance.flush();
      if (!await file.exists()) return <String>[];
      final handle = await file.open();
      late final List<String> lines;
      try {
        final length = await handle.length();
        const tailLimit = 1024 * 1024;
        final offset = math.max(0, length - tailLimit);
        await handle.setPosition(offset);
        var tail = utf8.decode(await handle.read(length - offset),
            allowMalformed: true);
        if (offset > 0) {
          final firstLine = tail.indexOf('\n');
          tail = firstLine < 0 ? '' : tail.substring(firstLine + 1);
        }
        lines = tail.split('\n');
      } finally {
        await handle.close();
      }
      final unique = <String>[];
      for (final line in lines) {
        if (unique.isNotEmpty && _sameLogMessage(unique.last, line)) continue;
        unique.add(line);
      }
      return unique
          .skip(unique.length > 100 ? unique.length - 100 : 0)
          .toList();
    }

    var entries = await readRecentEntries();
    Timer? refreshTimer;
    var live = true;
    var refreshRunning = false;
    StateSetter? updateSheet;
    ScrollController? logScrollController;
    if (!mounted) return;
    await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: Colors.transparent,
        builder: (context) =>
            StatefulBuilder(builder: (context, setSheetState) {
              updateSheet = setSheetState;
              if (refreshTimer == null) {
                refreshTimer =
                    Timer.periodic(const Duration(seconds: 1), (_) async {
                  if (!live || refreshRunning || updateSheet == null) return;
                  refreshRunning = true;
                  final wasAtBottom = logScrollController?.hasClients == true &&
                      logScrollController!.position.maxScrollExtent -
                              logScrollController!.position.pixels <
                          80;
                  try {
                    final refreshed = await readRecentEntries();
                    if (refreshed.join('\n') != entries.join('\n')) {
                      updateSheet?.call(() => entries = refreshed);
                      if (wasAtBottom) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          final scroll = logScrollController;
                          if (scroll?.hasClients == true) {
                            scroll!.animateTo(
                              scroll.position.maxScrollExtent,
                              duration: const Duration(milliseconds: 160),
                              curve: Curves.easeOut,
                            );
                          }
                        });
                      }
                    }
                  } on Object {
                    // A transient read error should not close the live journal.
                  } finally {
                    refreshRunning = false;
                  }
                });
              }
              return DraggableScrollableSheet(
                initialChildSize: .78,
                minChildSize: .45,
                maxChildSize: .94,
                expand: false,
                builder: (context, scrollController) {
                  logScrollController = scrollController;
                  return Container(
                      decoration: BoxDecoration(
                          color: _surface,
                          borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(26)),
                          border: Border.all(
                              color: Colors.white.withValues(alpha: .12))),
                      padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
                      child: Column(children: [
                        const SizedBox(height: 4),
                        Row(children: [
                          Expanded(
                              child: Text(_localized('Журнал соединения'),
                                  style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700))),
                          IconButton(
                              tooltip: live
                                  ? _text('Остановить live-обновление',
                                      'Pause live updates')
                                  : _text('Возобновить live-обновление',
                                      'Resume live updates'),
                              onPressed: () {
                                setSheetState(() => live = !live);
                                if (live) {
                                  unawaited(() async {
                                    try {
                                      final latest = await readRecentEntries();
                                      updateSheet?.call(() => entries = latest);
                                    } on Object {
                                      // Keep live mode active after a read error.
                                    }
                                  }());
                                }
                              },
                              icon: Icon(
                                  live
                                      ? Icons.sensors_rounded
                                      : Icons.pause_circle_outline_rounded,
                                  color: live ? _mint : _muted)),
                          IconButton(
                              tooltip: _localized('Скопировать журнал'),
                              onPressed: () => Clipboard.setData(ClipboardData(
                                  text: entries
                                      .map(_localizeJournalLine)
                                      .join('\n'))),
                              icon: const Icon(Icons.copy)),
                          IconButton(
                              tooltip: _localized('Экспорт полного журнала'),
                              onPressed: _exportFullLog,
                              icon: const Icon(Icons.file_download_outlined)),
                          IconButton(
                              tooltip: _localized('Очистить журнал'),
                              onPressed: () async {
                                await _clearJournal();
                                setSheetState(() => entries = <String>[]);
                              },
                              icon: const Icon(Icons.delete_sweep_outlined)),
                          IconButton(
                              tooltip: _localized('Закрыть'),
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.close)),
                        ]),
                        Align(
                            alignment: Alignment.centerLeft,
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      '${logFilePath ?? file.path}\n${core?.name ?? coreSettings.core} · ${backend.state.name} · ${core?.executable ?? _text('ядро не выбрано', 'core not selected')}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          color: _muted, fontSize: 11)),
                                  const SizedBox(height: 3),
                                  Text(
                                      live
                                          ? _text(
                                              'LIVE · обновление раз в секунду',
                                              'LIVE · refreshes every second')
                                          : _text('ПАУЗА', 'PAUSED'),
                                      style: TextStyle(
                                          color: live ? _mint : _muted,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700)),
                                ])),
                        const SizedBox(height: 10),
                        Expanded(
                            child: entries.isEmpty
                                ? Center(
                                    child: Text(_localized('Записей пока нет'),
                                        style: TextStyle(color: _muted)))
                                : ListView.separated(
                                    controller: scrollController,
                                    itemCount: entries.length,
                                    separatorBuilder: (_, __) => Divider(
                                        height: 1,
                                        color: Colors.white
                                            .withValues(alpha: .07)),
                                    itemBuilder: (context, index) => Padding(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 8),
                                        child: SelectableText(_localizeJournalLine(entries[index]),
                                            style: TextStyle(
                                                fontFamily: 'monospace',
                                                fontSize: 11,
                                                height: 1.4,
                                                color: entries[index].toLowerCase().contains('ошибка') ||
                                                        entries[index]
                                                            .toLowerCase()
                                                            .contains(
                                                                'error') ||
                                                        entries[index].toLowerCase().contains('failed')
                                                    ? Colors.orangeAccent
                                                    : _muted))))),
                      ]));
                },
              );
            }));
    refreshTimer?.cancel();
  }

  Future<void> _exportFullLog() async {
    try {
      await _logWriteQueue;
      await process?.flushLogs();
      await tunnelBridgeBackend?.flushLogs();
      await GhostBoxLogStore.instance.flush();
      final source = await _resolveLogFile();
      final location = await getSaveLocation(
        suggestedName: 'ghostbox-full-log.txt',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Text', extensions: ['txt', 'log'])
        ],
      );
      if (location == null) return;
      if (!await source.exists()) {
        throw const FileSystemException('Журнал пока пуст');
      }
      await File(location.path)
          .writeAsBytes(await source.readAsBytes(), flush: true);
      if (mounted)
        _message(_text('Полный журнал сохранён', 'Full log exported'));
    } on Object catch (error) {
      if (mounted)
        _message(
            '${_text('Не удалось экспортировать журнал', 'Could not export log')}: $error');
    }
  }

  void _showConnectionHistory() {
    final history = _deduplicatedHistory(connectionHistory);
    showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: Colors.transparent,
        builder: (context) => DraggableScrollableSheet(
            initialChildSize:
                MediaQuery.sizeOf(context).width >= 800 ? .52 : .68,
            minChildSize: MediaQuery.sizeOf(context).width >= 800 ? .3 : .4,
            maxChildSize: MediaQuery.sizeOf(context).width >= 800 ? .82 : .9,
            expand: false,
            builder: (context, scrollController) {
              final wide = MediaQuery.sizeOf(context).width >= 800;
              return Container(
                  decoration: BoxDecoration(
                      color: _surface,
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(26)),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: .12))),
                  padding: EdgeInsets.fromLTRB(
                      18, wide ? 7 : 10, 18, wide ? 10 : 16),
                  child: Column(children: [
                    SizedBox(height: wide ? 0 : 2),
                    Row(children: [
                      Expanded(
                          child: Text(_localized('Последние подключения'),
                              style: TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w700))),
                      Text('${history.length}/$logRetainedConnections',
                          style: TextStyle(color: _muted, fontSize: 12)),
                      IconButton(
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints.tightFor(
                              width: 40, height: 40),
                          tooltip: _localized('Закрыть'),
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close)),
                    ]),
                    Expanded(
                        child: history.isEmpty
                            ? Center(
                                child: Text(
                                    _localized('Попыток подключения пока нет'),
                                    style: TextStyle(color: _muted)))
                            : ListView.separated(
                                controller: scrollController,
                                itemCount: history.length,
                                separatorBuilder: (_, __) =>
                                    SizedBox(height: wide ? 5 : 8),
                                itemBuilder: (context, index) {
                                  final item = history[index];
                                  final success = item['success'] == true;
                                  final date =
                                      DateTime.tryParse('${item['at'] ?? ''}')
                                          ?.toLocal();
                                  final dateText = date == null
                                      ? _text(
                                          'Время неизвестно', 'Time unknown')
                                      : '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year} · ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
                                  return Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 13, vertical: 9),
                                      decoration: BoxDecoration(
                                          color: Colors.white
                                              .withValues(alpha: .055),
                                          borderRadius:
                                              BorderRadius.circular(16),
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
                                                    : Icons
                                                        .error_outline_rounded,
                                                color: success
                                                    ? _mint
                                                    : Colors.orangeAccent,
                                                size: 19),
                                            const SizedBox(width: 10),
                                            Expanded(
                                                child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                  Text(
                                                      '${item['profile'] ?? _text('Сервер', 'Server')}',
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                          fontSize: 12,
                                                          fontWeight:
                                                              FontWeight.w600)),
                                                  const SizedBox(height: 3),
                                                  Text(
                                                      '$dateText · ${item['core'] ?? ''} · ${item['mode'] ?? ''} · ${item['durationMs'] ?? 0} ${english ? 'ms' : 'мс'}',
                                                      style: TextStyle(
                                                          color: _muted,
                                                          fontSize: 10)),
                                                  SizedBox(
                                                      height: wide ? 2 : 4),
                                                  Text(
                                                      _messageText(
                                                          '${item['message'] ?? ''}'),
                                                      maxLines: wide ? 2 : 3,
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
                  ]));
            }));
  }

  bool _isDuplicateConnectionRecord(
      Map<String, dynamic> previous, Map<String, dynamic> next) {
    if (previous['profile'] != next['profile'] ||
        previous['core'] != next['core'] ||
        previous['mode'] != next['mode'] ||
        previous['success'] != next['success'] ||
        previous['message'] != next['message']) return false;
    final previousAt = DateTime.tryParse('${previous['at'] ?? ''}');
    final nextAt = DateTime.tryParse('${next['at'] ?? ''}');
    return previousAt != null &&
        nextAt != null &&
        previousAt.difference(nextAt).abs() <= const Duration(seconds: 3);
  }

  List<Map<String, dynamic>> _deduplicatedHistory(
      Iterable<Map<String, dynamic>> source) {
    final result = <Map<String, dynamic>>[];
    for (final record in source) {
      if (result.isNotEmpty &&
          _isDuplicateConnectionRecord(result.last, record)) continue;
      result.add(record);
    }
    return result.take(logRetainedConnections).toList();
  }

  bool _sameLogMessage(String first, String second) {
    final timestamp =
        RegExp(r'^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?\s+');
    return first.replaceFirst(timestamp, '').trim() ==
        second.replaceFirst(timestamp, '').trim();
  }

  Future<void> _waitForTunInterface() async {
    if (Platform.isWindows) {
      // Wintun adapter creation is asynchronous. Wait for Windows to expose
      // the adapter before declaring the tunnel ready or probing HTTPS.
      const script = r'''
$ErrorActionPreference = 'SilentlyContinue'
for ($i = 0; $i -lt 80; $i++) {
  $adapter = Get-NetAdapter -IncludeHidden | Where-Object {
    $_.Name -eq 'ghostbox0' -or $_.InterfaceDescription -match 'Wintun'
  } | Select-Object -First 1
  if ($adapter -and $adapter.Status -eq 'Up') {
    Write-Output "$($adapter.Name)|$($adapter.InterfaceDescription)"
    exit 0
  }
  Start-Sleep -Milliseconds 250
}
exit 1
''';
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ]).timeout(const Duration(seconds: 24));
      if (result.exitCode != 0) {
        throw FormatException(
          'sing-box не поднял адаптер Wintun ghostbox0. Проверьте права администратора, наличие vendor/bin/wintun.dll и состояние адаптера в Windows. ${result.stderr.toString().trim()}',
        );
      }
      _recordAppLog('Адаптер TUN активен: ${result.stdout.toString().trim()}');
      return;
    }
    if (Platform.isMacOS) {
      for (var attempt = 0; attempt < 80; attempt++) {
        final result = await Process.run('/sbin/ifconfig', ['-l']);
        if (result.exitCode == 0 &&
            RegExp(r'\butun\d+\b').hasMatch('${result.stdout}')) {
          _recordAppLog('macOS utun интерфейс поднят');
          return;
        }
        if (process?.state != VpnState.connected) break;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      throw const FormatException(
          'sing-box не создал utun-интерфейс macOS. Разрешите запрос администратора и проверьте журнал ядра.');
    }
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

  Future<ServerProfile> _addWindowsTunnelEndpointExclusions(
      ServerProfile profile) async {
    final addresses = await _lookupHost(profile.address);
    if (addresses.isEmpty) {
      throw FormatException(
          'Не удалось разрешить адрес VPN-сервера ${profile.address} до включения Windows TUN. Проверьте DNS и повторите подключение.');
    }
    final existing = profile.raw['_tunExcludeAddresses'];
    final exclusions = <String>{
      if (existing is List) ...existing.map((value) => value.toString()),
      ...addresses.map((address) =>
          '${address.address}/${address.type == InternetAddressType.IPv4 ? 32 : 128}'),
    }.toList();
    _recordAppLog(
        'Windows TUN: исключаю endpoint VPN из маршрута туннеля (${addresses.map((address) => address.address).join(', ')})');
    return ServerProfile(
      id: profile.id,
      name: profile.name,
      protocol: profile.protocol,
      address: profile.address,
      port: profile.port,
      uuid: profile.uuid,
      network: profile.network,
      security: profile.security,
      raw: {...profile.raw, '_tunExcludeAddresses': exclusions},
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

    // Exact domain -> IP expansion is only a fallback for destinations that
    // arrive as an IP before SNI/Host sniffing can classify them. Keep recent
    // results across app launches and bound cold DNS lookups so a large rules
    // list does not hold up VPN startup for several seconds.
    const cacheKey = 'splitRouteDnsCache';
    const cacheTtl = Duration(seconds: 60);
    const lookupDeadline = Duration(milliseconds: 900);
    final now = DateTime.now().millisecondsSinceEpoch;
    final savedCache = <String, dynamic>{};
    try {
      final rawCache = prefs?.getString(cacheKey);
      if (rawCache != null) {
        savedCache.addAll(jsonDecode(rawCache) as Map<String, dynamic>);
      }
    } on Object {
      savedCache.clear();
    }

    final addresses = <String>{};
    final toResolve = <String>[];
    for (final hostname in hostnames) {
      final item = savedCache[hostname];
      if (item is Map && (item['expires'] as int? ?? 0) > now) {
        addresses.addAll((item['ips'] as List? ?? const [])
            .map((value) => value.toString().toLowerCase()));
      } else {
        toResolve.add(hostname);
      }
    }

    final refreshed = <String, dynamic>{};
    await Future.wait(toResolve.map((hostname) async {
      try {
        final result =
            await InternetAddress.lookup(hostname).timeout(lookupDeadline);
        final ips =
            result.map((address) => address.address.toLowerCase()).toSet();
        addresses.addAll(ips);
        refreshed[hostname] = {
          'expires': now + cacheTtl.inMilliseconds,
          'ips': ips.toList(),
        };
      } on Object {
        refreshed[hostname] = {
          'expires': now + const Duration(seconds: 15).inMilliseconds,
          'ips': const <String>[],
        };
      }
    }));
    if (refreshed.isNotEmpty) {
      final nextCache = <String, dynamic>{
        for (final entry in savedCache.entries)
          if (entry.value is Map &&
              ((entry.value as Map)['expires'] as int? ?? 0) > now)
            entry.key: entry.value,
        ...refreshed,
      };
      await prefs?.setString(cacheKey, jsonEncode(nextCache));
    }
    _recordAppLog(
        'Split routing: доменов ${hostnames.length}, DNS из кэша ${hostnames.length - toResolve.length}, новых запросов ${toResolve.length}, IP ${addresses.length}');
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
    if (Platform.isWindows) {
      const script = r'''
$ErrorActionPreference = 'SilentlyContinue'
$routes = Get-NetRoute -AddressFamily IPv4 | Where-Object {
  $_.DestinationPrefix -in @('0.0.0.0/1', '128.0.0.0/1', '0.0.0.0/0')
}
foreach ($route in $routes) {
  $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -IncludeHidden
  if ($adapter -and ($adapter.Name -eq 'ghostbox0' -or $adapter.InterfaceDescription -match 'Wintun')) {
    Write-Output "$($route.DestinationPrefix)|$($adapter.Name)|$($adapter.Status)"
  }
}
''';
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ]).timeout(const Duration(seconds: 8));
      final routes = result.stdout.toString().trim();
      if (result.exitCode != 0 || routes.isEmpty) {
        throw const FormatException(
          'Адаптер Wintun поднялся, но системный маршрут через него не установлен. Перезапустите GhostBox с правами администратора и проверьте, что Windows не отключила виртуальный адаптер.',
        );
      }
      _recordAppLog(
          'Маршрут Windows через TUN: ${routes.replaceAll('\n', ', ')}');
      return;
    }
    if (Platform.isMacOS) {
      final result = await Process.run('/sbin/route', ['-n', 'get', probeIp])
          .timeout(const Duration(seconds: 4));
      if (result.exitCode != 0 ||
          !RegExp(r'^\s*interface:\s*utun\d+', multiLine: true)
              .hasMatch('${result.stdout}')) {
        throw const FormatException(
            'Интерфейс utun запущен, но маршрут macOS не идёт через VPN.');
      }
      _recordAppLog(
          'Маршрут macOS через TUN: ${result.stdout.toString().trim()}');
      return;
    }
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
    final configured = Uri.tryParse(coreSettings.proxyGetUrl.trim());
    final probes = <Uri>[
      if (configured != null &&
          configured.scheme == 'https' &&
          configured.host.isNotEmpty)
        configured,
      Uri.https('connectivitycheck.gstatic.com', '/generate_204'),
      Uri.https('cp.cloudflare.com', '/generate_204'),
      Uri.https('www.google.com', '/generate_204'),
    ];
    for (final probe in probes) {
      final client = HttpClient()
        ..connectionTimeout = timeout
        ..idleTimeout = timeout;
      try {
        final request = await client.getUrl(probe).timeout(timeout);
        request.followRedirects = true;
        request.headers.set(HttpHeaders.connectionHeader, 'close');
        final response = await request.close().timeout(timeout);
        await response.drain<void>().timeout(timeout);
        // A completed TLS handshake proves the route works even when a
        // provider-specific test URL intentionally returns 4xx/5xx.
        return;
      } on Object catch (error) {
        failures.add('${probe.host}: $error');
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
    final storage = prefs;
    if (storage != null &&
        (coreSettings.connectionMode == 'tun' ||
            coreSettings.connectionMode == 'mixed')) {
      await trafficStats.sample(storage);
    }
    final bridge = tunnelBridgeBackend;
    tunnelBridgeBackend = null;
    xrayTunnelBridgeActive = false;
    if (bridge != null) await bridge.disconnect();
    await backend.disconnect();
    await systemProxy.restore();
    activeLocalPort = null;
  }

  Future<void> _setKillSwitch(bool enabled) async {
    if (!Platform.isLinux) {
      _message(_text('Kill Switch пока доступен только в Linux',
          'Kill Switch is currently available on Linux only'));
      return;
    }
    if (enabled &&
        coreSettings.connectionMode != 'tun' &&
        coreSettings.connectionMode != 'mixed') {
      _message(_text('Для Kill Switch выбери режим TUN или Mixed',
          'Select TUN or Mixed mode to use Kill Switch'));
      return;
    }
    try {
      if (enabled) {
        final profile = selected;
        if (profile == null) {
          _message(_text('Сначала выбери сервер', 'Select a server first'));
          return;
        }
        final armedProfile = await LinuxKillSwitch.arm(profile,
            knownEndpoint: coreSettings.killSwitchProfileId == profile.id
                ? coreSettings.killSwitchEndpoint
                : null);
        await _saveCore(
            coreSettings.copyWith(
                killSwitchEnabled: true,
                killSwitchEndpoint: armedProfile.address,
                killSwitchProfileId: profile.id),
            requiresReconnect: false);
      } else {
        await LinuxKillSwitch.disarm();
        await _saveCore(
            coreSettings.copyWith(
                killSwitchEnabled: false,
                killSwitchEndpoint: '',
                killSwitchProfileId: ''),
            requiresReconnect: false);
      }
      _recordAppLog(enabled
          ? 'Kill Switch включён: весь исходящий трафик вне ghostbox0 заблокирован'
          : 'Kill Switch выключен');
      if (enabled) {
        _message(_text(
            'Kill Switch включён. При отключении VPN интернет останется заблокирован.',
            'Kill Switch is on. Internet stays blocked when VPN disconnects.'));
      }
    } on Object catch (error) {
      _message(_text('Не удалось изменить Kill Switch: $error',
          'Could not change Kill Switch: $error'));
    }
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
      if (Platform.isLinux && coreSettings.killSwitchEnabled) {
        final allowedProfile = await LinuxKillSwitch.arm(target,
            knownEndpoint: coreSettings.killSwitchProfileId == target.id
                ? coreSettings.killSwitchEndpoint
                : null);
        await _saveCore(
            coreSettings.copyWith(
                killSwitchEndpoint: allowedProfile.address,
                killSwitchProfileId: target.id),
            requiresReconnect: false);
      }
      await _disconnectActive();
      activeProfileId = null;
      // The VPN remains active from the user's perspective and reconnects
      // automatically. TUN has a brief traffic pause while its single
      // interface is handed from the old core to the new one.
      if (mounted) setState(() {});
      await _toggle(allowDuringSwitch: true);
    } on Object catch (error) {
      _recordAppLog('Не удалось переключить сервер: $error');
      _message('Не удалось переключить сервер: $error');
    } finally {
      switchingServer = false;
      pendingReconnect = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _setConnectionMode(String mode) async {
    if ((Platform.isAndroid || Platform.isIOS) && mode != 'tun') {
      _message(Platform.isIOS
          ? _text('На iOS доступен только системный VPN (TUN)',
              'iOS only supports the system VPN (TUN) mode')
          : 'Android подключает приложения через системный VPN (TUN)');
      return;
    }
    if (Platform.isLinux &&
        coreSettings.killSwitchEnabled &&
        mode != 'tun' &&
        mode != 'mixed') {
      _message(_text('Сначала выключи Kill Switch для смены режима',
          'Turn off Kill Switch before changing this mode'));
      return;
    }
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
    var proxyPort = activeLocalPort ?? coreSettings.localPort;
    var httpProxyPort = 0;
    try {
      if (mode == 'proxy' && Platform.isAndroid) {
        if (backend.state != VpnState.connected || activeLocalPort == null) {
          throw const SocketException(
              'На Android Proxy GET проверяется через активный VPN. Сначала подключите сервер.');
        }
        if (selected?.id != profile.id) {
          throw const SocketException(
              'Подключите этот сервер, чтобы Proxy GET проверил его через VPN.');
        }
        for (var i = 0; i < count; i++) {
          final watch = Stopwatch()..start();
          await _proxyHttpGet(activeLocalPort!, timeout);
          watch.stop();
          samples.add(_elapsedMilliseconds(watch));
        }
        samples.sort();
        return samples;
      }
      if (mode == 'proxy') {
        // Probe through an isolated local proxy configured to send every request
        // through this profile. The active connection may use split rules or a
        // TUN router, so its local port can send a test request directly.
        final reservation =
            await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        proxyPort = reservation.port;
        final httpProxyReservation =
            await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        httpProxyPort = httpProxyReservation.port;
        await httpProxyReservation.close();
        await reservation.close();
        final coreName = coreSettings.core == 'xray' ? 'xray' : 'sing-box';
        probeBackend = CoreProcessBackend(
          name: coreName,
          executable: process?.executable ?? coreExecutable(coreName, 'vendor'),
          configPath: 'vendor/config/$coreName.json',
        )..settings = coreSettings.copyWith(
            localPort: proxyPort,
            routing: 'proxy',
            connectionMode: 'proxy',
            dnsThroughProxy: true);
        final probeProfile = ServerProfile(
          id: profile.id,
          name: profile.name,
          protocol: profile.protocol,
          address: profile.address,
          port: profile.port,
          uuid: profile.uuid,
          network: profile.network,
          security: profile.security,
          raw: {
            ...profile.raw,
            '_ghostboxHttpProbePort': httpProxyPort,
          },
        );
        await probeBackend.connect(jsonEncode(probeProfile.toJson()));
        await _waitForProxyListener(proxyPort, timeout);
        await _waitForProxyListener(httpProxyPort, timeout);
      }
      for (var i = 0; i < count; i++) {
        if (mode == 'proxy') {
          final watch = Stopwatch()..start();
          await _proxyHttpGet(httpProxyPort, timeout);
          watch.stop();
          samples.add(_elapsedMilliseconds(watch));
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
          final latency =
              double.parse(match.group(1)!.replaceAll(',', '.')).ceil();
          samples.add(math.max(1, latency));
        } else {
          if (backend.state == VpnState.connected &&
              (coreSettings.connectionMode == 'tun' ||
                  coreSettings.connectionMode == 'mixed')) {
            final interface = await _routeInterface(profile.address);
            if (interface != null && _isTunnelInterface(interface)) {
              throw SocketException(
                  'TCP-пинг пошёл через активный VPN-интерфейс $interface и показывает задержку от VPN-сервера. Отключите VPN для прямой проверки или выберите Proxy GET.');
            }
          }
          final watch = Stopwatch()..start();
          final socket = await Socket.connect(profile.address, profile.port,
              timeout: timeout);
          socket.destroy();
          watch.stop();
          samples.add(_elapsedMilliseconds(watch));
        }
      }
      samples.sort();
      return samples;
    } finally {
      await probeBackend?.disconnect();
    }
  }

  Future<void> _testProfileSpeed(ServerProfile profile) async {
    if (_speedTestProfiles.contains(profile.id)) return;
    setState(() {
      _speedTestProfiles.add(profile.id);
      _profileDownloadSpeeds.remove(profile.id);
    });
    CoreProcessBackend? probeBackend;
    var httpPort = 0;
    try {
      final proxyReservation =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final proxyPort = proxyReservation.port;
      await proxyReservation.close();
      final httpReservation =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      httpPort = httpReservation.port;
      await httpReservation.close();

      final coreName = coreSettings.core == 'xray' ? 'xray' : 'sing-box';
      probeBackend = CoreProcessBackend(
        name: coreName,
        executable: process?.executable ?? coreExecutable(coreName, 'vendor'),
        configPath: 'vendor/config/$coreName-speed-test.json',
      )..settings = coreSettings.copyWith(
          localPort: proxyPort,
          routing: 'proxy',
          connectionMode: 'proxy',
          dnsThroughProxy: true,
        );
      final probeProfile = ServerProfile(
        id: profile.id,
        name: profile.name,
        protocol: profile.protocol,
        address: profile.address,
        port: profile.port,
        uuid: profile.uuid,
        network: profile.network,
        security: profile.security,
        raw: {...profile.raw, '_ghostboxHttpProbePort': httpPort},
      );
      await probeBackend.connect(jsonEncode(probeProfile.toJson()));
      const timeout = Duration(seconds: 35);
      await _waitForProxyListener(httpPort, timeout);
      final bytes = await _downloadThroughHttpProxy(httpPort, timeout);
      if (bytes == 0) throw const HttpException('Сервер не передал данные');
      final speed = bytes / 1024 / 1024;
      if (mounted) {
        setState(() => _profileDownloadSpeeds[profile.id] = speed);
        _message(_text(
          'Скорость ${profile.name}: ${speed.toStringAsFixed(2)} МБ/с',
          '${profile.name} speed: ${speed.toStringAsFixed(2)} MB/s',
        ));
      }
    } on Object catch (error) {
      if (mounted) {
        _message(_text(
          'Не удалось проверить скорость: $error',
          'Speed test failed: $error',
        ));
      }
    } finally {
      await probeBackend?.disconnect();
      if (mounted) setState(() => _speedTestProfiles.remove(profile.id));
    }
  }

  String _speedTestMenuLabel(String profileId) {
    final speed = _profileDownloadSpeeds[profileId];
    if (speed == null) {
      return _text('Проверить скорость соединения', 'Test connection speed');
    }
    return '${_text('Повторить тест скорости', 'Run speed test again')} · ${speed.toStringAsFixed(2)} ${english ? 'MB/s' : 'МБ/с'}';
  }

  Future<int> _downloadThroughHttpProxy(int localPort, Duration timeout) async {
    // Cloudflare's download endpoint returns a fixed-size payload, so this
    // measures the selected profile's real download throughput, not ping RTT.
    final uri =
        Uri.https('speed.cloudflare.com', '/__down', {'bytes': '8000000'});
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout
      ..findProxy = (_) => 'PROXY 127.0.0.1:$localPort';
    final watch = Stopwatch()..start();
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'GhostBox-Speed-Test');
      request.headers.set(HttpHeaders.connectionHeader, 'close');
      final response = await request.close().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      var received = 0;
      await for (final chunk in response.timeout(timeout)) {
        received += chunk.length;
        if (received >= 8000000) break;
      }
      watch.stop();
      if (watch.elapsedMicroseconds <= 0) return 0;
      return (received / (watch.elapsedMicroseconds / 1000000)).round();
    } finally {
      client.close(force: true);
    }
  }

  int _elapsedMilliseconds(Stopwatch watch) =>
      math.max(1, (watch.elapsedMicroseconds + 999) ~/ 1000).toInt();

  Future<String?> _routeInterface(String host) async {
    try {
      final literal = InternetAddress.tryParse(host);
      final address = literal?.address ??
          (await InternetAddress.lookup(host)).firstOrNull?.address;
      if (address == null) return null;
      if (Platform.isLinux) {
        final result = await Process.run('ip',
            ['-${address.contains(':') ? '6' : '4'}', 'route', 'get', address]);
        if (result.exitCode != 0) return null;
        return RegExp(r'\bdev\s+(\S+)')
            .firstMatch('${result.stdout}')
            ?.group(1);
      }
      if (Platform.isMacOS) {
        final result = await Process.run('route', ['-n', 'get', address]);
        if (result.exitCode != 0) return null;
        return RegExp(r'^\s*interface:\s*(\S+)', multiLine: true)
            .firstMatch('${result.stdout}')
            ?.group(1);
      }
      if (Platform.isWindows) {
        final result = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "(Find-NetRoute -RemoteIPAddress '$address' | Select-Object -First 1 -ExpandProperty InterfaceAlias)",
        ]).timeout(const Duration(seconds: 3));
        if (result.exitCode != 0) return null;
        return '${result.stdout}'.trim().split(RegExp(r'\s+')).firstOrNull;
      }
    } on Object {
      // If route inspection is unavailable, keep the TCP probe usable.
    }
    return null;
  }

  bool _isTunnelInterface(String name) => RegExp(
        r'^(tun|tap|wg|utun|ghostbox|tailscale|zt|vpn|wintun|ppp)',
        caseSensitive: false,
      ).hasMatch(name);

  Future<void> _waitForProxyListener(int port, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(milliseconds: 250),
        );
        socket.destroy();
        return;
      } on Object catch (error) {
        lastError = error;
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    }
    throw SocketException(
        'Локальный прокси на порту $port не запустился: $lastError');
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
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'PROXY 127.0.0.1:$localPort';
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'GhostBox-Alpha-v1.0');
      request.headers.set(HttpHeaders.connectionHeader, 'close');
      // The ping only needs the status line and headers. Draining the body can
      // turn a valid 404/204 into a false timeout if a test endpoint streams or
      // keeps its response open.
      await request.close().timeout(timeout);
    } on Object catch (error) {
      throw SocketException('HTTP GET ${uri.host} failed: $error');
    } finally {
      client.close(force: true);
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
          latencyErrors.remove(profile.id);
        });
    } catch (error) {
      if (mounted && generation == _probeGeneration) {
        setState(() {
          failedLatencies.add(profile.id);
          profileLatencies.remove(profile.id);
          latencyErrors[profile.id] = '$error';
        });
        _message(coreSettings.pingMode == 'icmp'
            ? 'ICMP не ответил. Попробуйте TCP в настройках.'
            : coreSettings.pingMode == 'proxy'
                ? 'Proxy GET: ${_compactError('$error')}'
                : _compactError('$error'));
      }
    } finally {
      if (mounted && generation == _probeGeneration)
        setState(() => checkingPing = false);
    }
  }

  Future<void> _checkOneProfile(ServerProfile profile) async {
    if (_checkingProfileIds.contains(profile.id)) return;
    setState(() => _checkingProfileIds.add(profile.id));
    try {
      final samples = await _probeProfile(profile);
      if (!mounted) return;
      final latency = samples[samples.length ~/ 2];
      setState(() {
        profileLatencies[profile.id] = latency;
        failedLatencies.remove(profile.id);
        latencyErrors.remove(profile.id);
        if (selectedId == profile.id) {
          pingMs = latency;
          pingSamples = samples;
        }
      });
      _message('${profile.name}: $latency мс');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        profileLatencies.remove(profile.id);
        failedLatencies.add(profile.id);
        latencyErrors[profile.id] = '$error';
      });
      _message('${profile.name}: ${_compactError('$error')}');
    } finally {
      if (mounted) {
        setState(() => _checkingProfileIds.remove(profile.id));
      }
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
      _checkingProfileIds.addAll(targets.map((profile) => profile.id));
    });
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < targets.length) {
        final profile = targets[cursor++];
        int? latency;
        try {
          final samples = await _probeProfile(profile);
          latency = samples[samples.length ~/ 2];
        } catch (error) {
          latencyErrors[profile.id] = '$error';
        }
        if (!mounted) return;
        setState(() {
          _checkingProfileIds.remove(profile.id);
          if (latency == null) {
            failedLatencies.add(profile.id);
            profileLatencies.remove(profile.id);
          } else {
            failedLatencies.remove(profile.id);
            latencyErrors.remove(profile.id);
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

  String _compactError(String error) {
    final compact = error.replaceFirst(RegExp(r'^SocketException: '), '');
    return compact.length > 150 ? '${compact.substring(0, 147)}…' : compact;
  }

  String _pingQuality(int value) {
    if (value < 90) return _text('Отлично', 'Excellent');
    if (value < 180) return _text('Хорошо', 'Good');
    if (value < 300) return _text('Средне', 'Fair');
    return _text('Высокая задержка', 'High latency');
  }

  Color _latencyColor(int? value) {
    if (value == null) return _muted;
    if (value < 90) return _mint;
    if (value < 180) return const Color(0xFF71C8FF);
    if (value < 300) return const Color(0xFFFFC857);
    return const Color(0xFFFF7777);
  }

  String _pingLabel() {
    if (checkingPing ||
        (selectedId != null && _checkingProfileIds.contains(selectedId))) {
      return _text('Проверяем…', 'Checking…');
    }
    if (pingMs == null) return _text('Проверить задержку', 'Check latency');
    final type = switch (coreSettings.pingMode) {
      'icmp' => 'ICMP',
      'tcp' => 'TCP',
      _ => 'Proxy GET',
    };
    return switch (coreSettings.pingView) {
      'number' => '$type · $pingMs ${english ? 'ms' : 'мс'}',
      'quality' => _pingQuality(pingMs!),
      _ =>
        '$type · $pingMs ${english ? 'ms' : 'мс'} · ${_pingQuality(pingMs!)}',
    };
  }

  Future<void> _refreshAllSubscriptions({bool quiet = false}) async {
    await _refreshSubscriptions(quiet: quiet, dueOnly: false);
  }

  Future<void> _refreshDueSubscriptions() async {
    await _refreshSubscriptions(quiet: true, dueOnly: true);
  }

  int _subscriptionRefreshIntervalHours(Map<String, dynamic> subscription) {
    final metadata = subscription['metadata'];
    final recommended = metadata is Map
        ? int.tryParse('${metadata['updateIntervalHours'] ?? ''}')
        : null;
    if (recommended != null && recommended > 0) return recommended;
    // profile-update-interval is expressed in hours. Providers that omit it
    // use the common 12-hour client default.
    return _defaultSubscriptionRefreshHours;
  }

  bool _subscriptionRefreshDue(
      Map<String, dynamic> subscription, DateTime now) {
    final rawUpdatedAt = subscription['updatedAt'];
    final updatedAt =
        rawUpdatedAt is String ? DateTime.tryParse(rawUpdatedAt) : null;
    if (updatedAt == null) return true;
    final age = now.difference(updatedAt);
    if (age.isNegative) return false;
    return age >=
        Duration(hours: _subscriptionRefreshIntervalHours(subscription));
  }

  Future<void> _refreshSubscriptions(
      {required bool quiet, required bool dueOnly}) async {
    if (refreshingSubscriptions || subscriptions.isEmpty) return;
    final retryAt = subscriptionRetryNotBefore;
    if (quiet && retryAt != null && DateTime.now().isBefore(retryAt)) {
      _scheduleSubscriptionRefresh();
      return;
    }
    final all = List<Map<String, dynamic>>.from(subscriptions);
    final targets = dueOnly
        ? all
            .where((subscription) =>
                _subscriptionRefreshDue(subscription, DateTime.now()))
            .toList()
        : all;
    if (targets.isEmpty || !mounted) return;
    setState(() => refreshingSubscriptions = true);
    var failed = 0;
    try {
      for (final sub in targets) {
        if (!mounted) return;
        final url = sub['url'];
        if (url is! String ||
            url.isEmpty ||
            !await _refreshSubscription(url, true)) {
          failed++;
        }
      }
    } finally {
      if (mounted) setState(() => refreshingSubscriptions = false);
      subscriptionRetryNotBefore =
          failed > 0 ? DateTime.now().add(const Duration(seconds: 10)) : null;
      _scheduleSubscriptionRefresh();
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
                  title: Text(_localized('Добавить подписку')),
                  subtitle: Text(_localized('Один или несколько URL')),
                  onTap: () => Navigator.pop(context, 'subscription')),
              ListTile(
                  leading: Icon(Icons.link_rounded, color: _accent),
                  title: Text(_localized('Импортировать профиль')),
                  subtitle:
                      Text(_localized('Ссылка · JSON-файл · буфер обмена')),
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
                                if (Platform.isAndroid || Platform.isIOS)
                                  TextButton.icon(
                                    onPressed: () async {
                                      final scanned = await showDialog<String>(
                                        context: ctx,
                                        builder: (scanContext) => Dialog(
                                          backgroundColor: _surface,
                                          clipBehavior: Clip.antiAlias,
                                          child: SizedBox(
                                            width: 420,
                                            height: 500,
                                            child: Column(
                                              children: [
                                                ListTile(
                                                  title: Text(_localized(
                                                      'Сканировать QR-код')),
                                                  trailing: IconButton(
                                                    onPressed: () =>
                                                        Navigator.pop(
                                                            scanContext),
                                                    icon: const Icon(
                                                        Icons.close_rounded),
                                                  ),
                                                ),
                                                Expanded(
                                                  child: MobileScanner(
                                                    onDetect: (capture) {
                                                      final value = capture
                                                          .barcodes
                                                          .map((barcode) =>
                                                              barcode.rawValue)
                                                          .firstWhere(
                                                              (value) =>
                                                                  value !=
                                                                      null &&
                                                                  value
                                                                      .trim()
                                                                      .isNotEmpty,
                                                              orElse: () =>
                                                                  null);
                                                      if (value != null &&
                                                          scanContext.mounted) {
                                                        Navigator.pop(
                                                            scanContext, value);
                                                      }
                                                    },
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      );
                                      if (scanned != null && ctx.mounted) {
                                        controller
                                          ..text = scanned.trim()
                                          ..selection = TextSelection.collapsed(
                                              offset: controller.text.length);
                                      }
                                    },
                                    icon: const Icon(Icons.qr_code_scanner,
                                        size: 18),
                                    label: Text(_localized('Сканировать QR')),
                                  ),
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
                                    label: Text(_localized('Из буфера'))),
                                TextButton.icon(
                                    onPressed: () async {
                                      try {
                                        final result = await openFile(
                                            acceptedTypeGroups: const [
                                              XTypeGroup(
                                                  label: 'JSON',
                                                  extensions: ['json'])
                                            ]);
                                        if (result == null) return;
                                        final bytes =
                                            await result.readAsBytes();
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
                                    label: Text(_localized('JSON-файл'))),
                                FilledButton.icon(
                                    onPressed: () =>
                                        Navigator.pop(ctx, controller.text),
                                    icon: Icon(Icons.arrow_forward_rounded,
                                        size: 18),
                                    label: Text(_localized('Добавить'))),
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
              title: Text(_localized('Новая подписка')),
              content: SizedBox(
                  width: 460,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: label,
                        decoration: InputDecoration(
                            labelText: _localized('Название (необязательно)'),
                            hintText: _localized('Например, Личная подписка'))),
                    SizedBox(height: 12),
                    TextField(
                        controller: urls,
                        autofocus: true,
                        minLines: 4,
                        maxLines: 8,
                        decoration: InputDecoration(
                            labelText: _localized('URL подписки'),
                            hintText:
                                'https://…\n${_localized('Можно добавить несколько URL, по одному на строку')}')),
                    TextButton.icon(
                        onPressed: () async {
                          final data =
                              await Clipboard.getData(Clipboard.kTextPlain);
                          if (data?.text?.isNotEmpty == true)
                            urls.text = data!.text!;
                        },
                        icon: Icon(Icons.content_paste_rounded),
                        label: Text(_localized('Вставить из буфера'))),
                  ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(_localized('Отмена'))),
                FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, (urls.text, label.text)),
                    child: Text(_localized('Добавить')))
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
    _scheduleSubscriptionRefresh();
    for (final url in sources) {
      unawaited(_checkSubscriptionEndpoint(url));
    }
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
                    title: Text(_localized('Путь подписки')),
                    content: TextField(
                        controller: controller,
                        autofocus: true,
                        keyboardType: TextInputType.url,
                        decoration: InputDecoration(
                            labelText: _localized('URL подписки'),
                            hintText: 'https://…')),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text(_localized('Отмена'))),
                      FilledButton(
                          onPressed: () =>
                              Navigator.pop(context, controller.text.trim()),
                          child: Text(_localized('Обновить')))
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
                    title: Text(_localized('Название подписки')),
                    content: TextField(controller: controller, autofocus: true),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text(_localized('Отмена'))),
                      FilledButton(
                          onPressed: () =>
                              Navigator.pop(context, controller.text.trim()),
                          child: Text(_localized('Сохранить')))
                    ]));
        if (name != null && name.isNotEmpty) {
          setState(() => sub['name'] = name);
          await _saveSubscriptions();
        }
        break;
      case 'remove':
        final subscriptionIds =
            (sub['ids'] as List? ?? []).cast<String>().toSet();
        final remainingIds = subscriptions
            .where((item) => item['url'] != url)
            .expand((item) => (item['ids'] as List? ?? []).cast<String>())
            .toSet();
        final removedIds = subscriptionIds.difference(remainingIds);
        if (activeProfileId != null &&
            removedIds.contains(activeProfileId) &&
            backend.state != VpnState.disconnected) {
          await _disconnectActive();
        }
        if (!mounted) break;
        setState(() {
          subscriptions.removeWhere((s) => s['url'] == url);
          profiles.removeWhere((profile) => removedIds.contains(profile.id));
          if (selectedId != null && removedIds.contains(selectedId)) {
            selectedId = profiles.firstOrNull?.id;
          }
          if (activeProfileId != null && removedIds.contains(activeProfileId)) {
            activeProfileId = null;
            pendingReconnect = false;
          }
          subscriptionEndpointPings.remove(url);
          checkingSubscriptionPings.remove(url);
          collapsedSubscriptions.remove(url);
          collapsedSubscriptionInfo.remove(url);
          subscriptionProfileIds = subscriptions
              .expand((s) => (s['ids'] as List? ?? []).cast<String>())
              .toSet()
              .toList();
        });
        await _persist();
        await _saveSubscriptions();
        _scheduleSubscriptionRefresh();
        _message('Подписка и её серверы удалены');
        break;
    }
  }

  void _bindCoreRecoveryNotices(CoreProcessBackend core) {
    core.onRecoveryNotice = (message, {bool error = false}) {
      if (!mounted) return;
      GhostNotice.show(
        context,
        _messageText(message),
        error: error,
        icon: error ? Icons.warning_amber_rounded : Icons.restart_alt_rounded,
        dismissTooltip: _localized('Закрыть уведомление'),
      );
    };
  }

  String _messageText(String text) {
    if (!english) return text;
    final exact = _englishLabels[text];
    if (exact != null) return exact;
    var translated = text;
    for (final entry in const <(String, String)>[
      (
        'Не удалось загрузить список рекламы: ',
        'Could not load ad block list: '
      ),
      (
        'Не удалось обновить список рекламы: ',
        'Could not refresh ad block list: '
      ),
      ('Не удалось подготовить TUN-конфиг: ', 'Could not prepare TUN config: '),
      ('Не удалось применить изменения: ', 'Could not apply changes: '),
      ('Не удалось переключить сервер: ', 'Could not switch server: '),
      ('Не удалось включить подключение: ', 'Could not connect: '),
      (
        'Не удалось восстановить Kill Switch: ',
        'Could not restore Kill Switch: '
      ),
      (
        'Не удалось восстановить системный прокси: ',
        'Could not restore the system proxy: '
      ),
      ('Не удалось изменить Kill Switch: ', 'Could not change Kill Switch: '),
      (
        'Не удалось проверить маршрут TUN: ',
        'Could not verify the TUN route: '
      ),
      (
        'Не удалось разрешить адрес сервера ',
        'Could not resolve the server address '
      ),
      ('Не удалось переключить сервер: ', 'Could not switch server: '),
      (
        'Windows запрос прав администратора отменён: ',
        'Windows administrator permission request was cancelled: '
      ),
      ('Диагностика подключения: ', 'Connection diagnostics: '),
      ('Ошибка подключения: ', 'Connection error: '),
      ('Проверено серверов: ', 'Servers checked: '),
      ('Переключаю сервер на ', 'Switching server to '),
      ('Подключение: ', 'Connecting: '),
      ('Подключено к ', 'Connected to '),
      ('Потеряно соединение: ', 'Connection lost: '),
      ('Не удалось обновить подписок: ', 'Could not refresh subscriptions: '),
      ('Подписка обновлена: ', 'Subscription updated: '),
      ('Не удалось загрузить ', 'Could not load '),
      ('Неверный домен: ', 'Invalid domain: '),
      ('Не удалось экспортировать журнал: ', 'Could not export the journal: '),
      ('Не удалось проверить обновления: ', 'Could not check for updates: '),
      ('Не удалось установить обновление: ', 'Could not install the update: '),
      (
        'Не удалось открыть страницу релизов: ',
        'Could not open the releases page: '
      ),
    ]) {
      if (translated.startsWith(entry.$1)) {
        translated = '${entry.$2}${translated.substring(entry.$1.length)}';
        break;
      }
    }
    final labels = _englishLabels.entries.toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));
    for (final entry in labels) {
      if (entry.key.isNotEmpty) {
        translated = translated.replaceAll(entry.key, entry.value);
      }
    }
    return translated
        .replaceAll(' мс', ' ms')
        .replaceAll(' МБ', ' MB')
        .replaceAll(' ГБ', ' GB');
  }

  String _localizeJournalLine(String line) {
    if (!english) return line;
    var result = line;
    final labels = _englishLabels.entries.toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));
    for (final entry in labels) {
      if (entry.key.isNotEmpty)
        result = result.replaceAll(entry.key, entry.value);
    }
    for (final entry in const <(String, String)>[
      ('Подключение: ', 'Connecting: '),
      ('Подключено к ', 'Connected to '),
      ('Потеряно соединение: ', 'Connection lost: '),
      ('Ошибка подключения: ', 'Connection error: '),
      ('Не удалось включить подключение: ', 'Could not connect: '),
      ('Не удалось переключить сервер: ', 'Could not switch server: '),
      ('Не удалось обновить подписок: ', 'Could not refresh subscriptions: '),
      (
        'Не удалось восстановить системный прокси: ',
        'Could not restore the system proxy: '
      ),
      (
        'Не удалось проверить маршрут TUN: ',
        'Could not verify the TUN route: '
      ),
      ('Диагностика подключения: ', 'Connection diagnostics: '),
      ('Проверено серверов: ', 'Servers checked: '),
      (
        'Системный TUN-маршрут активен через ',
        'System TUN route is active through '
      ),
    ]) {
      result = result.replaceAll(entry.$1, entry.$2);
    }
    return _messageText(result);
  }

  void _message(String text) {
    final displayText = _messageText(text);
    GhostNotice.show(
      context,
      displayText,
      dismissTooltip: _localized('Закрыть уведомление'),
      error: RegExp(
        'ошиб|не удалось|неверн|нет ответа|не отвечает|не поддерж|error|failed|invalid|no response|could not',
        caseSensitive: false,
      ).hasMatch(displayText),
    );
  }

  Future<void> _addProfile() async {
    final controller = TextEditingController();
    final input = await _showPasteDialog(
      title: _localized('Добавить сервер'),
      description: _localized(
          'Вставьте ссылку или JSON-конфиг сервера, либо выберите JSON-файл. Также можно добавить URL подписки.'),
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
        _scheduleSubscriptionRefresh();
      }
    } catch (e) {
      if (mounted) _message('$e');
    }
  }

  Future<void> _selectCore(String value) async {
    if (Platform.isIOS && value == 'Xray') {
      _message('На iOS VPN-режим использует sing-box');
      return;
    }
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
      backend = Platform.isAndroid
          ? AndroidVpnBackend()
          : next == 'xray'
              ? XrayBackend()
              : SingBoxBackend();
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
            top: false,
            child: Stack(children: [
              Positioned.fill(
                  child: IgnorePointer(
                      child: RepaintBoundary(
                          child: CustomPaint(
                              painter: _AmbientBackgroundPainter(
                                  animation: ambientMotion,
                                  color: _accent,
                                  enabled: animatedBackground))))),
              Padding(
                  padding: const EdgeInsets.fromLTRB(5, 16, 5, 12),
                  child: LayoutBuilder(builder: (context, bounds) {
                    final wideLayout = bounds.maxWidth >= 800;
                    final page = ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 280),
                            reverseDuration: const Duration(milliseconds: 180),
                            layoutBuilder: (current, previous) => Stack(
                                  fit: StackFit.passthrough,
                                  children: [
                                    ...previous,
                                    if (current != null) current,
                                  ],
                                ),
                            transitionBuilder: (child, animation) {
                              final fade = CurvedAnimation(
                                parent: animation,
                                curve: Curves.easeInOutCubic,
                                reverseCurve: Curves.easeInOutCubic,
                              );
                              return FadeTransition(
                                opacity: fade,
                                child: SlideTransition(
                                  position: Tween<Offset>(
                                          begin: const Offset(0, .012),
                                          end: Offset.zero)
                                      .animate(fade),
                                  child: child,
                                ),
                              );
                            },
                            child: KeyedSubtree(
                                key: ValueKey(_tabIndex),
                                child: settings
                                    ? _scrollFrame(_settings(), settingsScroll)
                                    : routingTab
                                        ? _scrollFrame(
                                            _routingPage(), routingScroll)
                                        : _scrollFrame(_home(), homeScroll))));
                    if (wideLayout) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: 120,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
                              child: _sideNav(),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Stack(
                              children: [
                                Positioned.fill(child: page),
                                Positioned(
                                  top: 0,
                                  left: 0,
                                  right: 0,
                                  child: _header(wideLayout: true),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    }
                    return Stack(children: [
                      Positioned.fill(child: page),
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: _header(wideLayout: false),
                      ),
                      Positioned(
                        left: 10,
                        right: 10,
                        bottom: 8,
                        child: _nav(),
                      ),
                    ]);
                  }))
            ]),
          )));

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
                  padding: const EdgeInsets.fromLTRB(5, 58, 9, 0),
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
        popUpAnimationStyle: AnimationStyle(
          duration: const Duration(milliseconds: 170),
          reverseDuration: const Duration(milliseconds: 130),
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        ),
        items: [
          _menuItem('ping_all', Icons.speed_rounded, 'Пинговать все'),
          _menuItem('refresh_all', Icons.sync_rounded, 'Обновить подписки'),
          _menuItem('logs', Icons.article_outlined, 'Журнал соединения'),
          _menuItem('history', Icons.history_rounded, 'Последние подключения'),
          _menuItem('about', Icons.info_outline_rounded,
              _text('О приложении', 'About GhostBox')),
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
      case 'about':
        await _showAbout();
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
            Expanded(
                child: Text(_localized('Один раз разреши TUN'),
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
            IconButton(
                tooltip: _localized('Скопировать команду'),
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
              _text(
                  'Запусти команду в терминале после первого запуска AppImage. Сам VPN будет работать от твоего пользователя, без sudo.',
                  'Run this command in a terminal after launching the AppImage once. The VPN itself will run as your user without sudo.'),
              style: TextStyle(fontSize: 10, color: _muted, height: 1.4)),
        ]),
      );

  Widget _versionMark() {
    final version = GitHubUpdater.displayVersion(GitHubUpdater.currentVersion);
    final separator = version.indexOf('-');
    if (separator < 0) {
      return Text(version,
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w500, color: _muted));
    }
    final versionNumber = version.substring(0, separator);
    final stage = version.substring(separator + 1);
    final glyph = switch (stage.toLowerCase()) {
      'alpha' => 'α',
      'beta' => 'β',
      _ => stage.toUpperCase(),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text(versionNumber,
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w500, color: _muted)),
      const SizedBox(width: 4),
      Tooltip(
        message: stage,
        child: Container(
          constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: _accent.withValues(alpha: .16),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: _accent.withValues(alpha: .35)),
          ),
          alignment: Alignment.center,
          child: Text(glyph,
              style: TextStyle(
                  fontSize: glyph.length == 1 ? 11 : 8,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  color: _accent)),
        ),
      ),
    ]);
  }

  Widget _header({required bool wideLayout}) => SizedBox(
      height: 48,
      child: Stack(alignment: Alignment.center, children: [
        if (!wideLayout)
          Positioned(
            left: 0,
            child: SizedBox(
              width: 44,
              height: 44,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 340),
                reverseDuration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  final motion = CurvedAnimation(
                      parent: animation, curve: Curves.easeOutCubic);
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, .08),
                        end: Offset.zero,
                      ).animate(motion),
                      child: ScaleTransition(
                        scale: Tween<double>(begin: .9, end: 1).animate(motion),
                        child: child,
                      ),
                    ),
                  );
                },
                child: _topButton(
                    routeListOpen || settings || routingTab
                        ? Icons.arrow_back_ios_new_rounded
                        : Icons.settings_rounded, () {
                  if (routeListOpen) {
                    setState(() => routeListOpen = false);
                  } else if (settings && settingsSubpage != null) {
                    setState(() => settingsSubpage = null);
                  } else {
                    _openTab(settings || routingTab ? 0 : 2);
                  }
                },
                    key: ValueKey(
                        'header-button-${routeListOpen || settings || routingTab ? 'back' : 'settings'}')),
              ),
            ),
          ),
        Center(
            child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 64),
                child: _headerIsland(
                    expanded: routeListOpen || settings || routingTab,
                    width: math
                        .min(
                          settings || routeListOpen
                              ? 210.0
                              : routingTab
                                  ? 194.0
                                  : 174.0,
                          (MediaQuery.sizeOf(context).width - 128)
                              .clamp(150.0, 220.0),
                        )
                        .toDouble(),
                    child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 270),
                        reverseDuration: const Duration(milliseconds: 220),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) {
                          final motion = CurvedAnimation(
                              parent: animation, curve: Curves.easeOutCubic);
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: Tween<Offset>(
                                      begin: const Offset(0, .10),
                                      end: Offset.zero)
                                  .animate(motion),
                              child: ScaleTransition(
                                scale: Tween<double>(begin: .985, end: 1)
                                    .animate(motion),
                                child: child,
                              ),
                            ),
                          );
                        },
                        child: routeListOpen || settings || routingTab
                            ? Text(
                                key: ValueKey(routeListOpen
                                    ? 'header-domains'
                                    : settings
                                        ? 'header-settings-$settingsSubpage'
                                        : 'header-routing'),
                                routeListOpen
                                    ? _localized('Список доменов')
                                    : settings
                                        ? switch (settingsSubpage) {
                                            'contacts' =>
                                              _localized('Контакты'),
                                            'release' => _localized('О релизе'),
                                            'about' =>
                                              _localized('О приложении'),
                                            _ => _localized('Настройки'),
                                          }
                                        : _localized('Маршрут'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: .2),
                              )
                            : FittedBox(
                                key: ValueKey('header-brand-$wideLayout'),
                                fit: BoxFit.scaleDown,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    InkWell(
                                      borderRadius: BorderRadius.circular(9),
                                      onTap: _showAbout,
                                      child: _brandMark(22),
                                    ),
                                    const SizedBox(width: 7),
                                    Text('GhostBox',
                                        style: const TextStyle(
                                            fontSize: 17,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: .2)),
                                    const SizedBox(width: 7),
                                    InkWell(
                                      borderRadius: BorderRadius.circular(8),
                                      onTap: _openReleaseDetails,
                                      child: _versionMark(),
                                    ),
                                  ],
                                ),
                              ))))),
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
                    builder: (buttonContext) => _headerActionIsland(
                        child: IconButton(
                            tooltip: _localized('Действия'),
                            onPressed: () => _openActionsMenu(buttonContext),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                                width: 44, height: 44),
                            icon: Icon(Icons.more_horiz_rounded,
                                color: _foreground, size: 25)))))),
      ]));

  Widget _headerIsland({
    required Widget child,
    required double width,
    bool expanded = false,
  }) =>
      ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 9, sigmaY: 9),
          child: AnimatedScale(
            scale: expanded ? 1.045 : 1,
            duration: const Duration(milliseconds: 360),
            curve: Curves.easeOutBack,
            child: AnimatedSize(
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOutBack,
              alignment: Alignment.center,
              child: AnimatedContainer(
                width: width,
                duration: const Duration(milliseconds: 440),
                curve: Curves.easeOutBack,
                padding: EdgeInsets.symmetric(
                    horizontal: expanded ? 16 : 12, vertical: 5),
                decoration: BoxDecoration(
                  color: Color.alphaBlend(_accent.withValues(alpha: .075),
                      _surface.withValues(alpha: .82)),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: Color.alphaBlend(_accent.withValues(alpha: .16),
                          Colors.white.withValues(alpha: .1))),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: .055),
                      _accent.withValues(alpha: .045),
                      _surface.withValues(alpha: .02),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .17),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                    BoxShadow(
                      color: _accent.withValues(alpha: .075),
                      blurRadius: 18,
                      spreadRadius: -5,
                    ),
                  ],
                ),
                child: child,
              ),
            ),
          ),
        ),
      );

  Widget _headerActionIsland({required Widget child, bool circular = false}) =>
      ClipRRect(
        borderRadius: BorderRadius.circular(circular ? 22 : 16),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Color.alphaBlend(_accent.withValues(alpha: .065),
                  _surface.withValues(alpha: .68)),
              borderRadius: BorderRadius.circular(circular ? 22 : 16),
              border: Border.all(color: Colors.white.withValues(alpha: .12)),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: .07),
                  _accent.withValues(alpha: .035),
                  _surface.withValues(alpha: .02),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .14),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: child,
          ),
        ),
      );

  Widget _brandMark(double size) {
    final appearance = ThemeScope.of(context);
    return GhostBoxBrandIcon(
      variant: appearance.iconVariant,
      size: size,
      foreground: appearance.iconForeground,
      background: appearance.iconBackground,
    );
  }

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
        settingsSubpage = null;
        settings = index == 2;
        routingTab = index == 1;
      });

  void _openSettingsPage(String page) => setState(() {
        settingsSubpage = page;
        settings = true;
        routingTab = false;
        routeListOpen = false;
      });

  void _openReleaseDetails() => _openSettingsPage('release');

  Widget
      _topButton(IconData icon, VoidCallback onTap, {Key? key}) => MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _headerButtonHovered = true),
            onExit: (_) => setState(() => _headerButtonHovered = false),
            child: AnimatedScale(
              scale: _headerButtonHovered ? 1.045 : 1,
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              child: _headerActionIsland(
                circular: true,
                child: IconButton(
                    key: key,
                    onPressed: onTap,
                    icon: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 210),
                        transitionBuilder: (child, animation) => FadeTransition(
                            opacity: animation,
                            child: RotationTransition(
                                turns: Tween<double>(begin: -.08, end: 0)
                                    .animate(CurvedAnimation(
                                        parent: animation,
                                        curve: Curves.easeOutCubic)),
                                child: ScaleTransition(
                                    scale: Tween<double>(begin: .76, end: 1)
                                        .animate(CurvedAnimation(
                                            parent: animation,
                                            curve: Curves.easeOutBack)),
                                    child: child))),
                        child: Icon(icon, key: ValueKey(icon.codePoint), size: 25, color: _foreground)),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(width: 44, height: 44),
                    style: IconButton.styleFrom(shape: const CircleBorder())),
              ),
            ),
          );

  Widget _home() => SingleChildScrollView(
      controller: homeScroll,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
            borderRadius: BorderRadius.circular(30),
            child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 7, sigmaY: 7),
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
              message: _messageText(pingSamples.isEmpty
                  ? 'Проверка ${coreSettings.pingMode == 'icmp' ? 'ICMP адреса' : coreSettings.pingMode == 'tcp' ? 'TCP порта' : 'HTTP GET через прокси'} выбранного сервера'
                  : '${coreSettings.pingCount} проб · ${pingSamples.first}–${pingSamples.last} мс · медиана $pingMs мс'),
              child: TextButton.icon(
                  onPressed: _checkConnection,
                  icon: checkingPing ||
                          (selectedId != null &&
                              _checkingProfileIds.contains(selectedId))
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
                      child: Text(_localized(_pingLabel()),
                          key: ValueKey(_pingLabel()))),
                  style: TextButton.styleFrom(
                      foregroundColor: _latencyColor(pingMs),
                      textStyle: TextStyle(fontSize: 12),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 11, vertical: 8),
                      backgroundColor: _surface.withValues(alpha: .68),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15),
                        side: BorderSide(
                            color: Colors.white.withValues(alpha: .10)),
                      )))),
          Spacer(),
          if (checkingAll)
            Text('$pingAllDone/$pingAllTotal',
                style: TextStyle(color: _muted, fontSize: 11)),
          TextButton(
              onPressed: () => setState(() => hideProfiles = !hideProfiles),
              style: TextButton.styleFrom(
                  foregroundColor: _muted,
                  textStyle: TextStyle(fontSize: 12),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                  backgroundColor: _surface.withValues(alpha: .68),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                      side: BorderSide(
                          color: Colors.white.withValues(alpha: .10)))),
              child: Text(_localized(
                  hideProfiles ? 'Показать серверы' : 'Скрыть серверы')))
        ]),
        _animatedReconnectBanner(
          visible: pendingReconnect,
          child: Padding(
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
                        child: Text(
                            _localized('Новый выбор ждёт переподключения'),
                            style: TextStyle(fontSize: 12))),
                    TextButton(
                        onPressed: _applyPendingReconnect,
                        child: Text(_localized('Применить'))),
                  ]))),
        ),
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
                    backgroundColor: _surface.withValues(alpha: .68),
                    side: BorderSide(color: _accent.withValues(alpha: .28)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(22))),
                icon: Icon(Icons.add_rounded, size: 23),
                label: Text(_localized('Добавить подписку или сервер'),
                    style: TextStyle(fontSize: 12)))),
        SizedBox(height: 112),
      ]));

  Widget _routingPage() => routeListOpen
      ? _routeListEditor()
      : ListView(
          controller: routingScroll,
          key: const PageStorageKey('routing'),
          padding: const EdgeInsets.only(top: 14, bottom: 120),
          children: [
            Text(_text('Как пускать трафик', 'Traffic routing'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.6)),
            const SizedBox(height: 5),
            Text(
                _text('Выбери, какие сайты отправлять через сервер',
                    'Choose which sites go through the server'),
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted, fontSize: 12)),
            const SizedBox(height: 20),
            _routeOption(
                _text('Всё через VPN', 'All traffic through VPN'),
                _text('Любые сайты идут через сервер.',
                    'All sites use the server.'),
                Icons.shield_rounded,
                'proxy'),
            _routeOption(
                _text('Только сайты из списка', 'Only sites in the list'),
                _text('В список — через VPN, всё остальное напрямую.',
                    'Listed sites use VPN; everything else connects directly.'),
                Icons.list_alt_rounded,
                'rules'),
            _routeOption(
                _text('Всё, кроме списка', 'Everything except the list'),
                _text('Сайты из списка идут напрямую, остальные — через VPN.',
                    'Listed sites connect directly; everything else uses VPN.'),
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
                      tooltip: _localized('Открыть список правил'),
                      onPressed: () => _openRouteList(coreSettings.routing),
                      icon: const Icon(Icons.chevron_right_rounded))),
              Padding(
                  padding: const EdgeInsets.only(top: 3, left: 2),
                  child: Text(
                      'Домены (*.ru) и IP-сети (203.0.113.0/24). Для IP-списков маршрутизация работает без TLS sniffing. Принимается JSON Amnezia.',
                      style:
                          TextStyle(color: _muted, fontSize: 11, height: 1.4))),
            ],
            _animatedReconnectBanner(
                visible: pendingReconnect,
                child: Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: _reconnectNotice())),
          ],
        );

  void _openRouteList(String mode) {
    routeListMode = mode;
    final values = mode == 'rules'
        ? coreSettings.proxyDomains
        : coreSettings.directDomains;
    routeListController.text = values.join('\n');
    routeDomainController.clear();
    setState(() => routeListOpen = true);
  }

  void _addRouteDomain() {
    final value =
        CoreSettings.normalizeRoutePattern(routeDomainController.text.trim());
    if (!CoreSettings.isValidRoutePattern(value)) {
      _message(_text('Укажи домен, *.маску или IP-сеть',
          'Enter a domain, *.pattern, or IP network'));
      return;
    }
    final parsed = _readRouteDomains(routeListController.text);
    if (parsed == null) {
      _message(_text('Исправь JSON-список или удали его перед добавлением',
          'Fix the JSON list or clear it before adding a rule'));
      return;
    }
    final values = parsed;
    values.add(value);
    routeListController.text =
        values.map(CoreSettings.normalizeRoutePattern).toSet().join('\n');
    routeDomainController.clear();
  }

  void _removeRouteDomain(String value) {
    final values = _readRouteDomains(routeListController.text) ?? <String>[];
    values.removeWhere((entry) =>
        CoreSettings.normalizeRoutePattern(entry) ==
        CoreSettings.normalizeRoutePattern(value));
    routeListController.text = values.join('\n');
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
    if (backend.state == VpnState.connecting) {
      _message('Подождите завершения подключения');
      return;
    }
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
        padding: const EdgeInsets.only(top: 14, bottom: 120),
        children: [
          Text(
              routeListMode == 'rules'
                  ? _localized('Сайты через VPN')
                  : _localized('Исключения из VPN'),
              style:
                  const TextStyle(fontSize: 23, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
              _localized(
                  'Домен, маска или IP-сеть на строку. Подойдут *.ru, 10.0.0.0/8 и JSON-списки Amnezia.'),
              style: TextStyle(color: _muted, fontSize: 12)),
          const SizedBox(height: 16),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
                child: TextField(
              controller: routeDomainController,
              autofocus: true,
              autocorrect: false,
              textCapitalization: TextCapitalization.none,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _addRouteDomain(),
              decoration: InputDecoration(
                labelText:
                    _text('Добавить сайт или сеть', 'Add site or network'),
                hintText: 'example.com · *.ru · 203.0.113.0/24',
                prefixIcon: const Icon(Icons.language_rounded),
                filled: true,
                fillColor: _surface,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(color: _line)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(color: _line)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(color: _accent, width: 1.4)),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              ),
            )),
            const SizedBox(width: 8),
            Padding(
                padding: const EdgeInsets.only(top: 5),
                child: IconButton.filledTonal(
                    tooltip: _text('Добавить правило', 'Add rule'),
                    onPressed: _addRouteDomain,
                    icon: const Icon(Icons.add_rounded))),
          ]),
          const SizedBox(height: 10),
          ValueListenableBuilder<TextEditingValue>(
              valueListenable: routeListController,
              builder: (context, value, _) {
                final domains =
                    _readRouteDomains(value.text) ?? const <String>[];
                if (domains.isEmpty) return const SizedBox.shrink();
                return Wrap(
                    spacing: 7,
                    runSpacing: 2,
                    children: domains
                        .map((domain) => InputChip(
                              label: Text(domain),
                              onDeleted: () => _removeRouteDomain(domain),
                              deleteIcon:
                                  const Icon(Icons.close_rounded, size: 16),
                              side: BorderSide(
                                  color: _accent.withValues(alpha: .35)),
                              backgroundColor: _accent.withValues(alpha: .08),
                            ))
                        .toList());
              }),
          const SizedBox(height: 8),
          Text(_text('Или вставь список целиком', 'Or paste a full list'),
              style: TextStyle(color: _muted, fontSize: 11)),
          const SizedBox(height: 7),
          Container(
            decoration: BoxDecoration(
                color: _surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _line.withValues(alpha: .55))),
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: routeListController,
              minLines: 6,
              maxLines: 12,
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
              label: Text(_localized('Скопировать как JSON'))),
          const SizedBox(height: 10),
          SizedBox(
              width: double.infinity,
              child: FilledButton(
                  onPressed: _saveRouteList,
                  child: Text(_localized('Сохранить список')))),
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
        Expanded(
            child: Text(
                _localized('Переподключи ядро, чтобы применить маршрут.'),
                style: TextStyle(fontSize: 12))),
        TextButton(
            onPressed: _applyPendingReconnect,
            child: Text(_localized('Применить'))),
      ]));

  Widget _animatedReconnectBanner(
          {required bool visible, required Widget child}) =>
      AnimatedSize(
        duration: const Duration(milliseconds: 190),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 170),
          reverseDuration: const Duration(milliseconds: 140),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position:
                  Tween<Offset>(begin: const Offset(0, -.08), end: Offset.zero)
                      .animate(animation),
              child: child,
            ),
          ),
          child: visible
              ? KeyedSubtree(
                  key: const ValueKey('reconnect-visible'), child: child)
              : const SizedBox(
                  key: ValueKey('reconnect-hidden'), width: 0, height: 0),
        ),
      );

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
                                    ? [
                                        Color.lerp(_accent, Colors.white, .28)!,
                                        _accent,
                                        Color.lerp(_accent, Colors.black, .18)!,
                                      ]
                                    : [
                                        Color.lerp(_accent, Colors.white, .22)!,
                                        _accent,
                                        Color.lerp(_accent, Colors.black, .22)!,
                                      ],
                          ),
                          border: Border.all(
                              color: Colors.white.withValues(alpha: .34),
                              width: 1.2),
                          boxShadow: [
                            BoxShadow(
                              color: _accent.withValues(
                                  alpha: powerHovered ? .48 : .34),
                              blurRadius: powerHovered ? 34 : 25,
                              spreadRadius: powerHovered ? 1 : 0,
                              offset: const Offset(0, 5),
                            ),
                            BoxShadow(
                              color: Colors.black.withValues(alpha: .38),
                              blurRadius: 14,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 240),
                              reverseDuration:
                                  const Duration(milliseconds: 180),
                              switchInCurve: Curves.easeOutBack,
                              switchOutCurve: Curves.easeInCubic,
                              transitionBuilder: (child, animation) {
                                final curved = CurvedAnimation(
                                    parent: animation,
                                    curve: Curves.easeOutCubic);
                                return FadeTransition(
                                  opacity: animation,
                                  child: ScaleTransition(
                                    scale: Tween<double>(begin: .72, end: 1)
                                        .animate(curved),
                                    child: RotationTransition(
                                      turns: Tween<double>(begin: -.04, end: 0)
                                          .animate(curved),
                                      child: child,
                                    ),
                                  ),
                                );
                              },
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
                    style: TextStyle(
                        color: _foreground,
                        fontSize: 15,
                        fontWeight: FontWeight.w600))))
      ]);
  String _uptimeLabel() {
    final d = process?.uptime ?? Duration.zero;
    return '${d.inHours.toString().padLeft(2, '0')}:${(d.inMinutes % 60).toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  String _connectedLabel() {
    return switch (coreSettings.connectionMode) {
      'proxy' => _text('ПРОКСИ ГОТОВ', 'PROXY READY'),
      'system' => _text('СИСТЕМНЫЙ ПРОКСИ', 'SYSTEM PROXY'),
      'tun' => _text('TUN АКТИВЕН', 'TUN ACTIVE'),
      'mixed' => _text('MIXED АКТИВЕН', 'MIXED ACTIVE'),
      _ => _text('ПОДКЛЮЧЕНО', 'CONNECTED'),
    };
  }

  Widget _connectionDetails() =>
      Column(mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _tinyStat('ЯДРО', process?.name ?? coreSettings.core,
              choices: Platform.isIOS
                  ? const [('sing-box', 'sing-box')]
                  : const [('xray', 'Xray'), ('sing-box', 'sing-box')],
              onSelected: (value) =>
                  _selectCore(value == 'xray' ? 'Xray' : value)),
          const SizedBox(width: 8),
          _tinyStat('РЕЖИМ', _connectionModeLabel(coreSettings.connectionMode),
              choices: Platform.isAndroid || Platform.isIOS
                  ? [('tun', Platform.isIOS ? 'iOS VPN' : 'Android VPN')]
                  : const [
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
              _messageText(backend.state == VpnState.connected
                  ? '${Platform.isAndroid ? 'RAM приложения' : 'RAM ядра'} · ${coreMemoryMb == null ? 'считаю…' : '${coreMemoryMb!} МБ'}'
                  : '${Platform.isAndroid ? 'RAM приложения' : 'RAM ядра'} · отключено'),
              style: TextStyle(
                  fontSize: 10, color: _muted, fontWeight: FontWeight.w500),
            ),
          ),
        ],
        if (backend.state == VpnState.connected &&
            (coreSettings.connectionMode == 'tun' ||
                coreSettings.connectionMode == 'mixed')) ...[
          const SizedBox(height: 7),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: Text(
              key: ValueKey(
                  '${trafficStats.available}:${trafficStats.receivedPerSecond.round()}:${trafficStats.sentPerSecond.round()}'),
              trafficStats.available
                  ? '↓ ${formatTrafficRate(trafficStats.receivedPerSecond)}   ↑ ${formatTrafficRate(trafficStats.sentPerSecond)}'
                  : _text(
                      'Скорость · собираю данные…', 'Speed · collecting data…'),
              style: TextStyle(
                  fontSize: 10,
                  color: trafficStats.available ? _accent : _muted,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [ui.FontFeature.tabularFigures()]),
            ),
          ),
        ],
      ]);

  Future<void> _refreshCoreMemoryUsage() async {
    if ((!Platform.isLinux && !Platform.isAndroid) ||
        readingCoreMemory ||
        !coreSettings.showRamUsage) {
      return;
    }
    if (backend.state != VpnState.connected) {
      if (coreMemoryMb != null && mounted) setState(() => coreMemoryMb = null);
      return;
    }
    readingCoreMemory = true;
    try {
      if (Platform.isAndroid && backend is AndroidVpnBackend) {
        final memoryMb = await (backend as AndroidVpnBackend).readMemoryMb();
        if (mounted) setState(() => coreMemoryMb = memoryMb);
        return;
      }
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
          tooltip: _text('Изменить $label', 'Edit $label'),
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
                    style: TextStyle(
                        color: _foreground,
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
        Text(_localized('Пока нет серверов'),
            style: TextStyle(fontWeight: FontWeight.w600)),
        SizedBox(height: 5),
        Text(_localized('Добавьте ссылку или подписку, чтобы начать'),
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
              filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
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
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                Text(
                                    '${sub['name'] ?? (host.isEmpty ? 'Подписка' : host)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: _foreground)),
                                const SizedBox(height: 3),
                                Row(children: [
                                  Flexible(
                                      child: Text(host,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              color: _muted, fontSize: 10))),
                                  const SizedBox(width: 8),
                                  if (checkingSubscriptionPings.contains(url))
                                    SizedBox(
                                        width: 10,
                                        height: 10,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 1.5, color: _muted))
                                  else if (subscriptionEndpointPings
                                      .containsKey(url))
                                    Text(
                                        'TCP · ${subscriptionEndpointPings[url]} ${english ? 'ms' : 'мс'}',
                                        style: TextStyle(
                                            color: _latencyColor(
                                                subscriptionEndpointPings[url]),
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600))
                                  else
                                    Text(_text('TCP · —', 'TCP · —'),
                                        style: TextStyle(
                                            color: _muted, fontSize: 10)),
                                ]),
                              ])),
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
                                      size: 19, color: _muted))),
                          IconButton(
                              tooltip: _localized('Обновить подписку'),
                              onPressed: () => _refreshSubscription(url),
                              icon: Icon(Icons.sync_rounded,
                                  size: 19, color: _muted)),
                          PopupMenuButton<String>(
                              tooltip: _localized('Действия с подпиской'),
                              icon: Icon(Icons.more_horiz_rounded,
                                  size: 20, color: _muted),
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
    if (gb >= 1) {
      return '${gb.toStringAsFixed(gb >= 10 ? 0 : 1)} ${english ? 'GB' : 'ГБ'}';
    }
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(0)} ${english ? 'MB' : 'МБ'}';
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
    if (remaining.isNegative || remaining.inSeconds == 0) {
      return _text('Срок истёк', 'Expired');
    }
    final date =
        '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}.${local.year}';
    if (remaining.inDays >= 1) {
      return _text('Ещё ${remaining.inDays} дн. · $date',
          '${remaining.inDays} days left · $date');
    }
    if (remaining.inHours >= 1) {
      return _text(
          'Истекает сегодня · ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}',
          'Expires today · ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}');
    }
    return _text(
        'Меньше часа · ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}',
        'Under an hour · ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}');
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
      final command = Platform.isWindows
          ? ('rundll32', ['url.dll,FileProtocolHandler', uri.toString()])
          : Platform.isMacOS
              ? ('open', [uri.toString()])
              : ('xdg-open', [uri.toString()]);
      final launch =
          await Process.start(command.$1, command.$2, runInShell: false);
      if (await launch.exitCode != 0 && mounted)
        _message('Не удалось открыть ссылку');
    } catch (_) {
      if (mounted) _message('Не удалось открыть ссылку');
    }
  }

  Future<void> _checkSubscriptionEndpoint(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.host.isEmpty ||
        !const {'http', 'https'}.contains(uri.scheme.toLowerCase())) return;
    if (!checkingSubscriptionPings.add(url)) return;
    if (mounted) setState(() {});
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(
        uri.host,
        uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80),
        timeout: const Duration(seconds: 5),
      );
      stopwatch.stop();
      if (mounted) {
        setState(() => subscriptionEndpointPings[url] =
            math.max(1, stopwatch.elapsedMilliseconds));
      }
    } on Object {
      if (mounted) setState(() => subscriptionEndpointPings.remove(url));
    } finally {
      socket?.destroy();
      checkingSubscriptionPings.remove(url);
      if (mounted) setState(() {});
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
    final expiryText = metadata.neverExpires
        ? _text('∞ · Без срока', '∞ · No expiry')
        : expires == null
            ? null
            : _expiryLabel(expires);
    final hasInfo = used != null ||
        total != null ||
        metadata.expire != null ||
        expires != null ||
        metadata.deviceLimit != null ||
        metadata.announcement != null ||
        metadata.description != null ||
        metadata.supportUrl != null ||
        metadata.websiteUrl != null ||
        metadata.updateIntervalHours != null;
    final hasProviderLinks =
        metadata.websiteUrl != null || metadata.supportUrl != null;
    final linksAtTop = MediaQuery.sizeOf(context).width >= 900;
    final progress = total != null && total > 0 && used != null
        ? (used / total).clamp(0.0, 1.0)
        : null;
    if (collapsed) {
      final summary = total == 0 && used != null
          ? _text('Без лимита · ${_formatBytes(used)} использовано',
              'Unlimited · ${_formatBytes(used)} used')
          : used != null && total != null
              ? _text('${_formatBytes(used)} из ${_formatBytes(total)}',
                  '${_formatBytes(used)} of ${_formatBytes(total)}')
              : used != null
                  ? _text('${_formatBytes(used)} использовано',
                      '${_formatBytes(used)} used')
                  : _text('Данные подписки', 'Subscription details');
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
                    if (expiryText != null) ...[
                      const SizedBox(width: 8),
                      Text(expiryText,
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
                Text(
                    _text('Провайдер не передал данные о трафике и сроке',
                        'The provider did not share usage or expiry details'),
                    style: TextStyle(color: _muted, fontSize: 11)),
              if (used != null || total != null) ...[
                Row(children: [
                  Icon(Icons.data_usage_rounded, color: _accent, size: 17),
                  SizedBox(width: 7),
                  Expanded(
                      child: Text(
                          total == 0
                              ? _text(
                                  'Без лимита · ${_formatBytes(used ?? 0)} использовано',
                                  'Unlimited · ${_formatBytes(used ?? 0)} used')
                              : total != null
                                  ? _text(
                                      '${_formatBytes(used ?? 0)} из ${_formatBytes(total)}',
                                      '${_formatBytes(used ?? 0)} of ${_formatBytes(total)}')
                                  : _text(
                                      'Использовано ${_formatBytes(used ?? 0)}',
                                      '${_formatBytes(used ?? 0)} used'),
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600))),
                  if (total != null && total > 0 && used != null)
                    Text('${(progress! * 100).round()}%',
                        style: TextStyle(color: _muted, fontSize: 11)),
                  if (linksAtTop && hasProviderLinks) ...[
                    const SizedBox(width: 6),
                    _subscriptionProviderLinks(metadata),
                  ],
                  IconButton(
                      tooltip: _localized('Свернуть детали'),
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
              if (expiryText != null ||
                  metadata.deviceLimit != null ||
                  metadata.updateIntervalHours != null) ...[
                SizedBox(height: 11),
                Wrap(spacing: 12, runSpacing: 7, children: [
                  if (expiryText != null)
                    _metadataBadge(Icons.event_rounded, expiryText,
                        expired ? Color(0xFFFFA3A3) : _muted),
                  if (metadata.deviceLimit != null)
                    _metadataBadge(
                        Icons.devices_rounded,
                        _text('До ${metadata.deviceLimit} устройств',
                            'Up to ${metadata.deviceLimit} devices'),
                        _muted),
                  if (metadata.updateIntervalHours != null)
                    _metadataBadge(
                        Icons.sync_rounded,
                        _text(
                            'Совет провайдера: ${metadata.updateIntervalHours} ч',
                            'Provider recommends ${metadata.updateIntervalHours} h'),
                        _muted),
                ]),
              ],
              if (linksAtTop &&
                  hasProviderLinks &&
                  used == null &&
                  total == null)
                Align(
                    alignment: Alignment.centerRight,
                    child: _subscriptionProviderLinks(metadata)),
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
                                title: Text(_localized('Сообщение провайдера')),
                                content: SelectableText(metadata.announcement!),
                                actions: [
                                  TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: Text(_localized('Закрыть')))
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
                Text(
                    _text(
                        'Обновлено ${_updatedLabel(sub['updatedAt'] as String)}',
                        'Updated ${_updatedLabel(sub['updatedAt'] as String)}'),
                    style: TextStyle(color: _muted, fontSize: 10)),
              ],
              if (hasProviderLinks && !linksAtTop) ...[
                SizedBox(height: 9),
                _subscriptionProviderLinks(metadata),
              ],
            ])));
  }

  Widget _subscriptionProviderLinks(SubscriptionMetadata metadata) =>
      Wrap(spacing: 2, runSpacing: 0, children: [
        if (metadata.websiteUrl != null)
          TextButton.icon(
              style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 11)),
              onPressed: () => _openProviderUrl(metadata.websiteUrl),
              icon: const Icon(Icons.language_rounded, size: 15),
              label: Text(_localized('Сайт'))),
        if (metadata.supportUrl != null)
          TextButton.icon(
              style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 11)),
              onPressed: () => _openProviderUrl(metadata.supportUrl),
              icon: const Icon(Icons.support_agent_rounded, size: 15),
              label: Text(_localized('Поддержка'))),
      ]);

  String _updatedLabel(String value) {
    final date = DateTime.tryParse(value)?.toLocal();
    if (date == null) return _text('недавно', 'recently');
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')} ${_text('в', 'at')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  Widget _metadataBadge(IconData icon, String text, Color color) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 14),
        SizedBox(width: 5),
        Text(text, style: TextStyle(color: color, fontSize: 10)),
      ]);

  Future<void> _showProfileJson(ServerProfile profile) async {
    final isXrayTun =
        (Platform.isLinux || Platform.isWindows || Platform.isMacOS) &&
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
            (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
                ? 'proxy'
                : coreSettings.connectionMode,
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
      configs['TUN · sing-box'] = bridgeBackend.makeConfig(bridgeProfile);
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
                      label: Text(_localized('Копировать'))),
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(_localized('Готово'))),
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
                      ? Color.alphaBlend(
                          _accent.withValues(alpha: .12), _surface)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(15)),
              child: Row(children: [
                _countryBadge(profile),
                SizedBox(width: 8),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(profile.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: _foreground,
                              fontSize: 13)),
                      SizedBox(height: 4),
                      Text(
                          '${profile.protocol.toUpperCase()} · ${_transportLabel(profile.network)}${profile.security == 'reality' ? ' · REALITY' : profile.security == 'tls' ? ' · TLS' : ''}',
                          style: TextStyle(
                              color: _muted, fontSize: 10, letterSpacing: .4)),
                    ])),
                Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                    decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .055),
                        borderRadius: BorderRadius.circular(8)),
                    child: Text(':${profile.port}',
                        style: TextStyle(
                            color: _muted,
                            fontSize: 10,
                            fontFeatures: const [
                              ui.FontFeature.tabularFigures()
                            ]))),
                const SizedBox(width: 8),
                if (_checkingProfileIds.contains(profile.id))
                  SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.8, color: _accent))
                else if (failedLatencies.contains(profile.id))
                  Tooltip(
                      message: latencyErrors[profile.id] ??
                          _localized('Проверка не прошла'),
                      child: Text('—',
                          style: TextStyle(color: _muted, fontSize: 12))),
                if (!_checkingProfileIds.contains(profile.id) &&
                    profileLatencies[profile.id] != null)
                  Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 4),
                      decoration: BoxDecoration(
                          color: _latencyColor(profileLatencies[profile.id])
                              .withValues(alpha: .13),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: _latencyColor(profileLatencies[profile.id])
                                  .withValues(alpha: .25))),
                      child: Text(
                          '${profileLatencies[profile.id]} ${english ? 'ms' : 'мс'}',
                          style: TextStyle(
                              color: _latencyColor(profileLatencies[profile.id]),
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [
                                ui.FontFeature.tabularFigures()
                              ]))),
                PopupMenuButton<String>(
                    tooltip: _localized('Действия с сервером'),
                    icon: Icon(Icons.more_horiz_rounded, color: _muted),
                    onSelected: (value) async {
                      if (value == 'speed') {
                        await _testProfileSpeed(profile);
                        return;
                      }
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
                      if (value == 'copy_host' || value == 'copy_endpoint') {
                        final host = profile.address.startsWith('[') &&
                                profile.address.endsWith(']')
                            ? profile.address
                                .substring(1, profile.address.length - 1)
                            : profile.address;
                        final endpoint = host.contains(':')
                            ? '[$host]:${profile.port}'
                            : '$host:${profile.port}';
                        final text =
                            value == 'copy_host' ? profile.address : endpoint;
                        await Clipboard.setData(ClipboardData(text: text));
                        _message(_text('Скопировано в буфер обмена',
                            'Copied to clipboard'));
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
                                Text(_localized('Проверить задержку'))
                              ])),
                          PopupMenuItem(
                              value: 'speed',
                              enabled: !_speedTestProfiles.contains(profile.id),
                              child: Row(children: [
                                if (_speedTestProfiles.contains(profile.id))
                                  SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: _accent),
                                  )
                                else
                                  Icon(Icons.network_check_rounded,
                                      size: 18, color: _accent),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(_speedTestMenuLabel(profile.id)),
                                ),
                              ])),
                          PopupMenuItem(
                              value: 'json',
                              child: Row(children: [
                                Icon(Icons.data_object_rounded,
                                    size: 18, color: _accent),
                                const SizedBox(width: 12),
                                Text(_localized('Посмотреть JSON'))
                              ])),
                          PopupMenuItem(
                              value: 'share',
                              child: Row(children: [
                                Icon(Icons.link_rounded,
                                    size: 18, color: _accent),
                                const SizedBox(width: 12),
                                Text(_localized('Скопировать GhostBox-ссылку'))
                              ])),
                          PopupMenuItem(
                              value: 'copy_host',
                              child: Row(children: [
                                Icon(Icons.dns_outlined,
                                    size: 18, color: _accent),
                                const SizedBox(width: 12),
                                Text(_localized('Скопировать IP/домен'))
                              ])),
                          PopupMenuItem(
                              value: 'copy_endpoint',
                              child: Row(children: [
                                Icon(Icons.content_copy_rounded,
                                    size: 18, color: _accent),
                                const SizedBox(width: 12),
                                Text(_localized('Скопировать адрес и порт'))
                              ])),
                          PopupMenuItem(
                              value: 'delete',
                              child: Row(children: [
                                Icon(Icons.delete_outline_rounded,
                                    size: 18, color: _muted),
                                const SizedBox(width: 12),
                                Text(_localized('Удалить сервер'))
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
            filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
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
      'испан': 'ES',
      'spain': 'ES',
      'es': 'ES',
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
    if (code.isEmpty) {
      for (final token in value.toUpperCase().split(RegExp(r'[^A-Z]+'))) {
        if (_countryFlagCodes.contains(token)) {
          code = token;
          break;
        }
      }
    }
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
    final hasFlagAsset = _countryFlagCodes.contains(code);
    return Container(
        width: 36,
        height: 30,
        decoration: BoxDecoration(
            color: hasFlagAsset
                ? Colors.transparent
                : Color.alphaBlend(tint.withValues(alpha: .15), _surface),
            borderRadius: BorderRadius.circular(8),
            border:
                hasFlagAsset ? null : Border.all(color: tint.withOpacity(.5))),
        child: hasFlagAsset
            ? ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset('assets/flags/$code.png',
                    width: 36,
                    height: 30,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium))
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
              title: Text(_localized('Свой DNS-резолвер')),
              content: TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: _localized('IP или URL резолвера'),
                  hintText: '1.1.1.1 · https://dns.example/dns-query',
                  helperText:
                      _localized('IP = UDP · также tcp:// и DNS-over-HTTPS'),
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(_localized('Отмена'))),
                FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, controller.text.trim()),
                    child: Text(_localized('Сохранить'))),
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
              title: Text(_localized('Ссылка для Proxy GET')),
              content: TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  hintText: 'https://example.com/ghostbox-probe-404',
                  helperText:
                      'Любой HTTP-ответ считается успехом. По умолчанию сервер отвечает 404.',
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(_localized('Отмена'))),
                FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, controller.text.trim()),
                    child: Text(_localized('Сохранить'))),
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
      if (!fromCache) {
        domains = await dnsAdBlocklist.update(
            additionalSources: customDnsBlocklistUrls);
      }
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
      final domains = await dnsAdBlocklist.update(
          additionalSources: customDnsBlocklistUrls);
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

  Future<void> _editDnsBlocklistSources() async {
    final controller =
        TextEditingController(text: customDnsBlocklistUrls.join('\n'));
    final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(_text('Ссылки DNS-листов', 'DNS list URLs')),
              content: SizedBox(
                width: 520,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_text(
                      'Добавь по одной HTTPS-ссылке на raw .txt файл. Списки объединяются с базовым списком рекламы.',
                      'Add one HTTPS URL per raw .txt file. These lists are combined with the built-in ad list.')),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    minLines: 3,
                    maxLines: 8,
                    keyboardType: TextInputType.multiline,
                    decoration: InputDecoration(
                      hintText:
                          'https://raw.githubusercontent.com/user/repo/main/list.txt',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ]),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(_localized('Отмена'))),
                FilledButton(
                    onPressed: () => Navigator.pop(context, controller.text),
                    child: Text(_localized('Сохранить'))),
              ],
            ));
    controller.dispose();
    if (value == null || !mounted) return;

    final urls = value
        .split(RegExp(r'[\r\n]+'))
        .map((url) => url.trim())
        .where((url) => url.isNotEmpty)
        .toSet()
        .toList();
    final invalid = urls.firstWhere(
        (url) => !DnsAdBlocklist.isValidSourceUrl(url),
        orElse: () => '');
    if (invalid.isNotEmpty) {
      _message(_text('Нужна HTTPS-ссылка на файл .txt: $invalid',
          'Expected an HTTPS URL to a .txt file: $invalid'));
      return;
    }

    setState(() => customDnsBlocklistUrls = urls);
    final storage = prefs ??= await SharedPreferences.getInstance();
    await storage.setStringList('customDnsBlocklistUrls', urls);
    if (coreSettings.dnsBlacklistMode == 'ads') {
      await _refreshAdBlocklist();
    } else {
      _message(_text('Ссылки DNS-листов сохранены', 'DNS list URLs saved'));
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
                            helperText: _text(
                                'Один домен на строку · действует и для поддоменов',
                                'One domain per line · includes subdomains')))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(_localized('Отмена'))),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, controller.text),
                      child: Text(_localized('Сохранить')))
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

  Widget _trafficStatsPanel() {
    const downloadColor = Color(0xFF55C6F2);
    const uploadColor = Color(0xFFB88AFF);
    String keyFor(DateTime date) =>
        '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final now = DateTime.now();
    final today = trafficStats.days[keyFor(now)] ?? const DailyTraffic();
    final bucketDays = trafficRangeDays > 7 ? 7 : 1;
    final rows = <(DateTime, DailyTraffic)>[];
    for (var offset = 0; offset < trafficRangeDays; offset += bucketDays) {
      final start = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: trafficRangeDays - 1 - offset));
      var bucket = const DailyTraffic();
      for (var day = 0;
          day < bucketDays && offset + day < trafficRangeDays;
          day++) {
        final date = start.add(Duration(days: day));
        final value = trafficStats.days[keyFor(date)] ?? const DailyTraffic();
        bucket = bucket.add(received: value.received, sent: value.sent);
      }
      rows.add((start, bucket));
    }
    final maxUsage = rows
        .map((row) => row.$2.received + row.$2.sent)
        .fold<int>(0, (maximum, value) => math.max(maximum, value));
    final total = rows.fold<DailyTraffic>(
      const DailyTraffic(),
      (sum, row) => sum.add(received: row.$2.received, sent: row.$2.sent),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _section(_text('СТАТИСТИКА ТРАФИКА', 'TRAFFIC STATISTICS')),
      ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: _surface.withValues(alpha: .78),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _line.withValues(alpha: .45)),
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: _trafficTotal(
                  _text('Загружено сегодня', 'Downloaded today'),
                  formatTrafficBytes(today.received),
                  Icons.south_rounded,
                  color: downloadColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _trafficTotal(
                  _text('Отправлено сегодня', 'Uploaded today'),
                  formatTrafficBytes(today.sent),
                  Icons.north_rounded,
                  color: uploadColor,
                ),
              ),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: Text(
                    trafficRangeDays > 7
                        ? _text('ИСТОРИЯ · ПО НЕДЕЛЯМ', 'HISTORY · WEEKLY')
                        : _text('ИСТОРИЯ · ПО ДНЯМ', 'HISTORY · DAILY'),
                    style: TextStyle(
                        color: _muted,
                        fontSize: 9,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w700)),
              ),
              for (final range in const [7, 30, 90])
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: ChoiceChip(
                    label: Text('$range${_text(' д', ' d')}'),
                    selected: trafficRangeDays == range,
                    onSelected: (_) => setState(() => trafficRangeDays = range),
                    visualDensity: VisualDensity.compact,
                    labelStyle: TextStyle(
                        fontSize: 9,
                        color:
                            trafficRangeDays == range ? _foreground : _muted),
                    padding: EdgeInsets.zero,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
            ]),
            const SizedBox(height: 7),
            Row(children: [
              _trafficLegendDot(downloadColor),
              const SizedBox(width: 4),
              Text(_text('Загрузка', 'Download'),
                  style: TextStyle(color: _muted, fontSize: 9)),
              const SizedBox(width: 12),
              _trafficLegendDot(uploadColor),
              const SizedBox(width: 4),
              Text(_text('Отдача', 'Upload'),
                  style: TextStyle(color: _muted, fontSize: 9)),
            ]),
            const SizedBox(height: 8),
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  SizedBox(
                    width: 43,
                    child: Text(
                      '${row.$1.day.toString().padLeft(2, '0')}.${row.$1.month.toString().padLeft(2, '0')}',
                      style: TextStyle(color: _muted, fontSize: 10),
                    ),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: SizedBox(
                        height: 7,
                        child: Row(children: [
                          if (row.$2.received > 0)
                            Expanded(
                              flex: row.$2.received,
                              child: ColoredBox(color: downloadColor),
                            ),
                          if (row.$2.sent > 0)
                            Expanded(
                              flex: row.$2.sent,
                              child: ColoredBox(color: uploadColor),
                            ),
                          if (row.$2.received + row.$2.sent == 0)
                            Expanded(
                                child: ColoredBox(
                                    color:
                                        Colors.white.withValues(alpha: .07))),
                          if (maxUsage > row.$2.received + row.$2.sent)
                            Expanded(
                              flex: maxUsage - row.$2.received - row.$2.sent,
                              child: ColoredBox(
                                  color: Colors.white.withValues(alpha: .07)),
                            ),
                        ]),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 145,
                    child: Text(
                      '↓ ${formatTrafficBytes(row.$2.received)}   ↑ ${formatTrafficBytes(row.$2.sent)}',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: _foreground,
                        fontSize: 9,
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ]),
              ),
            const SizedBox(height: 9),
            Divider(height: 1, color: _line.withOpacity(.45)),
            const SizedBox(height: 9),
            Row(children: [
              Expanded(
                child: Text(
                  _text('Всего за $trafficRangeDays дней',
                      'Total for $trafficRangeDays days'),
                  style: TextStyle(color: _muted, fontSize: 10),
                ),
              ),
              Text(
                '↓ ${formatTrafficBytes(total.received)}   ↑ ${formatTrafficBytes(total.sent)}',
                style: TextStyle(
                  color: _foreground,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [ui.FontFeature.tabularFigures()],
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: _trafficTotal(
                  _text('Скорость сейчас ↓', 'Current download ↓'),
                  formatTrafficRate(trafficStats.receivedPerSecond),
                  Icons.south_rounded,
                  color: downloadColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _trafficTotal(
                  _text('Скорость сейчас ↑', 'Current upload ↑'),
                  formatTrafficRate(trafficStats.sentPerSecond),
                  Icons.north_rounded,
                  color: uploadColor,
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
              '${_text('Пик за запуск', 'Peak since app launch')}: ↓ ${formatTrafficRate(trafficStats.peakReceivedPerSecond)} · ↑ ${formatTrafficRate(trafficStats.peakSentPerSecond)}',
              style: TextStyle(color: _muted, fontSize: 10),
            ),
            if (!trafficStats.available &&
                total.received + total.sent == 0) ...[
              const SizedBox(height: 7),
              Text(
                Platform.isAndroid || Platform.isIOS
                    ? _text(
                        'Системные счётчики трафика пока недоступны на этой платформе.',
                        'System traffic counters are not available on this platform yet.')
                    : _text('Данные собираются во время TUN/Mixed подключения.',
                        'Usage is collected while connected in TUN/Mixed mode.'),
                style: TextStyle(color: _muted, fontSize: 10),
              ),
            ],
          ]),
        ),
      ),
      const SizedBox(height: 14),
    ]);
  }

  Widget _trafficLegendDot(Color color) => Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle));

  Widget _trafficTotal(String label, String value, IconData icon,
          {Color? color}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 14, color: color ?? _accent),
            const SizedBox(width: 5),
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _muted, fontSize: 9)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(value,
              style: TextStyle(
                  color: _foreground,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [ui.FontFeature.tabularFigures()])),
        ],
      );

  Widget _settings() => ListView(
        controller: settingsScroll,
        key: const PageStorageKey('settings'),
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          const SizedBox(height: 8),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            reverseDuration: const Duration(milliseconds: 210),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: CurvedAnimation(
                  parent: animation, curve: Curves.easeInOutCubic),
              child: SlideTransition(
                position: Tween<Offset>(
                        begin: const Offset(0, .018), end: Offset.zero)
                    .animate(CurvedAnimation(
                        parent: animation, curve: Curves.easeOutCubic)),
                child: child,
              ),
            ),
            child: KeyedSubtree(
              key: ValueKey(settingsSubpage ?? 'settings-home'),
              child: settingsSubpage == null
                  ? _settingsHomeContent()
                  : _settingsSubpageContent(),
            ),
          ),
        ],
      );

  Widget _settingsHomeContent() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 12),
          Text(_localized('Настройки'),
              style: TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.7)),
          SizedBox(height: 5),
          Text(_localized('Управление локальным прокси и ядром'),
              style: TextStyle(color: _muted, fontSize: 13)),
          SizedBox(height: 24),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (details) {
              setState(() => _draggingSettingsMode = true);
              _dragSettingsMode(details.globalPosition);
            },
            onPanUpdate: (details) => _dragSettingsMode(details.globalPosition),
            onPanEnd: (_) => setState(() => _draggingSettingsMode = false),
            onPanCancel: () => setState(() => _draggingSettingsMode = false),
            child: AnimatedScale(
              scale: _draggingSettingsMode ? .99 : 1,
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              child: Container(
                key: _settingsModeKey,
                height: 48,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.065),
                    borderRadius: BorderRadius.circular(17),
                    border: Border.all(color: Colors.white.withOpacity(.09))),
                child: Stack(
                  children: [
                    AnimatedAlign(
                      alignment: advanced
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutCubic,
                      child: FractionallySizedBox(
                        widthFactor: .5,
                        heightFactor: 1,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 240),
                          curve: Curves.easeOutCubic,
                          decoration: BoxDecoration(
                            color: _accent.withOpacity(.19),
                            borderRadius: BorderRadius.circular(13),
                            border: Border.all(
                                color: _accent.withOpacity(.25), width: .8),
                            boxShadow: [
                              BoxShadow(
                                  color: _accent.withOpacity(.10),
                                  blurRadius: 12,
                                  offset: const Offset(0, 2)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Row(children: [
                      _segment(_localized('Основные'), !advanced,
                          () => setState(() => advanced = false)),
                      _segment(_localized('Для профи'), advanced,
                          () => setState(() => advanced = true)),
                    ]),
                  ],
                ),
              ),
            ),
          ),
          _animatedReconnectBanner(
              visible: pendingReconnect,
              child: Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Container(
                      padding: EdgeInsets.all(14),
                      decoration: BoxDecoration(
                          color: _accent.withOpacity(.13),
                          borderRadius: BorderRadius.circular(17),
                          border: Border.all(color: _accent.withOpacity(.35))),
                      child: Row(children: [
                        Icon(Icons.info_outline_rounded,
                            color: _accent, size: 19),
                        SizedBox(width: 10),
                        Expanded(
                            child: Text(
                                'Изменения вступят в силу после переподключения',
                                style: TextStyle(fontSize: 12))),
                        TextButton(
                            onPressed: _applyPendingReconnect,
                            child: Text(_localized('Применить'))),
                      ])))),
          SizedBox(height: 22),
          AnimatedSize(
              duration: const Duration(milliseconds: 290),
              curve: Curves.easeInOutCubic,
              alignment: Alignment.topCenter,
              child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 240),
                  reverseDuration: const Duration(milliseconds: 190),
                  transitionBuilder: (child, animation) => FadeTransition(
                        opacity: CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeInOutCubic,
                          reverseCurve: Curves.easeInOutCubic,
                        ),
                        child: child,
                      ),
                  child: KeyedSubtree(
                      key: ValueKey(advanced),
                      child:
                          advanced ? _advancedSettings() : _basicSettings()))),
          _trafficStatsPanel(),
          SizedBox(height: 18),
          _section('ЖУРНАЛ'),
          _row(
              Icons.history_rounded,
              _text('Хранить подключения', 'Retain connection sessions'),
              _text('Последние $logRetainedConnections',
                  'Last $logRetainedConnections'),
              _menu(
                  '$logRetainedConnections',
                  const {
                    '5': '5 подключений',
                    '10': '10 подключений',
                    '25': '25 подключений',
                    '50': '50 подключений',
                    '100': '100 подключений',
                  },
                  (value) => _setLogRetainedConnections(int.parse(value)))),
          _row(
              Icons.storage_rounded,
              _text('Максимальный размер', 'Maximum journal size'),
              _text('$logMaxSizeMb МБ', '$logMaxSizeMb MB'),
              _menu(
                  '$logMaxSizeMb',
                  const {
                    '1': '1 МБ',
                    '2': '2 МБ',
                    '5': '5 МБ',
                    '10': '10 МБ',
                    '25': '25 МБ',
                  },
                  (value) => _setLogMaxSize(int.parse(value)))),
          _row(
              Icons.article_outlined,
              _text('Подробные логи ядра', 'Detailed core logs'),
              logCoreOutput
                  ? _text('В файл записываются сообщения Xray и sing-box',
                      'Record Xray and sing-box output to the file')
                  : _text('В файле останутся события приложения',
                      'Keep app events only'),
              _compactSwitch(
                  value: logCoreOutput, onChanged: _setLogCoreOutput)),
          _row(
              Icons.delete_sweep_outlined,
              _text('Очистить журнал', 'Clear journal'),
              _text('Удалить записи из файла журнала',
                  'Delete all records from the journal file'),
              IconButton(
                  tooltip: _text('Очистить журнал', 'Clear journal'),
                  onPressed: _clearJournal,
                  icon: const Icon(Icons.delete_outline_rounded))),
          const SizedBox(height: 12),
          _section('GHOSTBOX'),
          _row(
              Icons.system_update_alt_rounded,
              _text('Автообновление приложения', 'App auto-update'),
              autoUpdateApp
                  ? _text('Скачать и установить при запуске',
                      'Download and install at launch')
                  : _text('Только сообщать о новой версии',
                      'Notify when a new version is available'),
              _compactSwitch(
                  value: autoUpdateApp, onChanged: _setAutoUpdateApp)),
          _row(
              Icons.cloud_download_outlined,
              _text('Версия приложения', 'App version'),
              appUpdateStatus ??
                  _text(
                      'Установлена ${GitHubUpdater.displayVersion(GitHubUpdater.currentVersion)} · ветка ${GitHubUpdater.updateBranch}',
                      'Installed ${GitHubUpdater.displayVersion(GitHubUpdater.currentVersion)} · branch ${GitHubUpdater.updateBranch}'),
              IconButton(
                  tooltip: _text('Проверить обновления', 'Check for updates'),
                  onPressed: checkingAppUpdate || installingAppUpdate
                      ? null
                      : () => _checkAppUpdate(),
                  icon: checkingAppUpdate || installingAppUpdate
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh_rounded))),
          _row(
              Icons.system_update_alt_rounded,
              _text('Принудительная установка', 'Force update'),
              _text('Повторно скачать и установить последнюю версию',
                  'Download and reinstall the latest release'),
              IconButton(
                  tooltip: _text('Принудительная установка', 'Force update'),
                  onPressed: checkingAppUpdate || installingAppUpdate
                      ? null
                      : () => _checkAppUpdate(forceLatest: true),
                  icon: const Icon(Icons.download_for_offline_rounded))),
          InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _openSettingsPage('release'),
              child: _row(
                  Icons.new_releases_outlined,
                  'О релизе',
                  _text('Примечания, канал и подробности версии',
                      'Release notes, channel and version details'),
                  const Icon(Icons.chevron_right_rounded))),
          InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _showAbout,
              child: _row(
                  Icons.info_outline_rounded,
                  'О приложении',
                  'Сборка, ядра и устройство',
                  const Icon(Icons.chevron_right_rounded))),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _deleteAllServers,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFF8B91),
                side: BorderSide(
                    color: const Color(0xFFFF8B91).withValues(alpha: .42)),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: const Icon(Icons.delete_sweep_outlined, size: 19),
              label: Text(_localized('Очистить серверы и подписки')),
            ),
          ),
          const SizedBox(height: 12),
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _openSettingsPage('contacts'),
            child: _row(
              Icons.alternate_email_rounded,
              'Контакты',
              _text('Репозиторий, релизы и сайты',
                  'Repository, releases and websites'),
              const Icon(Icons.chevron_right_rounded),
            ),
          ),
        ],
      );

  Widget _settingsSubpageContent() => switch (settingsSubpage) {
        'contacts' => _contactsPage(),
        'release' => _releaseDetailsPage(),
        'about' => _aboutPage(),
        _ => _settingsHomeContent(),
      };

  Widget _contactsPage() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _settingsPageIntro(
            Icons.alternate_email_rounded,
            _text('Связаться и открыть ссылки', 'Links and contacts'),
            _text('Проект, релизы и страницы разработчика',
                'Project, releases and developer pages'),
          ),
          const SizedBox(height: 18),
          _contactLink(
            Icons.code_rounded,
            'GitHub · GhostBox',
            'github.com/Krakva1337/GhostBox',
            'https://github.com/Krakva1337/GhostBox',
          ),
          _contactLink(
            Icons.new_releases_outlined,
            _text('Релизы GitHub', 'GitHub releases'),
            'github.com/Krakva1337/GhostBox/releases',
            GitHubUpdater.releasesPage,
          ),
          _contactLink(
            Icons.language_rounded,
            _text('Сайт GhostBox', 'GhostBox website'),
            'ghostbox.krakva1337.ru',
            'https://ghostbox.krakva1337.ru',
          ),
          _contactLink(
            Icons.person_outline_rounded,
            _text('Сайт разработчика', 'Developer website'),
            'krakva1337.ru',
            'https://krakva1337.ru',
          ),
          const SizedBox(height: 14),
          _row(
              Icons.info_outline_rounded,
              'О приложении',
              _text('Сведения о сборке, ядрах и устройстве',
                  'Build, core and device information'),
              IconButton(
                  tooltip: _localized('Открыть'),
                  onPressed: _showAbout,
                  icon: const Icon(Icons.chevron_right_rounded))),
        ],
      );

  Widget _releaseDetailsPage() {
    final release = availableAppRelease;
    final installed =
        GitHubUpdater.displayVersion(GitHubUpdater.currentVersion);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _settingsPageIntro(
          Icons.new_releases_rounded,
          _text('Информация о релизе', 'Release information'),
          _text('Версии, канал обновлений и примечания',
              'Versions, update channel and release notes'),
        ),
        const SizedBox(height: 18),
        _releaseInfoCard(
          _text('УСТАНОВЛЕННАЯ ВЕРСИЯ', 'INSTALLED VERSION'),
          installed,
          _text('Ветка обновлений: ${GitHubUpdater.updateBranch}',
              'Update branch: ${GitHubUpdater.updateBranch}'),
          Icons.verified_rounded,
        ),
        const SizedBox(height: 10),
        _releaseInfoCard(
          _text('ПОСЛЕДНИЙ РЕЛИЗ', 'LATEST RELEASE'),
          release == null
              ? _text('Пока не проверено', 'Not checked yet')
              : GitHubUpdater.displayVersion(release.version),
          appUpdateStatus ??
              _text('Проверь GitHub, чтобы загрузить сведения о релизе.',
                  'Check GitHub to load release details.'),
          Icons.cloud_sync_rounded,
        ),
        const SizedBox(height: 14),
        Wrap(
          alignment: WrapAlignment.center,
          runAlignment: WrapAlignment.center,
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              onPressed: checkingAppUpdate || installingAppUpdate
                  ? null
                  : () => _checkAppUpdate(),
              icon: checkingAppUpdate
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh_rounded, size: 18),
              label: Text(_text('Проверить обновления', 'Check for updates')),
            ),
            if (release != null)
              OutlinedButton.icon(
                onPressed: installingAppUpdate
                    ? null
                    : release.version == GitHubUpdater.currentVersion
                        ? _openReleasePage
                        : _installAppUpdate,
                icon: Icon(release.version == GitHubUpdater.currentVersion
                    ? Icons.open_in_new_rounded
                    : Icons.download_rounded),
                label: Text(release.version == GitHubUpdater.currentVersion
                    ? _text('Открыть релиз', 'View release')
                    : _text('Установить обновление', 'Install update')),
              ),
            OutlinedButton.icon(
              onPressed: _openReleasePage,
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: Text(_text('Все релизы', 'All releases')),
            ),
          ],
        ),
        if (release != null && release.notes.trim().isNotEmpty) ...[
          const SizedBox(height: 22),
          _section(_text('ПРИМЕЧАНИЯ К РЕЛИЗУ', 'RELEASE NOTES')),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _line.withValues(alpha: .45)),
            ),
            child: SelectableText(
              release.notes.trim(),
              style: TextStyle(color: _foreground, height: 1.5, fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }

  Widget _settingsPageIntro(IconData icon, String title, String subtitle) =>
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [_accent.withValues(alpha: .20), _surface],
          ),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: _accent.withValues(alpha: .22)),
        ),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: .16),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(icon, color: _accent),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(subtitle, style: TextStyle(color: _muted, fontSize: 11)),
              ],
            ),
          ),
        ]),
      );

  Widget _releaseInfoCard(
          String label, String value, String subtitle, IconData icon) =>
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _line.withValues(alpha: .45)),
        ),
        child: Row(children: [
          Icon(icon, color: _accent, size: 21),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        color: _muted,
                        fontSize: 9,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 5),
                Text(value,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(subtitle, style: TextStyle(color: _muted, fontSize: 11)),
              ],
            ),
          ),
        ]),
      );

  Widget _contactLink(
          IconData icon, String title, String address, String url) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Material(
          color: _surface,
          borderRadius: BorderRadius.circular(17),
          child: InkWell(
            borderRadius: BorderRadius.circular(17),
            onTap: () => _openProviderUrl(url),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
              child: Row(children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: _accent.withValues(alpha: .13),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(icon, size: 19, color: _accent),
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
                      Text(address,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: _muted, fontSize: 11)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: _localized('Скопировать ссылку'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: url));
                    if (mounted) {
                      _message(_text('Ссылка скопирована', 'Link copied'));
                    }
                  },
                  icon: Icon(Icons.copy_rounded, color: _muted, size: 17),
                ),
                Icon(Icons.open_in_new_rounded, color: _muted, size: 17),
              ]),
            ),
          ),
        ),
      );

  Future<void> _setAutoUpdateApp(bool enabled) async {
    setState(() => autoUpdateApp = enabled);
    final storage = prefs ??= await SharedPreferences.getInstance();
    await storage.setBool('autoUpdateApp', enabled);
    if (enabled && availableAppRelease != null) {
      if (backend.state == VpnState.disconnected) {
        await _installAppUpdate();
      } else {
        _message(_text('Обновление готово. Отключи VPN, чтобы установить его.',
            'Update is ready. Disconnect the VPN to install it.'));
      }
    }
  }

  Future<void> _setLogRetainedConnections(int value) async {
    setState(() => logRetainedConnections = value);
    final storage = prefs ??= await SharedPreferences.getInstance();
    await storage.setInt('logRetainedConnections', value);
    if (connectionHistory.length > value) {
      connectionHistory.removeRange(value, connectionHistory.length);
      await storage.setString(
          'connectionHistory', jsonEncode(connectionHistory));
    }
    await _configureLogStore();
  }

  Future<void> _setLogMaxSize(int value) async {
    setState(() => logMaxSizeMb = value);
    final storage = prefs ??= await SharedPreferences.getInstance();
    await storage.setInt('logMaxSizeMb', value);
    await _configureLogStore();
  }

  Future<void> _setLogCoreOutput(bool value) async {
    setState(() => logCoreOutput = value);
    final storage = prefs ??= await SharedPreferences.getInstance();
    await storage.setBool('logCoreOutput', value);
    await _configureLogStore();
  }

  Future<void> _configureLogStore() async {
    await GhostBoxLogStore.instance.configure(
      retainedConnections: logRetainedConnections,
      maxSizeMb: logMaxSizeMb,
      includeCoreOutput: logCoreOutput,
    );
    final file = await _resolveLogFile();
    if (mounted) setState(() => logFilePath = file.path);
  }

  Future<void> _clearJournal() async {
    await _logWriteQueue;
    await process?.flushLogs();
    await tunnelBridgeBackend?.flushLogs();
    await GhostBoxLogStore.instance.clear();
    appLogs.clear();
    if (backend is AndroidVpnBackend) {
      await (backend as AndroidVpnBackend).clearLogs();
    }
    process?.clearLogBuffer();
    tunnelBridgeBackend?.clearLogBuffer();
    if (mounted) _message(_text('Журнал очищен', 'Journal cleared'));
  }

  Future<void> _checkAppUpdate(
      {bool silent = false, bool forceLatest = false}) async {
    if (checkingAppUpdate || installingAppUpdate) return;
    setState(() => checkingAppUpdate = true);
    try {
      final release = await appUpdater.check(includeCurrent: forceLatest);
      if (!mounted) return;
      setState(() {
        availableAppRelease = release;
        appUpdateStatus = release == null
            ? _text(
                'Обновлений нет · ${GitHubUpdater.displayVersion(GitHubUpdater.currentVersion)} · ${GitHubUpdater.updateBranch}',
                'Up to date · ${GitHubUpdater.displayVersion(GitHubUpdater.currentVersion)} · ${GitHubUpdater.updateBranch}')
            : _text(
                'Доступна версия ${GitHubUpdater.displayVersion(release.version)} · ${GitHubUpdater.updateBranch}',
                'Version ${GitHubUpdater.displayVersion(release.version)} is available · ${GitHubUpdater.updateBranch}');
      });
      if (release == null) {
        if (!silent)
          _message(_text(
              'Установлена последняя версия', 'You have the latest version'));
      } else if ((forceLatest || autoUpdateApp) &&
          backend.state == VpnState.disconnected) {
        await _installAppUpdate();
      } else if (!silent) {
        _message(_text(
            'Доступно обновление GhostBox ${GitHubUpdater.displayVersion(release.version)}',
            'GhostBox ${GitHubUpdater.displayVersion(release.version)} is available'));
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          appUpdateStatus = _text('Проверка не удалась', 'Check failed');
        });
        if (!silent)
          _message(_text('Не удалось проверить обновления: $error',
              'Could not check for updates: $error'));
      }
    } finally {
      if (mounted) setState(() => checkingAppUpdate = false);
    }
  }

  Future<void> _installAppUpdate() async {
    final release = availableAppRelease;
    if (release == null || installingAppUpdate) return;
    if (backend.state != VpnState.disconnected) {
      _message(_text('Перед обновлением отключи VPN',
          'Disconnect the VPN before updating'));
      return;
    }
    setState(() => installingAppUpdate = true);
    try {
      final assetName = await appUpdater.platformAssetName(release);
      if (assetName == null) {
        _message(_text(
            'Для этой платформы скачай обновление со страницы релиза',
            'Download the update for this platform from the releases page'));
        await _openReleasePage();
        return;
      }
      final asset = release.asset(assetName);
      if (asset == null) {
        throw FileSystemException(
            'Файл $assetName не найден в релизе ${release.version}');
      }
      setState(() => appUpdateStatus = _text(
          'Загружаю ${GitHubUpdater.displayVersion(release.version)}…',
          'Downloading ${GitHubUpdater.displayVersion(release.version)}…'));
      await appUpdater.apply(release, asset);
    } on Object catch (error) {
      if (mounted) {
        setState(() =>
            appUpdateStatus = _text('Обновление не удалось', 'Update failed'));
        _message(_text('Не удалось установить обновление: $error',
            'Could not install update: $error'));
      }
    } finally {
      if (mounted) setState(() => installingAppUpdate = false);
    }
  }

  Future<void> _openReleasePage() async {
    final uri =
        Uri.parse(availableAppRelease?.pageUrl ?? GitHubUpdater.releasesPage);
    try {
      if (Platform.isWindows) {
        await Process.start('cmd.exe', ['/c', 'start', '', uri.toString()],
            mode: ProcessStartMode.detached);
      } else {
        await Process.start(
            Platform.isMacOS ? 'open' : 'xdg-open', [uri.toString()],
            mode: ProcessStartMode.detached);
      }
    } on Object catch (error) {
      _message(_text('Не удалось открыть страницу релизов: $error',
          'Could not open releases page: $error'));
    }
  }

  Future<String> _coreVersion(String name) async {
    try {
      final executable = coreExecutable(name, 'vendor');
      if (!File(executable).existsSync()) return 'Не найдено';
      final result = await Process.run(executable, ['version'])
          .timeout(const Duration(seconds: 3));
      final output = '${result.stdout}\n${result.stderr}';
      if (result.exitCode == 0) {
        if (name == 'sing-box') {
          final match =
              RegExp(r'sing-box version\s+([^\s]+)').firstMatch(output);
          final version = match?.group(1);
          if (version != null && version.toLowerCase() != 'unknown') {
            return 'sing-box $version';
          }
        } else {
          final firstLine = output
              .split('\n')
              .map((line) => line.trim())
              .firstWhere((line) => line.isNotEmpty, orElse: () => '');
          if (firstLine.isNotEmpty) return firstLine;
        }
      }

      // Older binaries were built without sing-box's version linker flag.
      // Use the adjacent build manifest first, then Go's embedded module info.
      final buildInfo = File('${File(executable).parent.path}/BUILD-INFO.txt');
      if (name == 'sing-box' && await buildInfo.exists()) {
        final manifest = await buildInfo.readAsString();
        final match = RegExp(r'^sing-box:\s*v?([^\s]+)', multiLine: true)
            .firstMatch(manifest);
        if (match != null) return 'sing-box ${match.group(1)}';
      }
      if (name == 'sing-box') {
        final moduleInfo =
            await Process.run('go', ['version', '-m', executable])
                .timeout(const Duration(seconds: 3));
        final match = RegExp(
          r'^\s*mod\s+github\.com/sagernet/sing-box\s+v([^\s]+)',
          multiLine: true,
        ).firstMatch('${moduleInfo.stdout}');
        if (match != null) return 'sing-box ${match.group(1)}';
      }
      return result.exitCode == 0 ? 'Версия недоступна' : 'Недоступно';
    } on Object {
      return 'Недоступно';
    }
  }

  Future<List<(String, String)>> _loadAboutDetails() async {
    final appVersion =
        GitHubUpdater.displayVersion(GitHubUpdater.currentVersion);
    const buildNumber = '1';
    final buildMode = kReleaseMode
        ? 'Release'
        : kProfileMode
            ? 'Profile'
            : 'Debug';
    final dartVersion =
        RegExp(r'^\d+\.\d+\.\d+').firstMatch(Platform.version)?.group(0) ??
            _text('Неизвестно', 'Unknown');
    final model = await DeviceIdentity.deviceModel;
    final installId = await DeviceIdentity.installationId;
    final xray = await _coreVersion('xray');
    final singBox = await _coreVersion('sing-box');
    return <(String, String)>[
      ('GhostBox', appVersion),
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
  }

  Future<void> _showAbout() async => _openSettingsPage('about');

  Widget _aboutPage() => FutureBuilder<List<(String, String)>>(
        future: _aboutDetailsFuture ??= _loadAboutDetails(),
        builder: (context, snapshot) {
          final intro = _settingsPageIntro(
            Icons.info_outline_rounded,
            _localized('О GhostBox'),
            _text('Информация о приложении, сборке и устройстве',
                'App, build and device information'),
          );
          if (snapshot.connectionState != ConnectionState.done) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                intro,
                const SizedBox(height: 22),
                const Center(child: CircularProgressIndicator()),
              ],
            );
          }
          final details = snapshot.data ?? const <(String, String)>[];
          final report = details
              .map((item) => '${_localized(item.$1)}: ${_messageText(item.$2)}')
              .join('\n');
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              intro,
              const SizedBox(height: 18),
              _section('СБОРКА'),
              for (final item in details.take(5))
                _aboutDetail(item.$1, item.$2),
              const SizedBox(height: 8),
              _section('ЯДРА'),
              for (final item in details.skip(5).take(2))
                _aboutDetail(item.$1, item.$2),
              const SizedBox(height: 8),
              _section('УСТРОЙСТВО'),
              for (final item in details.skip(7))
                _aboutDetail(item.$1, item.$2),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: report));
                    _message('Сведения скопированы');
                  },
                  icon: const Icon(Icons.copy_rounded, size: 17),
                  label: Text(_localized('Скопировать сведения')),
                ),
              ),
            ],
          );
        },
      );

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
                child: Text(_localized(label),
                    style: TextStyle(color: _muted, fontSize: 11)),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 6,
                child: SelectableText(_messageText(value),
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
            ThemeSettingsPanel(english: english),
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
                        tooltip: _localized('Выбрать порт'),
                        onPressed: _editPort,
                        icon: const Icon(Icons.edit_outlined)),
                ])),
            _row(
                Icons.alt_route_rounded,
                'Маршрутизация',
                _routingLabel(),
                IconButton(
                    tooltip: _localized('Открыть маршрутизацию'),
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
                      tooltip: _localized('Изменить DNS-резолвер'),
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
                      tooltip: _localized('Изменить список'),
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
                      tooltip: _localized('Обновить список рекламы'),
                      onPressed: loadingAdBlocklist
                          ? null
                          : () => _refreshAdBlocklist(),
                      icon: loadingAdBlocklist
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.refresh_rounded))),
            _dnsBlocklistSourcesRow(),
            SizedBox(height: 14),
            _section('ПРИЛОЖЕНИЕ'),
            _row(
                Icons.language_rounded,
                'Язык интерфейса',
                english ? 'English' : 'Русский',
                _menu(english ? 'en' : 'ru',
                    const {'ru': 'Русский', 'en': 'English'}, (value) async {
                  final next = value == 'en';
                  setState(() => english = next);
                  await prefs?.setBool('appEnglish', next);
                })),
            _row(
                Icons.auto_awesome_rounded,
                'Анимированный фон',
                animatedBackground
                    ? 'Мягкое движение цветового свечения'
                    : 'Выключен · меньше графической нагрузки',
                _compactSwitch(
                    value: animatedBackground,
                    onChanged: (value) async {
                      setState(() => animatedBackground = value);
                      if (value) {
                        ambientMotion.repeat();
                      } else {
                        ambientMotion.stop();
                        ambientMotion.value = .12;
                      }
                      await prefs?.setBool('animatedBackground', value);
                    })),
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
                '${Platform.isIOS ? "Низкий бюджет" : "Мягкий бюджет"} · ${coreSettings.memoryMb} МБ',
                SizedBox(
                    width: 180,
                    child: _compactSlider(
                        value: coreSettings.memoryMb.toDouble(),
                        min: Platform.isIOS ? 25 : 64,
                        max: Platform.isIOS ? 50 : 256,
                        divisions: Platform.isIOS ? 5 : 12,
                        onChanged: (v) => _saveCore(
                            coreSettings.copyWith(memoryMb: v.round()))))),
            _section('ЗАЩИТА ТРАФИКА'),
            _row(
                Icons.shield_moon_outlined,
                'Kill Switch',
                Platform.isLinux
                    ? _text(
                        'Блокирует сеть вне TUN даже после сбоя ядра. Требует подтверждения pkexec.',
                        'Blocks traffic outside TUN, even if the core stops. Requires pkexec approval.')
                    : _text('Доступен только в Linux TUN/Mixed',
                        'Available only on Linux TUN/Mixed'),
                _compactSwitch(
                    value: coreSettings.killSwitchEnabled,
                    onChanged: Platform.isLinux ? _setKillSwitch : null)),
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
                    Platform.isIOS
                        ? const {'tcp': 'TCP · порт сервера'}
                        : Platform.isAndroid
                            ? const {
                                'proxy': 'Proxy GET · через VPN',
                                'tcp': 'TCP · порт сервера',
                              }
                            : const {
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
                    tooltip: _localized('Добавить подписку'),
                    onPressed: _showAddMenu,
                    icon: Icon(Icons.add_rounded))),
            _row(
                Icons.sync_rounded,
                'Обновить все',
                'Перезагрузить профили из URL',
                IconButton(
                    tooltip: _localized('Обновить все'),
                    onPressed:
                        subscriptions.isEmpty ? null : _refreshAllSubscriptions,
                    icon: Icon(Icons.refresh_rounded))),
            _row(
                Icons.autorenew_rounded,
                'Автообновление',
                autoRefreshSubscriptions
                    ? _text('По расписанию провайдера', 'Provider schedule')
                    : _text('Выключено', 'Off'),
                _compactSwitch(
                    value: autoRefreshSubscriptions,
                    onChanged: _setAutoRefresh)),
            if (autoRefreshSubscriptions)
              _row(
                  Icons.schedule_rounded,
                  _text('Интервал обновления', 'Refresh interval'),
                  _text('По заголовку провайдера; если его нет — 12 ч',
                      'Provider header; 12 h if not specified'),
                  const SizedBox.shrink()),
          ]);

  Widget _advancedSettings() => Column(
          key: ValueKey('advanced'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _settingsPageIntro(
              Icons.tune_rounded,
              _text('Параметры для профи', 'Advanced configuration'),
              _text('Тонкая настройка ядра и сетевого поведения',
                  'Fine tune the core and network behavior'),
            ),
            const SizedBox(height: 14),
            _section('ЯДРО'),
            Row(children: [
              _choice('sing-box', coreSettings.core == 'sing-box',
                  () => _selectCore('sing-box')),
              if (!Platform.isIOS)
                _choice('Xray', coreSettings.core == 'xray',
                    () => _selectCore('Xray')),
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
                '${coreSettings.memoryMb} МБ · ${Platform.isIOS ? "25–50" : "64–256"} МБ',
                SizedBox(
                    width: 180,
                    child: _compactSlider(
                        value: coreSettings.memoryMb.toDouble(),
                        min: Platform.isIOS ? 25 : 64,
                        max: Platform.isIOS ? 50 : 256,
                        divisions: Platform.isIOS ? 5 : 12,
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
            SizedBox(height: 15),
            _section('ФРАГМЕНТАЦИЯ TLS'),
            _row(
                Icons.call_split_rounded,
                'Фрагментация TLS ClientHello',
                coreSettings.tlsFragmentEnabled
                    ? 'Разбивать TLS handshake на части'
                    : 'Фрагментация отключена',
                _compactSwitch(
                    value: coreSettings.tlsFragmentEnabled,
                    onChanged: (v) => _saveCore(
                        coreSettings.copyWith(tlsFragmentEnabled: v)))),
            if (coreSettings.tlsFragmentEnabled &&
                coreSettings.core == 'xray') ...[
              _row(
                  Icons.tune_rounded,
                  'Тип фрагментации',
                  'TLS hello или первые TCP отправки',
                  _menu(
                      coreSettings.fragmentPackets,
                      const {
                        'tlshello': 'TLS hello',
                        '1-3': 'Первые 3 отправки',
                      },
                      (v) => _saveCore(
                          coreSettings.copyWith(fragmentPackets: v)))),
              _row(
                  Icons.view_week_outlined,
                  'Размер фрагментов',
                  'В байтах · Xray',
                  _menu(
                      coreSettings.fragmentLength,
                      const {
                        '50-100': '50–100',
                        '100-200': '100–200',
                        '200-300': '200–300',
                      },
                      (v) =>
                          _saveCore(coreSettings.copyWith(fragmentLength: v)))),
              _row(
                  Icons.timer_outlined,
                  'Интервал между частями',
                  'В миллисекундах · Xray',
                  _menu(
                      coreSettings.fragmentInterval,
                      const {
                        '0-0': '0',
                        '5-10': '5–10',
                        '10-20': '10–20',
                        '20-30': '20–30',
                      },
                      (v) => _saveCore(
                          coreSettings.copyWith(fragmentInterval: v)))),
            ],
            if (coreSettings.core == 'sing-box') ...[
              _row(
                  Icons.data_array_rounded,
                  'Фрагментация TLS-записей',
                  'Sing-box · другая стратегия разделения',
                  _compactSwitch(
                      value: coreSettings.fragmentRecord,
                      onChanged: (v) =>
                          _saveCore(coreSettings.copyWith(fragmentRecord: v)))),
              if (coreSettings.tlsFragmentEnabled ||
                  coreSettings.fragmentRecord)
                _row(
                    Icons.hourglass_bottom_rounded,
                    'Резервная задержка',
                    '${coreSettings.fragmentFallbackDelayMs} мс · sing-box',
                    _menu(
                        '${coreSettings.fragmentFallbackDelayMs}',
                        const {
                          '200': '200 мс',
                          '500': '500 мс',
                          '1000': '1000 мс',
                        },
                        (v) => _saveCore(coreSettings.copyWith(
                            fragmentFallbackDelayMs: int.parse(v))))),
            ],
            SizedBox(height: 15),
            _section('РАСШИРЕННЫЕ ПАРАМЕТРЫ ЯДРА'),
            _row(
                Icons.travel_explore_rounded,
                'Анализ протоколов',
                'Нужен для доменных правил маршрутизации',
                _compactSwitch(
                    value: coreSettings.sniffingEnabled,
                    onChanged: (v) =>
                        _saveCore(coreSettings.copyWith(sniffingEnabled: v)))),
            _row(
                Icons.bolt_rounded,
                'TCP Fast Open',
                'Ускоряет TCP handshake, если поддерживается ОС',
                _compactSwitch(
                    value: coreSettings.tcpFastOpen,
                    onChanged: (v) =>
                        _saveCore(coreSettings.copyWith(tcpFastOpen: v)))),
            _row(
                Icons.data_usage_rounded,
                'Фрагментация UDP',
                'Может помочь с крупными UDP-пакетами; зависит от ядра и ОС',
                _compactSwitch(
                    value: coreSettings.udpFragment,
                    onChanged: coreSettings.core == 'sing-box'
                        ? (v) =>
                            _saveCore(coreSettings.copyWith(udpFragment: v))
                        : null)),
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
                        tooltip: _localized('Изменить порт'),
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
                      tooltip: _localized('Изменить DNS-резолвер'),
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
                      tooltip: _localized('Изменить список'),
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
                      tooltip: _localized('Обновить список рекламы'),
                      onPressed: loadingAdBlocklist
                          ? null
                          : () => _refreshAdBlocklist(),
                      icon: loadingAdBlocklist
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.refresh_rounded))),
            _dnsBlocklistSourcesRow(),
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
                    Platform.isIOS
                        ? const {'tcp': 'TCP'}
                        : Platform.isAndroid
                            ? const {'proxy': 'Proxy GET', 'tcp': 'TCP'}
                            : const {
                                'proxy': 'Proxy GET',
                                'tcp': 'TCP',
                                'icmp': 'ICMP',
                              },
                    (v) => _saveCore(coreSettings.copyWith(pingMode: v),
                        requiresReconnect: false))),
            if (coreSettings.pingMode == 'proxy')
              _row(
                  Icons.link_rounded,
                  'Ссылка для GET',
                  coreSettings.proxyGetUrl,
                  IconButton(
                      tooltip: _localized('Изменить ссылку проверки'),
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
            _section('ДАННЫЕ ПРИЛОЖЕНИЯ'),
            _row(
                Icons.data_object_rounded,
                'JSON настроек ядра',
                'Посмотреть или изменить полный набор параметров',
                IconButton(
                    tooltip: _localized('Открыть JSON'),
                    onPressed: _editCoreSettingsJson,
                    icon: const Icon(Icons.chevron_right_rounded))),
            _row(
                Icons.restart_alt_rounded,
                'Сбросить настройки',
                'Сбросить ядро, тему и поведение приложения',
                IconButton(
                    tooltip: _localized('Сбросить настройки'),
                    onPressed: _resetCoreSettings,
                    icon: const Icon(Icons.restart_alt_rounded))),
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
                                'Подключения ${connectionHistory.length}/$logRetainedConnections')),
                        const Spacer(),
                        TextButton.icon(
                            onPressed: _showLogs,
                            icon: const Icon(Icons.article_outlined, size: 16),
                            label: Text(_localized('Файл журнала'))),
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

  Future<void> _editCoreSettingsJson() async {
    final controller = TextEditingController(
        text:
            const JsonEncoder.withIndent('  ').convert(coreSettings.toJson()));
    String? error;
    final accepted = await showDialog<String>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
                  title: Text(_localized('JSON настроек ядра')),
                  content: SizedBox(
                    width:
                        math.min(520.0, MediaQuery.sizeOf(context).width - 64),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                        controller: controller,
                        minLines: 14,
                        maxLines: 22,
                        autofocus: true,
                        autocorrect: false,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 11, height: 1.4),
                        decoration: InputDecoration(
                            hintText: '{ ... }',
                            errorText:
                                error == null ? null : _messageText(error!)),
                      ),
                      const SizedBox(height: 8),
                      Text(
                          _localized(
                              'Применение проверит типы и допустимые значения. Текущие параметры соединения сохранятся.'),
                          style: TextStyle(fontSize: 11)),
                    ]),
                  ),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: Text(_localized('Отмена'))),
                    FilledButton.icon(
                        onPressed: () {
                          try {
                            final decoded = jsonDecode(controller.text);
                            if (decoded is! Map) {
                              throw FormatException(
                                  _localized('Нужен JSON-объект'));
                            }
                            final normalized = CoreSettings.fromJson(
                                Map<String, dynamic>.from(decoded));
                            Navigator.pop(
                                dialogContext, jsonEncode(normalized.toJson()));
                          } on Object catch (e) {
                            setDialogState(() => error = e.toString());
                          }
                        },
                        icon: const Icon(Icons.check_rounded),
                        label: Text(_localized('Проверить и применить'))),
                  ],
                )));
    controller.dispose();
    if (accepted == null || !mounted) return;
    try {
      final data = Map<String, dynamic>.from(jsonDecode(accepted) as Map);
      var updated = CoreSettings.fromJson(data);
      if (Platform.isIOS &&
          (updated.core != 'sing-box' ||
              updated.connectionMode != 'tun' ||
              updated.pingMode != 'tcp')) {
        throw const FormatException(
            'Для iOS требуются sing-box, системный VPN (TUN) и TCP-проверка задержки.');
      }
      if (updated.killSwitchEnabled && !Platform.isLinux) {
        throw const FormatException('Kill Switch доступен только в Linux.');
      }
      if (updated.killSwitchEnabled &&
          updated.connectionMode != 'tun' &&
          updated.connectionMode != 'mixed') {
        throw const FormatException('Kill Switch требует режим TUN или Mixed.');
      }
      if (updated.killSwitchEnabled != coreSettings.killSwitchEnabled) {
        if (updated.killSwitchEnabled) {
          final profile = selected;
          if (profile == null) {
            throw const FormatException(
                'Для Kill Switch сначала выбери сервер.');
          }
          final armedProfile = await LinuxKillSwitch.arm(profile,
              knownEndpoint: coreSettings.killSwitchProfileId == profile.id
                  ? coreSettings.killSwitchEndpoint
                  : null);
          updated = updated.copyWith(
              killSwitchEndpoint: armedProfile.address,
              killSwitchProfileId: profile.id);
        } else {
          await LinuxKillSwitch.disarm();
          updated =
              updated.copyWith(killSwitchEndpoint: '', killSwitchProfileId: '');
        }
      }
      final wasConnected = backend.state == VpnState.connected;
      await _saveCore(updated);
      process?.settings = updated;
      if (wasConnected && selected != null) {
        await _disconnectActive();
        await _toggle();
      }
      if (mounted) _message('Параметры ядра обновлены из JSON');
    } on Object catch (e) {
      if (mounted) _message('Не удалось применить JSON: $e');
    }
  }

  Future<void> _resetCoreSettings() async {
    final reset = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(_localized('Сбросить настройки приложения?')),
              content: Text(_localized(
                  'Вернутся стандартные параметры ядра, тема и поведение приложения. Серверы останутся.')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(_localized('Отмена'))),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(_localized('Сброс'))),
              ],
            ));
    if (reset != true || !mounted) return;
    if (Platform.isLinux && coreSettings.killSwitchEnabled) {
      try {
        await LinuxKillSwitch.disarm();
      } on Object catch (error) {
        _message('Сначала отключи Kill Switch: $error');
        return;
      }
    }
    if (backend.state != VpnState.disconnected) await _disconnectActive();
    final defaults = CoreSettings(
      core: Platform.isAndroid || Platform.isIOS ? 'sing-box' : 'xray',
      connectionMode: 'tun',
    );
    await _saveCore(defaults, requiresReconnect: false);
    process?.settings = defaults;
    await ThemeController.instance.select(ThemePreset.midnight);
    final storage = prefs ??= await SharedPreferences.getInstance();
    await storage.setBool('appEnglish', false);
    await storage.setBool('animatedBackground', true);
    await storage.setBool('autoRefreshSubscriptions', true);
    await storage.setBool('autoUpdateApp', true);
    if (mounted) {
      setState(() {
        english = false;
        animatedBackground = true;
        autoRefreshSubscriptions = true;
        autoUpdateApp = true;
      });
      ambientMotion.repeat();
    }
    _scheduleSubscriptionRefresh();
    if (mounted) _message('Настройки ядра сброшены');
  }

  Future<void> _deleteAllServers() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(_localized('Удалить серверы и подписки?')),
              content: Text(_localized(
                  'Все добавленные серверы, источники подписок и их сведения будут удалены с этого устройства.')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(_localized('Отмена'))),
                FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFB94B58)),
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(_localized('Удалить всё'))),
              ],
            ));
    if (confirmed != true || !mounted) return;
    if (backend.state != VpnState.disconnected) await _disconnectActive();
    setState(() {
      profiles.clear();
      subscriptions.clear();
      subscriptionProfileIds.clear();
      subscriptionUrl = null;
      selectedId = null;
      activeProfileId = null;
      pendingReconnect = false;
      collapsedSubscriptions.clear();
      collapsedSubscriptionInfo.clear();
    });
    await _persist();
    final storage = prefs ??= await SharedPreferences.getInstance();
    for (final key in const [
      'subscriptions',
      'subscriptionUrl',
      'subscriptionProfileIds',
      'selectedProfile',
    ]) {
      await storage.remove(key);
    }
    if (mounted) _message('Серверы и подписки удалены');
  }

  String _routingLabel() => switch (coreSettings.routing) {
        'rules' => _text('Только домены из списка через VPN',
            'Only domains in the list use VPN'),
        'exclude' => _text('Всё через VPN, кроме списка',
            'All traffic except listed domains uses VPN'),
        _ => _text('Весь трафик через VPN', 'All traffic through VPN'),
      };
  Widget _dnsBlocklistSourcesRow() => _row(
      Icons.playlist_add_check_rounded,
      _text('Ссылки DNS-листов', 'DNS list URLs'),
      _text('${customDnsBlocklistUrls.length} пользовательских .txt списков',
          '${customDnsBlocklistUrls.length} custom .txt lists'),
      IconButton(
          tooltip: _text('Добавить или изменить ссылки', 'Edit list URLs'),
          onPressed: _editDnsBlocklistSources,
          icon: const Icon(Icons.edit_outlined)));

  String _dnsLabel() => switch (coreSettings.dns) {
        'cloudflare' => 'Cloudflare · DoH',
        'google' => 'Google · DoH',
        'combined' => 'Cloudflare + Google',
        'custom' => coreSettings.customDnsResolver,
        _ => _text('Системный DNS', 'System DNS'),
      };

  String _dnsBlacklistLabel() => switch (coreSettings.dnsBlacklistMode) {
        'ads' => loadingAdBlocklist
            ? _text('Обновляется…', 'Updating…')
            : _text('Блок рекламы · ${coreSettings.adBlockDomains.length}',
                'Ad blocking · ${coreSettings.adBlockDomains.length} domains'),
        'custom' => _text(
            'Кастом · ${coreSettings.blockedDomains.length} доменов',
            'Custom · ${coreSettings.blockedDomains.length} domains'),
        _ => _text('Нет', 'Off'),
      };
  Widget _menu(String value, Map<String, String> choices,
          ValueChanged<String> onChanged) =>
      PopupMenuButton<String>(
          tooltip: _localized('Выбрать'),
          onSelected: onChanged,
          icon: Icon(Icons.unfold_more_rounded, size: 20, color: _accent),
          itemBuilder: (_) => choices.entries
              .map((e) =>
                  PopupMenuItem(value: e.key, child: Text(_localized(e.value))))
              .toList());

  Future<void> _editPort() async {
    final controller = TextEditingController(text: '${coreSettings.localPort}');
    final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                backgroundColor: _surface,
                title: Text(_localized('Локальный порт')),
                content: TextField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                        helperText: _localized('От 1024 до 65535'))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(_localized('Отмена'))),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, controller.text),
                      child: Text(_localized('Сохранить')))
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
      _scheduleSubscriptionRefresh();
      unawaited(_checkSubscriptionEndpoint(url));
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
      child: Text(_localized(text).toUpperCase(),
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
                  Text(_localized(title)),
                  Text(_localized(subtitle),
                      style: TextStyle(color: _muted, fontSize: 11))
                ])),
            trailing
          ]));

  Widget _compactSwitch(
      {required bool value, required ValueChanged<bool>? onChanged}) {
    return GlassSwitch(value: value, onChanged: onChanged);
  }

  Widget _compactSlider({
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double>? onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            activeTrackColor: _accent,
            inactiveTrackColor: Colors.white.withValues(alpha: .16),
            thumbColor: Colors.white,
            overlayColor: _accent.withValues(alpha: .14),
            thumbShape: _OutlinedSliderThumbShape(outlineColor: _accent),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            trackShape: const RoundedRectSliderTrackShape(),
          ),
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      );

  Widget _draggableTabIndicator({
    required bool vertical,
    required BoxDecoration decoration,
  }) =>
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => setState(() => _draggingTabIndicator = true),
        onPanUpdate: (details) =>
            _dragTabIndicator(details.globalPosition, vertical: vertical),
        onPanEnd: (_) => setState(() => _draggingTabIndicator = false),
        onPanCancel: () => setState(() => _draggingTabIndicator = false),
        child: AnimatedScale(
          scale: _draggingTabIndicator ? .98 : 1,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            decoration: decoration,
          ),
        ),
      );

  void _dragSettingsMode(Offset globalPosition) {
    final renderObject = _settingsModeKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final local = renderObject.globalToLocal(globalPosition);
    final nextAdvanced = local.dx >= renderObject.size.width / 2;
    if (nextAdvanced != advanced) setState(() => advanced = nextAdvanced);
  }

  void _dragTabIndicator(Offset globalPosition, {required bool vertical}) {
    final key = vertical ? _sideNavKey : _bottomNavKey;
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final local = box.globalToLocal(globalPosition);
    int? target;
    if (vertical) {
      const inset = 6.0;
      const rowStride = 80.0;
      const tabAreaHeight = 3 * 72.0 + 2 * 8.0;
      final offset = local.dy - inset;
      if (offset < 0 || offset >= tabAreaHeight) return;
      target = (offset / rowStride).floor().clamp(0, 2);
    } else {
      const inset = 6.0;
      final contentWidth = box.size.width - inset * 2;
      final offset = local.dx - inset;
      if (offset < 0 || offset >= contentWidth) return;
      target = (offset / (contentWidth / 3)).floor().clamp(0, 2);
    }
    if (target != _tabIndex) _openTab(target);
  }

  Widget _draggableTabSurface(
          {required bool vertical, required Widget child}) =>
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) {
          setState(() => _draggingTabIndicator = true);
          _dragTabIndicator(details.globalPosition, vertical: vertical);
        },
        onPanUpdate: (details) =>
            _dragTabIndicator(details.globalPosition, vertical: vertical),
        onPanEnd: (_) => setState(() => _draggingTabIndicator = false),
        onPanCancel: () => setState(() => _draggingTabIndicator = false),
        child: child,
      );

  Widget _nav() => _draggableTabSurface(
      vertical: false,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(29),
        child: BackdropFilter(
          // Keep the tab dock glassy even when the app-wide preview is off.
          filter: ui.ImageFilter.blur(sigmaX: 3, sigmaY: 3),
          child: Container(
              key: _bottomNavKey,
              height: 84,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                  color: _surface.withValues(alpha: .84),
                  borderRadius: BorderRadius.circular(27),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: .15)),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withOpacity(.24),
                        blurRadius: 25,
                        offset: const Offset(0, 10)),
                  ]),
              child: LayoutBuilder(builder: (context, bounds) {
                final itemWidth = bounds.maxWidth / 3;
                return Stack(children: [
                  AnimatedPositioned(
                      duration: const Duration(milliseconds: 205),
                      curve: Curves.easeOutQuart,
                      left: itemWidth * _tabIndex,
                      top: 0,
                      bottom: 0,
                      width: itemWidth,
                      child: _draggableTabIndicator(
                          vertical: false,
                          decoration: BoxDecoration(
                              gradient: LinearGradient(colors: [
                                _accent.withValues(alpha: .20),
                                _surface
                              ]),
                              borderRadius: BorderRadius.circular(21),
                              border: Border.all(
                                  color: _accent.withValues(alpha: .4)),
                              boxShadow: [
                                BoxShadow(
                                    color: _accent.withOpacity(.18),
                                    blurRadius: 17),
                              ]))),
                  Row(children: [
                    _navItem(Icons.shield_outlined,
                        _text('Подключение', 'Connect'), 0),
                    _navItem(Icons.alt_route_rounded,
                        _text('Маршрут', 'Routing'), 1),
                    _navItem(
                        Icons.tune_rounded, _text('Настройки', 'Settings'), 2),
                  ]),
                ]);
              })),
        ),
      ));
  Widget _sideNav() => _draggableTabSurface(
        vertical: true,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(25),
          child: Container(
              key: _sideNavKey,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                  color: _surface.withValues(alpha: .94),
                  borderRadius: BorderRadius.circular(25),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: .15)),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withOpacity(.18),
                        blurRadius: 24,
                        offset: const Offset(0, 8))
                  ]),
              child: LayoutBuilder(builder: (context, _) {
                const itemHeight = 72.0;
                const itemGap = 8.0;
                const selectedHeight = 72.0;
                return Stack(children: [
                  AnimatedPositioned(
                      duration: const Duration(milliseconds: 210),
                      curve: Curves.easeOutCubic,
                      top: (itemHeight + itemGap) * _tabIndex +
                          (itemHeight - selectedHeight) / 2,
                      left: 0,
                      right: 0,
                      height: selectedHeight,
                      child: _draggableTabIndicator(
                          vertical: true,
                          decoration: BoxDecoration(
                              gradient: LinearGradient(
                                  colors: [
                                    _accent.withValues(alpha: .20),
                                    _surface
                                  ],
                                  begin: Alignment.centerLeft,
                                  end: Alignment.centerRight),
                              borderRadius: BorderRadius.circular(19),
                              border: Border.all(
                                  color: _accent.withOpacity(.38))))),
                  Column(children: [
                    SizedBox(
                        height: itemHeight,
                        child: _sideNavItem(Icons.shield_outlined,
                            _text('Подключение', 'Connect'), 0)),
                    const SizedBox(height: itemGap),
                    SizedBox(
                        height: itemHeight,
                        child: _sideNavItem(Icons.alt_route_rounded,
                            _text('Маршрут', 'Routing'), 1)),
                    const SizedBox(height: itemGap),
                    SizedBox(
                        height: itemHeight,
                        child: _sideNavItem(Icons.tune_rounded,
                            _text('Настройки', 'Settings'), 2)),
                    const SizedBox(height: itemGap),
                    const Spacer(),
                    Divider(
                        height: 16,
                        thickness: 1,
                        indent: 10,
                        endIndent: 10,
                        color: Colors.white.withValues(alpha: .10)),
                    _sideActionItem(
                        Icons.speed_rounded,
                        _text('Пинг все', 'Ping all'),
                        () => _checkAllProfiles(List.of(profiles))),
                    _sideActionItem(Icons.article_outlined,
                        _text('Логи', 'Logs'), _showLogs),
                    _sideActionItem(Icons.history_rounded,
                        _text('История', 'History'), _showConnectionHistory),
                    const SizedBox(height: 4),
                  ]),
                ]);
              })),
        ),
      );

  Widget _sideActionItem(IconData icon, String label, VoidCallback onTap) =>
      SizedBox(
          height: 62,
          child: Tooltip(
              message: label,
              child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: onTap,
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(icon, size: 19, color: _muted),
                            const SizedBox(height: 4),
                            SizedBox(
                                width: double.infinity,
                                child: Text(label,
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: _muted, fontSize: 9.5)))
                          ])))));

  Widget _sideNavItem(IconData icon, String label, int index) => MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (_hoveredNavTab != index) setState(() => _hoveredNavTab = index);
      },
      onExit: (_) {
        if (_hoveredNavTab == index) setState(() => _hoveredNavTab = null);
      },
      child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _openTab(index),
          child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                  color: _hoveredNavTab == index
                      ? _accent.withValues(alpha: .16)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(19)),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AnimatedScale(
                      scale: _tabIndex == index ? 1.08 : 1,
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutBack,
                      child: Icon(icon,
                          size: 23,
                          color: _tabIndex == index ? _foreground : _muted),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                        width: double.infinity,
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          style: TextStyle(
                              color: _tabIndex == index ? _foreground : _muted,
                              fontSize: 10.5,
                              fontWeight: _tabIndex == index
                                  ? FontWeight.w600
                                  : FontWeight.w400),
                          child: Text(label,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ))
                  ]))));

  Widget _navItem(IconData icon, String label, int index) => Expanded(
      child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) {
            if (_hoveredNavTab != index) setState(() => _hoveredNavTab = index);
          },
          onExit: (_) {
            if (_hoveredNavTab == index) setState(() => _hoveredNavTab = null);
          },
          child: GestureDetector(
              onTap: () => _openTab(index),
              child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOutCubic,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                      color: _hoveredNavTab == index
                          ? Colors.white.withValues(alpha: .095)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(20)),
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedScale(
                          scale: _tabIndex == index ? 1.08 : 1,
                          duration: const Duration(milliseconds: 190),
                          curve: Curves.easeOutBack,
                          child: Icon(icon,
                              size: 24,
                              color:
                                  _tabIndex == index ? Colors.white : _muted),
                        ),
                        SizedBox(height: 5),
                        AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          style: TextStyle(
                              color: _tabIndex == index ? _foreground : _muted,
                              fontSize: 11,
                              fontWeight: _tabIndex == index
                                  ? FontWeight.w600
                                  : FontWeight.w400),
                          child: Text(label),
                        )
                      ])))));
  Widget _segment(String label, bool active, VoidCallback onTap) => Expanded(
      child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
              duration: Duration(milliseconds: 180),
              padding: EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(13)),
              alignment: Alignment.center,
              child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  style: TextStyle(
                      color: active ? _foreground : _muted,
                      fontWeight: active ? FontWeight.w600 : FontWeight.normal),
                  child: Text(label)))));
}

class _AmbientBackgroundPainter extends CustomPainter {
  _AmbientBackgroundPainter(
      {required this.animation, required this.color, required this.enabled})
      : super(repaint: animation);
  final Animation<double> animation;
  final Color color;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final phase = (enabled ? animation.value : .12) * math.pi * 2;
    final opacity = enabled ? .095 : .025;
    final upperCenter = Offset(size.width * (.18 + math.sin(phase) * .16),
        size.height * (.10 + math.cos(phase) * .12));
    // Both paths complete an integer number of turns per controller cycle,
    // so their positions match at the loop boundary without a visible jump.
    final lowerCenter = Offset(size.width * (.88 + math.cos(phase) * .10),
        size.height * (.74 + math.sin(phase) * .11));
    void drawBlob(Offset center, double radius, Color blobColor) {
      final paint = Paint()
        ..shader = RadialGradient(colors: [
          blobColor.withValues(alpha: opacity),
          blobColor.withValues(alpha: 0),
        ]).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(center, radius, paint);
    }

    drawBlob(upperCenter, size.width * .66, color);
    drawBlob(
        lowerCenter, size.width * .52, Color.lerp(color, Colors.indigo, .30)!);
  }

  @override
  bool shouldRepaint(covariant _AmbientBackgroundPainter oldDelegate) =>
      oldDelegate.animation != animation ||
      oldDelegate.color != color ||
      oldDelegate.enabled != enabled;
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
      old.color != color ||
      old.active != active ||
      old.connecting != connecting;
}

class _OutlinedSliderThumbShape extends SliderComponentShape {
  const _OutlinedSliderThumbShape({required this.outlineColor});

  final Color outlineColor;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size.square(21);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final radius = 9.5 + activationAnimation.value * .5;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.black.withValues(alpha: .18)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = sliderTheme.thumbColor ?? Colors.white
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      center,
      radius - .5,
      Paint()
        ..color = outlineColor.withValues(alpha: .72)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }
}
