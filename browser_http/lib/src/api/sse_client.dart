import 'dart:async';
import 'dart:convert';

import '../domain/errors.dart';
import '../domain/models/transport.dart';
import '../ports/transport_port.dart';
import 'browser_session.dart';

/// One dispatched Server-Sent Event.
final class SseEvent {
  const SseEvent({
    required this.data,
    this.id,
    this.event,
    this.retry,
  });

  /// Concatenated `data:` lines, joined with `\n`.
  final String data;

  /// Last event id seen by the parser.
  final String? id;

  /// `event:` field; servers usually omit it for the default `message` type.
  final String? event;

  /// Reconnection delay advertised by the server.
  final Duration? retry;

  @override
  String toString() => 'SseEvent(event: $event, id: $id, data: $data)';
}

/// Parses the `text/event-stream` wire format (HTML Living Standard §9.2).
///
/// The parser is deliberately separate from the transport: it is pure, has no
/// timers, and can be tested with a list of lines.
final class SseParser {
  const SseParser._();

  /// Consumes decoded lines and emits dispatched events.
  ///
  /// A trailing event without the final blank line is emitted when the stream
  /// closes, matching what browsers do.
  static Stream<SseEvent> parse(Stream<String> lines) async* {
    final data = <String>[];
    String? id;
    String? event;
    Duration? retry;

    await for (final line in lines) {
      if (line.isEmpty) {
        if (data.isNotEmpty) {
          yield SseEvent(
            data: data.join('\n'),
            id: id,
            event: event,
            retry: retry,
          );
        }
        data.clear();
        event = null;
        // `id` and `retry` persist across events, per spec.
        continue;
      }

      if (line.startsWith(':')) continue; // comment / keep-alive

      final colon = line.indexOf(':');
      final field = colon < 0 ? line : line.substring(0, colon);
      var value = colon < 0 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);

      switch (field) {
        case 'data':
          data.add(value);
        case 'event':
          event = value;
        case 'id':
          if (!value.contains('\u0000')) id = value;
        case 'retry':
          final millis = int.tryParse(value);
          if (millis != null && millis >= 0) {
            retry = Duration(milliseconds: millis);
          }
        default:
          break; // unknown fields are ignored
      }
    }

    if (data.isNotEmpty) {
      yield SseEvent(data: data.join('\n'), id: id, event: event, retry: retry);
    }
  }
}

/// Server-Sent Events client bound to a [BrowserSession].
///
/// The connection uses the native transport, so cookies, proxy and browser
/// fingerprint are identical to ordinary requests.
///
/// Automatic reconnection is intentionally left to the caller: it needs a
/// policy (max attempts, backoff) that belongs to the application. Pass the
/// last event id back via [lastEventId].
final class SseClient {
  SseClient({required this.session});

  final BrowserSession session;

  Stream<SseEvent> connect(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    CancelToken? cancelToken,
    String? lastEventId,
  }) async* {
    final request = TransportRequest(
      method: 'GET',
      uri: uri,
      profileId: session.profile.id,
      headers: <OrderedHeader>[
        const OrderedHeader('Accept', 'text/event-stream'),
        const OrderedHeader('Cache-Control', 'no-cache'),
        if (lastEventId != null && lastEventId.isNotEmpty)
          OrderedHeader('Last-Event-ID', lastEventId),
        for (final entry in headers.entries)
          OrderedHeader(entry.key, entry.value),
      ],
    );

    final response = await session.openStream(request, cancelToken: cancelToken);
    if (response.statusCode != 200) {
      throw TransportException(
        code: BrowserErrorCodes.transportProtocol,
        message: 'SSE endpoint returned HTTP ${response.statusCode}.',
      );
    }

    final lines = response.body
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter());
    yield* SseParser.parse(lines);
  }
}
