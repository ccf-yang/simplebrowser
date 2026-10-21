import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../domain/models/transport.dart';
import 'browser_session.dart';

/// Drop-in `http.Client` backed by the session's native transport.
///
/// ```dart
/// final client = BrowserClient(session: BrowserHttp.session());
/// final response = await client.get(Uri.parse('https://example.com'));
/// ```
///
/// Note: `http.BaseRequest.headers` is a map, so a caller-supplied map cannot
/// express every duplicate-header case. The native profile still applies the
/// browser-correct header *order* for its own defaults.
final class BrowserClient extends http.BaseClient {
  BrowserClient({required this.session});

  final BrowserSession session;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();

    final headers = <OrderedHeader>[
      for (final entry in request.headers.entries)
        OrderedHeader(entry.key, entry.value),
    ];

    final response = await session.send(
      TransportRequest(
        method: request.method,
        uri: request.url,
        profileId: session.profile.id,
        headers: headers,
        body: body.isEmpty ? null : Uint8List.fromList(body),
        followRedirects: request.followRedirects,
        maxRedirects: request.maxRedirects,
      ),
    );

    return http.StreamedResponse(
      Stream<List<int>>.value(response.body),
      response.statusCode,
      contentLength: response.body.length,
      request: request,
      headers: <String, String>{
        for (final header in response.headers) header.name: header.value,
      },
      reasonPhrase: response.header('reason-phrase'),
    );
  }

  @override
  void close() {
    // The session owns the transport lifetime.
  }
}
