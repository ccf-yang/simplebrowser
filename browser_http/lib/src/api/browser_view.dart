import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/models/page_network_event.dart';
import '../domain/models/webview_navigation_event.dart';
import '../ports/webview_port.dart';
import 'browser_session.dart';

/// Drives a real, user-visible WKWebView: navigation, history and page state.
///
/// The WebView shares its `WKWebsiteDataStore` with the native transport and
/// with [BrowserSession.challenge], so cookies set while browsing are seen by
/// subsequent [BrowserSession.capture] calls (and vice versa).
///
/// WebKit deliberately hides subresource request/response headers from host
/// apps. This controller exposes what is actually available — main-frame URL,
/// title, status, and Performance API resource timings — and the demo pairs
/// those with a native-engine capture of the same URL to show full metadata.
final class BrowserController extends ChangeNotifier {
  BrowserController({required this.session});

  final BrowserSession session;

  WebViewSession? _webView;
  Object? _error;
  Future<void>? _startFuture;
  bool _disposed = false;
  final StreamController<PageNetworkEvent> _networkEvents =
      StreamController<PageNetworkEvent>.broadcast();
  final StreamController<WebViewNavigationEvent> _navigationEvents =
      StreamController<WebViewNavigationEvent>.broadcast();
  StreamSubscription<PageNetworkEvent>? _networkSubscription;
  StreamSubscription<WebViewNavigationEvent>? _navigationSubscription;

  String? _url;
  String? _title;
  int? _statusCode;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _loading = false;
  double _progress = 0;
  List<WebResourceTiming> _resources = const <WebResourceTiming>[];

  WebViewSession? get webView => _webView;
  String? get webViewId => _webView?.id;
  bool get isReady => _webView != null;
  Object? get error => _error;
  String? get url => _url;
  String? get title => _title;
  int? get statusCode => _statusCode;
  bool get canGoBack => _canGoBack;
  bool get canGoForward => _canGoForward;

  /// The main document is still loading. Pushed by the WebView itself, so it
  /// turns true in the frame the tap starts the request.
  bool get isLoading => _loading;

  /// `WKWebView.estimatedProgress`, 0..1, only meaningful while [isLoading].
  double get progress => _progress;
  List<WebResourceTiming> get resourceTimings => _resources;

  /// fetch/XHR/beacon observations from the page script.
  ///
  /// Available before [start]: the controller relays the session stream once
  /// the WebView exists, so subscribing early loses nothing.
  Stream<PageNetworkEvent> get networkEvents => _networkEvents.stream;

  /// Every page jump the WebView decided about, including the ones cancelled
  /// because they would have opened another app.
  Stream<WebViewNavigationEvent> get navigationEvents =>
      _navigationEvents.stream;

  /// Creates the WKWebView and navigates to [initialUri] when given.
  ///
  /// Safe to call repeatedly; only the first call creates the native session.
  Future<void> start({Uri? initialUri}) {
    if (_disposed || _webView != null) return Future<void>.value();
    final inFlight = _startFuture;
    if (inFlight != null) return inFlight;
    final future = _start(initialUri);
    _startFuture = future;
    return future;
  }

  Future<void> _start(Uri? initialUri) async {
    try {
      final info = await session.profileInfo();
      final webView = await session.webView.create(
        userAgent: info.userAgent,
        headless: false,
      );
      if (_disposed) {
        await webView.dispose();
        return;
      }
      _webView = webView;
      _networkSubscription ??= webView.networkEvents.listen((event) {
        if (!_networkEvents.isClosed) _networkEvents.add(event);
      });
      _navigationSubscription ??= webView.navigationEvents.listen(_onWebViewEvent);
      if (!_pageNetwork) await webView.setPageNetworkEnabled(false);
      if (_contentBlocking) await webView.setContentBlockingEnabled(true);
      if (initialUri != null) await webView.navigate(initialUri);
      await refresh();
    } on Object catch (error) {
      if (!_disposed) _error = error;
    } finally {
      _startFuture = null;
      if (!_disposed) notifyListeners();
    }
  }

