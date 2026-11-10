import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'services/app_version.dart';
import 'services/update_startup.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows && await _startWindowsRecoveryIfNeeded()) {
    exit(0);
  }
  final updateId = _argumentValue(args, '--ghostbox-updated=');
  final handoffDirectory = _argumentValue(args, '--ghostbox-update-handoff=');
  final pendingHealthCheck =
      (updateId != null && handoffDirectory != null) || Platform.isAndroid
          ? Completer<void>()
          : null;
  UpdateStartup.healthCheck = pendingHealthCheck?.future;
  runApp(const GhostBoxApp());
  if (updateId != null && handoffDirectory != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_confirmUpdatedStartup(updateId, handoffDirectory)
          .whenComplete(() => pendingHealthCheck?.complete()));
    });
  }
  if (Platform.isAndroid) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_confirmAndroidUpdateStartup()
          .whenComplete(() => pendingHealthCheck?.complete()));
    });
  }
}

Future<void> _confirmAndroidUpdateStartup() async {
  try {
    await SharedPreferences.getInstance();
    final confirmed =
        await const MethodChannel('app.ghostbox.ghostbox/app_update')
            .invokeMethod<bool>('confirmAndroidUpdateHealth', {
      'version': AppVersion.version,
    });
    if (confirmed == true) {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('updateCompletedVersion', AppVersion.version);
    }
  } on Object {
    // Android owns APK rollback; keep a failed health check in its transaction.
  }
}

Future<bool> _startWindowsRecoveryIfNeeded() async {
  final local = Platform.environment['LOCALAPPDATA'];
  if (local == null || local.isEmpty) return false;
  final executableDirectory = File(Platform.resolvedExecutable).parent;
  final bundledHelper = File(
      '${executableDirectory.path}${Platform.pathSeparator}ghostbox-update-windows.ps1');
  final stateRoot = Directory(
      '$local${Platform.pathSeparator}GhostBox${Platform.pathSeparator}Updater');
  if (!await stateRoot.exists()) return false;
  await for (final entity in stateRoot.list(followLinks: false)) {
    if (entity is! Directory ||
        await FileSystemEntity.type(entity.path, followLinks: false) ==
            FileSystemEntityType.link) continue;
    final recordFile =
        File('${entity.path}${Platform.pathSeparator}update_transaction.json');
    if (!await recordFile.exists()) continue;
    try {
      final record = jsonDecode(await recordFile.readAsString());
      if (record is! Map) continue;
      final status = '${record['status'] ?? ''}'.toUpperCase();
      if (const {'COMMIT', 'CLEANUP', 'RESTORE_OLD'}.contains(status)) continue;
      final transactionId = record['id'];
      if (transactionId is! String ||
          transactionId != entity.path.split(RegExp(r'[/\\]')).last) continue;
      final backupPath = record['backupPath'];
      final installRoot = File(Platform.resolvedExecutable).parent.path;
      final expectedBackup = '$installRoot.ghostbox-backup-$transactionId';
      final stagingPath = record['stagingPath'];
      final expectedStaging = '$installRoot.ghostbox-staging-$transactionId';
      final backupExists = backupPath is String &&
          backupPath.toLowerCase() == expectedBackup.toLowerCase() &&
          await Directory(backupPath).exists();
      final preInstall = const {
        'CHECKING',
        'VERIFYING',
        'STAGING',
        'STOPPING',
      }.contains(status);
      final stagingRecordIsSafe = stagingPath == null ||
          (stagingPath is String &&
              stagingPath.toLowerCase() == expectedStaging.toLowerCase());
      if (!backupExists && !(preInstall && stagingRecordIsSafe)) continue;
      final stagedHelper = File(
          '${entity.path}${Platform.pathSeparator}ghostbox-update-windows.ps1');
      final helper = await stagedHelper.exists() ? stagedHelper : bundledHelper;
      if (!await helper.exists()) continue;
      await Process.start(
          'powershell.exe',
          [
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            helper.path,
            '-Recover',
            '-InstallRoot',
            installRoot,
            '-OldPid',
            '$pid',
            '-HandoffDir',
            entity.path,
          ],
          mode: ProcessStartMode.detached);
      return true;
    } on Object {
      // A malformed record is retained for diagnosis and cannot authorize a swap.
    }
  }
  return false;
}

