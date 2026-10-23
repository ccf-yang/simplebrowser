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
    this.isLoading = false,
    this.progress = 0,
    this.title,
    this.canGoBack,
    this.canGoForward,
  });

  /// Native WebView session id (`WebViewSession.id`).
  final String sessionId;

  /// One of `start`, `in-app`, `blocked`, `response`, `redirect`, `committed`,
  /// `failed`, `state`, as reported by the native side.
  ///
  /// `state` is not a decision but a snapshot of the WebView's own chrome
  /// properties (progress, title, history flags); it is pushed by KVO so a
  /// browser UI never has to poll the page.
  final String kind;

  final String url;
  final DateTime timestamp;
  final String method;

  /// What triggered it: `link`, `form`, `backForward`, `reload`, `other`,
  /// `state`.
  final String navigationType;
  final bool isMainFrame;
  final int? statusCode;
  final String? message;

  /// Only set on `state` events: WebKit is still loading the main document.
  final bool isLoading;

  /// Only set on `state` events: `WKWebView.estimatedProgress`, 0..1, quantised
  /// natively so a page with hundreds of subresources cannot flood the channel.
  final double progress;

  /// Only set on `state` events: the document title, once WebKit has one.
  final String? title;

  /// Only set on `state` events: the back/forward list as WebKit sees it.
  final bool? canGoBack;
  final bool? canGoForward;

  bool get isBlocked => kind == 'blocked';
  bool get isFailed => kind == 'failed';
  bool get isCommitted => kind == 'committed';
  bool get isState => kind == 'state';

  /// A jump that would leave the app, cancelled on the way and waiting for the
  /// host's answer. [url] is the app URL (`bilibili://video/…`), not the wrapper
  /// page that carried it, so a dialog can name the app it is asking about.
  bool get isExternalAsk => kind == 'ask';

  /// A jump the host's rules already settled: handed to the system without a
  /// dialog. The message says whether an app was there to receive it.
  bool get isExternalOpen => kind == 'external-open';

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
      isLoading: json['loading'] as bool? ?? false,
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      title: (json['title'] as String?)?.isEmpty == true
          ? null
          : json['title'] as String?,
      canGoBack: json['canGoBack'] as bool?,
      canGoForward: json['canGoForward'] as bool?,
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
    if (isState) ...<String, Object?>{
      'loading': isLoading,
      'progress': progress,
      'title': title ?? '',
      'canGoBack': canGoBack,
      'canGoForward': canGoForward,
    },
  };

  @override
  String toString() => '$kind $method $url';
}
