import 'dart:io';
import 'package:flutter/services.dart';

/// Native supervision applies only to the explicitly registered core processes.
/// Windows closes their Job Object after a UI crash, removing abandoned TUNs.
class WindowsCoreLifecycle {
  static const _channel = MethodChannel('app.ghostbox.ghostbox/core_lifecycle');

  static Future<void> trackCore({
    required int pid,
    required String executable,
  }) async {
    if (!Platform.isWindows) return;
    final tracked = await _channel.invokeMethod<bool>('trackCore', {
      'pid': pid,
      'executable': File(executable).absolute.path,
    });
    if (tracked != true) {
      throw StateError('Windows did not confirm VPN core supervision.');
    }
  }

  /// Call after disconnecting this app's own backends, before starting new ones.
  /// Cores owned by another live GhostBox instance are preserved.
  static Future<int> cleanupStaleCores({
    required List<String> executables,
  }) async {
    if (!Platform.isWindows) return 0;
    return await _channel.invokeMethod<int>('cleanupStaleCores', {
          'executables':
              executables.map((path) => File(path).absolute.path).toList(),
        }) ??
        0;
  }
}
