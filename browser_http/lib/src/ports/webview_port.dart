import '../domain/models/browser_cookie.dart';

/// One entry from the page's `PerformanceResourceTiming` list.
///
/// This is the only subresource information WebKit exposes to the host app:
/// URL, type, timing and (when not blocked by TAO) transfer sizes. Headers and
/// bodies of WebView subresources are not available through public APIs.
final class WebResourceTiming {
  const WebResourceTiming({
    required this.url,
    required this.initiatorType,
    required this.duration,
    this.transferSize,
    this.encodedBodySize,
  });

  final String url;
  final String initiatorType;

  /// Milliseconds, as reported by `PerformanceResourceTiming.duration`.
  final double duration;

  final int? transferSize;
  final int? encodedBodySize;

  factory WebResourceTiming.fromJson(Map<String, Object?> json) =>
      WebResourceTiming(
        url: json['url']! as String,
        initiatorType: (json['initiatorType'] as String?) ?? '',
        duration: (json['duration'] as num?)?.toDouble() ?? 0,
        transferSize: json['transferSize'] as int?,
        encodedBodySize: json['encodedBodySize'] as int?,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'url': url,
        'initiatorType': initiatorType,
        'duration': duration,
        'transferSize': transferSize,
        'encodedBodySize': encodedBodySize,
      };
}

/// Result of loading a page in the challenge WebView.
final class WebViewLoadResult {
  const WebViewLoadResult({
    required this.url,
    required this.httpStatusCode,
    required this.title,
  });

  final Uri url;
  final int? httpStatusCode;
  final String? title;
}

/// A live WKWebView instance.
///
/// Implementations must use a persistent `WKWebsiteDataStore` so that
/// localStorage and session state survive across challenge flows.
abstract interface class WebViewSession {
  /// Native handle. Used by `UiKitView` to attach the same WKWebView that
  /// owns the user's challenge session.
  String get id;

  Future<WebViewLoadResult> load(Uri uri, {Duration? timeout});

  /// Navigates the WebView (keeps history, unlike [load] which is also a
  /// normal navigation but is used for the initial challenge page).
  Future<void> navigate(Uri uri);

  Future<bool> canGoBack();
  Future<bool> canGoForward();
  Future<void> goBack();
  Future<void> goForward();
  Future<void> reload();

  /// Current committed URL, or `null` before the first navigation.
  Future<String?> currentUrl();

  /// Current document title, if any.
  Future<String?> currentTitle();

  /// HTTP status of the last main-frame navigation.
  Future<int?> lastStatusCode();

  /// Resources loaded by the page, from the Performance API.
  Future<List<WebResourceTiming>> resourceTimings();

  /// Evaluates JavaScript and returns the JSON-decodable result.
  Future<Object?> evaluate(String script);

  Future<List<BrowserCookie>> exportCookies(Uri uri);

  /// origin -> key -> value.
  Future<Map<String, String>> exportLocalStorage(Uri origin);

  /// Writes [values] into the page's `localStorage`. The page must already be
  /// on [origin], otherwise the write lands on the wrong origin.
  Future<void> importLocalStorage(
    Uri origin,
    Map<String, String> values,
  );

  /// Current `navigator.userAgent`, used to verify consistency.
  Future<String> currentUserAgent();

  Future<void> dispose();
}

/// Factory for headless and visible challenge WebViews.
abstract interface class WebViewPort {
  /// [headless] WebViews still have a real JS engine but no UI. Interactive
  /// challenges must use a visible one, driven by [BrowserChallengeView].
  Future<WebViewSession> create({
    required String userAgent,
    bool headless = true,
  });

  /// Ensures a visible WebView controller is available for the widget layer.
  bool get isVisibleModeSupported;
}
