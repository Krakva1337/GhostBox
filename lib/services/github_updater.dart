import 'dart:convert';
import 'dart:io';

class GhostBoxRelease {
  const GhostBoxRelease({
    required this.version,
    required this.pageUrl,
    required this.assets,
    this.notes = '',
  });

  final String version;
  final String pageUrl;
  final List<GhostBoxReleaseAsset> assets;
  final String notes;

  GhostBoxReleaseAsset? asset(String name) {
    for (final item in assets) {
      if (item.name == name) return item;
    }
    return null;
  }
}

class GhostBoxReleaseAsset {
  const GhostBoxReleaseAsset(this.name, this.url, this.size);
  final String name;
  final String url;
  final int size;
}

class GitHubUpdater {
  GitHubUpdater({HttpClient? client}) : _client = client ?? HttpClient();

  static const repository = 'Krakva1337/GhostBox';
  static const releasesPage = 'https://github.com/$repository/releases';
  static const currentVersion = String.fromEnvironment(
    'GHOSTBOX_VERSION',
    defaultValue: '1.0.0-alpha',
  );

  static String displayVersion(String version) {
    final normalized = version.replaceFirst(RegExp(r'^v'), '');
    if (RegExp(r'^1\.0(?:\.0)?-alpha$', caseSensitive: false)
        .hasMatch(normalized)) {
      return 'v1.0-Alpha';
    }
    final shortPreAlpha =
        RegExp(r'^(\d+)\.(\d+)\.0(-pre-alpha.*)$').firstMatch(normalized);
    if (shortPreAlpha != null) {
      return 'v${shortPreAlpha.group(1)}.${shortPreAlpha.group(2)}${shortPreAlpha.group(3)}';
    }
    return 'v$normalized';
  }

  final HttpClient _client;

