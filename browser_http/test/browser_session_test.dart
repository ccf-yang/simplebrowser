import 'dart:convert';
import 'dart:typed_data';

import 'package:browser_http/browser_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('BrowserSession', () {
    test('assigns a request id and logs start + response', () async {
      final sink = MemoryLogSink();
      final response = _response(
        statusCode: 200,
        headers: const <OrderedHeader>[
          OrderedHeader('Content-Type', 'text/plain'),
        ],
        body: 'hello',
      );
      final transport = _FakeTransport(response);
      final session = _session(transport: transport, logSink: sink);

      await session.send(
        TransportRequest(
          method: 'GET',
          uri: Uri.parse('https://example.com/a'),
          profileId: session.profile.id,
        ),
      );

      final sent = transport.requests.single;
      expect(sent.id, hasLength(16));
      expect(sent.profileId, session.profile.id);

      expect(
        sink.events.map((event) => event.phase),
        <RequestLogPhase>[
          RequestLogPhase.start,
          RequestLogPhase.response,
        ],
      );
      expect(sink.events.first.id, sent.id);
      expect(sink.events.last.id, sent.id);
      expect(sink.events.last.statusCode, 200);
    });

    test('keeps a caller-supplied request id', () async {
      final transport = _FakeTransport(_response());
      final session = _session(transport: transport);

      await session.send(
        TransportRequest(
          id: 'caller-id',
          method: 'GET',
          uri: Uri.parse('https://example.com/'),
          profileId: session.profile.id,
        ),
      );

      expect(transport.requests.single.id, 'caller-id');
    });

    test('rejects a request for a different profile', () async {
      final transport = _FakeTransport(_response());
      final session = _session(transport: transport);

      await expectLater(
        session.send(
          TransportRequest(
            method: 'GET',
            uri: Uri.parse('https://example.com/'),
            profileId: 'chrome_windows_149',
          ),
        ),
        throwsA(
          isA<ConsistencyException>().having(
            (error) => error.code,
            'code',
            BrowserErrorCodes.consistencyProfileMismatch,
          ),
        ),
      );
      expect(transport.requests, isEmpty);
    });

    test('injects stored cookies and persists Set-Cookie responses', () async {
      final uri = Uri.parse('https://example.com/');
      final cookieStore = _FakeCookies();
      await cookieStore.setAll(uri, <BrowserCookie>[
        const BrowserCookie(name: 'sid', value: 'abc'),
      ]);

      final transport = _FakeTransport(
        _response(
          headers: const <OrderedHeader>[
            OrderedHeader('Set-Cookie', 'fresh=1; Path=/; HttpOnly'),
          ],
        ),
      );
      final session = _session(transport: transport, cookies: cookieStore);

      await session.send(
        TransportRequest(
          method: 'GET',
          uri: uri,
          profileId: session.profile.id,
        ),
      );

      final sent = transport.requests.single;
      expect(sent.headers.last.name, 'Cookie');
      expect(sent.headers.last.value, 'sid=abc');

      final merged = cookieStore.merged.single;
      expect(merged.$1, uri);
      expect(merged.$2.single.name, 'fresh');
      expect(merged.$2.single.httpOnly, isTrue);
    });

    test('does not override a caller-supplied Cookie header', () async {
      final uri = Uri.parse('https://example.com/');
      final cookieStore = _FakeCookies();
      await cookieStore.setAll(uri, <BrowserCookie>[
        const BrowserCookie(name: 'sid', value: 'stored'),
      ]);
      final transport = _FakeTransport(_response());
      final session = _session(transport: transport, cookies: cookieStore);

      await session.send(
        TransportRequest(
          method: 'GET',
          uri: uri,
          profileId: session.profile.id,
          headers: const <OrderedHeader>[
            OrderedHeader('Cookie', 'explicit=1'),
          ],
        ),
      );

      final cookieHeaders = transport.requests.single.headers
          .where((header) => header.name.toLowerCase() == 'cookie')
          .toList();
      expect(cookieHeaders, hasLength(1));
      expect(cookieHeaders.single.value, 'explicit=1');
    });

    test('follows redirects and makes cookies available to the next hop',
        () async {
      final cookieStore = _FakeCookies();
      final transport = _ScriptedTransport(<TransportResponse>[
        _response(
          statusCode: 302,
          headers: const <OrderedHeader>[
            OrderedHeader('Set-Cookie', 'sid=1; Path=/'),
            OrderedHeader('Location', '/next'),
          ],
        ),
        _response(body: 'done'),
      ]);
      final session = _session(transport: transport, cookies: cookieStore);

      final response = await session.send(
        TransportRequest(
          method: 'GET',
          uri: Uri.parse('https://example.com/start'),
          profileId: session.profile.id,
        ),
      );

      expect(response.statusCode, 200);
      expect(transport.requests, hasLength(2));
      expect(
        transport.requests[1].uri.toString(),
        'https://example.com/next',
      );
      expect(
        transport.requests[1].headers
            .firstWhere((header) => header.name == 'Cookie')
            .value,
        'sid=1',
      );
    });

    test('303 turns a POST into a body-less GET', () async {
      final transport = _ScriptedTransport(<TransportResponse>[
        _response(
          statusCode: 303,
          headers: const <OrderedHeader>[
            OrderedHeader('Location', 'https://other.example.com/result'),
          ],
        ),
        _response(body: 'ok'),
      ]);
      final session = _session(transport: transport);

      await session.send(
        TransportRequest(
          method: 'POST',
          uri: Uri.parse('https://example.com/submit'),
          profileId: session.profile.id,
          headers: const <OrderedHeader>[
            OrderedHeader('Content-Type', 'application/json'),
            OrderedHeader('Authorization', 'Bearer secret'),
          ],
          body: Uint8List.fromList(utf8.encode('{}')),
        ),
      );

      final redirected = transport.requests[1];
      expect(redirected.method, 'GET');
      expect(redirected.body, isNull);
      expect(
        redirected.headers.any(
          (header) => header.name.toLowerCase() == 'content-type',
        ),
        isFalse,
      );
      expect(
        redirected.headers.any(
          (header) => header.name.toLowerCase() == 'authorization',
        ),
        isFalse,
        reason: 'authorization must not cross origins',
      );
    });

    test('does not follow redirects when the caller opts out', () async {
      final transport = _ScriptedTransport(<TransportResponse>[
        _response(
          statusCode: 302,
          headers: const <OrderedHeader>[
            OrderedHeader('Location', 'https://example.com/next'),
          ],
        ),
      ]);
      final session = _session(transport: transport);

      final response = await session.send(
        TransportRequest(
          method: 'GET',
          uri: Uri.parse('https://example.com/start'),
          profileId: session.profile.id,
          followRedirects: false,
        ),
      );

      expect(response.statusCode, 302);
      expect(transport.requests, hasLength(1));
    });

    test('openStream injects cookies and returns headers before the body',
        () async {
      final uri = Uri.parse('https://example.com/events');
      final cookieStore = _FakeCookies();
      await cookieStore.setAll(uri, <BrowserCookie>[
        const BrowserCookie(name: 'sid', value: '1'),
      ]);
      final transport = _StreamingTransport(
        TransportStream(
          statusCode: 200,
          headers: const <OrderedHeader>[
            OrderedHeader('Content-Type', 'text/event-stream'),
            OrderedHeader('Set-Cookie', 'a=b; Path=/'),
          ],
          body: Stream<List<int>>.value(utf8.encode('data: hi\n\n')),
        ),
      );
      final session = _session(transport: transport, cookies: cookieStore);

      final response = await session.openStream(
        TransportRequest(
          method: 'GET',
          uri: uri,
          profileId: session.profile.id,
        ),
      );

      expect(response.statusCode, 200);
      expect(response.header('content-type'), 'text/event-stream');
      expect(
        transport.requests.single.headers
            .firstWhere((header) => header.name == 'Cookie')
            .value,
        'sid=1',
      );
      expect(cookieStore.merged.single.$2.single.name, 'a');
      expect(
        await response.body.transform(utf8.decoder).join(),
        'data: hi\n\n',
      );
    });

    test('capture exposes the outgoing headers and buffered response',
        () async {
      final uri = Uri.parse('https://example.com/page');
      final cookieStore = _FakeCookies();
      await cookieStore.setAll(uri, <BrowserCookie>[
        const BrowserCookie(name: 'sid', value: '1'),
      ]);
      final transport = _FakeTransport(
        _response(
          statusCode: 204,
          headers: const <OrderedHeader>[
            OrderedHeader('X-Trace', 't-1'),
          ],
        ),
      );
      final session = _session(transport: transport, cookies: cookieStore);

      final captured = await session.capture(uri);

      expect(captured.method, 'GET');
      expect(captured.uri, uri);
      expect(captured.profile.userAgent, 'test-agent');
      expect(captured.response.statusCode, 204);
      expect(captured.responseBodyLength, 0);
      expect(
        captured.requestHeaders
            .firstWhere((header) => header.name == 'Cookie')
            .value,
        'sid=1',
      );
      expect(transport.requests.single.id, captured.requestId);
    });

    test('forwards the cancellation token to the transport', () async {
      final transport = _FakeTransport(_response());
      final session = _session(transport: transport);
      final token = CancelToken();

      await session.send(
        TransportRequest(
          method: 'GET',
          uri: Uri.parse('https://example.com/'),
          profileId: session.profile.id,
        ),
        cancelToken: token,
      );

      expect(transport.tokens.single, same(token));
    });

    test('logs errors and rethrows them', () async {
      final sink = MemoryLogSink();
      final session = _session(
        transport: _FakeTransport.error(
          const TransportException(
            code: BrowserErrorCodes.transportTimeout,
            message: 'timed out',
          ),
        ),
        logSink: sink,
      );

      await expectLater(
        session.send(
          TransportRequest(
            method: 'GET',
            uri: Uri.parse('https://example.com/'),
            profileId: session.profile.id,
          ),
        ),
        throwsA(isA<TransportException>()),
      );

      expect(sink.events.last.phase, RequestLogPhase.error);
      expect(sink.events.last.errorCode, BrowserErrorCodes.transportTimeout);
    });
  });

  group('BrowserClient', () {
    test('converts an http.BaseRequest and returns a StreamedResponse',
        () async {
      final transport = _FakeTransport(
        _response(
          statusCode: 201,
          headers: const <OrderedHeader>[
            OrderedHeader('X-Trace', 'abc'),
            OrderedHeader('X-Trace', 'def'),
          ],
          body: 'created',
        ),
      );
      final session = _session(transport: transport);
      final client = BrowserClient(session: session);

      final request = http.Request(
        'POST',
        Uri.parse('https://example.com/items?page=2'),
      )
        ..headers['X-Custom'] = '1'
        ..body = 'payload';

      final response = await client.send(request);

      final sent = transport.requests.single;
      expect(sent.method, 'POST');
      expect(sent.uri.toString(), 'https://example.com/items?page=2');
      expect(
        sent.headers.any(
          (header) => header.name == 'X-Custom' && header.value == '1',
        ),
        isTrue,
      );
      expect(utf8.decode(sent.body!), 'payload');

      expect(response.statusCode, 201);
      expect(await response.stream.bytesToString(), 'created');
      expect(response.headers['X-Trace'], 'def');
    });
  });
}

