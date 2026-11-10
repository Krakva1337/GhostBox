import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import 'app_version.dart';

enum UpdateTransactionStatus {
  checking,
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
  restoreOld,
}

class UpdateTransaction {
  UpdateTransaction._(this.id, this.file, this.data);

  static const _androidChannel =
      MethodChannel('app.ghostbox.ghostbox/app_update');

  final String id;
  final File file;
  final Map<String, Object?> data;

  static Future<UpdateTransaction> create({
    required String targetVersion,
    required String assetName,
  }) async {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    final id = '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    final root = await _directory();
    await root.create(recursive: true);
    if (!Platform.isWindows && !Platform.isAndroid) {
      if (await FileSystemEntity.type(root.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FileSystemException('Update storage cannot be a link.');
      }
      final permissions = await Process.run('chmod', ['700', root.path]);
      if (permissions.exitCode != 0) {
        throw const FileSystemException(
            'Could not secure the update transaction directory.');
      }
    }
    final directory = Directory('${root.path}${Platform.pathSeparator}$id');
    await directory.create();
    if (!Platform.isWindows && !Platform.isAndroid) {
      final permissions = await Process.run('chmod', ['700', directory.path]);
      if (permissions.exitCode != 0) {
        throw const FileSystemException(
            'Could not secure the update transaction directory.');
      }
    }
    final transaction = UpdateTransaction._(
      id,
      File('${directory.path}${Platform.pathSeparator}update_transaction.json'),
      <String, Object?>{
        'id': id,
        'status': UpdateTransactionStatus.checking.name.toUpperCase(),
        'currentVersion': AppVersion.version,
        'targetVersion': targetVersion,
        'assetName': assetName,
        'packagePath': null,
        'sha256': null,
        'backupPath': null,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      },
    );
    await transaction.save();
    return transaction;
  }

  static Future<Directory> _directory() async {
    if (Platform.isAndroid) {
      final path = await _androidChannel
          .invokeMethod<String>('getUpdatePersistentDirectory');
      if (path == null || path.isEmpty) {
        throw const FileSystemException(
            'Android did not provide persistent update storage.');
      }
      return Directory(path);
    }
    if (Platform.isWindows) {
      final root = Platform.environment['LOCALAPPDATA'];
      if (root == null || root.isEmpty) {
        throw const FileSystemException(
            'Could not locate the Windows update data directory.');
      }
      return Directory(
          '$root${Platform.pathSeparator}GhostBox${Platform.pathSeparator}Updater');
    }
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) {
        throw const FileSystemException('Could not locate the home directory.');
      }
      return Directory('$home/Library/Application Support/GhostBox/Updates');
    }
    if (Platform.isLinux) {
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) {
        throw const FileSystemException('Could not locate the home directory.');
      }
      final stateHome = Platform.environment['XDG_STATE_HOME'];
      return Directory(stateHome == null || stateHome.isEmpty
          ? '$home/.local/state/ghostbox/updates'
          : '$stateHome/ghostbox/updates');
    }
    return Directory.systemTemp.createTemp('ghostbox-update-state-');
  }

  static Future<Map<String, String>?> latestFailure() async {
    final root = await _directory();
    if (!await root.exists()) return null;
    final records = <({DateTime modified, Map data})>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory ||
          await FileSystemEntity.type(entity.path, followLinks: false) ==
              FileSystemEntityType.link) continue;
      final file = File(
          '${entity.path}${Platform.pathSeparator}update_transaction.json');
      if (!await file.exists() ||
          await FileSystemEntity.type(file.path, followLinks: false) ==
              FileSystemEntityType.link) continue;
      try {
        final data = jsonDecode(await file.readAsString());
        if (data is Map)
          records.add((modified: await file.lastModified(), data: data));
      } on Object {
        /* Ignore corrupt records; helpers retain them for recovery. */
      }
    }
    records.sort((a, b) => b.modified.compareTo(a.modified));
    for (final record in records) {
      final status = '${record.data['status'] ?? ''}'.toUpperCase();
      if (status != 'FAILED' && status != 'RESTORE_OLD') continue;
      final id = '${record.data['id'] ?? record.data['transactionId'] ?? ''}';
      if (id.isEmpty) continue;
      return {
        'id': id,
        'targetVersion':
            '${record.data['targetVersion'] ?? record.data['newVersion'] ?? ''}',
        'error': '${record.data['error'] ?? record.data['detail'] ?? ''}',
      };
    }
    return null;
  }

  Future<void> update(
    UpdateTransactionStatus status, {
    String? packagePath,
    String? sha256,
    String? backupPath,
    String? error,
  }) async {
    data
      ..['status'] = status.name
          .replaceAllMapped(RegExp(r'[A-Z]'), (match) => '_${match[0]}')
          .toUpperCase()
      ..['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    if (packagePath != null) data['packagePath'] = packagePath;
    if (sha256 != null) data['sha256'] = sha256;
    if (backupPath != null) data['backupPath'] = backupPath;
    if (error != null) data['error'] = error;
    await save();
  }

  Future<void> save() async {
    final path = file.absolute.path;
    final parent = file.parent.absolute.path;
    if (!path.startsWith('$parent${Platform.pathSeparator}') ||
        await FileSystemEntity.type(parent, followLinks: false) ==
            FileSystemEntityType.link) {
      throw const FileSystemException('Unsafe update transaction path.');
    }
    final temporary = File('$path.tmp');
    await temporary.writeAsString(jsonEncode(data), flush: true);
    await _replaceFile(temporary, file);
  }
}

Future<void> _replaceFile(File temporary, File destination) async {
  try {
    await temporary.rename(destination.path);
  } on FileSystemException {
    if (!await destination.exists()) rethrow;
    final previous = File('${destination.path}.previous');
    if (await previous.exists()) await previous.delete();
    await destination.rename(previous.path);
    try {
      await temporary.rename(destination.path);
      await previous.delete();
    } on Object {
      if (!await destination.exists() && await previous.exists()) {
        await previous.rename(destination.path);
      }
      rethrow;
    }
  }
}