  /// Splits the WebView's reports: a chrome snapshot updates this controller,
  /// a navigation decision is relayed to the host's log.
  ///
  /// The snapshot used to be produced by polling `currentUrl`/`currentTitle`
  /// eight times a second, which cost five bridge calls plus a JavaScript
  /// evaluation per tick and still showed a new page up to a full tick late.
  /// KVO on the native side delivers the same facts in the frame they happen.
  void _onWebViewEvent(WebViewNavigationEvent event) {
    if (_disposed) return;
    if (!event.isState) {
      if (!_navigationEvents.isClosed) _navigationEvents.add(event);
      return;
    }
    final previousUrl = _url;
    final urlChanged = event.url.isNotEmpty && event.url != previousUrl;
    if (urlChanged) {
      _url = event.url;
      // A different document brings its own title, and no status code yet.
      _title = event.title;
    } else {
      _title = event.title ?? _title;
    }
    _canGoBack = event.canGoBack ?? _canGoBack;
    _canGoForward = event.canGoForward ?? _canGoForward;
    _loading = event.isLoading;
    _progress = event.progress;
    // While a load is in flight the native side reports no code until the
    // response arrives, so the address bar must not keep the previous page's.
    _statusCode = event.isLoading
        ? event.statusCode
        : (event.statusCode ?? _statusCode);
    notifyListeners();
  }

  /// Marks the start of a navigation this controller issued, so the chrome can
  /// show progress before the WebView has any new property to report.
  void _beginNavigation(String? url) {
    if (_disposed) return;
    _loading = true;
    // Never rewind below what the page already reported: a reload of the same
    // document keeps its title and its half-drawn progress.
    if (_progress < 0.03) _progress = 0.03;
    _statusCode = null;
    if (url != null && url != _url) {
      _url = url;
      _title = null;
    }
    notifyListeners();
  }

  /// Overrides the WebView user agent for subsequent navigations.
  ///
  /// Pass `null` to return to WebKit's default agent.
  Future<void> setUserAgent(String? userAgent) async {
    await start();
    await _webView?.setUserAgent(userAgent);
  }