BrowserSession _session({
  required TransportPort transport,
  CookiePort? cookies,
  LogSink? logSink,
}) =>
    BrowserSession(
      profile: BrowserProfile.safariIos18,
      transport: transport,
      cookies: cookies ?? _FakeCookies(),
      vault: _FakeVault(),
      webView: _FakeWebView(),
      logSink: logSink,
    );

TransportResponse _response({
  int statusCode = 200,
  List<OrderedHeader> headers = const <OrderedHeader>[],
  String body = '',
}) =>
    TransportResponse(
      statusCode: statusCode,
      headers: headers,
      body: Uint8List.fromList(utf8.encode(body)),
    );

final class _FakeTransport implements TransportPort {
  _FakeTransport(this._response) : _error = null;

  _FakeTransport.error(this._error)
      : _response = null;

  final TransportResponse? _response;
  final Object? _error;

  final List<TransportRequest> requests = <TransportRequest>[];
  final List<CancelToken?> tokens = <CancelToken?>[];

  @override
  Future<TransportResponse> send(
    TransportRequest request, {
    CancelToken? cancelToken,
  }) async {
    requests.add(request);
    tokens.add(cancelToken);
    final error = _error;
    if (error != null) throw error;
    return _response!;
  }

  @override
  Future<TransportStream> openStream(
    TransportRequest request, {
    CancelToken? cancelToken,
  }) =>
      throw UnimplementedError();

