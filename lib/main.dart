import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:browser_http/browser_http.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, rootBundle;

import 'request_format.dart';
import 'settings_sheet.dart';
import 'theme.dart';

void main() => runApp(const SimpleBrApp());

class SimpleBrApp extends StatelessWidget {
  const SimpleBrApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'So~',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: const BrowserPage(),
      );
}

/// One entry of the user-agent preset list.
class _UaPreset {
  const _UaPreset(this.label, this.value);

  final String label;
  final String? value;
}

const List<_UaPreset> _uaPresets = <_UaPreset>[
  _UaPreset('Default (profile UA)', null),
  _UaPreset(
    'iPhone Safari 18',
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 '
        'Mobile/15E148 Safari/604.1',
  ),
  _UaPreset(
    'iPad Safari 18',
    'Mozilla/5.0 (iPad; CPU OS 18_5 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 '
        'Mobile/15E148 Safari/604.1',
  ),
  _UaPreset(
    'macOS Safari 18',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15',
  ),
  _UaPreset(
    'Windows Chrome 149',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36',
  ),
  _UaPreset(
    'macOS Chrome 149',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36',
  ),
  _UaPreset(
    'Android Chrome 149',
    'Mozilla/5.0 (Linux; Android 15; Pixel 9) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 '
        'Mobile Safari/537.36',
  ),
  _UaPreset(
    'Windows Edge 149',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 '
        'Safari/537.36 Edg/149.0.0.0',
  ),
  _UaPreset(
    'Windows Firefox 139',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:139.0) '
        'Gecko/20100101 Firefox/139.0',
  ),
  _UaPreset(
    'Googlebot (desktop)',
    'Mozilla/5.0 (compatible; Googlebot/2.1; '
        '+http://www.google.com/bot.html)',
  ),
];

enum _RefererMode { none, currentDomain }

