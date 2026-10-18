import 'server_profile.dart';

/// Information supplied alongside a subscription, usually in HTTP headers.
/// Traffic values are bytes; [expire] is a Unix timestamp in seconds.
class SubscriptionMetadata {
  const SubscriptionMetadata({
    this.title,
    this.description,
    this.announcement,
    this.supportUrl,
    this.websiteUrl,
    this.upload,
    this.download,
    this.total,
    this.expire,
    this.deviceLimit,
    this.updateIntervalHours,
    this.headers = const {},
  });

  final String? title;
  final String? description;
  final String? announcement;
  final String? supportUrl;
  final String? websiteUrl;
  final int? upload;
  final int? download;
  final int? total;
  final int? expire;
  final int? deviceLimit;
  final int? updateIntervalHours;

  /// Lower-case response header names and their original values. Excludes
  /// authentication and cookie headers so they cannot enter preferences.
  final Map<String, String> headers;

  int? get usedBytes => upload == null && download == null
      ? null
      : (upload ?? 0) + (download ?? 0);

  DateTime? get expiresAt => expire == null || expire == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(expire! * 1000);

  factory SubscriptionMetadata.fromJson(Map<String, dynamic> json) =>
      SubscriptionMetadata(
        title: json['title'] as String?,
        description: json['description'] as String?,
        announcement: json['announcement'] as String?,
        supportUrl: json['supportUrl'] as String?,
        websiteUrl: json['websiteUrl'] as String?,
        upload: (json['upload'] as num?)?.toInt(),
        download: (json['download'] as num?)?.toInt(),
        total: (json['total'] as num?)?.toInt(),
        expire: (json['expire'] as num?)?.toInt(),
        deviceLimit: (json['deviceLimit'] as num?)?.toInt(),
        updateIntervalHours: (json['updateIntervalHours'] as num?)?.toInt(),
        headers: Map<String, String>.from(json['headers'] as Map? ?? const {}),
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'description': description,
        'announcement': announcement,
        'supportUrl': supportUrl,
        'websiteUrl': websiteUrl,
        'upload': upload,
        'download': download,
        'total': total,
        'expire': expire,
        'deviceLimit': deviceLimit,
        'updateIntervalHours': updateIntervalHours,
        'headers': headers,
      };
}

class SubscriptionParseResult {
  const SubscriptionParseResult(this.profiles, this.metadata);

  final List<ServerProfile> profiles;
  final SubscriptionMetadata metadata;
}