  @override
  Future<ProfileInfo> profileInfo(String profileId) async => ProfileInfo(
        profileId: profileId,
        family: 'safari',
        userAgent: 'test-agent',
        clientHints: const <String, String>{},
      );

  @override
  Future<List<ProfileDescriptor>> listProfiles() async =>
      const <ProfileDescriptor>[];

  @override
  Future<void> close() async {}
}

final class _ScriptedTransport implements TransportPort {
  _ScriptedTransport(this._responses);

  final List<TransportResponse> _responses;
  final List<TransportRequest> requests = <TransportRequest>[];

  @override
  Future<TransportResponse> send(
    TransportRequest request, {
    CancelToken? cancelToken,
  }) async {
    requests.add(request);
    return _responses[requests.length - 1];
  }

  @override
  Future<TransportStream> openStream(
    TransportRequest request, {
    CancelToken? cancelToken,
  }) =>
      throw UnimplementedError();

  @override
  Future<ProfileInfo> profileInfo(String profileId) async => ProfileInfo(
        profileId: profileId,
        family: 'safari',
        userAgent: 'test-agent',
        clientHints: const <String, String>{},
      );

  @override
  Future<List<ProfileDescriptor>> listProfiles() async =>
      const <ProfileDescriptor>[];

  @override
  Future<void> close() async {}
}

