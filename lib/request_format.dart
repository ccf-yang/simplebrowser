import 'dart:convert';

import 'package:browser_http/browser_http.dart';

/// Pure formatters shared by the Engine tab and the page-request detail.
///
/// Keeping them out of the widget tree makes the copy output easy to test and
/// keeps the very large `main.dart` free of string-building logic.

/// Single-quotes [value] for a POSIX shell, escaping embedded quotes.
String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

String headerBlock(List<OrderedHeader> headers) =>
    headers.map((header) => '${header.name}: ${header.value}').join('\n');

String mapBlock(Map<String, String> headers) => headers.entries
    .map((entry) => '${entry.key}: ${entry.value}')
    .join('\n');

/// cURL for a native capture: headers are in real wire order.
String buildCurl(CapturedExchange capture) {
  final buffer = StringBuffer('curl -X ${capture.method}');
  buffer.write(' ${shellQuote(capture.uri.toString())}');
  for (final header in capture.requestHeaders) {
    buffer.write(' \\\n  -H ${shellQuote('${header.name}: ${header.value}')}');
  }
  final body = capture.requestBody;
  if (body != null && body.isNotEmpty) {
    buffer.write(
      ' \\\n  --data-binary '
      '${shellQuote(utf8.decode(body, allowMalformed: true))}',
    );
  }
  return buffer.toString();
}

/// cURL for a request observed by the injected page script.
///
/// These are the *caller* headers only: WebKit adds Cookie, Sec-Fetch-* and
/// the transport fingerprint itself, so this is not the wire-level packet.
String buildPageCurl(PageNetworkEvent event) {
  final buffer = StringBuffer('curl -X ${event.method ?? 'GET'}');
  buffer.write(' ${shellQuote(event.url ?? '')}');
  for (final entry in event.headers.entries) {
    buffer.write(' \\\n  -H ${shellQuote('${entry.key}: ${entry.value}')}');
  }
  final body = event.body;
  if (body != null && body.isNotEmpty) {
    buffer.write(' \\\n  --data-binary ${shellQuote(body)}');
  }
  return buffer.toString();
}

/// Text preview of a native response body, hex-dumping clearly binary data.
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
