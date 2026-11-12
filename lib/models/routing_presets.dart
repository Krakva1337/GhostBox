import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'core_settings.dart';

/// A named, reusable collection of routing patterns.
class RoutingPreset {
  const RoutingPreset({
    required this.id,
    required this.name,
    required this.domains,
    this.builtIn = false,
  });

  final String id;
  final String name;
  final List<String> domains;
  final bool builtIn;

  static const Set<String> _builtInIds = {
    'yandex',
    'roblox',
    'discord',
    'ru-banks',
    'ru-gos',
    'ru-other'
  };
  static final List<RoutingPreset> _fallbackBuiltIns = List.unmodifiable([
    _builtIn('yandex', 'Yandex', _yandexDomains),
    _builtIn('roblox', 'Roblox', _robloxDomains),
    _builtIn('discord', 'Discord', _discordDomains),
  ]);
  static List<RoutingPreset> _bundledBuiltIns = const [];

  static List<RoutingPreset> builtIns() =>
      _bundledBuiltIns.isEmpty ? _fallbackBuiltIns : _bundledBuiltIns;

  static Future<void> loadBundled() async {
    const definitions = <(String, String, String)>[
      ('yandex', 'Yandex', 'dnslists/routing/yandex'),
      ('roblox', 'Roblox', 'dnslists/routing/roblox'),
      ('discord', 'Discord', 'dnslists/routing/discord'),
      ('ru-banks', 'Банки России', 'dnslists/routing/ru.banks'),
      ('ru-gos', 'Госуслуги России', 'dnslists/routing/ru.gos'),
      ('ru-other', 'Российские сервисы', 'dnslists/routing/ru.other'),
    ];
    final sources = await Future.wait(definitions.map((definition) async {
      final (id, name, asset) = definition;
      try {
        return <String, String>{
          'id': id,
          'name': name,
          'source': await rootBundle.loadString(asset),
        };
      } on Object {
        // An older build can still start if one optional list asset is absent.
        return null;
      }
    }));
    final parsed =
        await compute<List<Map<String, String>>, List<Map<String, Object?>>>(
      _parseBundledRoutingAssets,
      sources.whereType<Map<String, String>>().toList(),
      debugLabel: 'GhostBox routing lists',
    );
    final presets = parsed
        .where((entry) => (entry['domains'] as List).isNotEmpty)
        .map((entry) => RoutingPreset(
              id: entry['id']! as String,
              name: entry['name']! as String,
              domains:
                  List.unmodifiable((entry['domains']! as List).cast<String>()),
              builtIn: true,
            ))
        .toList();
    if (presets.isNotEmpty) _bundledBuiltIns = List.unmodifiable(presets);
  }

  static RoutingPreset _builtIn(String id, String name, String source) {
    final domains = source
        .split(RegExp(r'\s+'))
        .where((domain) => domain.isNotEmpty)
        .toSet();
    return RoutingPreset(
      id: id,
      name: name,
      domains: List.unmodifiable(<String>{
        ...domains,
        ...domains.map((domain) => '*.$domain'),
      }),
      builtIn: true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'domains': domains,
        'builtIn': builtIn,
      };

  /// Loads a user preset. Shipped presets cannot be shadowed by JSON data.
  factory RoutingPreset.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final rawDomains = json['domains'];
    if (id is! String || !_isValidId(id)) {
      throw const FormatException('Некорректный идентификатор пресета');
    }
    if (_builtInIds.contains(id.toLowerCase()) || json['builtIn'] == true) {
      throw const FormatException('Нельзя импортировать встроенный пресет');
    }
    if (name is! String || name.trim().isEmpty || name.trim().length > 80) {
      throw const FormatException('Некорректное имя пресета');
    }
    if (rawDomains is! List || rawDomains.isEmpty) {
      throw const FormatException('Список правил пресета пуст или неверен');
    }
    final domains = <String>{};
    for (final raw in rawDomains) {
      if (raw is! String) {
        throw const FormatException('Правило пресета должно быть строкой');
      }
      final normalized = CoreSettings.normalizeRoutePattern(raw);
      if (!CoreSettings.isValidRoutePattern(normalized)) {
        throw FormatException('Некорректное правило пресета: $raw');
      }
      domains.add(normalized);
    }
    return RoutingPreset(
      id: id,
      name: name.trim(),
      domains: List.unmodifiable(domains),
    );
  }

  static bool _isValidId(String id) =>
      RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$').hasMatch(id);
}

