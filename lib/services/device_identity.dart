import 'dart:math';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Stable, random per-install identifier for subscription panels that count
/// devices. This deliberately does not fingerprint physical hardware.
class DeviceIdentity {
  DeviceIdentity._();

  static const _preferenceKey = 'device.installation_id';
  static Future<String>? _pending;

  static String get architecture => Abi.current().toString().split('.').last;

  static String get subscriptionUserAgent => 'GhostBox-Alpha-v1.0';

  static Future<String> get deviceModel async {
    if (Platform.isLinux) {
      for (final path in const [
        '/sys/class/dmi/id/product_name',
        '/sys/devices/virtual/dmi/id/product_name',
        '/proc/device-tree/model',
      ]) {
        try {
          final model = (await File(path).readAsString())
              .replaceAll(RegExp(r'[\x00\r\n\t]+'), ' ')
              .trim();
          if (model.isNotEmpty &&
              !const {
                'default string',
                'system product name',
                'to be filled by o.e.m.',
                'unknown',
              }.contains(model.toLowerCase())) {
            return model;
          }
        } on Object {
          // Some Linux systems hide DMI data; use the safe fallback below.
        }
      }
      return 'Linux PC';
    }
    if (Platform.isMacOS) return 'Mac';
    if (Platform.isWindows) return 'Windows PC';
    if (Platform.isAndroid) return 'Android device';
    if (Platform.isIOS) return 'iPhone or iPad';
    return Platform.operatingSystem;
  }

  /// Minimal, non-hardware-fingerprinting client details for the VPN provider.
  static Future<Map<String, String>> get transportHeaders async {
    final id = await installationId;
    final model = await deviceModel;
    return {
      'X-HWID': id,
      'X-Device-ID': id,
      'X-Client-Name': 'GhostBox',
      'X-Client-Version': '0.1',
      'X-Device-OS': Platform.operatingSystem,
      'X-Device-OS-Version': Platform.operatingSystemVersion,
      'X-Ver-OS': Platform.operatingSystemVersion,
      'X-Device-Model': model,
      'X-Device-Architecture': architecture,
      'X-GhostBox-Client': 'GhostBox-Alpha-v1.0',
      'X-GhostBox-OS': Platform.operatingSystem,
      'X-GhostBox-OS-Version': Platform.operatingSystemVersion,
      'X-GhostBox-Model': model,
      'X-GhostBox-Architecture': architecture,
    };
  }

  static Future<String> get installationId => _pending ??= _loadOrCreate();

  static Future<String> _loadOrCreate() async {
    final preferences = await SharedPreferences.getInstance();
    final existing = preferences.getString(_preferenceKey);
    if (existing != null && existing.isNotEmpty) return existing;

    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final compact =
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    final id = '${compact.substring(0, 8)}-${compact.substring(8, 12)}-'
        '${compact.substring(12, 16)}-${compact.substring(16, 20)}-'
        '${compact.substring(20)}';
    await preferences.setString(_preferenceKey, id);
    return id;
  }
}
