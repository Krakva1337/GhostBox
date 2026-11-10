import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'app_version.dart';
import 'update_transaction.dart';

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

enum UpdateDownloadStage {
  downloading,
  verifying,
  staging,
  stopping,
  installing,
  relaunching,
  healthCheck,
  commit,
  cleanup,
  failed,
  rollback,
  savingToDownloads,
  launchingInstaller,
}

class UpdateDownloadProgress {
  const UpdateDownloadProgress({
    required this.assetName,
    required this.path,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.bytesPerSecond,
    required this.stage,
  });

  final String assetName;
  final String path;
  final int downloadedBytes;
  final int totalBytes;
  final double bytesPerSecond;
  final UpdateDownloadStage stage;
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
    releases.sort((a, b) => compareVersions(b.version, a.version));
    for (final release in releases) {
      final versionOrder = compareVersions(release.version, currentVersion);
      if (!includeCurrent && versionOrder <= 0) continue;
      final compatibleAsset = await platformAssetName(release);
      if (compatibleAsset == null ||
          release.asset(compatibleAsset) == null ||
          release.asset('$compatibleAsset.sha256') == null) {
        continue;
      }
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

  Future<File> download(
    GhostBoxReleaseAsset asset, {
    void Function(UpdateDownloadProgress progress)? onProgress,
  }) async {
    if (Platform.isAndroid) {
      return _downloadAndroid(asset, onProgress: onProgress);
    }
    final name = asset.name.split(RegExp(r'[/\\]')).last;
    if (name.isEmpty || name == '.' || name == '..') {
      throw const FormatException('Некорректное имя файла обновления.');
    }
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
    final downloadDirectory =
        await Directory.systemTemp.createTemp('ghostbox-download-');
    final destination =
        File('${downloadDirectory.path}${Platform.pathSeparator}$name');
    final sink = destination.openWrite();
    final stopwatch = Stopwatch()..start();
    var downloadedBytes = 0;
    final totalBytes =
        response.contentLength > 0 ? response.contentLength : asset.size;
    try {
      await for (final chunk in response.timeout(const Duration(minutes: 15))) {
        sink.add(chunk);
        downloadedBytes += chunk.length;
        onProgress?.call(UpdateDownloadProgress(
          assetName: asset.name,
          path: destination.path,
          downloadedBytes: downloadedBytes,
          totalBytes: totalBytes,
          bytesPerSecond: stopwatch.elapsedMicroseconds == 0
              ? 0
              : downloadedBytes * 1000000 / stopwatch.elapsedMicroseconds,
          stage: UpdateDownloadStage.downloading,
        ));
      }
      await sink.flush();
      await sink.close();
    } on Object {
      await sink.close();
      await _removeDownload(destination);
      rethrow;
    }
    final actualSize = await destination.length();
    if (asset.size > 0 && actualSize != asset.size) {
      await _removeDownload(destination);
      throw HttpException(
        'Загрузка ${asset.name} неполная: ожидалось ${asset.size} байт, получено $actualSize.',
      );
    }
    return destination;
  }

  Future<File> _downloadAndroid(
    GhostBoxReleaseAsset asset, {
    void Function(UpdateDownloadProgress progress)? onProgress,
  }) async {
    final cachePath = await _androidUpdateChannel
        .invokeMethod<String>('getUpdateCacheDirectory');
    if (cachePath == null || cachePath.isEmpty) {
      throw const FileSystemException(
          'Android не вернул каталог загрузки обновлений.');
    }
    final directory = await Directory(cachePath).createTemp('ghostbox-update-');
    final name = asset.name.split(RegExp(r'[/\\]')).last;
    final destination = File('${directory.path}/$name');
    IOSink? sink;
    try {
      final request = await _client
          .getUrl(Uri.parse(asset.url))
          .timeout(const Duration(seconds: 20));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/octet-stream')
        ..set(HttpHeaders.userAgentHeader, AppVersion.userAgent);
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != HttpStatus.ok) {
        await response.timeout(const Duration(seconds: 30)).drain<void>();
        throw HttpException(
            'Не удалось скачать ${asset.name}: HTTP ${response.statusCode}');
      }
      final total =
          response.contentLength > 0 ? response.contentLength : asset.size;
      final clock = Stopwatch()..start();
      var bytes = 0;
      var lastPaint = -200;
      void report() => onProgress?.call(UpdateDownloadProgress(
            assetName: asset.name,
            path: destination.path,
            downloadedBytes: bytes,
            totalBytes: total,
            bytesPerSecond: clock.elapsedMicroseconds == 0
                ? 0
                : bytes * 1000000 / clock.elapsedMicroseconds,
            stage: UpdateDownloadStage.downloading,
          ));
      report();
      sink = destination.openWrite();
      await sink
          .addStream(response.timeout(const Duration(seconds: 30)).map((chunk) {
        bytes += chunk.length;
        if (clock.elapsedMilliseconds - lastPaint >= 180) {
          lastPaint = clock.elapsedMilliseconds;
          report();
        }
        return chunk;
      }));
      await sink.close();
      sink = null;
      if (bytes == 0 ||
          (asset.size > 0 && bytes != asset.size) ||
          (total > 0 && bytes != total)) {
        throw HttpException(
            'Загрузка ${asset.name} неполная: получено $bytes байт, ожидалось $total.');
      }
      report();
      return destination;
    } on Object {
      try {
        await sink?.close();
      } on Object {/* Preserve the download error. */}
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> _removeDownload(File file) async {
    if (await file.exists()) await file.delete();
    final parentName = file.parent.path.split(RegExp(r'[/\\]')).last;
    if ((Platform.isAndroid && parentName.startsWith('ghostbox-update-')) ||
        (!Platform.isAndroid && parentName.startsWith('ghostbox-download-'))) {
      if (await file.parent.exists()) await file.parent.delete(recursive: true);
    }
  }

  Future<String?> apply(
    GhostBoxRelease release,
    GhostBoxReleaseAsset asset, {
    void Function(UpdateDownloadProgress progress)? onProgress,
    bool installAndroidPackage = true,
    Future<void> Function()? beforeHandoff,
  }) async {
    final transaction = await UpdateTransaction.create(
      targetVersion: release.version,
      assetName: asset.name,
    );
    await transaction.update(UpdateTransactionStatus.downloading);
    late final File package;
    try {
      package = await _downloadWithRetry(asset, onProgress: onProgress);
    } on Object catch (error) {
      await transaction.update(UpdateTransactionStatus.failed,
          error: error.toString());
      rethrow;
    }
    var packageVerified = false;
    String? packageHash;
    void emitStage(UpdateDownloadStage stage) {
      onProgress?.call(UpdateDownloadProgress(
        assetName: asset.name,
        path: package.path,
        downloadedBytes: 0,
        totalBytes: 0,
        bytesPerSecond: 0,
        stage: stage,
      ));
    }

    try {
      await transaction.update(UpdateTransactionStatus.verifying,
          packagePath: package.absolute.path);
      onProgress?.call(UpdateDownloadProgress(
        assetName: asset.name,
        path: package.path,
        downloadedBytes: await package.length(),
        totalBytes: await package.length(),
        bytesPerSecond: 0,
        stage: UpdateDownloadStage.verifying,
      ));
      final checksumAsset = release.asset('${asset.name}.sha256');
      if (checksumAsset == null) {
        throw FileSystemException(
            'В релизе ${release.tagName} нет файла ${asset.name}.sha256. Загрузите пакет и созданный рядом checksum-файл в один релиз.');
      }
      final checksumFile = await _downloadWithRetry(checksumAsset);
      try {
        final expected = RegExp(r'\b([0-9a-fA-F]{64})\b')
            .firstMatch(await checksumFile.readAsString())
            ?.group(1)
            ?.toLowerCase();
        if (expected == null) {
          throw const FormatException('Некорректный SHA-256');
        }
        packageHash = await _sha256(package);
        if (packageHash != expected) {
          throw const FormatException('SHA-256 пакета не совпал');
        }
        packageVerified = true;
      } finally {
        await _removeDownload(checksumFile);
      }

      emitStage(UpdateDownloadStage.staging);
      if (!Platform.isAndroid || installAndroidPackage) {
        await beforeHandoff?.call();
        emitStage(UpdateDownloadStage.stopping);
      }

      if (Platform.isLinux) {
        await transaction.update(UpdateTransactionStatus.staging,
            packagePath: package.absolute.path, sha256: packageHash);
        final helper =
            File('${Platform.environment['HOME']}/.local/bin/ghostbox-update');
        if (!await helper.exists()) {
          throw const FileSystemException(
              'Обновлятор не найден. Переустановите приложение через tool/install_appimage.sh.');
        }
        await transaction.update(UpdateTransactionStatus.stopping);
        await Process.start(
          helper.path,
          [
            package.absolute.path,
            '$pid',
            transaction.id,
            transaction.file.parent.path
          ],
          mode: ProcessStartMode.detached,
        );
        final deadline = DateTime.now().add(const Duration(seconds: 90));
        final ready = File('${transaction.file.parent.path}/ready');
        final failed = File('${transaction.file.parent.path}/failed');
        while (!await ready.exists()) {
          if (await failed.exists()) {
            final error = File('${transaction.file.parent.path}/error');
            throw FileSystemException(
                'Linux could not prepare the update: ${await error.exists() ? await error.readAsString() : 'helper failed'}');
          }
          if (DateTime.now().isAfter(deadline)) {
            await File('${transaction.file.parent.path}/cancelled')
                .writeAsString('handoff timeout');
            throw TimeoutException(
                'Linux update helper did not confirm staging.');
          }
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        // The detached helper waits for this process, swaps the extracted AppDir,
        // then starts the stable desktop launcher again.
        exit(0);
      }
      if (Platform.isWindows) {
        await transaction.update(UpdateTransactionStatus.staging,
            packagePath: package.absolute.path, sha256: packageHash);
        onProgress?.call(UpdateDownloadProgress(
          assetName: asset.name,
          path: package.path,
          downloadedBytes: await package.length(),
          totalBytes: await package.length(),
          bytesPerSecond: 0,
          stage: UpdateDownloadStage.launchingInstaller,
        ));
        final helper = await _windowsHelperPath(transaction.file.parent);
        await transaction.update(UpdateTransactionStatus.stopping);
        final installRoot = File(Platform.resolvedExecutable).parent.path;
        await Process.start(
            'powershell.exe',
            [
              '-NoProfile',
              '-NonInteractive',
              '-ExecutionPolicy',
              'Bypass',
              '-File',
              helper,
              '-Package',
              package.absolute.path,
              '-Mode',
              asset.name.endsWith('-Setup.exe') ? 'installer' : 'portable',
              '-OldPid',
              '$pid',
              '-TransactionId',
              transaction.id,
              '-HandoffDir',
              transaction.file.parent.path,
              '-InstallRoot',
              installRoot,
              '-ExpectedSha256',
              packageHash,
            ],
            mode: ProcessStartMode.detached);
        final deadline = DateTime.now().add(const Duration(seconds: 90));
        final ready = File(
            '${transaction.file.parent.path}${Platform.pathSeparator}ready');
        final failed = File(
            '${transaction.file.parent.path}${Platform.pathSeparator}failed');
        while (!await ready.exists()) {
          if (await failed.exists()) {
            final error = File(
                '${transaction.file.parent.path}${Platform.pathSeparator}error');
            throw FileSystemException(
                'Windows could not prepare the update: ${await error.exists() ? await error.readAsString() : 'helper failed'}');
          }
          if (DateTime.now().isAfter(deadline)) {
            await File(
                    '${transaction.file.parent.path}${Platform.pathSeparator}cancelled')
                .writeAsString('handoff timeout');
            throw TimeoutException(
                'Windows update helper did not confirm staging.');
          }
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
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
        final size = await package.length();
        onProgress?.call(UpdateDownloadProgress(
          assetName: asset.name,
          path: package.path,
          downloadedBytes: size,
          totalBytes: size,
          bytesPerSecond: 0,
          stage: UpdateDownloadStage.launchingInstaller,
        ));
        // The updater must survive replacing the bundle that contains it.
        final handoff = transaction.file.parent;
        await transaction.update(UpdateTransactionStatus.staging,
            packagePath: package.absolute.path, sha256: packageHash);
        try {
          final stagedHelper =
              await helper.copy('${handoff.path}/ghostbox-update-macos.sh');
          final log = File('${handoff.path}/installer.log');
          await Process.start(
            '/bin/bash',
            [
              stagedHelper.path,
              package.absolute.path,
              '$pid',
              appBundle,
              handoff.path,
              transaction.id,
            ],
            mode: ProcessStartMode.detached,
          );
          // Exit only once the helper has extracted and validated the package.
          // A failed handoff leaves this app running so its UI can show errors.
          final deadline = DateTime.now().add(const Duration(seconds: 60));
          final ready = File('${handoff.path}/ready');
          final error = File('${handoff.path}/error');
          while (!await ready.exists()) {
            if (await error.exists()) {
              throw FileSystemException(
                  'Не удалось подготовить обновление: ${await error.readAsString()}');
            }
            if (DateTime.now().isAfter(deadline)) {
              await File('${handoff.path}/cancelled').writeAsString('timeout');
              throw FileSystemException(
                  'Установщик не подтвердил готовность. Журнал: ${log.path}');
            }
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        } on Object {
          // Keep the helper's log and cancellation marker for diagnostics.
          await File('${handoff.path}/cancelled').writeAsString('cancelled');
          rethrow;
        }
        exit(0);
      }
      if (Platform.isAndroid) {
        final size = await package.length();
        onProgress?.call(UpdateDownloadProgress(
          assetName: asset.name,
          path: package.path,
          downloadedBytes: size,
          totalBytes: size,
          bytesPerSecond: 0,
          stage: installAndroidPackage
              ? UpdateDownloadStage.installing
              : UpdateDownloadStage.savingToDownloads,
        ));
        if (!installAndroidPackage) {
          final saved = await _androidUpdateChannel
              .invokeMethod<String>('saveApkToDownloads', {
            'path': package.absolute.path,
            'fileName': 'GhostBox-${release.version}.apk',
          });
          if (saved == null || !saved.startsWith('downloads_')) {
            throw const FileSystemException(
                'Android did not confirm saving the APK to Downloads.');
          }
          await transaction.update(UpdateTransactionStatus.commit);
          await transaction.update(UpdateTransactionStatus.cleanup);
          await _removeDownload(package);
          return saved.substring(saved.indexOf(':') + 1);
        }
        await transaction.update(UpdateTransactionStatus.installing,
            packagePath: package.absolute.path, sha256: packageHash);
        final result =
            await _androidUpdateChannel.invokeMethod<Object?>('installApk', {
          'path': package.absolute.path,
          'sha256': packageHash,
          'transactionId': transaction.id,
          'transactionPath': transaction.file.absolute.path,
          'targetVersion': release.version,
        });
        final status = result is Map ? result['status'] : result;
        if (status != 'session_created') {
          throw const FileSystemException(
              'Android не подтвердил создание сессии PackageInstaller.');
        }
        return null;
      }
      throw UnsupportedError(
          'Автоустановка не поддерживается на этой платформе');
    } on Object catch (error) {
      try {
        await transaction.update(UpdateTransactionStatus.failed,
            error: error.toString());
      } on Object {/* Preserve the update error. */}
      if (!Platform.isMacOS || !packageVerified) {
        await _removeDownload(package);
      }
      rethrow;
    }
  }

  Future<String> _sha256(File file) async {
    if (Platform.isAndroid) {
      final value = await _androidUpdateChannel
          .invokeMethod<String>('sha256File', {'path': file.absolute.path});
      if (value == null || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value)) {
        throw const FormatException('Android не подтвердил SHA-256 пакета.');
      }
      return value.toLowerCase();
    }
    if (Platform.isWindows) {
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "(Get-FileHash -Algorithm SHA256 -LiteralPath '${file.path.replaceAll("'", "''")}').Hash.ToLowerInvariant()",
      ]);
      if (result.exitCode != 0) {
        throw const ProcessException('powershell.exe', []);
      }
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
      final executable =
          File(Platform.resolvedExecutable).absolute.path.toLowerCase();
      final installerInstall = executable.contains('\\programs\\ghostbox\\');
      return installerInstall
          ? 'GhostBox-${release.version}-Windows-x64-Setup.exe'
          : 'GhostBox-${release.version}-Windows-x64.zip';
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
      // sysctl detects Apple Silicon even when this app runs under Rosetta.
      final silicon =
          await Process.run('/usr/sbin/sysctl', ['-n', 'hw.optional.arm64']);
      final machine = await Process.run('/usr/bin/uname', ['-m']);
      final arch = '${machine.stdout}'.trim().toLowerCase();
      final suffix = '${silicon.stdout}'.trim() == '1' || arch == 'arm64'
          ? 'arm64'
          : arch == 'x86_64'
              ? 'x86_64'
              : null;
      return suffix == null
          ? null
          : 'GhostBox-${release.version}-macOS-$suffix.zip';
    }
    if (Platform.isAndroid) {
      const expectedName = 'GhostBox-Android-universal.apk';
      if (release.asset(expectedName) != null) return expectedName;
      final apkAssets = release.assets
          .where((asset) =>
              asset.name.toLowerCase().contains('android') &&
              asset.name.toLowerCase().endsWith('.apk'))
          .toList();
      final abis = await _androidUpdateChannel
              .invokeMethod<List<Object?>>('getSupportedAbis') ??
          const <Object?>[];
      for (final abiValue in abis) {
        final abi = '$abiValue'.toLowerCase();
        final tokens = switch (abi) {
          'arm64-v8a' => const ['arm64-v8a', 'arm64', 'aarch64'],
          'armeabi-v7a' => const ['armeabi-v7a', 'armv7'],
          'x86_64' => const ['x86_64', 'amd64'],
          'x86' => const ['x86'],
          _ => const <String>[],
        };
        for (final token in tokens) {
          for (final candidate in apkAssets) {
            if (candidate.name.toLowerCase().contains(token)) {
              return candidate.name;
            }
          }
        }
      }
      return null;
    }
    return null;
  }

  Future<File> _downloadWithRetry(
    GhostBoxReleaseAsset asset, {
    void Function(UpdateDownloadProgress progress)? onProgress,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await download(asset, onProgress: onProgress);
      } on Object catch (error) {
        lastError = error;
        if (attempt < 2) {
          await Future<void>.delayed(
              Duration(milliseconds: 400 * (attempt + 1)));
        }
      }
    }
    Error.throwWithStackTrace(lastError!, StackTrace.current);
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

  Future<String> _windowsHelperPath(Directory handoff) async {
    final executableDirectory = File(Platform.resolvedExecutable).parent;
    final candidates = <File>[
      File(
          '${executableDirectory.path}${Platform.pathSeparator}ghostbox-update-windows.ps1'),
      File(
          '${executableDirectory.path}${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}assets${Platform.pathSeparator}ghostbox-update-windows.ps1'),
    ];
    for (final candidate in candidates) {
      if (await candidate.exists()) {
        final staged = File(
            '${handoff.path}${Platform.pathSeparator}ghostbox-update-windows.ps1');
        await candidate.copy(staged.path);
        return staged.path;
      }
    }
    throw const FileSystemException(
        'Windows update helper was not found beside the installed app.');
  }

  GhostBoxRelease? _parseRelease(Map row) {
    final tag = row['tag_name'];
    final page = row['html_url'];
    if (tag is! String || page is! String) return null;
    final version = normalizeReleaseTag(tag);
    if (!_isSemVer(version)) return null;
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
      version: version,
      tagName: tag,
      pageUrl: page,
      assets: assets,
      notes: row['body'] is String ? row['body'] as String : '',
    );
  }