  Future<GhostBoxRelease?> check({bool includeCurrent = false}) async {
    final request = await _client
        .getUrl(Uri.parse(
            'https://api.github.com/repos/$repository/releases?per_page=10'))
        .timeout(const Duration(seconds: 12));
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set(HttpHeaders.userAgentHeader, 'GhostBox/$currentVersion');
    final response = await request.close().timeout(const Duration(seconds: 12));
    final body = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        response.statusCode == HttpStatus.notFound
            ? 'GitHub Releases недоступны. Если репозиторий приватный, нужен публичный источник обновлений.'
            : 'GitHub API вернул HTTP ${response.statusCode}',
      );
    }
    final rows = jsonDecode(body);
    if (rows is! List) throw const FormatException('Некорректный ответ GitHub');
    final releases = rows
        .whereType<Map>()
        .where((row) => row['draft'] != true)
        .map(_parseRelease)
        .whereType<GhostBoxRelease>()
        .toList();
    releases.sort((a, b) => _compareVersions(b.version, a.version));
    for (final release in releases) {
      if (includeCurrent ||
          _compareVersions(release.version, currentVersion) > 0) {
        return release;
      }
    }
    return null;
  }

  Future<File> download(GhostBoxReleaseAsset asset) async {
    final destination = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}${asset.name}');
    final request = await _client
        .getUrl(Uri.parse(asset.url))
        .timeout(const Duration(seconds: 20));
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/octet-stream')
      ..set(HttpHeaders.userAgentHeader, 'GhostBox/$currentVersion');
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
          'Не удалось скачать ${asset.name}: HTTP ${response.statusCode}');
    }
    final sink = destination.openWrite();
    try {
      await response.pipe(sink).timeout(const Duration(minutes: 15));
    } on Object {
      await sink.close();
      if (destination.existsSync()) await destination.delete();
      rethrow;
    }
    return destination;
  }

  Future<void> apply(
      GhostBoxRelease release, GhostBoxReleaseAsset asset) async {
    final package = await download(asset);
    try {
      final checksumAsset = release.asset('${asset.name}.sha256');
      if (checksumAsset != null) {
        final checksumFile = await download(checksumAsset);
        try {
          final expected = RegExp(r'\b([0-9a-fA-F]{64})\b')
              .firstMatch(await checksumFile.readAsString())
              ?.group(1)
              ?.toLowerCase();
          if (expected == null)
            throw const FormatException('Некорректный SHA-256');
          final actual = await _sha256(package);
          if (actual != expected)
            throw const FormatException('SHA-256 пакета не совпал');
        } finally {
          if (checksumFile.existsSync()) await checksumFile.delete();
        }
      }

      if (Platform.isLinux) {
        final helper =
            File('${Platform.environment['HOME']}/.local/bin/ghostbox-update');
        if (!await helper.exists()) {
          throw const FileSystemException(
              'Обновлятор не найден. Переустановите приложение через tool/install_appimage.sh.');
        }
        await Process.start(helper.path, [package.path, pid.toString()],
            mode: ProcessStartMode.detached);
        // The detached helper waits for this process, swaps the extracted AppDir,
        // then starts the stable desktop launcher again.
        exit(0);
      }
      if (Platform.isWindows) {
        await Process.start(
            package.path,
            [
              '/VERYSILENT',
              '/SUPPRESSMSGBOXES',
              '/CLOSEAPPLICATIONS',
              '/NORESTART',
            ],
            mode: ProcessStartMode.detached);
        exit(0);
      }
      throw UnsupportedError(
          'Автоустановка не поддерживается на этой платформе');
    } on Object {
      if (package.existsSync()) await package.delete();
      rethrow;
    }
  }

  Future<String> _sha256(File file) async {
    if (Platform.isWindows) {
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "(Get-FileHash -Algorithm SHA256 -LiteralPath '${file.path.replaceAll("'", "''")}').Hash.ToLowerInvariant()",
      ]);
      if (result.exitCode != 0)
        throw const ProcessException('powershell.exe', []);
      return '${result.stdout}'.trim().toLowerCase();
    }
    final result = await Process.run('sha256sum', [file.path]);
    if (result.exitCode != 0) throw const ProcessException('sha256sum', []);
    return '${result.stdout}'.trim().split(RegExp(r'\s+')).first.toLowerCase();
  }

  Future<String?> platformAssetName(GhostBoxRelease release) async {
    if (Platform.isWindows) return 'GhostBox-Setup-x64.exe';
    if (Platform.isLinux) {
      final result = await Process.run('uname', ['-m']);
      final arch = '${result.stdout}'.trim().toLowerCase();
      final suffix = switch (arch) {
        'x86_64' || 'amd64' => 'x86_64',
        'aarch64' || 'arm64' => 'aarch64',
        _ => null,
      };
      return suffix == null
          ? null
          : 'GhostBox-${release.version}-linux-$suffix.AppImage';
    }
    return null;
  }

  GhostBoxRelease? _parseRelease(Map row) {
    final tag = row['tag_name'];
    final page = row['html_url'];
    if (tag is! String || page is! String) return null;
    final assets = (row['assets'] as List? ?? const [])
        .whereType<Map>()
        .where((asset) =>
            asset['name'] is String && asset['browser_download_url'] is String)
        .map((asset) => GhostBoxReleaseAsset(
              asset['name'] as String,
              asset['browser_download_url'] as String,
              (asset['size'] as num?)?.toInt() ?? 0,
            ))
        .toList();
    return GhostBoxRelease(
      version: normalizeReleaseTag(tag),
      pageUrl: page,
      assets: assets,
      notes: row['body'] is String ? row['body'] as String : '',
    );
  }

  String normalizeReleaseTag(String tag) {
    final value = tag.replaceFirst(RegExp(r'^v'), '');
    final shortTag = RegExp(r'^(\d+)\.(\d+)(-.+)$').firstMatch(value);
    if (shortTag == null) return value;
    return '${shortTag.group(1)}.${shortTag.group(2)}.0${shortTag.group(3)}';
  }

  int _compareVersions(String left, String right) {
    final a = _versionParts(left);
    final b = _versionParts(right);
    for (var i = 0; i < 3; i++) {
      final order = a.$1[i].compareTo(b.$1[i]);
      if (order != 0) return order;
    }
    final ap = a.$2;
    final bp = b.$2;
    if (ap.isEmpty || bp.isEmpty) {
      if (ap.isEmpty && bp.isEmpty) return 0;
      return ap.isEmpty ? 1 : -1;
    }
    final count = ap.length < bp.length ? ap.length : bp.length;
    for (var i = 0; i < count; i++) {
      final ai = int.tryParse(ap[i]);
      final bi = int.tryParse(bp[i]);
      final order = ai != null && bi != null
          ? ai.compareTo(bi)
          : ai != null
              ? -1
              : bi != null
                  ? 1
                  : ap[i].compareTo(bp[i]);
      if (order != 0) return order;
    }
    return ap.length.compareTo(bp.length);
  }

  (List<int>, List<String>) _versionParts(String value) {
    final match =
        RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?').firstMatch(value);
    if (match == null) return ([0, 0, 0], const []);
    final pre = match.group(4);
    return (
      [
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!)
      ],
      pre == null ? const [] : pre.split('.')
    );
  }
}
