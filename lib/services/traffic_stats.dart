import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TrafficCounters {
  const TrafficCounters({required this.received, required this.sent});

  final int received;
  final int sent;
}

class DailyTraffic {
  const DailyTraffic({this.received = 0, this.sent = 0});

  final int received;
  final int sent;

  DailyTraffic add({int received = 0, int sent = 0}) => DailyTraffic(
        received: this.received + received,
        sent: this.sent + sent,
      );

  Map<String, int> toJson() => {'rx': received, 'tx': sent};

  static DailyTraffic fromJson(Object? value) {
    if (value is! Map) return const DailyTraffic();
    return DailyTraffic(
      received: (value['rx'] as num?)?.toInt() ?? 0,
      sent: (value['tx'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Reads the OS counters for GhostBox's tunnel interface and keeps daily totals.
/// Unsupported modes/platforms return null rather than reporting misleading data.
class TrafficStats {
  static const _storageKey = 'dailyTrafficBytesV1';
  static const _androidChannel = MethodChannel('app.ghostbox.ghostbox/vpn');
  Map<String, DailyTraffic> _days = <String, DailyTraffic>{};
  TrafficCounters? _previous;
  DateTime? _previousAt;
  double receivedPerSecond = 0;
  double sentPerSecond = 0;
  double peakReceivedPerSecond = 0;
  double peakSentPerSecond = 0;
  bool available = false;
  bool _loaded = false;

  Map<String, DailyTraffic> get days => Map.unmodifiable(_days);

  Future<void> load(SharedPreferences preferences) async {
    if (_loaded) return;
    _loaded = true;
    final raw = preferences.getString(_storageKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _days = <String, DailyTraffic>{
          for (final entry in decoded.entries)
            if (entry.value is Map)
              entry.key.toString(): DailyTraffic.fromJson(entry.value),
        };
      }
    } on Object {
      _days = <String, DailyTraffic>{};
    }
  }

  Future<void> sample(SharedPreferences preferences) async {
    final current = await readCounters();
    final now = DateTime.now();
    available = current != null;
    if (current == null) {
      receivedPerSecond = 0;
      sentPerSecond = 0;
      _previous = null;
      _previousAt = null;
      return;
    }
    final previous = _previous;
    final previousAt = _previousAt;
    _previous = current;
    _previousAt = now;
    if (previous == null || previousAt == null) return;

    final elapsed = now.difference(previousAt).inMicroseconds / 1000000;
    if (elapsed <= 0 ||
        current.received < previous.received ||
        current.sent < previous.sent) {
      receivedPerSecond = 0;
      sentPerSecond = 0;
      return;
    }
    final received = current.received - previous.received;
    final sent = current.sent - previous.sent;
    receivedPerSecond = received / elapsed;
    sentPerSecond = sent / elapsed;
    if (receivedPerSecond > peakReceivedPerSecond) {
      peakReceivedPerSecond = receivedPerSecond;
    }
    if (sentPerSecond > peakSentPerSecond) {
      peakSentPerSecond = sentPerSecond;
    }
    if (received == 0 && sent == 0) return;

    final key = _dayKey(now);
    _days[key] = (_days[key] ?? const DailyTraffic()).add(
      received: received,
      sent: sent,
    );
    final cutoff = now.subtract(const Duration(days: 90));
    _days.removeWhere((day, _) {
      final parsed = DateTime.tryParse(day);
      return parsed == null ||
          parsed.isBefore(DateTime(cutoff.year, cutoff.month, cutoff.day));
    });
    await preferences.setString(
      _storageKey,
      jsonEncode(
          {for (final entry in _days.entries) entry.key: entry.value.toJson()}),
    );
  }

  Future<TrafficCounters?> readCounters() async {
    try {
      if (Platform.isLinux) {
        final interface = await _linuxTunnelInterface();
        if (interface == null) return null;
        final base = '/sys/class/net/$interface/statistics';
        final received =
            int.tryParse(await File('$base/rx_bytes').readAsString());
        final sent = int.tryParse(await File('$base/tx_bytes').readAsString());
        if (received == null || sent == null) return null;
        return TrafficCounters(received: received, sent: sent);
      }
      if (Platform.isMacOS) return await _macTunnelCounters();
      if (Platform.isWindows) return await _windowsTunnelCounters();
      if (Platform.isAndroid) return await _androidTunnelCounters();
    } on Object {
      return null;
    }
    return null;
  }

  Future<String?> _linuxTunnelInterface() async {
    for (final name in const ['ghostbox0', 'tun0']) {
      if (await Directory('/sys/class/net/$name').exists()) return name;
    }
    return null;
  }

  Future<TrafficCounters?> _macTunnelCounters() async {
    final result = await Process.run('netstat', ['-ibn']);
    if (result.exitCode != 0) return null;
    var received = 0;
    var sent = 0;
    var found = false;
    for (final line in '${result.stdout}'.split('\n')) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length < 10 || !RegExp(r'^utun\d+$').hasMatch(fields[0]))
        continue;
      final rx = int.tryParse(fields[6]);
      final tx = int.tryParse(fields[9]);
      if (rx == null || tx == null) continue;
      found = true;
      received += rx;
      sent += tx;
    }
    return found ? TrafficCounters(received: received, sent: sent) : null;
  }

  Future<TrafficCounters?> _androidTunnelCounters() async {
    try {
      final lines = await File('/proc/net/dev').readAsLines();
      for (final line in lines.skip(2)) {
        final separator = line.indexOf(':');
        if (separator < 0) continue;
        final name = line.substring(0, separator).trim();
        if (!RegExp(r'^tun\d+$').hasMatch(name)) continue;
        final counters =
            line.substring(separator + 1).trim().split(RegExp(r'\s+'));
        if (counters.length < 9) continue;
        final received = int.tryParse(counters[0]);
        final sent = int.tryParse(counters[8]);
        if (received != null && sent != null) {
          return TrafficCounters(received: received, sent: sent);
        }
      }
    } on Object {
      // Some Android versions hide the VPN interface from the app's proc view.
    }
    // Android accounts the VPN service's underlying sockets to the app UID.
    // This keeps the live rate visible when /proc/net/dev omits tun*.
    final counters = await _androidChannel.invokeMapMethod<String, Object?>(
      'androidTrafficCounters',
    );
    final received = (counters?['received'] as num?)?.toInt();
    final sent = (counters?['sent'] as num?)?.toInt();
    if (received == null || sent == null || received < 0 || sent < 0) {
      return null;
    }
    return TrafficCounters(received: received, sent: sent);
  }

  Future<TrafficCounters?> _windowsTunnelCounters() async {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "Get-NetAdapterStatistics -Name 'ghostbox0' -ErrorAction SilentlyContinue | Select-Object ReceivedBytes,SentBytes | ConvertTo-Json -Compress",
    ]).timeout(const Duration(seconds: 3));
    if (result.exitCode != 0 || '${result.stdout}'.trim().isEmpty) return null;
    final decoded = jsonDecode('${result.stdout}');
    if (decoded is! Map) return null;
    final received = int.tryParse('${decoded['ReceivedBytes']}');
    final sent = int.tryParse('${decoded['SentBytes']}');
    if (received == null || sent == null) return null;
    return TrafficCounters(received: received, sent: sent);
  }

  static String _dayKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
}

String formatTrafficBytes(num bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100
      ? 0
      : value >= 10
          ? 1
          : 2;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

String formatTrafficRate(num bytesPerSecond) {
  if (bytesPerSecond < 1024) return '${bytesPerSecond.round()} B/s';
  if (bytesPerSecond < 1024 * 1024) {
    return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
  }
  return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
}