  String normalizeReleaseTag(String tag) {
    final value = tag.replaceFirst(RegExp(r'^[vV]'), '');
    final shortTag = RegExp(r'^(\d+)\.(\d+)(-.+)$').firstMatch(value);
    if (shortTag == null) return value;
    return '${shortTag.group(1)}.${shortTag.group(2)}.0${shortTag.group(3)}';
  }

  int compareVersions(String left, String right) {
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
    final match = RegExp(
      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
      r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
      r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
    ).firstMatch(value);
    if (match == null) return ([0, 0, 0], const []);
    final pre = match.group(4);
    if (pre != null &&
        pre.split('.').any((part) =>
            RegExp(r'^\d+$').hasMatch(part) &&
            part.length > 1 &&
            part.startsWith('0'))) {
      return ([0, 0, 0], const []);
    }
    return (
      [
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!)
      ],
      pre == null ? const [] : pre.split('.')
    );
  }

  bool _isSemVer(String value) {
    if (!RegExp(
      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
      r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
      r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
    ).hasMatch(value)) return false;
    final pre = value.split('+').first.split('-');
    if (pre.length < 2) return true;
    return !pre[1].split('.').any((part) =>
        RegExp(r'^\d+$').hasMatch(part) &&
        part.length > 1 &&
        part.startsWith('0'));
  }
}