  Future<void> load(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    String? userAgent,
  }) async {
    await start();
    final webView = _webView;
    if (webView == null) return;
    _beginNavigation(uri.toString());
    if (userAgent != null) await webView.setUserAgent(userAgent);
    final cookie = headers['Cookie'];
    if (cookie != null && cookie.isNotEmpty) {
      await webView.setCookie(uri, cookie);
    }
    await webView.navigate(uri, headers: headers);
    await refresh();
  }

  Future<void> reload({
    Map<String, String> headers = const <String, String>{},
    String? userAgent,
  }) async {
    final webView = _webView;
    if (webView == null) return;
    _beginNavigation(null);
    if (userAgent != null) await webView.setUserAgent(userAgent);
    if (headers.isEmpty) {
      await webView.reload();
    } else {
      final current = await webView.currentUrl();
      final uri = current == null ? null : Uri.tryParse(current);
      if (uri == null) {
        await webView.reload();
      } else {
        final cookie = headers['Cookie'];
        if (cookie != null && cookie.isNotEmpty) {
          await webView.setCookie(uri, cookie);
        }
        await webView.navigate(uri, headers: headers);
      }
    }
    await refresh();
  }

  /// Cancels the load in flight. The WebView reports itself idle afterwards, so
  /// the chrome stops on its own.
  Future<void> stopLoading() async {
    final webView = _webView;
    if (webView == null) return;
    await webView.stopLoading();
    if (_disposed) return;
    _loading = false;
    _progress = 0;
    notifyListeners();
    await refresh();
  }

  Future<void> goBack() async {
    final webView = _webView;
    if (webView == null || !_canGoBack) return;
    _beginNavigation(null);
    await webView.goBack();
    await refresh();
  }

  Future<void> goForward() async {
    final webView = _webView;
    if (webView == null || !_canGoForward) return;
    _beginNavigation(null);
    await webView.goForward();
    await refresh();
  }

  /// Re-reads the page state from the native side.
  ///
  /// Only a gap filler: KVO events keep the fields below current, and this is
  /// what a host calls after it issues a navigation itself. Resource timings
  /// are deliberately not fetched here — they come from a JavaScript
  /// evaluation, so pulling them on every state change would tax the page.
  Future<void> refresh() async {
    final webView = _webView;
    if (webView == null || _disposed) return;

    try {
      final url = await webView.currentUrl();
      final title = await webView.currentTitle();
      final statusCode = await webView.lastStatusCode();
      final canGoBack = await webView.canGoBack();
      final canGoForward = await webView.canGoForward();

      final changed =
          url != _url ||
          title != _title ||
          statusCode != _statusCode ||
          canGoBack != _canGoBack ||
          canGoForward != _canGoForward;
      // A probe between two documents can still answer with the previous URL,
      // so a missing value never rewinds what the WebView already reported.
      _url = url ?? _url;
      _title = title ?? _title;
      _statusCode = statusCode ?? _statusCode;
      _canGoBack = canGoBack;
      _canGoForward = canGoForward;

      if (changed && !_disposed) notifyListeners();
    } on Object {
      // The page can be between documents; a failed probe is not fatal.
    }
  }

  /// Re-reads the Performance API resource list.
  Future<List<WebResourceTiming>> refreshResources({bool notify = true}) async {
    final webView = _webView;
    if (webView == null) return const <WebResourceTiming>[];
    try {
      _resources = await webView.resourceTimings();
    } on Object {
      _resources = const <WebResourceTiming>[];
    }
    if (notify && !_disposed) notifyListeners();
    return _resources;
  }

  Future<Object?> evaluate(String script) async {
    final webView = _webView;
    if (webView == null) return null;
    return webView.evaluate(script);
  }

  /// Whether the page-script hooks are installed. Off means the Page tab is
  /// closed and nothing from the page is collected.
  bool _pageNetwork = true;

  /// Installs (or removes) the debug console for this WebView and every
  /// document it loads afterwards.
  ///
  /// [source] is the eruda bundle; it is cached natively and evaluated by the
  /// native side on every navigation commit, so later documents need no help
  /// from Dart. Returns `ok`, `queued` or the reason it failed.
  Future<String> setDebugOverlay({
    required bool enabled,
    String? source,
    double displaySize = 50,
  }) async {
    await start();
    final webView = _webView;
    if (webView == null) return 'no-webview';
    return webView.setDebugOverlay(
      enabled: enabled,
      source: source,
      displaySize: displaySize,
    );
  }

  /// Turns the page-script hooks on or off. Buffered until the WebView exists.
  Future<void> setPageNetworkEnabled(bool enabled) async {
    _pageNetwork = enabled;
    final webView = _webView;
    if (webView != null) await webView.setPageNetworkEnabled(enabled);
  }

  /// Compiles (first run) and installs the content-blocker list. The compiled
  /// list is cached natively by WebKit and shared by later sessions.
  Future<String> applyContentRuleList({
    required String identifier,
    String? encodedRules,
  }) async {
    await start();
    final webView = _webView;
    if (webView == null) return 'no-webview';
    return webView.applyContentRuleList(
      identifier: identifier,
      encodedRules: encodedRules,
    );
  }

  /// Attaches or detaches the installed content-blocker list. Buffered until
  /// the WebView exists, like [setPageNetworkEnabled].
  bool _contentBlocking = false;

  Future<void> setContentBlockingEnabled(bool enabled) async {
    _contentBlocking = enabled;
    final webView = _webView;
    if (webView != null) await webView.setContentBlockingEnabled(enabled);
  }

  bool get contentBlockingEnabled => _contentBlocking;

  /// Updates the panel size used by the next documents. Cheap: the injected
  /// bundle is rebuilt natively, nothing is re-evaluated.
  Future<void> setDebugDisplaySize(double displaySize) async {
    final webView = _webView;
    if (webView == null) return;
    await webView.setDebugDisplaySize(displaySize);
  }

  /// Turns the "never leave the app" navigation rules on or off.
  Future<void> setNavigationPolicy({
    bool blockExternal = true,
    bool reissueTaps = true,
  }) async {
    await start();
    await _webView?.setNavigationPolicy(
      blockExternal: blockExternal,
      reissueTaps: reissueTaps,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    final webView = _webView;
    _webView = null;
    if (webView != null) unawaited(webView.dispose());
    unawaited(_networkSubscription?.cancel());
    _networkSubscription = null;
    unawaited(_navigationSubscription?.cancel());
    _navigationSubscription = null;
    unawaited(_networkEvents.close());
    unawaited(_navigationEvents.close());
    super.dispose();
  }
}

/// Renders the WKWebView owned by [controller].
///
/// The user clicks links themselves; this widget only forwards navigation
/// commands issued through [BrowserController].
final class BrowserView extends StatefulWidget {
  const BrowserView({super.key, required this.controller, this.initialUri});

  final BrowserController controller;
  final Uri? initialUri;

  @override
  State<BrowserView> createState() => _BrowserViewState();
}

class _BrowserViewState extends State<BrowserView> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    unawaited(widget.controller.start(initialUri: widget.initialUri));
  }

  @override
  void didUpdateWidget(BrowserView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
      unawaited(widget.controller.start(initialUri: widget.initialUri));
    }
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return const Center(
        child: Text('The browser WebView is only available on iOS.'),
      );
    }

    final error = widget.controller.error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Could not open WKWebView: $error'),
        ),
      );
    }

    final id = widget.controller.webViewId;
    if (id == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return UiKitView(
      key: ValueKey<String>(id),
      viewType: 'browser_http/browser_view',
      creationParams: <String, Object?>{'id': id},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: (_) => unawaited(widget.controller.refresh()),
    );
  }
}