String? _argumentValue(List<String> args, String prefix) {
  for (final argument in args) {
    if (argument.startsWith(prefix)) return argument.substring(prefix.length);
  }
  return null;
}

Future<void> _confirmUpdatedStartup(String id, String handoffPath) async {
  final handoff = Directory(handoffPath);
  var safeHandoff = false;
  var safeDirectory = handoff.path;
  try {
    if (!RegExp(r'^[0-9a-zA-Z-]{8,80}$').hasMatch(id) ||
        !await handoff.exists() ||
        await FileSystemEntity.type(handoff.path, followLinks: false) ==
            FileSystemEntityType.link) {
      throw const FormatException('Invalid updater handoff directory.');
    }
    final expectedParent = await _expectedHandoffParent();
    final canonicalParent =
        await Directory(expectedParent).resolveSymbolicLinks();
    final canonicalHandoff = await handoff.resolveSymbolicLinks();
    final expectedPath = '$canonicalParent${Platform.pathSeparator}$id';
    final pathMatches = Platform.isWindows
        ? canonicalHandoff.toLowerCase() == expectedPath.toLowerCase()
        : canonicalHandoff == expectedPath;
    if (!pathMatches) {
      throw const FormatException(
          'Updater handoff path is outside update storage.');
    }
    safeHandoff = true;
    safeDirectory = canonicalHandoff;
    final transactionFile = File(
        '$canonicalHandoff${Platform.pathSeparator}update_transaction.json');
    if (await FileSystemEntity.type(transactionFile.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('Updater transaction file cannot be a link.');
    }
    final transaction = jsonDecode(await transactionFile.readAsString());
    if (transaction is! Map ||
        transaction['id'] != id ||
        transaction['targetVersion'] != AppVersion.version) {
      throw const FormatException(
          'The installed version does not match the update transaction.');
    }
    // Reaching this callback means Flutter rendered a frame. Read persisted
    // settings as a second health signal before allowing the helper to commit.
    await SharedPreferences.getInstance();
    transaction['status'] = 'HEALTH_CHECK';
    transaction['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    await _writeJsonAtomically(transactionFile, transaction);
    await File('$safeDirectory/started').writeAsString('$pid\n', flush: true);
    transaction['status'] = 'COMMIT';
    transaction['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    await _writeJsonAtomically(transactionFile, transaction);
    await File('$safeDirectory/confirmed').writeAsString('$id\n', flush: true);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('updateCompletedVersion', AppVersion.version);
  } on Object catch (error) {
    if (safeHandoff) {
      try {
        await File('$safeDirectory/failed')
            .writeAsString('$error\n', flush: true);
      } on Object {/* The helper also has a startup timeout. */}
    }
  }
}

Future<String> _expectedHandoffParent() async {
  if (Platform.isWindows) {
    final local = Platform.environment['LOCALAPPDATA'];
    if (local == null || local.isEmpty) {
      throw const FileSystemException(
          'Could not locate Windows update storage.');
    }
    return '$local${Platform.pathSeparator}GhostBox${Platform.pathSeparator}Updater';
  }
  if (Platform.isMacOS) {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw const FileSystemException('Could not locate macOS update storage.');
    }
    return '$home/Library/Application Support/GhostBox/Updates';
  }
  if (Platform.isLinux) {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw const FileSystemException('Could not locate Linux update storage.');
    }
    final state = Platform.environment['XDG_STATE_HOME'];
    return state == null || state.isEmpty
        ? '$home/.local/state/ghostbox/updates'
        : '$state/ghostbox/updates';
  }
  throw UnsupportedError('No desktop updater handoff is configured.');
}

Future<void> _writeJsonAtomically(File file, Map<dynamic, dynamic> data) async {
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(jsonEncode(data), flush: true);
  try {
    await temporary.rename(file.path);
  } on FileSystemException {
    if (!await file.exists()) rethrow;
    final previous = File('${file.path}.previous');
    if (await previous.exists()) await previous.delete();
    await file.rename(previous.path);
    try {
      await temporary.rename(file.path);
      await previous.delete();
    } on Object {
      if (!await file.exists() && await previous.exists()) {
        await previous.rename(file.path);
      }
      rethrow;
    }
  }
}