List<Map<String, Object?>> _parseBundledRoutingAssets(
        List<Map<String, String>> sources) =>
    [
      for (final entry in sources)
        {
          'id': entry['id']!,
          'name': entry['name']!,
          'domains': {
            for (final raw in const LineSplitter().convert(entry['source']!))
              if (raw.trim().isNotEmpty &&
                  !raw.trim().startsWith('#') &&
                  !raw.trim().startsWith('//'))
                if (CoreSettings.isValidRoutePattern(
                    CoreSettings.normalizeRoutePattern(raw.trim())))
                  CoreSettings.normalizeRoutePattern(raw.trim()),
          }.toList(),
        },
    ];

const String _yandexDomains = '''
yandex.ru
yandex.net
yandex.com
yandex.cloud
yandexcloud.net
yandex.st
yandex.sx
ya.ru
ya.cc
yastatic.net
yastatic-net.ru
yastat.net
yccdn.ru
yndx.net
yndx-static.net
static-storage.net
clstorage.net
yandexadexchange.net
yandexmetrica.com
yandex-metrica.ru
yads.tech
adfox.ru
admetrica.ru
webvisor.com
webvisor.org
web-visor.com
yandex.by
yandex.kz
yandex.uz
yandex.com.tr
yandex.com.am
yandex.com.ge
yandex.co.il
yandex.az
yandex.kg
yandex.md
yandex.tj
yandex.tm
yandex.ua
yandex.de
yandex.fr
yandex.fi
yandex.ee
yandex.lt
yandex.lv
yandex.pl
yandex.eu
yandex.tr
yandex.travel
yandex.market
yandex.mobi
yandex.pro
yandex.org
yandex.asia
yandex.aero
yandex.taxi
yandexgo.com
yandexwebcache.net
yandexwebcache.org
yandexcom.net
yandex-team.ru
yandex-team.com
yandexdataschool.ru
yandexdataschool.com
yandexlyceum.ru
static.yandex.net
cdn.yandex.net
cloud.cdn.yandex.net
cdn.browser.yandex.net
home.yastatic.net
brotli.yastatic.net
br.yastatic.net
et.yastatic.net
static.yandex.sx
js.static.yandex.net
img-css.friends.yandex.net
s3.yandex.net
s3.mds.yandex.net
storage.yandex.net
storage.mds.yandex.net
storage.yandexcloud.net
avatars.mds.yandex.net
avatars-fast.yandex.net
resize.yandex.net
favicon.yandex.net
upics.yandex.net
strm.yandex.net
strm.yandex.ru
goloom.strm.yandex.net
player.video.yandex.net
streaming.disk.yandex.net
downloader.yandex.net
downloader.disk.yandex.ru
cloud-api.yandex.net
cloud-api.yandex.ru
api.yandex.ru
api-maps.yandex.ru
maps.yandex.ru
maps.yandex.net
core-renderer-tiles.maps.yandex.net
suggest-maps.yandex.ru
suggest.yandex.ru
translate.yandex.net
translate.yandex.ru
speller.yandex.net
dictionary.yandex.net
passport.yandex.ru
passport.yandex.net
oauth.yandex.ru
id.yandex.ru
sso.ya.ru
push.yandex.ru
portal-xiva.yandex.net
captcha-api.yandex.ru
ext.captcha.yandex.net
smartcaptcha.yandexcloud.net
smartcaptcha.cloud.yandex.ru
browser.yandex.ru
browser.yandex.net
browser-updater.yandex.net
repo.yandex.ru
mail.yandex.ru
disk.yandex.ru
disk.yandex.net
docs.yandex.ru
docviewer.yandex.ru
calendar.yandex.ru
telemost.yandex.ru
telemost.yandex.net
messenger.yandex.ru
api.messenger.yandex.net
backend.messenger.yandex.ru
files.messenger.yandex.net
files.messenger.yandex.ru
images.messenger.yandex.net
download.messenger.yandex.ru
stun.rtc.yandex.net
turn.webrtc.yandex.net
music.yandex.ru
music-browser.music.yandex.net
market.yandex.ru
cloud.yandex.ru
datalens.yandex
datalens.yandex.ru
forms.yandex.ru
360.yandex.ru
alice.yandex.ru
uniproxy.alice.ya.ru
mc.yandex.ru
mc.yandex.com
mc.yandex.net
an.yandex.ru
bs.yandex.ru
yabs.yandex.ru
awaps.yandex.net
awaps.yandex.ru
ads.yandex.ru
adv.yandex.ru
adfox.yandex.ru
ads.adfox.ru
banners.adfox.ru
content.adfox.ru
metrika.yandex.ru
metrika.yandex.net
metrika.yandex.com
appmetrica.yandex.ru
appmetrica.yandex.net
counter.yandex.ru
clck.yandex.ru
clck.ru
informer.yandex.ru
adfstat.yandex.ru
log.strm.yandex.ru
csp.yandex.net
uaas.yandex.ru
site.yandex.net
abt.s3.yandex.net
kinopoisk.ru
yango.com
yango.tech
yango.taxi
shedevrum.ai
shedevrum.ru
meteum.ai
turbopages.org
sourcecraft.dev
''';

