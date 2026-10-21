import 'dart:typed_data';

/// A header with its emission order preserved.
///
/// Header order is part of the browser fingerprint, so it must never be
/// normalized into an unordered map on the way to the native layer.
final class OrderedHeader {
  const OrderedHeader(this.name, this.value);

  final String name;
  final String value;

  @override
  String toString() => '$name: $value';
}

/// A request as handed to a [TransportPort].
final class TransportRequest {
  const TransportRequest({
    required this.method,
    required this.uri,
    required this.profileId,
    this.id = '',
    this.headers = const <OrderedHeader>[],
    this.body,
    this.timeout,
    this.followRedirects = true,
    this.maxRedirects = 10,
    this.proxyUrl,
  });

  /// Correlates the request with cancellation and logs. Filled in by
  /// [BrowserSession] when empty.
  final String id;

  final String method;
  final Uri uri;

  /// Must match a profile registered in the native core.
  final String profileId;

  /// Order is significant.
  final List<OrderedHeader> headers;

  final Uint8List? body;
  final Duration? timeout;
  final bool followRedirects;
  final int maxRedirects;

  /// `http://`, `https://` or `socks5://`. `null` means direct.
  final Uri? proxyUrl;

  TransportRequest copyWith({
    String? id,
    List<OrderedHeader>? headers,
    Uint8List? body,
    Uri? proxyUrl,
    bool? followRedirects,
  }) =>
      TransportRequest(
        method: method,
        uri: uri,
        profileId: profileId,
        id: id ?? this.id,
        headers: headers ?? this.headers,
        body: body ?? this.body,
        timeout: timeout,
        followRedirects: followRedirects ?? this.followRedirects,
        maxRedirects: maxRedirects,
        proxyUrl: proxyUrl ?? this.proxyUrl,
      );
}

/// Identity defaults owned by a native profile.
///
/// Dart must never hard-code these values (design rule #2); they are queried
/// from the native core so the two engines cannot drift apart.
final class ProfileInfo {
  const ProfileInfo({
    required this.profileId,
    required this.family,
    required this.userAgent,
    required this.clientHints,
  });

  final String profileId;

  /// `safari`, `chrome`, `firefox`.
  final String family;

  final String userAgent;
  final Map<String, String> clientHints;
}

/// Lightweight description of a profile supported by the native core.
final class ProfileDescriptor {
  const ProfileDescriptor({
    required this.id,
    required this.family,
    required this.browser,
    required this.version,
    required this.iosCompatible,
  });

  final String id;
  final String family;
  final String browser;
  final String version;

  /// Only Safari profiles can share a session with WKWebView on iOS.
  final bool iosCompatible;
}

/// Metadata captured while the request was in flight.
///
/// Only populated when debug logging is enabled.
final class FingerprintInfo {
  const FingerprintInfo({
    required this.profileId,
    required this.ja3,
    required this.ja4,
    required this.alpn,
    required this.tlsVersion,
    required this.h2Settings,
  });

  final String profileId;
  final String ja3;
  final String ja4;
  final String alpn;
  final String tlsVersion;

  /// Raw HTTP/2 SETTINGS payload, hex encoded.
  final String h2Settings;

  Map<String, Object?> toJson() => <String, Object?>{
        'profile': profileId,
        'ja3': ja3,
        'ja4': ja4,
        'alpn': alpn,
        'tls_version': tlsVersion,
        'h2_settings': h2Settings,
      };
}

/// A response whose body is still arriving.
///
/// Headers are available before the first body byte, which is what SSE and
/// long downloads need.
final class TransportStream {
  const TransportStream({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;

  /// Order as received.
  final List<OrderedHeader> headers;

  /// Body chunks.
  ///
  /// Cancelling the subscription stops local delivery; pass a `CancelToken` to
  /// abort the socket as well.
  final Stream<List<int>> body;

  String? header(String name) {
    final lower = name.toLowerCase();
    for (final h in headers) {
      if (h.name.toLowerCase() == lower) return h.value;
    }
    return null;
  }
}

/// A response as returned by a [TransportPort].
final class TransportResponse {
  const TransportResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    this.fingerprint,
  });

  final int statusCode;

  /// Order as received.
  final List<OrderedHeader> headers;

  final Uint8List body;
  final FingerprintInfo? fingerprint;

  String? header(String name) {
    final lower = name.toLowerCase();
    for (final h in headers) {
      if (h.name.toLowerCase() == lower) return h.value;
    }
    return null;
  }
}