/// Hybrid test browser.
///
/// Top: a real WKWebView the user browses and clicks in. Bottom: what the
/// native fingerprint engine sees, plus the request log. Both sides share one
/// persistent cookie jar, so a clearance obtained by browsing is reused by the
/// capture button.
///
/// Every navigation stays inside the app: the WebView cancels custom-scheme
/// jumps and re-issues Universal-Link taps from code, and the debug console is
/// registered natively so it survives any number of page changes.
class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage>
    with SingleTickerProviderStateMixin {
  static const double _erudaPillHeight = 30;
  static const List<String> _erudaUrls = <String>[
    'https://cdn.jsdelivr.net/npm/eruda@3.4.3/eruda.js',
    'https://unpkg.com/eruda@3.4.3/eruda.js',
  ];

  final StreamLogSink _logSink = StreamLogSink(400);
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _cookieController = TextEditingController();
  final FocusNode _urlFocus = FocusNode();
  final List<RequestLogEvent> _events = <RequestLogEvent>[];

  /// fetch/XHR/beacon observations merged into one entry per request, keyed by
  /// `page:id` so a response overwrites its own request row.
  final Map<String, PageNetworkEvent> _pageRequests =
      <String, PageNetworkEvent>{};

  late final BrowserSession _session;
  late final BrowserController _browser;
  late final StreamSubscription<RequestLogEvent> _logSubscription;
  late final StreamSubscription<PageNetworkEvent> _pageSubscription;
  late final StreamSubscription<WebViewNavigationEvent> _navigationSubscription;
  late final TabController _tabs;

  CapturedExchange? _capture;
  String? _captureError;
  bool _busy = false;

  int _uaIndex = 0;
  _RefererMode _refererMode = _RefererMode.none;
  String? _defaultUserAgent;
  String? _profileLabel;

  bool _urlFocused = false;
  bool _started = false;

  /// Share of the body height taken by the info panel; draggable.
  double _panelFraction = 0.4;
  bool _panelVisible = true;
  bool _didHidePanelForEruda = false;

  /// Cancel navigations that would open another app. On by default: a test
  /// browser that leaves the app cannot be debugged.
  bool _blockExternal = true;

  /// Serial number for synthetic log rows (page jumps have no engine id).
  int _navSeq = 0;

  int _logFilter = 0; // 0 all, 1 warn, 2 error

  String? _seenUrl;
  String? _seenTitle;
  int? _seenStatus;
  bool _seenBack = false;
  bool _seenForward = false;
  int _seenResources = 0;

  // Eruda overlay state.
  bool _erudaOpen = false;
  bool _erudaBusy = false;
  double _erudaSize = 50;
  String? _erudaSource;
  Timer? _erudaVerifyTimer;
  Timer? _debugSizeTimer;

  @override
  void initState() {
    super.initState();
    _session = BrowserHttp.session(logSink: _logSink);
    _browser = BrowserController(session: _session)
      ..addListener(_onBrowserChanged);
    _tabs = TabController(length: 4, vsync: this);
    _urlFocus.addListener(_onUrlFocusChanged);
    _logSubscription = _logSink.stream.listen((event) {
      if (!mounted) return;
      setState(() => _events.insert(0, event));
    });
    // Buffered even while the panel is closed, so opening "Page" shows the
    // requests of the current document instead of an empty list.
    _pageSubscription = _browser.networkEvents.listen(_onPageNetworkEvent);
    _navigationSubscription =
        _browser.navigationEvents.listen(_onNavigationEvent);
    unawaited(_loadProfileInfo());
  }

  Future<void> _loadProfileInfo() async {
    try {
      final info = await _session.profileInfo();
      if (!mounted) return;
      setState(() {
        _defaultUserAgent = info.userAgent;
        _profileLabel =
            info.family.isNotEmpty ? info.family : info.profileId;
      });
    } on Object {
      // Keep null; the engine still works with its defaults.
    }
  }

  void _onUrlFocusChanged() {
    final focused = _urlFocus.hasFocus;
    if (focused) {
      final length = _urlController.text.length;
      _urlController.selection =
          TextSelection(baseOffset: 0, extentOffset: length);
    }
    if (focused != _urlFocused) setState(() => _urlFocused = focused);
  }

  /// The controller polls the WebView; rebuild only on real changes so the
  /// platform view is not re-laid-out every tick.
  void _onBrowserChanged() {
    if (!mounted) return;
    final changed = _seenUrl != _browser.url ||
        _seenTitle != _browser.title ||
        _seenStatus != _browser.statusCode ||
        _seenBack != _browser.canGoBack ||
        _seenForward != _browser.canGoForward ||
        _seenResources != _browser.resourceTimings.length;
    if (!changed) return;

    final previousUrl = _seenUrl;
    _seenUrl = _browser.url;
    _seenTitle = _browser.title;
    _seenStatus = _browser.statusCode;
    _seenBack = _browser.canGoBack;
    _seenForward = _browser.canGoForward;
    _seenResources = _browser.resourceTimings.length;

    setState(() {
      final url = _browser.url;
      if (!_urlFocus.hasFocus &&
          url != null &&
          url.isNotEmpty &&
          url != 'about:blank') {
        _urlController.text = url;
      }
    });

    // The console is registered as a native user script, so a new document
    // restores itself. Only check when the URL changed, and never close the
    // panel because a probe came back too early.
    if (_erudaOpen && previousUrl != _browser.url) _scheduleErudaVerify();
  }

  // ---------------------------------------------------------------------------
  // Page jumps (navigation delegate)
  // ---------------------------------------------------------------------------

  /// One navigation the WebView decided about: allowed, re-issued in-app,
  /// blocked because it targeted another app, or failed.
  void _onNavigationEvent(WebViewNavigationEvent event) {
    if (!mounted) return;
    if (!event.isMainFrame) return;
    final log = RequestLogEvent(
      id: 'nav-${_navSeq++}',
      phase: switch (event.kind) {
        'blocked' => RequestLogPhase.cancelled,
        'failed' => RequestLogPhase.error,
        'redirect' => RequestLogPhase.redirect,
        'response' => RequestLogPhase.response,
        'committed' => RequestLogPhase.response,
        _ => RequestLogPhase.start,
      },
      timestamp: event.timestamp,
      level: switch (event.kind) {
        'blocked' => RequestLogLevel.warn,
        'failed' => RequestLogLevel.error,
        _ => RequestLogLevel.info,
      },
      method: event.method,
      uri: Uri.tryParse(event.url),
      statusCode: event.statusCode,
      errorCode: switch (event.kind) {
        'blocked' => 'webview.externalBlocked',
        'failed' => 'webview.navigationFailed',
        _ => null,
      },
      message: switch (event.kind) {
        'blocked' => '${event.message ?? 'blocked'} (${event.navigationType})',
        'in-app' => 'tap kept in-app',
        _ => event.message,
      },
    );
    setState(() {
      _events.insert(0, log);
      while (_events.length > 400) {
        _events.removeLast();
      }
    });

    // Mirror it into the eruda console; the page's own context prints the
    // landing line, the host prints what the page cannot see.
    if (_erudaOpen) {
      _pushToConsole(
        switch (event.kind) {
          'blocked' =>
            '已拦截外部跳转 ${event.method} ${event.url} '
                '(${event.navigationType})',
          'in-app' => '点击链接改为站内加载 ${event.url}',
          'failed' => '加载失败 ${event.url} ${event.message ?? ''}',
          'redirect' => '${event.statusCode} 跳转 ${event.url}',
          'committed' =>
            '页面已打开 ${event.statusCode ?? ''} ${event.url}',
          _ => null,
        },
        level: event.isBlocked
            ? 'warn'
            : event.isFailed
                ? 'error'
                : 'info',
      );
    }

    if (event.isBlocked && mounted) {
      final host = Uri.tryParse(event.url)?.host;
      _snack('已阻止跳转到外部应用${host == null ? '' : '：$host'}');
    }
  }

  /// Prints one line into the eruda console of the current document.
  void _pushToConsole(String? text, {String level = 'info'}) {
    if (text == null || text.isEmpty) return;
    final safe = _jsString(text);
    _evalQuiet(
      'window.__bhDebugLog && window.__bhDebugLog($safe, "$level");',
    );
  }

  static String _jsString(String value) {
    final escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll('\n', r'\n')
        .replaceAll('\r', '');
    return "'$escaped'";
  }

  Uri? _parseUrl(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final withScheme = text.contains('://') ? text : 'https://$text';
    final uri = Uri.tryParse(withScheme);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return null;
    }
    return uri;
  }

  Uri? _currentUri() => _parseUrl(_browser.url ?? _urlController.text);

  /// A fresh WKWebView may report an empty string or `about:blank`; neither is
  /// a real document for the start page / Eruda.
  bool get _hasDocument {
    final url = _browser.url;
    return url != null && url.isNotEmpty && url != 'about:blank';
  }

  /// UA sent to the engine capture; `null` means "use the profile default".
  String? get _uaOverride => _uaPresets[_uaIndex].value;

  /// UA applied to the WebView. "No override" keeps the profile agent that the
  /// WebView was created with.
  String? get _effectiveUserAgent => _uaOverride ?? _defaultUserAgent;

  String? get _cookieValue {
    final value = _cookieController.text.trim();
    return value.isEmpty ? null : value;
  }

  /// Headers applied to both the WebView navigation and the engine capture.
  Map<String, String> _headersFor(Uri uri) {
    final headers = <String, String>{};
    if (_refererMode == _RefererMode.currentDomain) {
      headers['Referer'] = '${uri.scheme}://${uri.authority}/';
    }
    final cookie = _cookieValue;
    if (cookie != null) headers['Cookie'] = cookie;
    return headers;
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _go() async {
    final uri = _parseUrl(_urlController.text);
    if (uri == null) {
      _snack('Enter an http:// or https:// URL');
      return;
    }
    _urlFocus.unfocus();
    setState(() => _started = true);
    try {
      await _browser.load(
        uri,
        headers: _headersFor(uri),
        userAgent: _effectiveUserAgent,
      );
    } on Object catch (error) {
      if (mounted) {
        if (!_hasDocument) setState(() => _started = false);
        _snack('Load failed: $error');
      }
    }
  }

  void _openShortcut(String url) {
    _urlController.text = url;
    unawaited(_go());
  }

  Future<void> _reload() async {
    final uri = _currentUri();
    try {
      await _browser.reload(
        headers: uri == null ? const <String, String>{} : _headersFor(uri),
        userAgent: _effectiveUserAgent,
      );
    } on Object catch (error) {
      if (mounted) _snack('Reload failed: $error');
    }
  }

  Future<void> _openSettings() async {
    final result = await showModalBottomSheet<SettingsValues>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: AppColors.ink.withAlpha(88),
      builder: (context) => SettingsSheet(
        initial: SettingsValues(
          uaIndex: _uaIndex,
          refererMode: _refererMode == _RefererMode.currentDomain ? 1 : 0,
          cookie: _cookieController.text,
          showPanel: _panelVisible,
          blockExternal: _blockExternal,
        ),
        uaLabels: <String>[for (final preset in _uaPresets) preset.label],
        onShowPanelChanged: _setPanelVisible,
        onBlockExternalChanged: _setBlockExternal,
      ),
    );
    if (result == null || !mounted) return;

    setState(() {
      _uaIndex = result.uaIndex;
      _refererMode = result.refererMode == 1
          ? _RefererMode.currentDomain
          : _RefererMode.none;
      _panelVisible = result.showPanel;
      _blockExternal = result.blockExternal;
    });
    unawaited(_browser.setNavigationPolicy(
      blockExternal: _blockExternal,
      reissueTaps: _blockExternal,
    ));
    _cookieController.text = result.cookie;

    final userAgent = _effectiveUserAgent;
    await _browser.setUserAgent(userAgent);
    if (!mounted) return;

    final uri = _currentUri();
    if (uri != null) {
      await _browser.reload(
        headers: _headersFor(uri),
        userAgent: userAgent,
      );
    }
    if (!mounted) return;
    _snack(
      uri == null ? 'Settings saved' : 'Saved, reloaded with new headers',
    );
  }

  void _setPanelVisible(bool value) {
    if (_panelVisible == value) return;
    setState(() => _panelVisible = value);
  }

  /// Applied immediately, not only on "Save": while the sheet is open the user
  /// may tap a link in the page behind it.
  void _setBlockExternal(bool value) {
    if (_blockExternal == value) return;
    setState(() => _blockExternal = value);
    unawaited(_browser.setNavigationPolicy(
      blockExternal: value,
      reissueTaps: value,
    ));
  }

  /// Runs the current URL through the native (Rust/wreq) engine so the panel
  /// can show ordered request headers, status, response headers, body and
  /// timing.
  Future<void> _captureCurrent() async {
    if (_busy) return;
    final uri = _parseUrl(_urlController.text) ??
        (_browser.url == null ? null : Uri.tryParse(_browser.url!));
    if (uri == null) {
      _snack('Nothing to capture yet');
      return;
    }

    final headers = <OrderedHeader>[
      if (_uaOverride != null) OrderedHeader('User-Agent', _uaOverride!),
      for (final entry in _headersFor(uri).entries)
        OrderedHeader(entry.key, entry.value),
    ];

    setState(() {
      _busy = true;
      _captureError = null;
    });
    try {
      final capture = await _session.capture(uri, headers: headers);
      if (mounted) setState(() => _capture = capture);
    } on BrowserHttpException catch (error) {
      if (mounted) {
        setState(() => _captureError = '${error.code}: ${error.message}');
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _captureError = error.toString());
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Page-script requests (fetch / XHR / sendBeacon)
  // ---------------------------------------------------------------------------

  /// Merges the injected script's request/response events into one entry per
  /// request: headers and body come from the request, status/timing/response
  /// body from the matching response.
  void _onPageNetworkEvent(PageNetworkEvent event) {
    if (!mounted) return;
    setState(() {
      final existing = _pageRequests[event.key];
      _pageRequests[event.key] = existing == null
          ? _normalizePageEvent(event)
          : _mergePageEvent(existing, event);
      while (_pageRequests.length > 50) {
        _pageRequests.remove(_pageRequests.keys.first);
      }
    });
  }

  /// A lone response/error event has no request row to merge into, so its
  /// response headers are moved into the response slot.
  static PageNetworkEvent _normalizePageEvent(PageNetworkEvent event) {
    if (event.phase == PageNetworkPhase.request) return event;
    return PageNetworkEvent(
      sessionId: event.sessionId,
      page: event.page,
      id: event.id,
      phase: event.phase,
      timestamp: event.timestamp,
      method: event.method,
      url: event.url,
      headers: const <String, String>{},
      responseHeaders: event.headers,
      body: event.body,
      responseBody: event.responseBody,
      statusCode: event.statusCode,
      duration: event.duration,
      size: event.size,
      message: event.message,
    );
  }

  static PageNetworkEvent _mergePageEvent(
    PageNetworkEvent request,
    PageNetworkEvent update,
  ) {
    return PageNetworkEvent(
      sessionId:
          update.sessionId.isEmpty ? request.sessionId : update.sessionId,
      page: request.page,
      id: request.id,
      phase: update.phase == PageNetworkPhase.body
          ? request.phase
          : update.phase,
      timestamp: request.timestamp,
      method: request.method ?? update.method,
      url: request.url ?? update.url,
      headers: request.headers,
      responseHeaders:
          update.headers.isNotEmpty ? update.headers : request.responseHeaders,
      body: request.body ?? update.body,
      responseBody: update.responseBody ?? request.responseBody,
      statusCode: update.statusCode ?? request.statusCode,
      duration: update.duration ?? request.duration,
      size: update.size ?? request.size,
      message: update.message ?? request.message,
    );
  }

  /// Newest first.
  List<PageNetworkEvent> get _pageRequestList {
    final list = _pageRequests.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  }

  void _clearPageRequests() {
    if (_pageRequests.isEmpty) return;
    setState(_pageRequests.clear);
  }

  /// Replays a page-script request through the native engine, keeping its
  /// method, caller headers and body. The fingerprint is applied natively.
  Future<void> _replayPageEvent(PageNetworkEvent source) async {
    if (_busy) return;
    final uri = Uri.tryParse(source.url ?? '');
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      _snack('This row has no replayable URL');
      return;
    }
    final currentHeaders = _headersFor(uri);
    final headers = <OrderedHeader>[
      if (_uaOverride != null) OrderedHeader('User-Agent', _uaOverride!),
      for (final entry in currentHeaders.entries)
        OrderedHeader(entry.key, entry.value),
      // Settings win: they describe the identity the user asked for now.
      for (final entry in source.headers.entries)
        if (!currentHeaders.containsKey(entry.key))
          OrderedHeader(entry.key, entry.value),
    ];
    final body = source.body == null
        ? null
        : Uint8List.fromList(utf8.encode(source.body!));

    setState(() {
      _busy = true;
      _captureError = null;
    });
    try {
      final capture = await _session.capture(
        uri,
        method: source.method ?? 'GET',
        headers: headers,
        body: body,
      );
      if (!mounted) return;
      setState(() {
        _capture = capture;
        _tabs.index = 1;
      });
      _snack('Replayed through the native engine');
    } on BrowserHttpException catch (error) {
      if (mounted) {
        setState(() => _captureError = '${error.code}: ${error.message}');
      }
    } on Object catch (error) {
      if (mounted) setState(() => _captureError = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Re-sends a captured exchange with the current header settings.
  Future<void> _replayCapture(CapturedExchange source) async {
    if (_busy) return;
    final headers = <OrderedHeader>[
      if (_uaOverride != null) OrderedHeader('User-Agent', _uaOverride!),
      for (final entry in _headersFor(source.uri).entries)
        OrderedHeader(entry.key, entry.value),
    ];
    setState(() {
      _busy = true;
      _captureError = null;
    });
    try {
      final capture = await _session.capture(
        source.uri,
        method: source.method,
        headers: headers,
        body: source.requestBody,
      );
      if (mounted) setState(() => _capture = capture);
    } on BrowserHttpException catch (error) {
      if (mounted) {
        setState(() => _captureError = '${error.code}: ${error.message}');
      }
    } on Object catch (error) {
      if (mounted) setState(() => _captureError = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _copyText(String text, String label) {
    if (text.isEmpty) {
      _snack('Nothing to copy');
      return;
    }
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    _snack('$label copied');
  }

  // ---------------------------------------------------------------------------
  // Page request detail
  // ---------------------------------------------------------------------------

  void _openPageDetail(PageNetworkEvent event) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: AppColors.ink.withAlpha(88),
      builder: (_) => _PageRequestDetail(
        event: event,
        onReplay: () {
          Navigator.of(context).pop();
          unawaited(_replayPageEvent(event));
        },
      ),
    );
  }

  @override
  void dispose() {
    _erudaVerifyTimer?.cancel();
    _debugSizeTimer?.cancel();
    _urlFocus.removeListener(_onUrlFocusChanged);
    unawaited(_logSubscription.cancel());
    unawaited(_pageSubscription.cancel());
    unawaited(_navigationSubscription.cancel());
    _browser.removeListener(_onBrowserChanged);
    _browser.dispose();
    unawaited(_session.close());
    _tabs.dispose();
    _urlController.dispose();
    _cookieController.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _buildToolbar(),
            _buildContextBar(),
            Expanded(child: _buildSplitBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(6, 2, 8, 8),
      child: Row(
        children: <Widget>[
          _toolButton(
            Icons.chevron_left_rounded,
            'Back',
            _browser.canGoBack ? () => unawaited(_browser.goBack()) : null,
            size: 24,
          ),
          _toolButton(
            Icons.chevron_right_rounded,
            'Forward',
            _browser.canGoForward ? () => unawaited(_browser.goForward()) : null,
            size: 24,
          ),
          Expanded(child: _buildAddressField()),
          _toolButton(
            Icons.tune_rounded,
            'Settings',
            () => unawaited(_openSettings()),
          ),
          _buildErudaButton(),
        ],
      ),
    );
  }

  Widget _toolButton(
    IconData icon,
    String tooltip,
    VoidCallback? onTap, {
    bool active = false,
    double size = 21,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active ? AppColors.ink : Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onTap,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Icon(
              icon,
              size: size,
              color: onTap == null
                  ? AppColors.faint.withAlpha(150)
                  : active
                      ? AppColors.onInk
                      : AppColors.ink,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErudaButton() {
    if (_erudaBusy) {
      return const SizedBox(
        width: 34,
        height: 34,
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.ink,
            ),
          ),
        ),
      );
    }
    return _toolButton(
      Icons.terminal_rounded,
      _erudaOpen ? 'Close console' : 'Debug console, stays open across pages',
      () => unawaited(_toggleEruda()),
      active: _erudaOpen,
      size: 19,
    );
  }

  Widget _buildAddressField() {
    return Container(
      height: 38,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      padding: const EdgeInsets.only(left: 11, right: 3),
      decoration: BoxDecoration(
        color: AppColors.wash,
        borderRadius: BorderRadius.circular(19),
      ),
      child: Row(
        children: <Widget>[
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _urlController,
            builder: (context, value, _) =>
                _addressLeading(value.text.trim()),
          ),
          const SizedBox(width: 7),
          Expanded(child: _buildUrlEditor()),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _urlController,
            builder: (context, value, _) {
              if (value.text.isEmpty) return const SizedBox.shrink();
              return _pillAction(Icons.close_rounded, 'Clear', _clearUrl);
            },
          ),
          _urlFocused
              ? _pillAction(Icons.arrow_forward_rounded, 'Go', () {
                  _urlFocus.unfocus();
                  unawaited(_go());
                })
              : _pillAction(
                  Icons.refresh_rounded,
                  'Reload',
                  () => unawaited(_reload()),
                ),
        ],
      ),
    );
  }

  Widget _addressLeading(String text) {
    if (text.isEmpty) {
      return const Icon(
        Icons.search_rounded,
        size: 14,
        color: AppColors.faint,
      );
    }
    if (text.startsWith('https://')) {
      return const Icon(
        Icons.lock_outline_rounded,
        size: 12,
        color: AppColors.muted,
      );
    }
    return const Icon(
      Icons.public_rounded,
      size: 13,
      color: AppColors.muted,
    );
  }

  void _clearUrl() {
    _urlController.clear();
    _urlFocus.requestFocus();
  }

  Widget _buildUrlEditor() {
    return TextField(
      controller: _urlController,
      focusNode: _urlFocus,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.go,
      autocorrect: false,
      enableSuggestions: false,
      style: const TextStyle(fontSize: 13, color: AppColors.ink),
      cursorColor: AppColors.ink,
      decoration: const InputDecoration(
        isCollapsed: true,
        border: InputBorder.none,
        hintText: 'Search or enter address',
        hintStyle: TextStyle(fontSize: 13, color: AppColors.faint),
      ),
      onSubmitted: (_) => unawaited(_go()),
    );
  }

  Widget _pillAction(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: SizedBox(
            width: 27,
            height: 27,
            child: Icon(icon, size: 15, color: AppColors.ink),
          ),
        ),
      ),
    );
  }

  Widget _buildContextBar() {
    final fingerprint = _capture?.response.fingerprint;
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(
        color: Color(0xFFF6F6F1),
        border: Border(
          top: BorderSide(color: AppColors.line),
          bottom: BorderSide(color: AppColors.line),
        ),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: AppColors.signal,
              shape: BoxShape.circle,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: AppColors.signal.withAlpha(80),
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Engine ready · ${_profileLabel ?? 'native profile'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 9.5,
                color: AppColors.muted,
                letterSpacing: 0.1,
              ),
            ),
          ),
          Text(
            fingerprint == null
                ? 'WKWebView + wreq'
                : '${fingerprint.tlsVersion} · ${fingerprint.alpn}',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 9,
              color: AppColors.faint,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Web area + start page
  // ---------------------------------------------------------------------------

  Widget _buildSplitBody() {
    const handleHeight = 15.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = math.max(
          0.0,
          constraints.maxHeight - (_panelVisible ? handleHeight : 0),
        );
        final panelHeight = _panelVisible
            ? (available * _panelFraction)
                .clamp(0.0, available * 0.85)
                .toDouble()
            : 0.0;
        final webHeight = math.max(0.0, available - panelHeight);
        return Column(
          children: <Widget>[
            SizedBox(height: webHeight, child: _buildWebArea()),
            if (_panelVisible) ...<Widget>[
              _buildDragHandle(available),
              SizedBox(height: panelHeight, child: _buildPanel()),
            ],
          ],
        );
      },
    );
  }

  Widget _buildWebArea() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final top = (height * (1 - _erudaSize / 100) - _erudaPillHeight / 2)
            .clamp(0.0, math.max(0.0, height - _erudaPillHeight))
            .toDouble();
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            BrowserView(controller: _browser),
            if (!_started && !_hasDocument)
              _StartPage(onOpen: _openShortcut),
            if (_erudaOpen)
              Positioned(
                left: 0,
                right: 0,
                top: top,
                height: _erudaPillHeight,
                child: Center(child: _buildErudaPill(height)),
              ),
          ],
        );
      },
    );
  }

  Widget _buildDragHandle(double available) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (details) {
        if (available <= 0) return;
        setState(() {
          _panelFraction =
              (_panelFraction - details.delta.dy / available)
                  .clamp(0.15, 0.8)
                  .toDouble();
        });
      },
      child: SizedBox(
        height: 15,
        child: Center(
          child: Container(
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFCFD1C6),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Panel
  // ---------------------------------------------------------------------------

  Widget _buildPanel() {
    return Container(
      color: AppColors.surface,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 8, 6),
            child: Row(
              children: <Widget>[
                Expanded(child: _buildSegmented()),
                const SizedBox(width: 4),
                _toolButton(
                  Icons.keyboard_arrow_down_rounded,
                  'Hide info panel',
                  () => _setPanelVisible(false),
                  size: 20,
                ),
              ],
            ),
          ),
          Expanded(
            child: AnimatedBuilder(
              animation: _tabs,
              builder: (context, _) {
                return IndexedStack(
                  index: _tabs.index,
                  children: <Widget>[
                    _buildWebViewTab(),
                    _buildEngineTab(),
                    _buildPageTab(),
                    _buildLogTab(),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSegmented() {
    return AnimatedBuilder(
      animation: _tabs,
      builder: (context, _) {
        return Container(
          height: 38,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: AppColors.wash,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _segItem(0, 'WebView', null),
              _segItem(1, 'Engine', null),
              _segItem(2, 'Page', _pageRequests.length),
              _segItem(3, 'Log', _events.length),
            ],
          ),
        );
      },
    );
  }

  Widget _segItem(int index, String label, int? count) {
    final selected = _tabs.index == index;
    return Expanded(
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: () => _tabs.index = index,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: selected ? AppColors.card : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              boxShadow: selected
                  ? const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x140E0F0E),
                        blurRadius: 2,
                        offset: Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      letterSpacing: 0.1,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? AppColors.ink : AppColors.muted,
                    ),
                  ),
                ),
                if (count != null && count > 0) ...<Widget>[
                  const SizedBox(width: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: selected ? AppColors.signal : AppColors.wash,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      count > 99 ? '99+' : '$count',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 9.5,
                        color: selected ? AppColors.ink : AppColors.faint,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // WebView tab
  // ---------------------------------------------------------------------------

  Widget _buildWebViewTab() {
    final resources = _browser.resourceTimings;
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 18),
      children: <Widget>[
        _kv('Title', _browser.title ?? '—'),
        _kv('URL', _browser.url ?? '—', mono: true),
        _kv('Status', _browser.statusCode == null
            ? '—'
            : '${_browser.statusCode} · OK'),
        _kv(
          'History',
          'back=${_browser.canGoBack} · forward=${_browser.canGoForward}',
          mono: true,
        ),
        _kv('User-Agent', _uaPresets[_uaIndex].label),
        const SizedBox(height: 10),
        const _Notice(
          'WebKit does not expose subresource headers or bodies. Page shows '
          'fetch/XHR/beacon calls with POST bodies; Engine replays the URL '
          'through the native fingerprint engine.',
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            const Text(
              'Resource timings',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 6),
            Text(
              '${resources.length}',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 9,
                color: AppColors.faint,
              ),
            ),
            const Spacer(),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => unawaited(_browser.refreshResources()),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text(
                  'Refresh',
                  style: TextStyle(fontSize: 10, color: AppColors.muted),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (resources.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text(
              'No PerformanceResourceTiming entries yet.',
              style: TextStyle(fontSize: 10.5, color: AppColors.faint),
            ),
          )
        else
          for (final resource in resources)
            _ResourceRow(
              type: resource.initiatorType.isEmpty
                  ? 'resource'
                  : resource.initiatorType,
              url: resource.url,
              duration: resource.duration,
              transferSize: resource.transferSize,
              bodySize: resource.encodedBodySize,
            ),
        const SizedBox(height: 12),
        _kv(
          'Shared jar',
          '${_browser.session.profile.id} · persistent WKWebsiteDataStore',
          mono: true,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Engine tab
  // ---------------------------------------------------------------------------

  Widget _buildEngineTab() {
    final error = _captureError;
    final capture = _capture;

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 20),
      children: <Widget>[
        Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                'Native engine capture',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
              ),
            ),
            _SmallButton(
              label: _busy ? 'Capturing…' : 'Capture',
              icon: Icons.radar_rounded,
              onTap: _busy ? null : () => unawaited(_captureCurrent()),
            ),
          ],
        ),
        const SizedBox(height: 2),
        const Text(
          'Same cookie jar as the WebView. UA, Referer and Cookie from '
          'settings are applied to the capture request.',
          style: TextStyle(
            fontSize: 9.5,
            height: 1.5,
            color: AppColors.muted,
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              error,
              style: const TextStyle(
                fontSize: 10.5,
                color: AppColors.danger,
              ),
            ),
          ),
        if (capture == null) ...<Widget>[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
            decoration: BoxDecoration(
              color: AppColors.card,
              border: Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: <Widget>[
                const Icon(
                  Icons.radar_rounded,
                  size: 26,
                  color: AppColors.faint,
                ),
                const SizedBox(height: 8),
                const Text(
                  'No capture yet',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                const Text(
                  'Load a page, then tap Capture to replay the URL through '
                  'the native engine.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 9.5,
                    height: 1.5,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: 10),
                _SmallButton(
                  label: 'Capture URL',
                  icon: Icons.radar_rounded,
                  onTap: _busy
                      ? null
                      : () => unawaited(_captureCurrent()),
                ),
              ],
            ),
          ),
        ] else ...<Widget>[
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              _Stat(
                label: 'Status',
                value: '${capture.response.statusCode}',
              ),
              const SizedBox(width: 7),
              _Stat(
                label: 'Elapsed',
                value: '${capture.elapsed.inMilliseconds}',
                unit: 'ms',
              ),
              const SizedBox(width: 7),
              _Stat(
                label: 'Body',
                value: _kb(capture.responseBodyLength),
                unit: 'KB',
              ),
            ],
          ),
          const SizedBox(height: 9),
          _buildIdentityCard(capture),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                _ActionChip(
                  label: 'cURL',
                  icon: Icons.terminal_rounded,
                  onTap: () => _copyText(buildCurl(capture), 'cURL'),
                ),
                const SizedBox(width: 6),
                _ActionChip(
                  label: 'URL',
                  icon: Icons.link_rounded,
                  onTap: () =>
                      _copyText(capture.uri.toString(), 'URL'),
                ),
                const SizedBox(width: 6),
                _ActionChip(
                  label: 'Request headers',
                  icon: Icons.list_alt_rounded,
                  onTap: () => _copyText(
                    headerBlock(capture.requestHeaders),
                    'Headers',
                  ),
                ),
                if (capture.requestBody != null &&
                    capture.requestBody!.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 6),
                  _ActionChip(
                    label: 'Request body',
                    icon: Icons.upload_rounded,
                    onTap: () => _copyText(
                      utf8.decode(
                        capture.requestBody!,
                        allowMalformed: true,
                      ),
                      'Request body',
                    ),
                  ),
                ],
                const SizedBox(width: 6),
                _ActionChip(
                  label: 'Response body',
                  icon: Icons.download_rounded,
                  onTap: () => _copyText(
                    formatBodyPreview(capture.response),
                    'Response body',
                  ),
                ),
                const SizedBox(width: 6),
                _ActionChip(
                  label: 'Replay',
                  icon: Icons.replay_rounded,
                  onTap: _busy
                      ? null
                      : () => unawaited(_replayCapture(capture)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const _SectionLabel('Request headers — wire order'),
          for (var i = 0; i < capture.requestHeaders.length; i++)
            _HeaderLine(
              index: '${i + 1}'.padLeft(2, '0'),
              name: capture.requestHeaders[i].name,
              value: capture.requestHeaders[i].value,
            ),
          if (capture.requestHeaders.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text(
                '(no caller headers; profile defaults are applied natively)',
                style: TextStyle(fontSize: 9.5, color: AppColors.faint),
              ),
            ),
          const SizedBox(height: 12),
          _SectionLabel('Response headers · ${capture.response.headers.length}'),
          for (var i = 0; i < capture.response.headers.length; i++)
            _HeaderLine(
              index: '${i + 1}'.padLeft(2, '0'),
              name: capture.response.headers[i].name,
              value: capture.response.headers[i].value,
            ),
          const SizedBox(height: 12),
          const _SectionLabel('Body preview'),
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.fromLTRB(11, 9, 11, 10),
            decoration: BoxDecoration(
              color: AppColors.dark,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              formatBodyPreview(capture.response),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 9,
                height: 1.55,
                color: AppColors.darkText,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildIdentityCard(CapturedExchange capture) {
    final profile = capture.profile;
    final fingerprint = capture.response.fingerprint;
    final hints = profile.clientHints.keys.take(4).toList();

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
      decoration: BoxDecoration(
        color: AppColors.dark,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 5,
                height: 5,
                decoration: const BoxDecoration(
                  color: AppColors.signal,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                'NATIVE PROFILE',
                style: TextStyle(
                  fontSize: 8,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.3,
                  color: AppColors.darkMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _identityLine('profile', profile.profileId),
          _identityLine('family', profile.family),
          if (fingerprint != null) ...<Widget>[
            _identityLine('JA4', fingerprint.ja4),
            _identityLine('JA3', fingerprint.ja3),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: <Widget>[
              if (fingerprint != null) ...<Widget>[
                _DarkChip(fingerprint.tlsVersion),
                _DarkChip(fingerprint.alpn),
                if (fingerprint.h2Settings.isNotEmpty)
                  _DarkChip(_shorten(fingerprint.h2Settings, 18)),
              ] else
                const _DarkChip('TLS / H2 applied natively'),
              for (final hint in hints) _DarkChip(_shorten(hint, 20)),
              if (hints.isEmpty) const _DarkChip('UA applied'),
            ],
          ),
          if (fingerprint == null) ...<Widget>[
            const SizedBox(height: 7),
            const Text(
              'JA3 / JA4 export is not wired in this build; the identity is '
              'still applied by the native profile.',
              style: TextStyle(
                fontSize: 8.5,
                height: 1.45,
                color: AppColors.darkMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _identityLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 46,
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 8.5,
                color: AppColors.darkMuted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 9.5,
                color: Color(0xFFDCE0D3),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Page tab
  // ---------------------------------------------------------------------------

  Widget _buildPageTab() {
    final requests = _pageRequestList;
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 8, 4),
          child: Row(
            children: <Widget>[
              const Text(
                'Page script requests',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 6),
              Text(
                '${requests.length}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9,
                  color: AppColors.faint,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Clear',
                onPressed: requests.isEmpty ? null : _clearPageRequests,
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  size: 17,
                  color: AppColors.faint,
                ),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints:
                    const BoxConstraints.tightFor(width: 30, height: 30),
              ),
            ],
          ),
        ),
        Expanded(
          child: requests.isEmpty
              ? ListView(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
                  children: const <Widget>[
                    _EmptyRequests(),
                  ],
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  itemCount: requests.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return const _MutedLine(
                        'Observed by the injected page script. Headers are '
                        'caller-set; WebKit adds Cookie and Sec-Fetch-* — use '
                        'Engine for the true wire packet.',
                      );
                    }
                    final event = requests[index - 1];
                    return _PageRequestRow(
                      event: event,
                      onTap: () => _openPageDetail(event),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Log tab
  // ---------------------------------------------------------------------------

  Widget _buildLogTab() {
    final warn = _events
        .where((event) => event.level == RequestLogLevel.warn)
        .length;
    final errors = _events
        .where((event) => event.level == RequestLogLevel.error)
        .length;
    final filtered = switch (_logFilter) {
      1 => _events
          .where((event) => event.level == RequestLogLevel.warn)
          .toList(),
      2 => _events
          .where((event) => event.level == RequestLogLevel.error)
          .toList(),
      _ => _events,
    };

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 8, 4),
          child: Row(
            children: <Widget>[
              _FilterChip(
                label: 'All ${_events.length}',
                selected: _logFilter == 0,
                onTap: () => setState(() => _logFilter = 0),
              ),
              const SizedBox(width: 6),
              _FilterChip(
                label: 'Warn $warn',
                selected: _logFilter == 1,
                onTap: () => setState(() => _logFilter = 1),
              ),
              const SizedBox(width: 6),
              _FilterChip(
                label: 'Error $errors',
                selected: _logFilter == 2,
                onTap: () => setState(() => _logFilter = 2),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Clear log',
                onPressed: _events.isEmpty
                    ? null
                    : () => setState(_events.clear),
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  size: 17,
                  color: AppColors.faint,
                ),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints:
                    const BoxConstraints.tightFor(width: 30, height: 30),
              ),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? const Center(
                  child: Text(
                    'No request events yet.',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: AppColors.faint,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) =>
                      _LogRow(event: filtered[index]),
                ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Eruda overlay
  // ---------------------------------------------------------------------------

  Future<void> _toggleEruda() async {
    if (_erudaBusy) return;

    if (_erudaOpen) {
      setState(() {
        _erudaOpen = false;
        if (_didHidePanelForEruda && !_panelVisible) _panelVisible = true;
        _didHidePanelForEruda = false;
      });
      _erudaVerifyTimer?.cancel();
      _debugSizeTimer?.cancel();
      await _browser.setDebugOverlay(enabled: false);
      return;
    }

    if (!_hasDocument) {
      _snack('Open a page first');
      return;
    }

    setState(() => _erudaBusy = true);
    try {
      final source = await _loadErudaSource();
      final shown = await _browser.setDebugOverlay(
        enabled: true,
        source: source,
        displaySize: _erudaSize,
      );
      if (!mounted) return;
      setState(() {
        _erudaOpen = true;
        _didHidePanelForEruda = _panelVisible;
        _panelVisible = false;
      });
      // Registered as a native user script, so every later document gets the
      // console back. A page that has not finished loading shows it on commit.
      if (!shown) _snack('Console appears when this page finishes loading');
    } on Object catch (error) {
      if (mounted) _snack('Eruda failed: $error');
    } finally {
      if (mounted) setState(() => _erudaBusy = false);
    }
  }

  /// Prefers the bundle shipped as an asset (fetched at CI build time), then
  /// falls back to the CDN through the native transport. Cached in memory.
  Future<String> _loadErudaSource() async {
    final cached = _erudaSource;
    if (cached != null) return cached;

    try {
      final bundled = await rootBundle.loadString('assets/eruda/eruda.js');
      if (_looksLikeEruda(bundled)) {
        _erudaSource = bundled;
        return bundled;
      }
    } on Object {
      // Asset absent in local builds; fall through to the network.
    }

    Object? lastError;
    for (final url in _erudaUrls) {
      try {
        final response = await _session
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 25));
        final source = utf8.decode(response.body, allowMalformed: true);
        if (response.statusCode == 200 && _looksLikeEruda(source)) {
          _erudaSource = source;
          return source;
        }
        lastError = 'HTTP ${response.statusCode} from $url';
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw StateError('could not load eruda.js ($lastError)');
  }

  bool _looksLikeEruda(String source) =>
      source.length > 20000 && !source.trimLeft().startsWith('<');

  /// Safety net for documents the user script cannot reach: a same-document
  /// route change, a page that replaced the JS context, or a load that started
  /// before the console was switched on.
  void _scheduleErudaVerify() {
    _erudaVerifyTimer?.cancel();
    _erudaVerifyTimer = Timer(const Duration(milliseconds: 600), () {
      unawaited(_verifyEruda());
    });
  }

  Future<void> _verifyEruda() async {
    if (!_erudaOpen || !mounted) return;
    Object? present;
    try {
      present = await _browser.evaluate('!!(window.eruda && window.__bhEruda)');
    } on Object {
      // Mid-navigation: the next URL change retries.
      return;
    }
    final source = _erudaSource;
    if (!mounted || present == true || source == null) return;
    await _browser.setDebugOverlay(
      enabled: true,
      source: source,
      displaySize: _erudaSize,
    );
  }

  void _applyErudaSize(double value) {
    final size = value.clamp(40.0, 100.0).toDouble();
    if ((size - _erudaSize).abs() < 0.01) return;
    setState(() => _erudaSize = size);
    _evalQuiet(
      'try{eruda.get().config.set("displaySize", '
      '${size.toStringAsFixed(1)})}catch(e){}',
    );
    // The registered script decides the size of the *next* document; rewrite it
    // once the drag settles instead of on every pointer tick.
    _debugSizeTimer?.cancel();
    _debugSizeTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_browser.setDebugDisplaySize(size));
    });
  }

  void _evalQuiet(String script) {
    unawaited(_browser.evaluate(script).catchError((Object _) => null));
  }

  /// Split control between the page and the console: grip on the left, the
  /// share in the middle, close on the right. Spacers keep the three evenly
  /// distributed instead of hugging the left edge of the bar.
  Widget _buildErudaPill(double viewHeight) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (details) {
        if (viewHeight <= 0) return;
        _applyErudaSize(_erudaSize - details.delta.dy / viewHeight * 100);
      },
      child: Container(
        width: 168,
        height: _erudaPillHeight,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(248),
          border: Border.all(color: AppColors.line2),
          borderRadius: BorderRadius.circular(15),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x330E0F0E),
              blurRadius: 14,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: <Widget>[
            const Icon(
              Icons.drag_handle_rounded,
              size: 15,
              color: AppColors.muted,
            ),
            const Spacer(),
            Text(
              '${_erudaSize.round()}%',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: AppColors.ink2,
              ),
            ),
            const Spacer(),
            Tooltip(
              message: 'Close console',
              child: GestureDetector(
                onTap: () => unawaited(_toggleEruda()),
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: const BoxDecoration(
                    color: AppColors.ink,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    size: 11,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Small helpers
  // ---------------------------------------------------------------------------

  static Widget _kv(String label, String value, {bool mono = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4.5),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFFECEDE4)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 78,
            child: Text(
              label,
              style: const TextStyle(fontSize: 10, color: AppColors.muted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 11,
                height: 1.35,
                color: AppColors.ink2,
                fontFamily: mono ? 'monospace' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _kb(int bytes) =>
      (bytes / 1024).toStringAsFixed(bytes < 10240 ? 1 : 0);

  static String _shorten(String value, int max) =>
      value.length <= max ? value : '${value.substring(0, max)}…';
}

// -----------------------------------------------------------------------------
// Widgets
// -----------------------------------------------------------------------------

class _Notice extends StatelessWidget {
  const _Notice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppColors.signalWash,
        border: Border.all(color: AppColors.signalLine),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.info_outline_rounded,
            size: 13,
            color: Color(0xFF6E7A3C),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 9,
                height: 1.5,
                color: Color(0xFF4C5430),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResourceRow extends StatelessWidget {
  const _ResourceRow({
    required this.type,
    required this.url,
    required this.duration,
    required this.transferSize,
    required this.bodySize,
  });

  final String type;
  final String url;
  final double duration;
  final int? transferSize;
  final int? bodySize;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(9, 7, 9, 7),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                type.toUpperCase(),
                style: const TextStyle(
                  fontSize: 8,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: AppColors.muted,
                ),
              ),
              const Spacer(),
              Text(
                '${duration.toStringAsFixed(1)} ms',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9,
                  color: AppColors.ink,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 9,
              color: AppColors.ink2,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'transfer ${transferSize ?? 0} B · body ${bodySize ?? 0} B',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 8,
              color: AppColors.faint,
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.unit});

  final String label;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(9, 7, 9, 7),
        decoration: BoxDecoration(
          color: AppColors.card,
          border: Border.all(color: AppColors.line),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              label.toUpperCase(),
              style: const TextStyle(
                fontSize: 8,
                letterSpacing: 0.8,
                color: AppColors.faint,
              ),
            ),
            const SizedBox(height: 2),
            Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: value,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                      color: AppColors.ink,
                    ),
                  ),
                  if (unit != null)
                    TextSpan(
                      text: ' $unit',
                      style: const TextStyle(
                        fontSize: 9,
                        color: AppColors.muted,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 8.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
          color: AppColors.faint,
        ),
      );
}

class _HeaderLine extends StatelessWidget {
  const _HeaderLine({
    required this.index,
    required this.name,
    required this.value,
  });

  final String index;
  final String name;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 16,
            child: Text(
              index,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 8.5,
                color: AppColors.faint,
              ),
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: '$name: ',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppColors.ink,
                    ),
                  ),
                  TextSpan(
                    text: value,
                    style: const TextStyle(color: AppColors.ink2),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 9,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DarkChip extends StatelessWidget {
  const _DarkChip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2.5),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white.withAlpha(40)),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 8,
          letterSpacing: 0.2,
          color: Color(0xFFD8DCCD),
        ),
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: enabled ? AppColors.ink : AppColors.ink.withAlpha(90),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 12, color: AppColors.onInk),
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.onInk,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? AppColors.ink : AppColors.card,
          border: Border.all(
            color: selected ? AppColors.ink : AppColors.line,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 9.5,
            color: selected ? AppColors.onInk : AppColors.muted,
          ),
        ),
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.event});

  final RequestLogEvent event;

  @override
  Widget build(BuildContext context) {
    final isError = event.level == RequestLogLevel.error;
    final isWarn = event.level == RequestLogLevel.warn;
    final color = isError
        ? AppColors.danger
        : isWarn
            ? AppColors.warn
            : null;

    final phase = switch (event.phase) {
      RequestLogPhase.start => 'SEND',
      RequestLogPhase.response => 'RECV',
      RequestLogPhase.redirect => 'RDIR',
      RequestLogPhase.challengeDetected => 'CHAL',
      RequestLogPhase.challengeResolved => 'OK',
      RequestLogPhase.retry => 'RETRY',
      RequestLogPhase.error => 'ERR',
      RequestLogPhase.cancelled => 'CANCEL',
    };

    final time = '${event.timestamp.hour.toString().padLeft(2, '0')}:'
        '${event.timestamp.minute.toString().padLeft(2, '0')}:'
        '${event.timestamp.second.toString().padLeft(2, '0')}';
    final right = <String>[
      if (event.statusCode != null) '${event.statusCode}',
      if (event.elapsed != null) '${event.elapsed!.inMilliseconds}ms',
      if (event.statusCode == null && event.elapsed == null)
        event.errorCode ?? '',
    ].where((part) => part.isNotEmpty).join(' · ');

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFECEDE4))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 40,
            child: Text(
              time,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 8.5,
                color: AppColors.faint,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
            decoration: BoxDecoration(
              color: isError
                  ? AppColors.danger.withAlpha(20)
                  : isWarn
                      ? AppColors.warn.withAlpha(24)
                      : event.phase == RequestLogPhase.response
                          ? AppColors.signal.withAlpha(70)
                          : AppColors.wash,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              phase,
              style: TextStyle(
                fontSize: 7.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: color ?? AppColors.muted,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${event.method ?? ''} ${event.uri ?? ''}'.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 8.5,
                    color: color ?? AppColors.ink2,
                  ),
                ),
                if (event.message != null && event.message!.isNotEmpty)
                  Text(
                    '${event.errorCode ?? ''} ${event.message}'.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 8,
                      color: color ?? AppColors.faint,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Text(
            right,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 8.5,
              color: color ?? AppColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

Widget _statusBadge(int? status) {
  final color = _statusTint(status);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: color.withAlpha(18),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      status == null ? '—' : '$status',
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: 9.5,
        fontWeight: FontWeight.w700,
        color: color,
      ),
    ),
  );
}

Widget _detailRow(String label, String value) {
  return Container(
    padding: const EdgeInsets.symmetric(vertical: 4.5),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Color(0xFFECEDE4))),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 70,
          child: Text(
            label,
            style: const TextStyle(fontSize: 10, color: AppColors.muted),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 10,
              height: 1.4,
              color: AppColors.ink2,
            ),
          ),
        ),
      ],
    ),
  );
}

