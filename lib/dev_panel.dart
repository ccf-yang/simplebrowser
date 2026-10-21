import 'dart:async';
import 'dart:convert';

import 'package:browser_http/browser_http.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const Color _kBg = Color(0xFF1B1F23);
const Color _kLine = Color(0xFF30363D);
const Color _kAccent = Color(0xFF4DD0B1);
const Color _kMuted = Color(0xFF8B949E);
const Color _kText = Color(0xFFD7DEE7);

/// What the WebView tab needs; keeps [DevPanel] independent of the controller.
class DevPageState {
  const DevPageState({
    this.title,
    this.url,
    this.statusCode,
    this.userAgentLabel,
    this.profileId,
    this.canGoBack = false,
    this.canGoForward = false,
    this.resources = const <WebResourceTiming>[],
  });

  final String? title;
  final String? url;
  final int? statusCode;
  final String? userAgentLabel;
  final String? profileId;
  final bool canGoBack;
  final bool canGoForward;
  final List<WebResourceTiming> resources;
}

/// Eruda-style panel: a dark, draggable list of captured exchanges.
///
/// The drag handle at the top reports pixel deltas to the parent, which owns
/// the height fraction so the panel can also be resized from the outside.
class DevPanel extends StatefulWidget {
  const DevPanel({
    super.key,
    required this.captures,
    required this.pageRequests,
    required this.events,
    required this.busy,
    required this.captureError,
    required this.page,
    required this.onResize,
    required this.onCapture,
    required this.onClear,
    required this.onClose,
    required this.onReplay,
    required this.onReplayPage,
  });

  final List<CapturedExchange> captures;
  final List<PageNetworkEvent> pageRequests;
  final List<RequestLogEvent> events;
  final bool busy;
  final String? captureError;
  final DevPageState page;

  /// Positive values grow the panel (drag the handle upwards).
  final ValueChanged<double> onResize;
  final VoidCallback onCapture;
  final VoidCallback onClear;
  final VoidCallback onClose;
  final ValueChanged<CapturedExchange> onReplay;
  final ValueChanged<PageNetworkEvent> onReplayPage;

  @override
  State<DevPanel> createState() => _DevPanelState();
}

class _DevPanelState extends State<DevPanel> {
  int _tab = 0;
  CapturedExchange? _selected;
  PageNetworkEvent? _selectedPage;

