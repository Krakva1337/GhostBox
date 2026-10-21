import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'app_version.dart';

class GhostBoxRelease {
  const GhostBoxRelease({
    required this.version,
    required this.tagName,
    required this.pageUrl,
    required this.assets,
    this.notes = '',
  });

  final String version;
  final String tagName;
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
  static const updateBranch = String.fromEnvironment(
    'GHOSTBOX_UPDATE_BRANCH',
    defaultValue: 'main',
  );
  static const currentVersion = AppVersion.version;
  static const _androidUpdateChannel =
      MethodChannel('app.ghostbox.ghostbox/app_update');

  static String displayVersion(String version) {
    final normalized = version.replaceFirst(RegExp(r'^v'), '');
    if (RegExp(r'^1\.3(?:\.0)?-alpha$', caseSensitive: false)
        .hasMatch(normalized)) {
      return 'v1.3-Alpha';
    }
    if (RegExp(r'^1\.2(?:\.0)?-alpha$', caseSensitive: false)
        .hasMatch(normalized)) {
      return 'v1.2-Alpha';
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
    final branch = updateBranch.trim();
    if (branch.isEmpty) {
      throw const FormatException('Не задана ветка обновлений GitHub.');
    }
    final branchData = await _getJson(Uri.https('api.github.com',
        '/repos/$repository/branches/${Uri.encodeComponent(branch)}'));
    if (branchData is! Map || branchData['commit'] is! Map) {
      throw const FormatException(
          'GitHub вернул некорректную ветку обновлений.');
    }
    final branchSha = (branchData['commit'] as Map)['sha'];
    if (branchSha is! String || branchSha.isEmpty) {
      throw const FormatException('GitHub не вернул commit ветки обновлений.');
    }

    final rows = await _getJson(Uri.https(
        'api.github.com', '/repos/$repository/releases', {'per_page': '30'}));
    if (rows is! List) throw const FormatException('Некорректный ответ GitHub');
    final releases = rows
        .whereType<Map>()
        .where((row) => row['draft'] != true)
        .map(_parseRelease)
        .whereType<GhostBoxRelease>()
        .toList();
    releases.sort((a, b) => _compareVersions(b.version, a.version));
    for (final release in releases) {
      final versionOrder = _compareVersions(release.version, currentVersion);
      if (!includeCurrent && versionOrder <= 0) continue;
      if (await _isCommitOnBranch(release, branchSha)) return release;
    }
    return null;
  }

  Future<dynamic> _getJson(Uri uri) async {
    final request =
        await _client.getUrl(uri).timeout(const Duration(seconds: 12));
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set(HttpHeaders.userAgentHeader, AppVersion.userAgent);
    final response = await request.close().timeout(const Duration(seconds: 12));
    final body = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        response.statusCode == HttpStatus.notFound
            ? 'GitHub не нашёл ветку или релизы репозитория $repository.'
            : 'GitHub API вернул HTTP ${response.statusCode}',
      );
    }
    return jsonDecode(body);
  }

  Future<bool> _isCommitOnBranch(
      GhostBoxRelease release, String branchSha) async {
    final comparison = await _getJson(Uri.https(
      'api.github.com',
      '/repos/$repository/compare/${Uri.encodeComponent(release.tagName)}...$branchSha',
    ));
    if (comparison is! Map) return false;
    // The release tag must be an ancestor of the selected update branch. This
    // keeps a newer release from another branch out of this channel.
    return comparison['status'] == 'ahead' ||
        comparison['status'] == 'identical';
  }

  Future<File> download(GhostBoxReleaseAsset asset) async {
    final destination = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}${asset.name}');
    final request = await _client
        .getUrl(Uri.parse(asset.url))
        .timeout(const Duration(seconds: 20));
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/octet-stream')
      ..set(HttpHeaders.userAgentHeader, AppVersion.userAgent);
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
    final actualSize = await destination.length();
    if (asset.size > 0 && actualSize != asset.size) {
      await destination.delete();
      throw HttpException(
        'Загрузка ${asset.name} неполная: ожидалось ${asset.size} байт, получено $actualSize.',
      );
    }
    return destination;
  }

  Future<void> apply(
      GhostBoxRelease release, GhostBoxReleaseAsset asset) async {
    final package = await download(asset);
    try {
      final checksumAsset = release.asset('${asset.name}.sha256');
      if (checksumAsset == null) {
        throw FileSystemException(
            'В релизе ${release.tagName} нет SHA-256 для ${asset.name}');
      }
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
        final helper = File(
            '${Directory.systemTemp.path}${Platform.pathSeparator}ghostbox-update-${pid}.ps1');
        await helper.writeAsString(_windowsUpdateScript, flush: true);
        await Process.start(
          'powershell.exe',
          [
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-WindowStyle',
            'Hidden',
            '-File',
            helper.path,
            '$pid',
            package.path,
            Platform.resolvedExecutable,
          ],
          mode: ProcessStartMode.detached,
        );
        exit(0);
      }
      if (Platform.isMacOS) {
        final appBundle = _macOSAppBundlePath();
        final helper =
            File('$appBundle/Contents/Resources/ghostbox-update-macos.sh');
        if (!await helper.exists()) {
          throw const FileSystemException(
              'Не найден установщик обновлений. Установите GhostBox заново из macOS ZIP.');
        }
        await Process.start(
            '/bin/bash',
            [
              helper.path,
              package.path,
              '$pid',
              appBundle,
            ],
            mode: ProcessStartMode.detached);
        exit(0);
      }
      if (Platform.isAndroid) {
        final result = await _androidUpdateChannel
            .invokeMethod<String>('installApk', {'path': package.path});
        if (result == 'permission_required') {
          throw const FileSystemException(
              'Разреши GhostBox устанавливать приложения в системных настройках и нажми «Проверить обновления» ещё раз.');
        }
        if (package.existsSync()) await package.delete();
        return;
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
    final command = Platform.isMacOS ? 'shasum' : 'sha256sum';
    final arguments = Platform.isMacOS ? ['-a', '256', file.path] : [file.path];
    final result = await Process.run(command, arguments);
    if (result.exitCode != 0) throw ProcessException(command, arguments);
    return '${result.stdout}'.trim().split(RegExp(r'\s+')).first.toLowerCase();
  }

  Future<String?> platformAssetName(GhostBoxRelease release) async {
    if (Platform.isWindows) {
      return 'GhostBox-${release.version}-Windows-x64.zip';
    }
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
    if (Platform.isMacOS) {
      final result = await Process.run('uname', ['-m']);
      if ('${result.stdout}'.trim().toLowerCase() == 'arm64') {
        return 'GhostBox-${release.version}-macOS-arm64.zip';
      }
    }
    if (Platform.isAndroid) return 'GhostBox-Android-universal.apk';
    return null;
  }

  String _macOSAppBundlePath() {
    var current = File(Platform.resolvedExecutable).parent;
    while (current.parent.path != current.path) {
      if (current.path.toLowerCase().endsWith('.app')) return current.path;
      current = current.parent;
    }
    throw const FileSystemException(
        'Не удалось определить расположение GhostBox.app');
  }

  static const _windowsUpdateScript = r'''
$ErrorActionPreference = 'Stop'
$oldPid = [int]$args[0]
$archive = $args[1]
$appExe = $args[2]
$helper = $PSCommandPath
$installDir = Split-Path -Parent $appExe
$parentDir = Split-Path -Parent $installDir
$stage = Join-Path $parentDir ".ghostbox-update-$oldPid"
$backup = Join-Path $parentDir ".ghostbox-old-$oldPid"
try {
  while (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) {
    Start-Sleep -Milliseconds 400
  }
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Expand-Archive -LiteralPath $archive -DestinationPath $stage -Force
  $newExe = Join-Path $stage 'GhostBox.exe'
  if (-not (Test-Path -LiteralPath $newExe)) { throw 'The Windows ZIP does not contain GhostBox.exe at its root.' }
  Move-Item -LiteralPath $installDir -Destination $backup
  try {
    Move-Item -LiteralPath $stage -Destination $installDir
  } catch {
    if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force }
    if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $installDir }
    throw
  }
  Start-Process -FilePath (Join-Path $installDir 'GhostBox.exe') -ArgumentList '--ghostbox-updated'
  Start-Sleep -Seconds 3
  Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
} catch {
  if (Test-Path -LiteralPath $appExe) {
    Start-Process -FilePath $appExe -ArgumentList '--ghostbox-updated' -ErrorAction SilentlyContinue
  }
  throw
} finally {
  Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $helper -Force -ErrorAction SilentlyContinue
}
''';

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
      tagName: tag,
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
