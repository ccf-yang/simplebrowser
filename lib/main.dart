import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:browser_http/browser_http.dart';
import 'package:flutter/material.dart';

import 'dev_panel.dart';

void main() => runApp(const SimpleBrApp());

class SimpleBrApp extends StatelessWidget {
  const SimpleBrApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'SimpleBrowser',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
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
  _UaPreset('无（默认 UA）', null),
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
];

enum _RefererMode { none, currentDomain }

/// Hybrid test browser.
///
/// Top: a real WKWebView the user browses and clicks in. Bottom: what the
/// native fingerprint engine sees, plus the request log. Both sides share one
/// persistent cookie jar, so a clearance obtained by browsing is reused by the
/// capture button.
class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage>
    with SingleTickerProviderStateMixin {
  static final Uri _initialUri = Uri.parse('https://example.com');

  final StreamLogSink _logSink = StreamLogSink(400);
  final TextEditingController _urlController = TextEditingController(
    text: _initialUri.toString(),
  );
  final TextEditingController _cookieController = TextEditingController();
  final FocusNode _urlFocus = FocusNode();
  final List<RequestLogEvent> _events = <RequestLogEvent>[];

  late final BrowserSession _session;
  late final BrowserController _browser;
  late final StreamSubscription<RequestLogEvent> _logSubscription;
  late final TabController _tabs;

  CapturedExchange? _capture;
  String? _captureError;
  bool _busy = false;

  final List<CapturedExchange> _devCaptures = <CapturedExchange>[];
  final Map<String, PageNetworkEvent> _pageRequests =
      <String, PageNetworkEvent>{};
  late final StreamSubscription<PageNetworkEvent> _pageSubscription;
  bool _devPanelOpen = false;
  double _devPanelFraction = 0.62;
  String? _autoCapturedUrl;
  String? _pendingAutoCaptureUrl;

  bool _showHeaders = false;
  int _uaIndex = 0;
  _RefererMode _refererMode = _RefererMode.none;
  String? _defaultUserAgent;

  /// Share of the body height taken by the info/log panel; draggable.
  double _panelFraction = 0.4;

  String? _seenUrl;
  String? _seenTitle;
  int? _seenStatus;
  bool _seenBack = false;
  bool _seenForward = false;
  int _seenResources = 0;

  @override
  void initState() {
    super.initState();
    _session = BrowserHttp.session(logSink: _logSink);
    _browser = BrowserController(session: _session)
      ..addListener(_onBrowserChanged);
    _tabs = TabController(length: 3, vsync: this);
    _logSubscription = _logSink.stream.listen((event) {
      if (!mounted) return;
      setState(() => _events.insert(0, event));
    });
    _pageSubscription = _browser.networkEvents.listen(_onPageNetworkEvent);
    unawaited(_loadDefaultUserAgent());
  }

  /// Merges the injected script's request/response events into one row per
  /// request. Headers and body come from the request event; status, timing and
  /// response headers come from the matching response event.
  ///
  /// Events are buffered even while the panel is closed (bounded to 50), so
  /// opening it shows the current document's requests instead of an empty list.
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
      sessionId: update.sessionId.isEmpty
          ? request.sessionId
          : update.sessionId,
      page: request.page,
      id: request.id,
      phase: update.phase == PageNetworkPhase.body
          ? request.phase
          : update.phase,
      timestamp: request.timestamp,
      method: request.method ?? update.method,
      url: request.url ?? update.url,
      headers: request.headers,
      responseHeaders: update.headers.isNotEmpty
          ? update.headers
          : request.responseHeaders,
      body: request.body ?? update.body,
      responseBody: update.responseBody ?? request.responseBody,
      statusCode: update.statusCode ?? request.statusCode,
      duration: update.duration ?? request.duration,
      size: update.size ?? request.size,
      message: update.message ?? request.message,
    );
  }

  /// Page-script requests, newest first.
  List<PageNetworkEvent> get _pageRequestList {
    final list = _pageRequests.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  }

  Future<void> _loadDefaultUserAgent() async {
    try {
      final info = await _session.profileInfo();
      if (mounted) setState(() => _defaultUserAgent = info.userAgent);
    } on Object {
      // Keep null; the WebView keeps the UA it was created with.
    }
  }

  /// The controller polls the WebView; rebuild only on real changes so the
  /// platform view is not re-laid-out every tick.
  void _onBrowserChanged() {
    if (!mounted) return;
    final changed =
        _seenUrl != _browser.url ||
        _seenTitle != _browser.title ||
        _seenStatus != _browser.statusCode ||
        _seenBack != _browser.canGoBack ||
        _seenForward != _browser.canGoForward ||
        _seenResources != _browser.resourceTimings.length;
    if (!changed) return;

    _seenUrl = _browser.url;
    _seenTitle = _browser.title;
    _seenStatus = _browser.statusCode;
    _seenBack = _browser.canGoBack;
    _seenForward = _browser.canGoForward;
    _seenResources = _browser.resourceTimings.length;

    setState(() {
      if (!_urlFocus.hasFocus && (_browser.url ?? '').isNotEmpty) {
        _urlController.text = _browser.url!;
      }
    });

    if (_devPanelOpen) {
      final url = _browser.url;
      if (url != null && url != _autoCapturedUrl) {
        unawaited(_captureCurrent(auto: true));
      }
    }
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
    try {
      await _browser.load(
        uri,
        headers: _headersFor(uri),
        userAgent: _effectiveUserAgent,
      );
    } on Object catch (error) {
      if (mounted) _snack('Load failed: $error');
    }
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

  Future<void> _saveHeaders() async {
    final userAgent = _effectiveUserAgent;
    await _browser.setUserAgent(userAgent);
    if (!mounted) return;
    setState(() => _showHeaders = false);

    final uri = _currentUri();
    if (uri != null) {
      await _browser.reload(headers: _headersFor(uri), userAgent: userAgent);
    }
    if (!mounted) return;
    _snack(
      uri == null
          ? 'Header settings saved'
          : 'Saved, reloaded with new headers',
    );
  }

  void _resetHeaders() {
    setState(() {
      _uaIndex = 0;
      _refererMode = _RefererMode.none;
      _cookieController.clear();
    });
  }

  /// Runs the current URL through the native (Rust/wreq) engine so the panel
  /// can show ordered request headers, status, response headers, body and
  /// timing.
  ///
  /// [auto] is used by the devtools panel: it follows the WebView URL and stays
  /// silent when there is nothing to capture yet.
  Future<void> _captureCurrent({bool auto = false}) async {
    if (_busy) {
      if (auto) _pendingAutoCaptureUrl = _browser.url;
      return;
    }
    final uri = auto
        ? Uri.tryParse(_browser.url ?? '')
        : (_parseUrl(_urlController.text) ?? Uri.tryParse(_browser.url ?? ''));
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      if (!auto) _snack('Nothing to capture yet');
      return;
    }

    final headers = <OrderedHeader>[
      if (_uaOverride != null) OrderedHeader('User-Agent', _uaOverride!),
      for (final entry in _headersFor(uri).entries)
        OrderedHeader(entry.key, entry.value),
    ];

    _autoCapturedUrl = uri.toString();
    setState(() {
      _busy = true;
      _captureError = null;
    });
    try {
      final capture = await _session.capture(uri, headers: headers);
      if (!mounted) return;
      setState(() {
        _capture = capture;
        _devCaptures.insert(0, capture);
        while (_devCaptures.length > 30) {
          _devCaptures.removeLast();
        }
      });
    } on BrowserHttpException catch (error) {
      if (mounted) {
        setState(() => _captureError = '${error.code}: ${error.message}');
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _captureError = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        final pending = _pendingAutoCaptureUrl;
        _pendingAutoCaptureUrl = null;
        if (pending != null && _devPanelOpen && pending != _autoCapturedUrl) {
          unawaited(_captureCurrent(auto: true));
        }
      }
    }
  }

  /// Re-sends one captured exchange with the current header settings so the
  /// result can be compared against the original packet.
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
      if (!mounted) return;
      setState(() {
        _capture = capture;
        _devCaptures.insert(0, capture);
        while (_devCaptures.length > 30) {
          _devCaptures.removeLast();
        }
      });
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

  /// Replays a page-script request through the native engine, reusing its
  /// method, caller headers and body.
  Future<void> _replayPageEvent(PageNetworkEvent source) async {
    if (_busy) return;
    final uri = Uri.tryParse(source.url ?? '');
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      _snack('这条记录没有可重发的 URL');
      return;
    }
    final currentHeaders = _headersFor(uri);
    final headers = <OrderedHeader>[
      if (_uaOverride != null) OrderedHeader('User-Agent', _uaOverride!),
      for (final entry in currentHeaders.entries)
        OrderedHeader(entry.key, entry.value),
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
        _devCaptures.insert(0, capture);
        while (_devCaptures.length > 30) {
          _devCaptures.removeLast();
        }
      });
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

  void _toggleDevPanel() {
    if (_devPanelOpen) {
      _closeDevPanel();
      return;
    }
    setState(() {
      _devPanelOpen = true;
      _autoCapturedUrl = null;
    });
    unawaited(_browser.refreshResources());
    unawaited(_captureCurrent(auto: true));
  }

  /// Close = clean the collected packets/logs, then refresh the page so the
  /// next open starts from a fresh document.
  void _closeDevPanel() {
    setState(() {
      _devPanelOpen = false;
      _devCaptures.clear();
      _pageRequests.clear();
      _events.clear();
      _capture = null;
      _captureError = null;
      _autoCapturedUrl = null;
      _pendingAutoCaptureUrl = null;
    });
    unawaited(_refreshAfterDevPanel());
  }

  Future<void> _refreshAfterDevPanel() async {
    final uri = _currentUri();
    try {
      if (uri == null) {
        await _browser.refreshResources();
        return;
      }
      await _browser.reload(
        headers: _headersFor(uri),
        userAgent: _effectiveUserAgent,
      );
    } on Object catch (error) {
      if (mounted) _snack('Refresh failed: $error');
    }
  }

  @override
  void dispose() {
    unawaited(_logSubscription.cancel());
    unawaited(_pageSubscription.cancel());
    _browser.removeListener(_onBrowserChanged);
    _browser.dispose();
    unawaited(_session.close());
    _tabs.dispose();
    _urlController.dispose();
    _cookieController.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _buildToolbar(),
            if (_showHeaders) _buildHeaderSettings(),
            const Divider(height: 1),
            Expanded(child: _buildSplitBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildDevButton() {
    return Tooltip(
      message: _devPanelOpen ? '关闭 DevTools' : '打开 DevTools',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(26),
          onTap: _toggleDevPanel,
          child: Opacity(
            opacity: 0.78,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFF1B1F23),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0x664DD0B1)),
                boxShadow: const <BoxShadow>[
                  BoxShadow(color: Color(0x55000000), blurRadius: 10),
                ],
              ),
              child: Icon(
                _devPanelOpen ? Icons.close : Icons.terminal,
                color: const Color(0xFF4DD0B1),
                size: 22,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(2, 6, 4, 6),
      child: Row(
        children: <Widget>[
          _compactIcon(
            Icons.arrow_back,
            'Back',
            _browser.canGoBack ? () => unawaited(_browser.goBack()) : null,
          ),
          _compactIcon(
            Icons.arrow_forward,
            'Forward',
            _browser.canGoForward
                ? () => unawaited(_browser.goForward())
                : null,
          ),
          _compactIcon(Icons.refresh, 'Reload', () => unawaited(_reload())),
          Expanded(child: _buildUrlField()),
          _compactIcon(
            _showHeaders ? Icons.tune : Icons.tune_outlined,
            'Request headers',
            () => setState(() => _showHeaders = !_showHeaders),
          ),
        ],
      ),
    );
  }

  Widget _buildUrlField() {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _urlController,
      builder: (context, value, _) {
        return TextField(
          controller: _urlController,
          focusNode: _urlFocus,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: scheme.surface,
            hintText: 'https://example.com',
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: BorderSide.none,
            ),
            suffixIconConstraints: const BoxConstraints(minWidth: 0),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (value.text.isNotEmpty)
                  _compactIcon(Icons.close, 'Clear', () {
                    _urlController.clear();
                    _urlFocus.requestFocus();
                  }),
                _compactIcon(Icons.arrow_forward, 'Go', () => unawaited(_go())),
                const SizedBox(width: 2),
              ],
            ),
          ),
          onSubmitted: (_) => unawaited(_go()),
        );
      },
    );
  }

  Widget _buildHeaderSettings() {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = TextStyle(fontSize: 11, color: scheme.onSurfaceVariant);
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainer,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Request headers',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          InputDecorator(
            decoration: const InputDecoration(
              labelText: 'User-Agent',
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: _uaIndex,
                isDense: true,
                isExpanded: true,
                items: <DropdownMenuItem<int>>[
                  for (var i = 0; i < _uaPresets.length; i++)
                    DropdownMenuItem<int>(
                      value: i,
                      child: Text(
                        _uaPresets[i].label,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _uaIndex = value);
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Referer',
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<_RefererMode>(
                value: _refererMode,
                isDense: true,
                isExpanded: true,
                items: const <DropdownMenuItem<_RefererMode>>[
                  DropdownMenuItem<_RefererMode>(
                    value: _RefererMode.none,
                    child: Text('无', style: TextStyle(fontSize: 13)),
                  ),
                  DropdownMenuItem<_RefererMode>(
                    value: _RefererMode.currentDomain,
                    child: Text('当前域名', style: TextStyle(fontSize: 13)),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _refererMode = value);
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _cookieController,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              labelText: 'Cookie',
              hintText: 'name=value; name2=value2',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(child: Text('保存后会用新的请求头重新加载当前页面。', style: labelStyle)),
              TextButton(onPressed: _resetHeaders, child: const Text('重置')),
              const SizedBox(width: 4),
              FilledButton.icon(
                onPressed: () => unawaited(_saveHeaders()),
                icon: const Icon(Icons.check, size: 18),
                label: const Text('保存并刷新'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _compactIcon(IconData icon, String tooltip, VoidCallback? onPressed) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 34, height: 34),
    );
  }

  Widget _buildSplitBody() {
    const handleHeight = 14.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = math.max(0.0, constraints.maxHeight);
        final panelSpace = _devPanelOpen
            ? total
            : math.max(0.0, total - handleHeight);
        final fraction = _devPanelOpen ? _devPanelFraction : _panelFraction;
        final panelHeight = (panelSpace * fraction)
            .clamp(0.0, panelSpace)
            .toDouble();
        final webHeight = panelSpace - panelHeight;

        return Column(
          children: <Widget>[
            SizedBox(
              height: webHeight,
              child: Stack(
                children: <Widget>[
                  Positioned.fill(child: _buildWebView()),
                  Positioned(right: 14, bottom: 14, child: _buildDevButton()),
                ],
              ),
            ),
            if (_devPanelOpen)
              SizedBox(
                height: panelHeight,
                child: DevPanel(
                  captures: _devCaptures,
                  pageRequests: _pageRequestList,
                  events: _events,
                  busy: _busy,
                  captureError: _captureError,
                  page: DevPageState(
                    title: _browser.title,
                    url: _browser.url,
                    statusCode: _browser.statusCode,
                    userAgentLabel: _uaPresets[_uaIndex].label,
                    profileId: _browser.session.profile.id,
                    canGoBack: _browser.canGoBack,
                    canGoForward: _browser.canGoForward,
                    resources: _browser.resourceTimings,
                  ),
                  onResize: (delta) {
                    if (panelSpace <= 0) return;
                    setState(() {
                      _devPanelFraction =
                          (_devPanelFraction + delta / panelSpace)
                              .clamp(0.2, 0.85)
                              .toDouble();
                    });
                  },
                  onCapture: () => unawaited(_captureCurrent()),
                  onClear: () => setState(() {
                    _devCaptures.clear();
                    _pageRequests.clear();
                    _events.clear();
                    _capture = null;
                    _captureError = null;
                    _autoCapturedUrl = null;
                  }),
                  onClose: _closeDevPanel,
                  onReplay: (capture) => unawaited(_replayCapture(capture)),
                  onReplayPage: (event) => unawaited(_replayPageEvent(event)),
                ),
              )
            else ...<Widget>[
              _buildDragHandle(panelSpace),
              SizedBox(height: panelHeight, child: _buildPanel()),
            ],
          ],
        );
      },
    );
  }

  Widget _buildDragHandle(double available) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (details) {
        if (available <= 0) return;
        setState(() {
          _panelFraction = (_panelFraction - details.delta.dy / available)
              .clamp(0.15, 0.85)
              .toDouble();
        });
      },
      child: SizedBox(
        height: 14,
        child: Center(
          child: Container(
            width: 44,
            height: 4,
            decoration: BoxDecoration(
              color: scheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWebView() {
    return BrowserView(controller: _browser, initialUri: _initialUri);
  }

  Widget _buildPanel() {
    return Column(
      children: <Widget>[
        TabBar(
          controller: _tabs,
          tabs: <Widget>[
            const Tab(text: 'WebView'),
            const Tab(text: 'Engine'),
            Tab(text: 'Log (${_events.length})'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: <Widget>[
              _buildWebViewInfo(),
              _buildEngineInfo(),
              _buildLog(),
            ],
          ),
        ),
      ],
    );
  }

  /// Main-document facts reported by WKWebView plus the resource timings the
  /// Performance API exposes. Subresource headers and bodies are not available
  /// to host apps, which is why the Engine tab exists.
  Widget _buildWebViewInfo() {
    final resources = _browser.resourceTimings;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        _kv('Title', _browser.title ?? '—'),
        _kv('URL', _browser.url ?? '—'),
        _kv('HTTP status', '${_browser.statusCode ?? '—'}'),
        _kv(
          'History',
          'back=${_browser.canGoBack} forward=${_browser.canGoForward}',
        ),
        _kv('User-Agent', _uaPresets[_uaIndex].label),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                'Resource timings',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            TextButton(
              onPressed: () {
                unawaited(_browser.refreshResources());
              },
              child: const Text('Refresh'),
            ),
          ],
        ),
        const Text(
          'WebKit does not expose headers or bodies of WebView subresources. '
          'Use Engine for a full request/response capture of the current URL.',
          style: TextStyle(fontSize: 11),
        ),
        const SizedBox(height: 8),
        if (resources.isEmpty)
          const Text('No PerformanceResourceTiming entries yet.')
        else
          for (final resource in resources)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    resource.url,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                  Text(
                    '${resource.initiatorType.isEmpty ? 'resource' : resource.initiatorType}'
                    ' · ${resource.duration.toStringAsFixed(1)} ms'
                    ' · transfer ${resource.transferSize ?? 0} B'
                    ' · body ${resource.encodedBodySize ?? 0} B',
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ],
              ),
            ),
        const SizedBox(height: 12),
        _kv(
          'Shared jar',
          '${_browser.session.profile.id} · persistent WKWebsiteDataStore',
        ),
      ],
    );
  }

  Widget _buildEngineInfo() {
    final error = _captureError;
    final capture = _capture;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                'Native engine capture',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            TextButton.icon(
              onPressed: _busy ? null : () => unawaited(_captureCurrent()),
              icon: const Icon(Icons.radar, size: 18),
              label: const Text('Capture URL'),
            ),
          ],
        ),
        const Text(
          'Same persistent cookie jar as the WebView. UA, Referer and Cookie '
          'from the header settings are applied to the capture request.',
          style: TextStyle(fontSize: 11),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(error, style: const TextStyle(color: Colors.red)),
          ),
        if (capture == null)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text('No capture yet. Load a page, then tap Capture URL.'),
          )
        else ...<Widget>[
          const Divider(),
          _kv('Request id', capture.requestId),
          _kv('Method', '${capture.method} ${capture.uri}'),
          _kv('Status', '${capture.response.statusCode}'),
          _kv('Elapsed', '${capture.elapsed.inMilliseconds} ms'),
          _kv('Response body', '${capture.responseBodyLength} bytes'),
          _kv('Profile', capture.profile.profileId),
          const SizedBox(height: 8),
          _section('Request headers (ordered, as handed to Rust)'),
          for (final header in capture.requestHeaders)
            _headerLine('${header.name}: ${header.value}'),
          if (capture.requestHeaders.isEmpty)
            const Text(
              '(no caller headers; profile defaults are applied natively)',
            ),
          const SizedBox(height: 6),
          _section('Native identity'),
          _headerLine('User-Agent: ${capture.profile.userAgent}'),
          for (final hint in capture.profile.clientHints.entries)
            _headerLine('${hint.key}: ${hint.value}'),
          const SizedBox(height: 8),
          _section('Response headers (received order)'),
          for (final header in capture.response.headers)
            _headerLine('${header.name}: ${header.value}'),
          const SizedBox(height: 8),
          _section('Body preview'),
          SelectableText(
            formatBodyPreview(capture.response),
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
          ),
        ],
      ],
    );
  }

  Widget _buildLog() {
    if (_events.isEmpty) {
      return const Center(child: Text('No request events yet.'));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _events.length,
      itemBuilder: (context, index) {
        final event = _events[index];
        final color = switch (event.level) {
          RequestLogLevel.error => Colors.red,
          RequestLogLevel.warn => Colors.orange,
          _ => null,
        };
        return ListTile(
          dense: true,
          leading: Text(
            event.phase.name,
            style: TextStyle(fontSize: 11, color: color),
          ),
          title: Text(
            '${event.method ?? ''} ${event.uri ?? ''}'.trim(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
          ),
          subtitle: Text(
            '${event.statusCode == null ? '' : '${event.statusCode} '}'
            '${event.elapsed == null ? '' : '${event.elapsed!.inMilliseconds} ms '}'
            '${event.errorCode ?? ''} ${event.message ?? ''}',
            style: TextStyle(fontSize: 10, color: color),
          ),
          trailing: Text(
            '${event.timestamp.hour.toString().padLeft(2, '0')}:'
            '${event.timestamp.minute.toString().padLeft(2, '0')}:'
            '${event.timestamp.second.toString().padLeft(2, '0')}',
            style: const TextStyle(fontSize: 10),
          ),
        );
      },
    );
  }

  static Widget _kv(String key, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 110,
          child: Text(key, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: SelectableText(value, style: const TextStyle(fontSize: 12)),
        ),
      ],
    ),
  );

  static Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 4),
    child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
  );

  static Widget _headerLine(String line) => SelectableText(
    line,
    style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
  );
}
