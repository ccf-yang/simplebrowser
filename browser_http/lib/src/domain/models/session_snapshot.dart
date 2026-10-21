import 'browser_cookie.dart';

/// The complete identity of a browsing session.
///
/// Cookies alone are not enough: anti-bot clearances are bound to the user
/// agent, client hints, TLS family and (usually) the egress IP. This snapshot
/// is the unit that gets persisted, restored and verified.
final class SessionSnapshot {
  const SessionSnapshot({
    required this.profileId,
    required this.userAgent,
    required this.cookies,
    required this.origin,
    required this.createdAt,
    required this.expiresAt,
    this.clientHints = const <String, String>{},
    this.localStorage = const <String, Map<String, String>>{},
    this.egressIpHash,
  });

  /// Origin the cookies and storage were captured from.
  final Uri origin;

  /// Profile family, e.g. `safari_ios_18`.
  final String profileId;

  final String userAgent;

  /// `sec-ch-ua`, `sec-ch-ua-platform`, ... Empty for Safari.
  final Map<String, String> clientHints;

  final List<BrowserCookie> cookies;

  /// origin -> key -> value.
  final Map<String, Map<String, String>> localStorage;

  /// SHA-256 of the egress IP; `null` when unknown.
  final String? egressIpHash;

  final DateTime createdAt;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);

  SessionSnapshot copyWith({
    String? userAgent,
    Map<String, String>? clientHints,
    List<BrowserCookie>? cookies,
    Map<String, Map<String, String>>? localStorage,
    String? egressIpHash,
    DateTime? expiresAt,
  }) =>
      SessionSnapshot(
        profileId: profileId,
        userAgent: userAgent ?? this.userAgent,
        clientHints: clientHints ?? this.clientHints,
        cookies: cookies ?? this.cookies,
        origin: origin,
        localStorage: localStorage ?? this.localStorage,
        egressIpHash: egressIpHash ?? this.egressIpHash,
        createdAt: createdAt,
        expiresAt: expiresAt ?? this.expiresAt,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'profile_id': profileId,
        'origin': origin.toString(),
        'user_agent': userAgent,
        'client_hints': clientHints,
        'cookies': cookies.map((c) => c.toJson()).toList(growable: false),
        'local_storage': localStorage,
        'egress_ip_hash': egressIpHash,
        'created_at': createdAt.toUtc().toIso8601String(),
        'expires_at': expiresAt.toUtc().toIso8601String(),
      };

  factory SessionSnapshot.fromJson(Map<String, Object?> json) =>
      SessionSnapshot(
        profileId: json['profile_id']! as String,
        origin: Uri.parse(json['origin']! as String),
        userAgent: json['user_agent']! as String,
        clientHints: (json['client_hints'] as Map?)?.cast<String, String>() ??
            const <String, String>{},
        cookies: ((json['cookies'] as List?) ?? const <Object?>[])
            .map((e) => BrowserCookie.fromJson(
                (e! as Map).cast<String, Object?>()))
            .toList(growable: false),
        localStorage: <String, Map<String, String>>{
          for (final entry
              in ((json['local_storage'] as Map?) ?? const <Object?, Object?>{})
                  .entries)
            entry.key! as String:
                (entry.value! as Map).cast<String, String>(),
        },
        egressIpHash: json['egress_ip_hash'] as String?,
        createdAt: DateTime.parse(json['created_at']! as String).toUtc(),
        expiresAt: DateTime.parse(json['expires_at']! as String).toUtc(),
      );
}
