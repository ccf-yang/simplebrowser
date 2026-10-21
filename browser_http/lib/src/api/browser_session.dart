import 'dart:math';

import '../domain/consistency_guard.dart';
import '../domain/cookies/set_cookie_parser.dart';
import '../domain/errors.dart';
import '../domain/logging/log_redactor.dart';
import '../domain/logging/request_log.dart';
import '../domain/models/browser_cookie.dart';
import '../domain/models/captured_exchange.dart';
import '../domain/models/session_snapshot.dart';
import '../domain/models/transport.dart';
import '../ports/cookie_port.dart';
import '../ports/log_sink.dart';
import '../ports/transport_port.dart';
import '../ports/vault_port.dart';
import '../ports/webview_port.dart';
import 'browser_profile.dart';
import 'challenge_controller.dart';

/// A browsing identity: one profile, one cookie jar, one challenge controller.
///
/// Everything that must stay consistent across the native transport and
/// WKWebView is owned here.
final class BrowserSession {
  BrowserSession({
    required this.profile,
    required this.transport,
    required this.cookies,
    required this.vault,
    required this.webView,
    LogSink? logSink,
    LogRedactor? redactor,
    ConsistencyGuard? guard,
  })  : _logSink = logSink,
        _redactor = redactor ?? const LogRedactor(),
        _guard = guard ?? const ConsistencyGuard() {
    challenge = ChallengeController(session: this);
  }

  final BrowserProfile profile;
  final TransportPort transport;
  final CookiePort cookies;
  final VaultPort vault;
  final WebViewPort webView;

  final LogSink? _logSink;
  final LogRedactor _redactor;
  final ConsistencyGuard _guard;

  late final ChallengeController challenge;

  final Random _random = Random.secure();

  /// Identity defaults as defined by the native profile.
  Future<ProfileInfo> profileInfo() => transport.profileInfo(profile.id);

  /// Sends a request through the native transport.
  ///
  /// Profile defaults (UA, header order, client hints) are applied natively;
  /// [request] only carries caller-supplied headers.
  Future<TransportResponse> send(
    TransportRequest request, {
    CancelToken? cancelToken,
  }) async {
    if (request.profileId != profile.id) {
      throw ConsistencyException(
        code: BrowserErrorCodes.consistencyProfileMismatch,
        message: 'Request profile ${request.profileId} does not match the '
            'session profile ${profile.id}.',
      );
    }

    final id = request.id.isEmpty ? _newRequestId() : request.id;
    final effective = request.id == id ? request : request.copyWith(id: id);
    final stopwatch = Stopwatch()..start();
    _log(RequestLogEvent(
      id: id,
      phase: RequestLogPhase.start,
      timestamp: DateTime.now(),
      method: request.method,
      uri: _redactor.uri(request.uri),
      profileId: profile.id,
    ));

    try {
      final response = await _sendFollowingRedirects(
        effective,
        cancelToken: cancelToken,
      );
      _log(RequestLogEvent(
        id: id,
        phase: RequestLogPhase.response,
        timestamp: DateTime.now(),
        statusCode: response.statusCode,
        elapsed: stopwatch.elapsed,
        method: request.method,
        uri: _redactor.uri(request.uri),
        profileId: profile.id,
        fingerprint: response.fingerprint,
      ));
      return response;
    } on BrowserHttpException catch (error, stackTrace) {
      _log(RequestLogEvent(
        id: id,
        phase: error is CancelledException
            ? RequestLogPhase.cancelled
            : RequestLogPhase.error,
        timestamp: DateTime.now(),
        level: RequestLogLevel.error,
        elapsed: stopwatch.elapsed,
        method: request.method,
        uri: _redactor.uri(request.uri),
        profileId: profile.id,
        errorCode: error.code,
        message: error.message,
      ));
      Error.throwWithStackTrace(error, stackTrace);
    } on Object catch (error, stackTrace) {
      final wrapped = TransportException(
        code: BrowserErrorCodes.transportConnect,
        message: 'Transport failed: $error',
        cause: error,
        stackTrace: stackTrace,
      );
      _log(RequestLogEvent(
        id: id,
        phase: RequestLogPhase.error,
        timestamp: DateTime.now(),
        level: RequestLogLevel.error,
        elapsed: stopwatch.elapsed,
        method: request.method,
        uri: _redactor.uri(request.uri),
        profileId: profile.id,
        errorCode: wrapped.code,
        message: wrapped.message,
      ));
      Error.throwWithStackTrace(wrapped, stackTrace);
    }
  }

