import 'dart:convert';

class ServerProfile {
  const ServerProfile({
    required this.id,
    required this.name,
    required this.protocol,
    required this.address,
    required this.port,
    this.uuid,
    this.network = 'tcp',
    this.security,
    this.raw = const <String, dynamic>{},
  });

  final String id;
  final String name;
  final String protocol;
  final String address;
  final int port;
  final String? uuid;
  final String network;
  final String? security;
  final Map<String, dynamic> raw;

  /// Optional server icon supplied by the `srv-logo` profile tag.
  ///
  /// Only remote HTTP(S) URLs are surfaced to UI code. The original tag stays
  /// in [raw] and therefore survives profile serialization and re-import.
  String? get srvLogoUrl {
    final value = raw['srv-logo'] ?? raw['srv_logo'] ?? raw['srvLogo'];
    if (value is! String || value.trim().isEmpty) return null;
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      return null;
    }
    return uri.toString();
  }

  factory ServerProfile.fromJson(Map<String, dynamic> json) => ServerProfile(
        id: json['id'] as String,
        name: _decodeStoredName(json['name'] as String),
        protocol: json['protocol'] as String,
        address: json['address'] as String,
        port: (json['port'] as num).toInt(),
        uuid: json['uuid'] as String?,
        network: json['network'] as String? ?? 'tcp',
        security: json['security'] as String?,
        raw: Map<String, dynamic>.from(json['raw'] as Map? ?? const {}),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'protocol': protocol,
        'address': address,
        'port': port,
        'uuid': uuid,
        'network': network,
        'security': security,
        'raw': raw,
      };
}

String _decodeStoredName(String value) {
  var result = value;
  for (var i = 0; i < 3; i++) {
    final decoded = result
        .replaceAll('+', ' ')
        .replaceAllMapped(RegExp(r'(?:%[0-9A-Fa-f]{2})+'), (match) {
      final bytes = RegExp(r'%([0-9A-Fa-f]{2})')
          .allMatches(match.group(0)!)
          .map((part) => int.parse(part.group(1)!, radix: 16))
          .toList();
      return utf8.decode(bytes, allowMalformed: true);
    });
    if (decoded == result) break;
    result = decoded;
  }
  final runes = result.runes.toList();
  if (runes.length >= 2 &&
      runes.take(2).every((r) => r >= 0x1F1E6 && r <= 0x1F1FF)) {
    return String.fromCharCodes(runes.skip(2)).trimLeft();
  }
  return result;
}
