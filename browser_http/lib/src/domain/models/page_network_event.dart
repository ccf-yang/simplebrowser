/// One network observation reported by the injected page script.
///
/// The script hooks `fetch`, `XMLHttpRequest` and `navigator.sendBeacon`, so it
/// sees the method, URL, caller headers and body of requests made by page
/// JavaScript — including POST bodies that WebKit never exposes to the host.
/// It also reports response headers and, when it can read them cheaply, a
/// truncated response body.
enum PageNetworkPhase { request, response, body, error }

final class PageNetworkEvent {
  const PageNetworkEvent({
    required this.sessionId,
    required this.page,
    required this.id,
    required this.phase,
    required this.timestamp,
    this.method,
    this.url,
    this.headers = const <String, String>{},
    this.responseHeaders = const <String, String>{},
    this.body,
    this.responseBody,
    this.statusCode,
    this.duration,
    this.size,
    this.message,
  });

  /// Native WebView session id (`WebViewSession.id`).
  final String sessionId;

  /// Random tag for the document that produced this event; request and
  /// response events share it together with [id].
  final String page;

  /// Document-local sequence number.
  final int id;

  final PageNetworkPhase phase;
  final DateTime timestamp;

  final String? method;
  final String? url;

  /// Caller-set request headers (empty on response events).
  final Map<String, String> headers;

  /// Response headers, when the page could read them.
  final Map<String, String> responseHeaders;

  final String? body;

  /// Truncated response body, when the page script could read it.
  final String? responseBody;

  final int? statusCode;

  /// Milliseconds, set on response/error events.
  final int? duration;

  /// Bytes, when the page reported a length.
  final int? size;

  final String? message;

  /// Stable pairing key across request/response/error events.
  String get key => '$page:$id';

  factory PageNetworkEvent.fromJson(Map<String, Object?> json) {
    final phase = switch (json['phase'] as String?) {
      'response' => PageNetworkPhase.response,
      'response-body' => PageNetworkPhase.body,
      'error' => PageNetworkPhase.error,
      _ => PageNetworkPhase.request,
    };
    return PageNetworkEvent(
      sessionId: json['sessionId'] as String? ?? '',
      page: json['page'] as String? ?? '',
      id: (json['id'] as num?)?.toInt() ?? 0,
      phase: phase,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (json['ts'] as num?)?.toInt() ?? 0,
      ),
      method: json['method'] as String?,
      url: json['url'] as String?,
      headers: _stringMap(json['headers']),
      responseHeaders: _stringMap(json['responseHeaders']),
      body: json['body'] as String?,
      responseBody: json['responseBody'] as String?,
      statusCode: (json['status'] as num?)?.toInt(),
      duration: (json['duration'] as num?)?.toInt(),
      size: (json['size'] as num?)?.toInt(),
      message: json['message'] as String?,
    );
  }

  static Map<String, String> _stringMap(Object? raw) {
    if (raw is! Map) return const <String, String>{};
    return <String, String>{
      for (final entry in raw.entries)
        if (entry.key != null && entry.value != null)
          '${entry.key}': '${entry.value}',
    };
  }
}
