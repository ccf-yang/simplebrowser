import 'transport.dart';

/// One request/response pair observed by the native transport.
///
/// This is the bridge between "what the app asked for" and "what actually
/// went over the wire": [requestHeaders] already contains the `Cookie` header
/// assembled from the shared jar, and the profile defaults (UA, client hints,
/// TLS/H2 settings) are applied natively just before the request is sent.
final class CapturedExchange {
  const CapturedExchange({
    required this.requestId,
    required this.method,
    required this.uri,
    required this.requestHeaders,
    required this.profile,
    required this.elapsed,
    required this.response,
  });

  final String requestId;
  final String method;
  final Uri uri;

  /// Ordered headers handed to the native transport.
  final List<OrderedHeader> requestHeaders;

  /// Identity the native layer applied on top of [requestHeaders].
  final ProfileInfo profile;

  final Duration elapsed;
  final TransportResponse response;

  int get responseBodyLength => response.body.length;
}
