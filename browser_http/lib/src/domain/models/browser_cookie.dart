/// A cookie as exchanged between the native jar and WKWebView.
///
/// Deliberately independent of `dart:io` so it can be serialized, compared and
/// tested in pure Dart.
final class BrowserCookie {
  const BrowserCookie({
    required this.name,
    required this.value,
    this.domain,
    this.path = '/',
    this.expires,
    this.secure = false,
    this.httpOnly = false,
    this.sameSite,
  });

  final String name;
  final String value;
  final String? domain;
  final String path;
  final DateTime? expires;
  final bool secure;
  final bool httpOnly;

  /// `Strict`, `Lax` or `None`.
  final String? sameSite;

  bool get isExpired =>
      expires != null && expires!.isBefore(DateTime.now().toUtc());

  bool matches(Uri uri) {
    if (isExpired) return false;
    if (secure && uri.scheme != 'https') return false;
    final host = uri.host;
    if (domain != null && domain!.isNotEmpty) {
      final d = domain!.startsWith('.') ? domain!.substring(1) : domain!;
      if (host != d && !host.endsWith('.$d')) return false;
    }
    if (!uri.path.startsWith(path)) return false;
    return true;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'value': value,
        'domain': domain,
        'path': path,
        'expires': expires?.toUtc().toIso8601String(),
        'secure': secure,
        'httpOnly': httpOnly,
        'sameSite': sameSite,
      };

  factory BrowserCookie.fromJson(Map<String, Object?> json) => BrowserCookie(
        name: json['name']! as String,
        value: json['value']! as String,
        domain: json['domain'] as String?,
        path: (json['path'] as String?) ?? '/',
        expires: json['expires'] == null
            ? null
            : DateTime.parse(json['expires']! as String).toUtc(),
        secure: (json['secure'] as bool?) ?? false,
        httpOnly: (json['httpOnly'] as bool?) ?? false,
        sameSite: json['sameSite'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is BrowserCookie &&
      other.name == name &&
      other.value == value &&
      other.domain == domain &&
      other.path == path &&
      other.expires == expires &&
      other.secure == secure &&
      other.httpOnly == httpOnly &&
      other.sameSite == sameSite;

  @override
  int get hashCode => Object.hash(
        name,
        value,
        domain,
        path,
        expires,
        secure,
        httpOnly,
        sameSite,
      );
}