  @override
  void didUpdateWidget(covariant DevPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selected = _selected;
    if (selected != null && !widget.captures.contains(selected)) {
      _selected = null;
    }
    final selectedPage = _selectedPage;
    if (selectedPage != null) {
      // Keep the open detail in sync when the matching response arrives.
      PageNetworkEvent? latest;
      for (final request in widget.pageRequests) {
        if (request.key == selectedPage.key) {
          latest = request;
          break;
        }
      }
      _selectedPage = latest;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _kBg,
      elevation: 16,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          _buildGrabber(),
          if (_selectedPage != null)
            _buildPageEventHeader()
          else if (_selected == null)
            _buildTabHeader()
          else
            _buildDetailHeader(),
          const Divider(height: 1, color: _kLine),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildGrabber() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (details) => widget.onResize(-details.delta.dy),
      child: SizedBox(
        height: 18,
        child: Center(
          child: Container(
            width: 44,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFF4A525C),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 4, 4),
      child: Row(
        children: <Widget>[
          _tabChip(0, '网络'),
          const SizedBox(width: 4),
          _tabChip(1, '日志'),
          const SizedBox(width: 4),
          _tabChip(2, '页面'),
          const Spacer(),
          if (widget.busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _kAccent,
                ),
              ),
            )
          else
            _icon(Icons.radar, '抓当前页面', widget.onCapture),
          _icon(Icons.delete_sweep_outlined, '清空', widget.onClear),
          _icon(Icons.close, '关闭', widget.onClose),
        ],
      ),
    );
  }

  Widget _buildDetailHeader() {
    final capture = _selected!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 4, 4),
      child: Row(
        children: <Widget>[
          _icon(
            Icons.arrow_back,
            '返回列表',
            () => setState(() => _selected = null),
          ),
          _statusBadge(capture.response.statusCode),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${capture.method} ${capture.uri}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: _kText,
              ),
            ),
          ),
          _icon(Icons.close, '关闭', widget.onClose),
        ],
      ),
    );
  }

  Widget _buildPageEventHeader() {
    final event = _selectedPage!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 4, 4),
      child: Row(
        children: <Widget>[
          _icon(
            Icons.arrow_back,
            '返回列表',
            () => setState(() => _selectedPage = null),
          ),
          _statusBadgeOrNull(event.statusCode),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${event.method ?? 'GET'} ${event.url ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: _kText,
              ),
            ),
          ),
          _icon(Icons.close, '关闭', widget.onClose),
        ],
      ),
    );
  }

  Widget _tabChip(int index, String label) {
    final active = _tab == index;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => setState(() {
        _tab = index;
        _selected = null;
        _selectedPage = null;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? _kAccent.withAlpha(41) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: active ? _kAccent : _kMuted,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _icon(IconData icon, String tooltip, VoidCallback onTap) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      color: _kMuted,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
    );
  }

  Widget _buildBody() {
    if (_selectedPage != null) return _buildPageEventDetail(_selectedPage!);
    if (_selected != null) return _buildDetail(_selected!);
    return switch (_tab) {
      0 => _buildNetwork(),
      1 => _buildLog(),
      _ => _buildPage(),
    };
  }

  Widget _buildNetwork() {
    final error = widget.captureError;
    final requests = widget.pageRequests;
    if (widget.captures.isEmpty && requests.isEmpty && error == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                '还没有抓到请求',
                style: TextStyle(fontSize: 12, color: _kMuted),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: widget.busy ? null : widget.onCapture,
                icon: const Icon(Icons.radar, size: 16),
                label: const Text('抓当前页面'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _kAccent,
                  side: const BorderSide(color: _kLine),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: <Widget>[
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              error,
              style: const TextStyle(fontSize: 11, color: Color(0xFFFF7B72)),
            ),
          ),
        if (requests.isNotEmpty) ...<Widget>[
          _groupHeader('页面脚本请求 (fetch / XHR / beacon)'),
          for (final request in requests) _pageEventRow(request),
        ],
        if (widget.captures.isNotEmpty) ...<Widget>[
          _groupHeader('原生回放 (当前页面主文档)'),
          for (final capture in widget.captures) _captureRow(capture),
        ],
      ],
    );
  }

  Widget _groupHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: _kMuted,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _pageEventRow(PageNetworkEvent request) {
    final uri = Uri.tryParse(request.url ?? '');
    final path = uri == null ? (request.url ?? '') : '${uri.host}${uri.path}';
    final details = <String>[
      if (request.duration != null) '${request.duration} ms',
      if (request.size != null) '${request.size} B',
      if (request.phase == PageNetworkPhase.error) '失败',
    ];
    return InkWell(
      onTap: () => setState(() => _selectedPage = request),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: <Widget>[
            _statusBadgeOrNull(request.statusCode),
            const SizedBox(width: 8),
            SizedBox(
              width: 44,
              child: Text(
                request.method ?? 'GET',
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: _kAccent,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: _kText,
                    ),
                  ),
                  Text(
                    details.isEmpty ? '页面脚本' : '${details.join(' · ')} · 页面脚本',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: _kMuted),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 16, color: _kMuted),
          ],
        ),
      ),
    );
  }

  Widget _captureRow(CapturedExchange capture) {
    return InkWell(
      onTap: () => setState(() => _selected = capture),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: <Widget>[
            _statusBadge(capture.response.statusCode),
            const SizedBox(width: 8),
            SizedBox(
              width: 38,
              child: Text(
                capture.method,
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: _kAccent,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '${capture.uri.host}${capture.uri.path}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: _kText,
                    ),
                  ),
                  Text(
                    '${capture.elapsed.inMilliseconds} ms'
                    ' · ${capture.responseBodyLength} B'
                    '${capture.uri.hasQuery ? ' · ?${capture.uri.query}' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: _kMuted),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 16, color: _kMuted),
          ],
        ),
      ),
    );
  }

  Widget _buildDetail(CapturedExchange capture) {
    final requestBody = capture.requestBody;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      children: <Widget>[
        _buildActions(capture),
        const SizedBox(height: 6),
        _kv('URL', capture.uri.toString()),
        _kv('Status', '${capture.response.statusCode}'),
        _kv('Elapsed', '${capture.elapsed.inMilliseconds} ms'),
        _kv('Response body', '${capture.responseBodyLength} bytes'),
        _kv('Profile', capture.profile.profileId),
        _section('请求行'),
        _code('${capture.method} ${capture.uri}'),
        _section('请求头 (${capture.requestHeaders.length})'),
        if (capture.requestHeaders.isEmpty)
          _hint('(no caller headers; profile defaults applied natively)')
        else
          for (final header in capture.requestHeaders)
            _code('${header.name}: ${header.value}'),
        _section('请求体'),
        if (requestBody == null || requestBody.isEmpty)
          _hint('GET 请求没有请求体（WebKit 不暴露子资源请求体）')
        else
          SelectableText(
            utf8.decode(requestBody, allowMalformed: true),
            style: const TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: _kText,
              height: 1.4,
            ),
          ),
        _section('实际身份'),
        _code('User-Agent: ${capture.profile.userAgent}'),
        for (final hint in capture.profile.clientHints.entries)
          _code('${hint.key}: ${hint.value}'),
        _section('响应头 (${capture.response.headers.length})'),
        for (final header in capture.response.headers)
          _code('${header.name}: ${header.value}'),
        _section('响应体'),
        SelectableText(
          formatBodyPreview(capture.response),
          style: const TextStyle(
            fontSize: 11,
            fontFamily: 'monospace',
            color: _kText,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _buildPageEventDetail(PageNetworkEvent event) {
    final body = event.body;
    final responseBody = event.responseBody;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      children: <Widget>[
        _buildPageEventActions(event),
        const SizedBox(height: 6),
        _kv('URL', event.url ?? '-'),
        _kv('Method', event.method ?? 'GET'),
        _kv('Status', '${event.statusCode ?? '-'}'),
        _kv('Duration', event.duration == null ? '-' : '${event.duration} ms'),
        _kv('Size', event.size == null ? '-' : '${event.size} bytes'),
        if (event.message != null) _kv('Error', event.message!),
        _section('请求头 (${event.headers.length})'),
        if (event.headers.isEmpty)
          _hint('(页面脚本未上报请求头)')
        else
          for (final entry in event.headers.entries)
            _code('${entry.key}: ${entry.value}'),
        _section('请求体'),
        if (body == null || body.isEmpty)
          _hint('无请求体')
        else
          SelectableText(
            body,
            style: const TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: _kText,
              height: 1.4,
            ),
          ),
        _section('响应头 (${event.responseHeaders.length})'),
        if (event.responseHeaders.isEmpty)
          _hint('(页面脚本读不到响应头，可能是跨域或未完成)')
        else
          for (final entry in event.responseHeaders.entries)
            _code('${entry.key}: ${entry.value}'),
        _section('响应体'),
        if (responseBody == null || responseBody.isEmpty)
          _hint('(未捕获响应体)')
        else
          SelectableText(
            responseBody,
            style: const TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: _kText,
              height: 1.4,
            ),
          ),
      ],
    );
  }

  Widget _buildPageEventActions(PageNetworkEvent event) {
    final body = event.body;
    final responseBody = event.responseBody;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        _action('复制 cURL', () {
          unawaited(_copy(buildPageCurl(event), 'cURL 已复制'));
        }),
        _action('复制 URL', () {
          unawaited(_copy(event.url ?? '', 'URL 已复制'));
        }),
        _action('复制请求头', () {
          unawaited(_copy(_mapBlock(event.headers), '请求头已复制'));
        }),
        if (body != null && body.isNotEmpty)
          _action('复制请求体', () {
            unawaited(_copy(body, '请求体已复制'));
          }),
        if (responseBody != null && responseBody.isNotEmpty)
          _action('复制响应体', () {
            unawaited(_copy(responseBody, '响应体已复制'));
          }),
        _action('原生重发', () => widget.onReplayPage(event)),
      ],
    );
  }

  Widget _buildActions(CapturedExchange capture) {
    final hasBody =
        capture.requestBody != null && capture.requestBody!.isNotEmpty;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        _action('复制 cURL', () {
          unawaited(_copy(buildCurl(capture), 'cURL 已复制'));
        }),
        _action('复制 URL', () {
          unawaited(_copy(capture.uri.toString(), 'URL 已复制'));
        }),
        _action('复制请求头', () {
          unawaited(_copy(_headerBlock(capture.requestHeaders), '请求头已复制'));
        }),
        if (hasBody)
          _action('复制请求体', () {
            unawaited(
              _copy(
                utf8.decode(capture.requestBody!, allowMalformed: true),
                '请求体已复制',
              ),
            );
          }),
        _action('复制响应体', () {
          unawaited(_copy(formatBodyPreview(capture.response), '响应体已复制'));
        }),
        _action('重发', () => widget.onReplay(capture)),
      ],
    );
  }

  Widget _action(String label, VoidCallback onTap) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: _kAccent,
        side: const BorderSide(color: _kLine),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: const Size(0, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 11),
      ),
      child: Text(label),
    );
  }

  Future<void> _copy(String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(milliseconds: 900),
      ),
    );
  }

  Widget _buildLog() {
    if (widget.events.isEmpty) {
      return const Center(
        child: Text('暂无日志', style: TextStyle(fontSize: 12, color: _kMuted)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: widget.events.length,
      itemBuilder: (context, index) {
        final event = widget.events[index];
        final color = switch (event.level) {
          RequestLogLevel.error => const Color(0xFFFF7B72),
          RequestLogLevel.warn => const Color(0xFFF0883E),
          _ => _kText,
        };
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 54,
                child: Text(
                  event.phase.name,
                  style: const TextStyle(fontSize: 10, color: _kMuted),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '${event.method ?? ''} ${event.uri ?? ''}'.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: color,
                      ),
                    ),
                    Text(
                      ('${event.statusCode ?? ''} '
                              '${event.elapsed?.inMilliseconds ?? ''}ms '
                              '${event.errorCode ?? ''} ${event.message ?? ''}')
                          .trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10, color: _kMuted),
                    ),
                  ],
                ),
              ),
              Text(
                _time(event.timestamp),
                style: const TextStyle(fontSize: 10, color: _kMuted),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPage() {
    final page = widget.page;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
      children: <Widget>[
        _kv('Title', page.title ?? '-'),
        _kv('URL', page.url ?? '-'),
        _kv('HTTP status', '${page.statusCode ?? '-'}'),
        _kv('History', 'back=${page.canGoBack} forward=${page.canGoForward}'),
        _kv('User-Agent', page.userAgentLabel ?? '-'),
        _kv('Profile', page.profileId ?? '-'),
        _section('资源计时 (${page.resources.length})'),
        _hint('WebKit 不暴露子资源请求头与响应体，网络页展示的是原生引擎回放结果。'),
        for (final resource in page.resources)
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
                    color: _kText,
                  ),
                ),
                Text(
                  '${resource.initiatorType.isEmpty ? 'resource' : resource.initiatorType}'
                  ' · ${resource.duration.toStringAsFixed(1)} ms'
                  ' · transfer ${resource.transferSize ?? 0} B',
                  style: const TextStyle(fontSize: 10, color: _kMuted),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _statusBadge(int status) {
    final color = _statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(41),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$status',
        style: TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _statusBadgeOrNull(int? status) {
    if (status == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: _kMuted.withAlpha(31),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text(
          '···',
          style: TextStyle(
            fontSize: 11,
            fontFamily: 'monospace',
            color: _kMuted,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return _statusBadge(status);
  }

  static Color _statusColor(int status) {
    if (status >= 500) return const Color(0xFFFF7B72);
    if (status >= 400) return const Color(0xFFF0883E);
    if (status >= 300) return const Color(0xFFD29922);
    if (status >= 200) return _kAccent;
    return _kMuted;
  }

  static String _time(DateTime timestamp) =>
      '${timestamp.hour.toString().padLeft(2, '0')}:'
      '${timestamp.minute.toString().padLeft(2, '0')}:'
      '${timestamp.second.toString().padLeft(2, '0')}';

  static Widget _kv(String key, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 92,
          child: Text(
            key,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: _kMuted,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(fontSize: 11, color: _kText),
          ),
        ),
      ],
    ),
  );

  static Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 4),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: _kAccent,
      ),
    ),
  );

  static Widget _hint(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Text(text, style: const TextStyle(fontSize: 11, color: _kMuted)),
  );

  static Widget _code(String line) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: SelectableText(
      line,
      style: const TextStyle(
        fontSize: 11,
        fontFamily: 'monospace',
        color: _kText,
      ),
    ),
  );
}