  /// Convenience wrapper used by the examples and the challenge flow.
  Future<TransportResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    CancelToken? cancelToken,
  }) =>
      send(
        TransportRequest(
          method: 'GET',
          uri: uri,
          profileId: profile.id,
          headers: <OrderedHeader>[
            for (final entry in headers.entries)
              OrderedHeader(entry.key, entry.value),
          ],
        ),
        cancelToken: cancelToken,
      );

  /// Sends one request through the native transport and returns both the
  /// outgoing headers and the buffered response.
  ///
  /// Intended for diagnostics (the demo browser's capture panel): unlike
  /// [send], it keeps the effective request — including the `Cookie` header
  /// taken from the shared jar — so a UI can show exactly what was asked of
  /// the native engine.
  Future<CapturedExchange> capture(
    Uri uri, {
    String method = 'GET',
    List<OrderedHeader> headers = const <OrderedHeader>[],
    CancelToken? cancelToken,
  }) async {
    final info = await profileInfo();
    final request = TransportRequest(
      id: _newRequestId(),
      method: method,
      uri: uri,
      profileId: profile.id,
      headers: headers,
      followRedirects: true,
    );
    final outgoing = await _withCookies(request);
    final stopwatch = Stopwatch()..start();
    final response = await send(outgoing, cancelToken: cancelToken);
    stopwatch.stop();
    return CapturedExchange(
      requestId: outgoing.id,
      method: outgoing.method,
      uri: outgoing.uri,
      requestHeaders: outgoing.headers,
      profile: info,
      elapsed: stopwatch.elapsed,
      response: response,
    );
  }

  /// Opens a response without buffering the body.
  ///
  /// Used by SSE and long downloads. Redirects are left to the native layer
  /// here: following them in Dart would require buffering the interim
  /// response. Pass `followRedirects: false` to observe 3xx yourself.
  Future<TransportStream> openStream(
    TransportRequest request, {
    CancelToken? cancelToken,
  }) async {
    if (request.profileId != profile.id) {
      throw ConsistencyException(
        code: BrowserErrorCodes.consistencyProfileMismatch,
        message: 'Request profile ${request.profileId} does not match the '
            'session profile ${profile.id}.',
      );
    }

    final id = request.id.isEmpty ? _newRequestId() : request.id;
    final effective = request.id == id ? request : request.copyWith(id: id);
    final stopwatch = Stopwatch()..start();
    _log(RequestLogEvent(
      id: id,
      phase: RequestLogPhase.start,
      timestamp: DateTime.now(),
      method: request.method,
      uri: _redactor.uri(request.uri),
      profileId: profile.id,
    ));

    try {
      final outgoing = await _withCookies(effective);
      final stream = await transport.openStream(
        outgoing,
        cancelToken: cancelToken,
      );
      await _storeCookies(outgoing.uri, stream.headers);
      _log(RequestLogEvent(
        id: id,
        phase: RequestLogPhase.response,
        timestamp: DateTime.now(),
        statusCode: stream.statusCode,
        elapsed: stopwatch.elapsed,
        method: request.method,
        uri: _redactor.uri(request.uri),
        profileId: profile.id,
      ));
      return stream;
    } on BrowserHttpException catch (error, stackTrace) {
      _log(RequestLogEvent(
        id: id,
        phase: error is CancelledException
            ? RequestLogPhase.cancelled
            : RequestLogPhase.error,
        timestamp: DateTime.now(),
        level: RequestLogLevel.error,
        elapsed: stopwatch.elapsed,
        method: request.method,
        uri: _redactor.uri(request.uri),
        profileId: profile.id,
        errorCode: error.code,
        message: error.message,
      ));
      Error.throwWithStackTrace(error, stackTrace);
    } on Object catch (error, stackTrace) {
      final wrapped = TransportException(
        code: BrowserErrorCodes.transportConnect,
        message: 'Transport failed: $error',
        cause: error,
        stackTrace: stackTrace,
      );
      _log(RequestLogEvent(
        id: id,
        phase: RequestLogPhase.error,
        timestamp: DateTime.now(),
        level: RequestLogLevel.error,
        elapsed: stopwatch.elapsed,
        method: request.method,
        uri: _redactor.uri(request.uri),
        profileId: profile.id,
        errorCode: wrapped.code,
        message: wrapped.message,
      ));
      Error.throwWithStackTrace(wrapped, stackTrace);
    }
  }

  /// Captures the current identity, including cookies and localStorage.
  Future<SessionSnapshot> snapshot({
    required Uri origin,
    Duration ttl = const Duration(minutes: 30),
    String? egressIpHash,
  }) async {
    final info = await profileInfo();
    final now = DateTime.now().toUtc();
    return SessionSnapshot(
      profileId: profile.id,
      origin: origin,
      userAgent: info.userAgent,
      clientHints: info.clientHints,
      cookies: await cookies.get(origin),
      localStorage: <String, Map<String, String>>{
        origin.origin: await _exportLocalStorage(origin),
      },
      egressIpHash: egressIpHash,
      createdAt: now,
      expiresAt: now.add(ttl),
    );
  }

  /// Restores a snapshot after verifying that it is still consistent with the
  /// current native profile and device identity.
  Future<void> restore(SessionSnapshot snapshot) async {
    final info = await profileInfo();
    final now = DateTime.now().toUtc();
    final current = SessionSnapshot(
      profileId: profile.id,
      origin: snapshot.origin,
      userAgent: info.userAgent,
      clientHints: info.clientHints,
      cookies: const <BrowserCookie>[],
      createdAt: now,
      expiresAt: snapshot.expiresAt,
      egressIpHash: snapshot.egressIpHash,
    );
    _guard.verify(expected: snapshot, actual: current);

    for (final entry in snapshot.localStorage.entries) {
      await _importLocalStorage(entry.key, entry.value);
    }
    await cookies.merge(snapshot.origin, snapshot.cookies);
  }

  Future<void> persist(String key, {required Uri origin}) async {
    final captured = await snapshot(origin: origin);
    await vault.write(key, captured);
  }

  Future<SessionSnapshot?> restorePersisted(String key) async {
    final snapshot = await vault.read(key);
    if (snapshot == null) return null;
    await restore(snapshot);
    return snapshot;
  }

  Future<void> close() async {
    await transport.close();
    await _logSink?.close();
  }

  static const Set<int> _redirectCodes = <int>{301, 302, 303, 307, 308};

  static const Set<String> _bodyHeaders = <String>{
    'content-length',
    'content-type',
    'transfer-encoding',
  };

  /// Follows redirects in Dart rather than in Rust.
  ///
  /// This is what lets the cookie jar see every intermediate `Set-Cookie`
  /// (login and clearance flows depend on it) and keeps `Cookie`,
  /// `Authorization` and body handling browser-correct across hops.
  Future<TransportResponse> _sendFollowingRedirects(
    TransportRequest request, {
    CancelToken? cancelToken,
  }) async {
    var current = request.copyWith(followRedirects: false);
    var hops = 0;

    while (true) {
      final outgoing = await _withCookies(current);
      final response = await transport.send(outgoing, cancelToken: cancelToken);
      await _storeCookies(outgoing.uri, response.headers);

      final location = response.header('location');
      if (!request.followRedirects ||
          location == null ||
          !_redirectCodes.contains(response.statusCode)) {
        return response;
      }
      if (hops >= request.maxRedirects) return response;

      final target = outgoing.uri.resolve(location);
      if (target.scheme != 'http' && target.scheme != 'https') return response;

      hops++;
      _log(RequestLogEvent(
        id: request.id,
        phase: RequestLogPhase.redirect,
        timestamp: DateTime.now(),
        method: outgoing.method,
        uri: _redactor.uri(target),
        statusCode: response.statusCode,
        profileId: profile.id,
      ));
      current = _redirectRequest(
        outgoing,
        response.statusCode,
        target,
        request.id,
      );
    }
  }

  TransportRequest _redirectRequest(
    TransportRequest previous,
    int statusCode,
    Uri target,
    String id,
  ) {
    final switchToGet = statusCode == 303 ||
        ((statusCode == 301 || statusCode == 302) &&
            previous.method != 'GET' &&
            previous.method != 'HEAD');
    final crossOrigin = target.origin != previous.uri.origin;

    final headers = <OrderedHeader>[
      for (final header in previous.headers)
        if (!_shouldDropOnRedirect(header.name, switchToGet, crossOrigin))
          header,
    ];

    return TransportRequest(
      id: id,
      method: switchToGet ? 'GET' : previous.method,
      uri: target,
      profileId: previous.profileId,
      headers: headers,
      body: switchToGet ? null : previous.body,
      timeout: previous.timeout,
      followRedirects: false,
      maxRedirects: previous.maxRedirects,
      proxyUrl: previous.proxyUrl,
    );
  }

  bool _shouldDropOnRedirect(
    String name,
    bool switchToGet,
    bool crossOrigin,
  ) {
    final lower = name.toLowerCase();
    if (lower == 'cookie') return true;
    if (switchToGet && _bodyHeaders.contains(lower)) return true;
    if (crossOrigin && (lower == 'authorization' || lower == 'host')) return true;
    return false;
  }

  /// Adds the cookie jar contents to the request, matching what a browser
  /// would put on the wire. A caller-supplied `Cookie` header wins.
  Future<TransportRequest> _withCookies(TransportRequest request) async {
    final hasCookie = request.headers
        .any((header) => header.name.toLowerCase() == 'cookie');
    if (hasCookie) return request;

    final stored = await cookies.get(request.uri);
    final applicable = stored.where((cookie) => cookie.matches(request.uri));
    if (applicable.isEmpty) return request;

    final value = applicable
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
    return request.copyWith(
      headers: <OrderedHeader>[
        ...request.headers,
        OrderedHeader('Cookie', value),
      ],
    );
  }

  /// Persists `Set-Cookie` headers so the next request (and the WKWebView)
  /// sees the same jar. The cookie store is the single source of truth.
  Future<void> _storeCookies(Uri uri, List<OrderedHeader> headers) async {
    final parsed = <BrowserCookie>[];
    for (final header in headers) {
      if (header.name.toLowerCase() != 'set-cookie') continue;
      final cookie = parseSetCookie(header.value, uri);
      if (cookie != null) parsed.add(cookie);
    }
    if (parsed.isEmpty) return;
    await cookies.merge(uri, parsed);
  }

  Future<Map<String, String>> _exportLocalStorage(Uri origin) async {
    try {
      final session =
          await webView.create(userAgent: (await profileInfo()).userAgent);
      try {
        // localStorage is origin-scoped, so the page must be on that origin.
        await session.load(origin);
        return await session.exportLocalStorage(origin);
      } finally {
        await session.dispose();
      }
    } on BrowserHttpException {
      return const <String, String>{};
    }
  }

  Future<void> _importLocalStorage(
    String origin,
    Map<String, String> values,
  ) async {
    if (values.isEmpty) return;
    final session =
        await webView.create(userAgent: (await profileInfo()).userAgent);
    try {
      await session.load(Uri.parse(origin));
      await session.importLocalStorage(Uri.parse(origin), values);
    } finally {
      await session.dispose();
    }
  }

  void _log(RequestLogEvent event) {
    try {
      _logSink?.add(event);
    } on Object {
      // Logging must never break a request.
    }
  }

  String _newRequestId() {
    final bytes = List<int>.generate(8, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