Widget _bodyBlock(String text) {
  return Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 4),
    padding: const EdgeInsets.fromLTRB(11, 9, 11, 10),
    decoration: BoxDecoration(
      color: AppColors.dark,
      borderRadius: BorderRadius.circular(12),
    ),
    child: SelectableText(
      text,
      style: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 9,
        height: 1.55,
        color: AppColors.darkText,
      ),
    ),
  );
}

/// Bottom sheet for one observed page request: copy actions with inline
/// "copied" feedback (a SnackBar would sit behind the sheet) and a native
/// replay button.
class _PageRequestDetail extends StatefulWidget {
  const _PageRequestDetail({required this.event, required this.onReplay});

  final PageNetworkEvent event;
  final VoidCallback onReplay;

  @override
  State<_PageRequestDetail> createState() => _PageRequestDetailState();
}

class _PageRequestDetailState extends State<_PageRequestDetail> {
  String? _copied;
  Timer? _copiedTimer;

  Future<void> _copy(String text, String label) async {
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _copiedTimer?.cancel();
    setState(() => _copied = label);
    _copiedTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = null);
    });
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final body = event.body;
    final responseBody = event.responseBody;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      minChildSize: 0.4,
      maxChildSize: 0.94,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: Column(
            children: <Widget>[
              const SizedBox(height: 8),
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.line2,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 10, 4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '${event.method ?? 'GET'} request',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                    AnimatedOpacity(
                      opacity: _copied == null ? 0 : 1,
                      duration: const Duration(milliseconds: 160),
                      child: Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.signal,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${_copied ?? ''} copied',
                          style: const TextStyle(
                            fontSize: 8,
                            fontWeight: FontWeight.w700,
                            color: AppColors.ink,
                          ),
                        ),
                      ),
                    ),
                    _statusBadge(event.statusCode),
                    const SizedBox(width: 2),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: AppColors.faint,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: SelectableText(
                  event.url ?? '',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9.5,
                    height: 1.4,
                    color: AppColors.muted,
                  ),
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: <Widget>[
                    _ActionChip(
                      label: 'cURL',
                      icon: Icons.terminal_rounded,
                      onTap: () => _copy(buildPageCurl(event), 'cURL'),
                    ),
                    const SizedBox(width: 6),
                    _ActionChip(
                      label: 'URL',
                      icon: Icons.link_rounded,
                      onTap: () => _copy(event.url ?? '', 'URL'),
                    ),
                    const SizedBox(width: 6),
                    _ActionChip(
                      label: 'Request headers',
                      icon: Icons.list_alt_rounded,
                      onTap: () => _copy(mapBlock(event.headers), 'Headers'),
                    ),
                    if (body != null && body.isNotEmpty) ...<Widget>[
                      const SizedBox(width: 6),
                      _ActionChip(
                        label: 'Request body',
                        icon: Icons.upload_rounded,
                        onTap: () => _copy(body, 'Body'),
                      ),
                    ],
                    if (responseBody != null && responseBody.isNotEmpty) ...<Widget>[
                      const SizedBox(width: 6),
                      _ActionChip(
                        label: 'Response body',
                        icon: Icons.download_rounded,
                        onTap: () => _copy(responseBody, 'Response'),
                      ),
                    ],
                    const SizedBox(width: 6),
                    _ActionChip(
                      label: 'Replay natively',
                      icon: Icons.replay_rounded,
                      onTap: widget.onReplay,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                  children: <Widget>[
                    _detailRow('Status', '${event.statusCode ?? '—'}'),
                    _detailRow(
                      'Duration',
                      event.duration == null ? '—' : '${event.duration} ms',
                    ),
                    _detailRow(
                      'Size',
                      event.size == null ? '—' : '${event.size} bytes',
                    ),
                    if (event.message != null)
                      _detailRow('Error', event.message!),
                    const SizedBox(height: 14),
                    _SectionLabel(
                      'Request headers · ${event.headers.length}',
                    ),
                    if (event.headers.isEmpty)
                      const _MutedLine(
                        'The page set no headers; WebKit adds Cookie, '
                        'Sec-Fetch-* and the rest natively.',
                      )
                    else
                      for (var i = 0; i < event.headers.length; i++)
                        _HeaderLine(
                          index: '${i + 1}'.padLeft(2, '0'),
                          name: event.headers.keys.elementAt(i),
                          value: event.headers.values.elementAt(i),
                        ),
                    const SizedBox(height: 14),
                    const _SectionLabel('Request body'),
                    if (body == null || body.isEmpty)
                      const _MutedLine('No request body.')
                    else
                      _bodyBlock(body),
                    const SizedBox(height: 14),
                    _SectionLabel(
                      'Response headers · ${event.responseHeaders.length}',
                    ),
                    if (event.responseHeaders.isEmpty)
                      const _MutedLine(
                        'Not readable from the page — likely cross-origin '
                        'or the response has not completed.',
                      )
                    else
                      for (var i = 0;
                          i < event.responseHeaders.length;
                          i++)
                        _HeaderLine(
                          index: '${i + 1}'.padLeft(2, '0'),
                          name: event.responseHeaders.keys.elementAt(i),
                          value: event.responseHeaders.values.elementAt(i),
                        ),
                    const SizedBox(height: 14),
                    const _SectionLabel('Response body'),
                    if (responseBody == null || responseBody.isEmpty)
                      const _MutedLine(
                        'Not captured — binary, too large, or unreadable.',
                      )
                    else
                      _bodyBlock(responseBody),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

Color _statusTint(int? status) {
  if (status == null) return AppColors.faint;
  if (status >= 500) return AppColors.danger;
  if (status >= 400) return AppColors.warn;
  if (status >= 300) return AppColors.muted;
  return const Color(0xFF4C6B2F);
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.line),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                icon,
                size: 12,
                color: enabled ? AppColors.ink : AppColors.faint,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  color: enabled ? AppColors.ink : AppColors.faint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MutedLine extends StatelessWidget {
  const _MutedLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 9,
          height: 1.5,
          color: AppColors.faint,
        ),
      ),
    );
  }
}