/// One body preview for both the DevPanel and the Engine tab.
String formatBodyPreview(TransportResponse response) {
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

String _headerBlock(List<OrderedHeader> headers) =>
    headers.map((header) => '${header.name}: ${header.value}').join('\n');

String _mapBlock(Map<String, String> headers) =>
    headers.entries.map((entry) => '${entry.key}: ${entry.value}').join('\n');

/// Builds a copyable cURL command from a page-script capture.
String buildPageCurl(PageNetworkEvent event) {
  final buffer = StringBuffer('curl -X ${event.method ?? 'GET'}');
  buffer.write(' ${_shellQuote(event.url ?? '')}');
  for (final entry in event.headers.entries) {
    buffer.write(' \\\n  -H ${_shellQuote('${entry.key}: ${entry.value}')}');
  }
  final body = event.body;
  if (body != null && body.isNotEmpty) {
    buffer.write(' \\\n  --data-binary ${_shellQuote(body)}');
  }
  return buffer.toString();
}

/// Builds a copyable cURL command from a captured exchange.
String buildCurl(CapturedExchange capture) {
  final buffer = StringBuffer('curl -X ${capture.method}');
  buffer.write(' ${_shellQuote(capture.uri.toString())}');
  for (final header in capture.requestHeaders) {
    buffer.write(' \\\n  -H ${_shellQuote('${header.name}: ${header.value}')}');
  }
  final body = capture.requestBody;
  if (body != null && body.isNotEmpty) {
    buffer.write(
      ' \\\n  --data-binary ${_shellQuote(utf8.decode(body, allowMalformed: true))}',
    );
  }
  return buffer.toString();
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";
