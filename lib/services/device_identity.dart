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

  static String get subscriptionUserAgent =>
      'GhostBox-Alpha-v0.1 (${Platform.operatingSystem}; $architecture; ${Platform.operatingSystemVersion})';

  /// Minimal, non-hardware-fingerprinting client details for the VPN provider.
  static Future<Map<String, String>> get transportHeaders async {
    final id = await installationId;
    return {
      'X-HWID': id,
      'X-Device-ID': id,
      'X-GhostBox-Client': 'GhostBox-Alpha-v0.1',
      'X-GhostBox-OS': Platform.operatingSystem,
      'X-GhostBox-OS-Version': Platform.operatingSystemVersion,
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
