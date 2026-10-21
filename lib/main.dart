import 'dart:async';
import 'dart:convert';

import 'package:browser_http/browser_http.dart';
import 'package:flutter/material.dart';

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
  final TextEditingController _urlController =
      TextEditingController(text: _initialUri.toString());
  final FocusNode _urlFocus = FocusNode();
  final List<RequestLogEvent> _events = <RequestLogEvent>[];

  late final BrowserSession _session;
  late final BrowserController _browser;
  late final StreamSubscription<RequestLogEvent> _logSubscription;
  late final TabController _tabs;

  CapturedExchange? _capture;
  String? _captureError;
  bool _busy = false;

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
    await _browser.load(uri);
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

    setState(() {
      _busy = true;
      _captureError = null;
    });
    try {
      final capture = await _session.capture(uri);
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

  @override
  void dispose() {
    unawaited(_logSubscription.cancel());
    _browser.removeListener(_onBrowserChanged);
    _browser.dispose();
    unawaited(_session.close());
    _tabs.dispose();
    _urlController.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SimpleBrowser'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Capture through native engine',
            onPressed: _busy ? null : _captureCurrent,
            icon: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.radar),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _buildUrlBar(),
            Expanded(flex: 3, child: _buildWebView()),
            const Divider(height: 1),
            Expanded(flex: 2, child: _buildPanel()),
          ],
        ),
      ),
    );
  }

  Widget _buildUrlBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: 'Back',
            onPressed: _browser.canGoBack ? _browser.goBack : null,
            icon: const Icon(Icons.arrow_back),
          ),
          IconButton(
            tooltip: 'Forward',
            onPressed: _browser.canGoForward ? _browser.goForward : null,
            icon: const Icon(Icons.arrow_forward),
          ),
          IconButton(
            tooltip: 'Reload',
            onPressed: _browser.reload,
            icon: const Icon(Icons.refresh),
          ),
          Expanded(
            child: TextField(
              controller: _urlController,
              focusNode: _urlFocus,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                hintText: 'https://example.com',
              ),
              onSubmitted: (_) => _go(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: _go, child: const Text('Go')),
        ],
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
              onPressed: _busy ? null : _captureCurrent,
              icon: const Icon(Icons.radar, size: 18),
              label: const Text('Capture URL'),
            ),
          ],
        ),
        const Text(
          'Same persistent cookie jar as the WebView; UA, header order, TLS '
          'and HTTP/2 settings come from the native profile.',
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
            _bodyPreview(capture.response),
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
              child: Text(
                key,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Expanded(
              child: SelectableText(
                value,
                style: const TextStyle(fontSize: 12),
              ),
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

  static String _bodyPreview(TransportResponse response) {
    if (response.body.isEmpty) return '(empty)';
    final text = utf8.decode(response.body, allowMalformed: true);
    final printable = text.runes
        .where((rune) => rune == 9 || rune == 10 || rune == 13 || rune >= 32)
        .length;
    final ratio = text.isEmpty ? 0.0 : printable / text.length;
    if (ratio < 0.9) {
      final hex = response.body
          .take(48)
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      return '${response.body.length} bytes (binary)\n$hex';
    }
    if (text.length > 2000) return '${text.substring(0, 2000)}\n…';
    return text;
  }
}
