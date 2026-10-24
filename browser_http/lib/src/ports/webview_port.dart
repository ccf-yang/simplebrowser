import 'dart:async';
import 'dart:typed_data';

import '../domain/models/browser_cookie.dart';
import '../domain/models/page_network_event.dart';
import '../domain/models/webview_link_press.dart';
import '../domain/models/webview_navigation_event.dart';
import '../domain/models/webview_video_event.dart';

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

  /// fetch/XHR/beacon observations reported by the injected page script.
  ///
  /// Events for all sessions share one native channel; implementations filter
  /// them by [id].
  Stream<PageNetworkEvent> get networkEvents;

  Future<WebViewLoadResult> load(
    Uri uri, {
    Duration? timeout,
    Map<String, String> headers = const <String, String>{},
  });

  /// Navigates the WebView (keeps history, unlike [load] which is also a
  /// normal navigation but is used for the initial challenge page).
  Future<void> navigate(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  });

  /// Overrides `WKWebView.customUserAgent`. Pass `null` to clear the override.
  Future<void> setUserAgent(String? userAgent);

  /// Stores the cookies in [cookieHeader] (`name=value; name2=value2`) in the
  /// WebView's shared `WKHTTPCookieStore` for [uri]'s host.
  Future<void> setCookie(Uri uri, String cookieHeader);

  Future<bool> canGoBack();
  Future<bool> canGoForward();
  Future<void> goBack();
  Future<void> goForward();
  Future<void> reload();

  /// Cancels the load in flight, the way Safari's Stop button does. A page that
  /// never answers leaves the host (and its chrome) waiting otherwise.
  Future<void> stopLoading();

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
  Future<void> importLocalStorage(Uri origin, Map<String, String> values);

  /// Current `navigator.userAgent`, used to verify consistency.
  Future<String> currentUserAgent();

  /// Navigation decisions of this WebView.
  ///
  /// Includes the jumps the native side cancelled because they would have left
  /// the app for another application.
  Stream<WebViewNavigationEvent> get navigationEvents;

  /// Links the user pressed and held in this WebView.
  ///
  /// A host that supports more than one browsing window needs the held anchor
  /// itself: WebKit's long-press menu cannot offer a command it does not know
  /// about, and the page script is the only place that sees the hold.
  Stream<WebViewLinkPress> get linkPresses;

  /// The page's video, for a host that draws its own player window.
  ///
  /// The page keeps the picture — WebKit stays the player — and this stream
  /// says when the user tapped a video (`enter`), tapped the picture again so
  /// the control layer should toggle (`tap`), where a horizontal drag is
  /// heading (`seeking`), where the playhead is (`state`), and when the window
  /// was closed (`exit`). Drive it with
  /// `evaluate('window.__soVideo.seekBy(seconds)')`,
  /// `window.__soVideo.seekTo(seconds)`, `window.__soVideo.toggle()` and
  /// `window.__soVideo.close()`. The script owns the gestures: pinch zooms the
  /// picture, a horizontal drag seeks, a pull-down leaves.
  Stream<WebViewVideoEvent> get videoEvents;

  /// PNG of what the WebView is showing, scaled down to at most [maxWidth]
  /// pixels wide, or `null` when there is nothing to render.
  ///
  /// Ask a window that is still on screen: WebKit composites what it displays,
  /// so a host takes the picture of a window at the moment it leaves it and
  /// keeps the card for as long as that window is away.
  Future<Uint8List?> snapshot({int maxWidth = 360});

  /// Installs the persistent debug console (eruda) for every later document.
  ///
  /// The native side evaluates the cached bundle on every navigation commit,
  /// so a reload, a link tap, a form post or a redirect all get the console
  /// back without host-side timing. Returns a short status: `ok` (the current
  /// document shows it), `queued` (a document is loading, its commit brings it
  /// up) or the reason it could not start.
  Future<String> setDebugOverlay({
    required bool enabled,
    String? source,
    double displaySize = 50,
  });

  /// Updates the panel size of the console, current document included.
  Future<void> setDebugDisplaySize(double displaySize);

  /// Installs or removes the page-script `fetch`/XHR hooks. While disabled the
  /// host collects nothing from the page.
  Future<void> setPageNetworkEnabled(bool enabled);

  /// Installs a WebKit content-blocker list for this WebView.
  ///
  /// [encodedRules] is the JSON document Safari expects. It is compiled and
  /// cached under [identifier]; later calls may omit it and reuse the cache.
  /// Returns `ready`, `missing` or `error: …`.
  Future<String> applyContentRuleList({
    required String identifier,
    String? encodedRules,
  });

  /// Attaches or detaches the last applied content-blocker list.
  Future<void> setContentBlockingEnabled(bool enabled);

  /// Whether non-http(s) navigations are cancelled instead of opening another
  /// app, and whether Universal-Link taps are re-issued in-app.
  ///
  /// The three protocol lists decide what happens to a jump that would leave the
  /// app. [deniedSchemes] is closed in silence; [allowedSchemes] is handed to the
  /// system without asking; anything else is either cancelled quietly or reported
  /// as a `kind: 'ask'` navigation event for the host to put in a dialog,
  /// depending on [askExternal].
  Future<void> setNavigationPolicy({
    bool blockExternal = true,
    bool reissueTaps = true,
    bool askExternal = false,
    List<String> allowSchemes = const <String>[],
    List<String> denySchemes = const <String>[],
  });

  /// Hands [uri] to the system — the one way a jump may leave the app on
  /// purpose, after the user said yes.
  Future<void> openExternal(Uri uri);

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