class _EmptyRequests extends StatelessWidget {
  const _EmptyRequests();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Column(
        children: <Widget>[
          Icon(Icons.hub_rounded, size: 26, color: AppColors.faint),
          SizedBox(height: 8),
          Text(
            'No page requests yet',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 3),
          Text(
            'Open a page that calls fetch, XHR or sendBeacon. Requests appear '
            'here live, including POST bodies that WebKit never exposes.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 9.5,
              height: 1.5,
              color: AppColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _PageRequestRow extends StatelessWidget {
  const _PageRequestRow({required this.event, required this.onTap});

  final PageNetworkEvent event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(event.url ?? '');
    final path = uri == null || uri.host.isEmpty
        ? (event.url ?? '(unknown)')
        : '${uri.host}${uri.path.isEmpty ? '/' : uri.path}';
    final method = event.method ?? 'GET';
    final failed = event.phase == PageNetworkPhase.error;
    final hasBody = event.body != null && event.body!.isNotEmpty;
    final tint = failed ? AppColors.danger : _statusTint(event.statusCode);
    final meta = <String>[
      if (event.statusCode != null) '${event.statusCode}',
      if (event.duration != null) '${event.duration} ms',
      if (event.size != null) '${event.size} B',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: hasBody ? AppColors.ink : AppColors.wash,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        method,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 8,
                          fontWeight: FontWeight.w700,
                          color: hasBody ? AppColors.onInk : AppColors.muted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 9.5,
                          color: AppColors.ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      failed ? 'FAILED' : meta,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 8.5,
                        color: tint,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  event.url ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 8,
                    color: AppColors.faint,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Start page + app mark
// -----------------------------------------------------------------------------

class _StartPage extends StatelessWidget {
  const _StartPage({required this.onOpen});

  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(34, 24, 34, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const _AppMark(size: 64),
              const SizedBox(height: 18),
              const Text(
                'Where to?',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Browse with WKWebView. Verify the real fingerprint and '
                'headers with the native engine.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.55,
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 20),
              _QuickLink(
                letter: 'E',
                title: 'example.com',
                subtitle: 'https://example.com',
                filled: true,
                onTap: () => onOpen('https://example.com'),
              ),
              const SizedBox(height: 8),
              _QuickLink(
                letter: 'W',
                title: 'Wikipedia',
                subtitle: 'https://en.wikipedia.org',
                onTap: () => onOpen('https://en.wikipedia.org'),
              ),
              const SizedBox(height: 8),
              _QuickLink(
                letter: '?',
                title: 'httpbin',
                subtitle: 'https://httpbin.org/headers',
                onTap: () => onOpen('https://httpbin.org/headers'),
              ),
              const SizedBox(height: 22),
              const Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.tune_rounded,
                    size: 12,
                    color: AppColors.faint,
                  ),
                  SizedBox(width: 6),
                  Text(
                    'UA / Referer / Cookie live in Settings',
                    style: TextStyle(
                      fontSize: 9,
                      color: AppColors.faint,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickLink extends StatelessWidget {
  const _QuickLink({
    required this.letter,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.filled = false,
  });

  final String letter;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.line),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: filled ? AppColors.ink : AppColors.wash,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  letter,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: filled ? AppColors.onInk : AppColors.ink,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 8.5,
                        color: AppColors.faint,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: AppColors.faint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Route / Socket app mark, drawn with the same geometry as the SVG in
/// ui.html so the start page and the icon stay in sync.
class _AppMark extends StatelessWidget {
  const _AppMark({this.size = 64});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _AppMarkPainter()),
    );
  }
}

class _AppMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 1024;

    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(232 * s),
    );
    canvas.drawRRect(
      rrect,
      Paint()..color = const Color(0xFFF5F5F1),
    );
    canvas.drawRRect(
      rrect.deflate(1.5 * s),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * s
        ..color = const Color(0x140E0F10),
    );

    final ink = Paint()
      ..color = AppColors.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 74 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final path = Path()
      ..moveTo(706 * s, 302 * s)
      ..cubicTo(
        706 * s,
        176 * s,
        318 * s,
        176 * s,
        318 * s,
        302 * s,
      )
      ..cubicTo(
        318 * s,
        428 * s,
        706 * s,
        428 * s,
        706 * s,
        554 * s,
      )
      ..cubicTo(
        706 * s,
        680 * s,
        318 * s,
        680 * s,
        318 * s,
        806 * s,
      );
    canvas.drawPath(path, ink);

    final ring = Paint()
      ..color = AppColors.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 44 * s;
    canvas.drawCircle(Offset(706 * s, 302 * s), 116 * s, ring);
    canvas.drawCircle(Offset(318 * s, 806 * s), 116 * s, ring);

    final dot = Paint()..color = AppColors.ink;
    canvas.drawCircle(Offset(706 * s, 302 * s), 54 * s, dot);
    canvas.drawCircle(Offset(318 * s, 806 * s), 54 * s, dot);
  }

  @override
  bool shouldRepaint(covariant _AppMarkPainter oldDelegate) => false;
}
