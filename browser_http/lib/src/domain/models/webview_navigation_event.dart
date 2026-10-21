/// One main-frame (or blocked) navigation reported by the WKWebView itself.
///
/// `WKNavigationDelegate` is the only place a host app sees a page jump at all:
/// the destination of a `baidu://` link, a redirect chain and a failed load are
/// invisible to the `fetch`/XHR hooks. These events are what the browser lists
/// in its log and prints into the debug console.
final class WebViewNavigationEvent {
  const WebViewNavigationEvent({
    required this.sessionId,
    required this.kind,
    required this.url,
    required this.timestamp,
    this.method = 'GET',
    this.navigationType = 'other',
    this.isMainFrame = true,
    this.statusCode,
    this.message,
  });

  /// Native WebView session id (`WebViewSession.id`).
  final String sessionId;

  /// One of `start`, `in-app`, `blocked`, `response`, `redirect`, `committed`,
  /// `failed`, as reported by the native side.
  final String kind;

  final String url;
  final DateTime timestamp;
  final String method;

  /// What triggered it: `link`, `form`, `backForward`, `reload`, `other`.
  final String navigationType;
  final bool isMainFrame;
  final int? statusCode;
  final String? message;

  bool get isBlocked => kind == 'blocked';
  bool get isFailed => kind == 'failed';
  bool get isCommitted => kind == 'committed';

  factory WebViewNavigationEvent.fromJson(Map<String, Object?> json) {
    return WebViewNavigationEvent(
      sessionId: json['sessionId'] as String? ?? '',
      kind: (json['kind'] as String?) ?? 'start',
      url: (json['url'] as String?) ?? '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (json['ts'] as num?)?.toInt() ?? 0,
      ),
      method: (json['method'] as String?) ?? 'GET',
      navigationType: (json['navigationType'] as String?) ?? 'other',
      isMainFrame: json['mainFrame'] as bool? ?? true,
      statusCode: (json['status'] as num?)?.toInt(),
      message: json['message'] as String?,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'sessionId': sessionId,
    'kind': kind,
    'url': url,
    'ts': timestamp.millisecondsSinceEpoch,
    'method': method,
    'navigationType': navigationType,
    'mainFrame': isMainFrame,
    if (statusCode != null) 'status': statusCode,
    if (message != null) 'message': message,
  };

  @override
  String toString() => '$kind $method $url';
}