const String _robloxDomains = '''
roblox.com
roblox.net
roblox.us
roblox.co.uk
roblox.cn
roblox.qq.com
rbxcdn.com
rbxinfra.net
rbxinfra.com
rbxtrk.com
rblx.com
rblx.co
rblx.org
rbx.com
rbxlabs.com
robloxlabs.com
robloxapp.com
robloxgames.com
www.roblox.com
web.roblox.com
m.roblox.com
api.roblox.com
apis.roblox.com
apis.rcs.roblox.com
auth.roblox.com
authsite.roblox.com
users.roblox.com
accountinformation.roblox.com
accountsettings.roblox.com
clientsettings.roblox.com
clientsettings.api.roblox.com
clientsettingscdn.roblox.com
versioncompatibility.api.roblox.com
assetgame.roblox.com
assetdelivery.roblox.com
setup.roblox.com
setup.rbxcdn.com
static.rbxcdn.com
js.rbxcdn.com
apis.rbxcdn.com
c0.rbxcdn.com
c1.rbxcdn.com
c2.rbxcdn.com
c3.rbxcdn.com
c4.rbxcdn.com
c5.rbxcdn.com
c6.rbxcdn.com
c7.rbxcdn.com
t0.rbxcdn.com
t1.rbxcdn.com
t2.rbxcdn.com
t3.rbxcdn.com
t4.rbxcdn.com
t5.rbxcdn.com
t6.rbxcdn.com
t7.rbxcdn.com
tr.rbxcdn.com
games.roblox.com
gamejoin.roblox.com
gamesite.roblox.com
presence.roblox.com
friends.roblox.com
friendsite.roblox.com
followings.roblox.com
chat.roblox.com
chatsite.roblox.com
voice.roblox.com
realtime-signalr.roblox.com
notifications.roblox.com
privatemessages.roblox.com
contacts.roblox.com
groups.roblox.com
avatar.roblox.com
avatarsite.roblox.com
thumbnails.roblox.com
catalog.roblox.com
inventory.roblox.com
itemconfiguration.roblox.com
badges.roblox.com
economy.roblox.com
economycreatorstats.roblox.com
billing.roblox.com
premiumfeatures.roblox.com
trades.roblox.com
engagementpayouts.roblox.com
ads.roblox.com
adconfiguration.roblox.com
captcha.roblox.com
cdn.arkoselabs.com
roblox-api.arkoselabs.com
locale.roblox.com
localizationtables.roblox.com
gameinternationalization.roblox.com
translationroles.roblox.com
translate.roblox.com
share.roblox.com
develop.roblox.com
create.roblox.com
publish.roblox.com
data.roblox.com
developer.roblox.com
devforum.roblox.com
en.help.roblox.com
support.roblox.com
status.roblox.com
metrics.roblox.com
ecsv2.roblox.com
ephemeralcounters.api.roblox.com
client-telemetry.roblox.com
abtesting.roblox.com
midas.roblox.com
midas-android.roblox.com
rbxcdn.qq.com
''';

const String _discordDomains = '''
discord.com
discord.gg
discord.media
discordapp.com
discordapp.net
discordcdn.com
discord.co
discord.dev
discord.design
discord.gift
discord.gifts
discord.new
discord.store
discord.tools
discordstatus.com
discordmerch.com
discordactivities.com
discord-activities.com
discordpartygames.com
discordsays.com
discordsez.com
discordquests.com
discordvibeapps.com
dis.gd
i.dis.gd
daveprotocol.com
www.discord.com
canary.discord.com
ptb.discord.com
support.discord.com
support-dev.discord.com
feedback.discord.com
safety.discord.com
pax.discord.com
api.discord.com
gateway.discord.gg
cdn.discordapp.com
media.discordapp.net
images-ext-1.discordapp.net
images-ext-2.discordapp.net
static.discord.com
status.discord.com
discord-attachments-uploads-prd.storage.googleapis.com
''';