final class _StreamingTransport implements TransportPort {
  _StreamingTransport(this._response);

  final TransportStream _response;
  final List<TransportRequest> requests = <TransportRequest>[];

  @override
  Future<TransportResponse> send(
    TransportRequest request, {
    CancelToken? cancelToken,
  }) =>
      throw UnimplementedError();

  @override
  Future<TransportStream> openStream(
    TransportRequest request, {
    CancelToken? cancelToken,
  }) async {
    requests.add(request);
    return _response;
  }

  @override
  Future<ProfileInfo> profileInfo(String profileId) async => ProfileInfo(
        profileId: profileId,
        family: 'safari',
        userAgent: 'test-agent',
        clientHints: const <String, String>{},
      );

  @override
  Future<List<ProfileDescriptor>> listProfiles() async =>
      const <ProfileDescriptor>[];

  @override
  Future<void> close() async {}
}

/// Mimics a browser jar: cookies are matched by domain/path, not by the exact
/// URL that stored them.
final class _FakeCookies implements CookiePort {
  final List<BrowserCookie> _cookies = <BrowserCookie>[];
  final List<(Uri, List<BrowserCookie>)> merged =
      <(Uri, List<BrowserCookie>)>[];

  @override
  Future<List<BrowserCookie>> get(Uri uri) async =>
      _cookies.where((cookie) => cookie.matches(uri)).toList(growable: false);

  @override
  Future<void> setAll(Uri uri, List<BrowserCookie> cookies) async {
    _cookies.removeWhere((existing) => _sameKey(existing, cookies));
    _cookies.removeWhere((existing) => existing.matches(uri));
    _cookies.addAll(cookies);
  }

  @override
  Future<void> merge(Uri uri, List<BrowserCookie> cookies) async {
    merged.add((uri, List<BrowserCookie>.of(cookies)));
    _cookies.removeWhere((existing) => _sameKey(existing, cookies));
    _cookies.addAll(cookies);
  }

  @override
  Future<void> removeAll(Uri uri) async {
    _cookies.removeWhere((cookie) => cookie.matches(uri));
  }

  @override
  Future<void> clear() async {
    _cookies.clear();
  }

  static bool _sameKey(BrowserCookie cookie, List<BrowserCookie> others) =>
      others.any(
        (other) =>
            other.name == cookie.name &&
            other.domain == cookie.domain &&
            other.path == cookie.path,
      );
}

final class _FakeVault implements VaultPort {
  final Map<String, SessionSnapshot> _values = <String, SessionSnapshot>{};

  @override
  Future<SessionSnapshot?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, SessionSnapshot snapshot) async {
    _values[key] = snapshot;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

final class _FakeWebView implements WebViewPort {
  @override
  Future<WebViewSession> create({
    required String userAgent,
    bool headless = true,
  }) =>
      throw UnimplementedError();

  @override
  bool get isVisibleModeSupported => false;
}
