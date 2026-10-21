import 'package:browser_http/browser_http.dart';
import 'package:flutter_test/flutter_test.dart';

SessionSnapshot _snapshot({
  String profileId = 'safari_ios_18',
  String userAgent = 'UA',
  Map<String, String> hints = const <String, String>{},
  DateTime? expiresAt,
}) {
  final now = DateTime.now().toUtc();
  return SessionSnapshot(
    profileId: profileId,
    origin: Uri.parse('https://example.com'),
    userAgent: userAgent,
    clientHints: hints,
    cookies: const <BrowserCookie>[],
    createdAt: now,
    expiresAt: expiresAt ?? now.add(const Duration(minutes: 30)),
  );
}

void main() {
  const guard = ConsistencyGuard();

  test('accepts identical identities', () {
    expect(
      () => guard.verify(expected: _snapshot(), actual: _snapshot()),
      returnsNormally,
    );
  });

  test('rejects a profile mismatch', () {
    expect(
      () => guard.verify(
        expected: _snapshot(),
        actual: _snapshot(profileId: 'chrome_windows_131'),
      ),
      throwsA(
        isA<ConsistencyException>().having(
          (e) => e.code,
          'code',
          BrowserErrorCodes.consistencyProfileMismatch,
        ),
      ),
    );
  });

  test('rejects a user agent mismatch', () {
    expect(
      () => guard.verify(
        expected: _snapshot(userAgent: 'A'),
        actual: _snapshot(userAgent: 'B'),
      ),
      throwsA(
        isA<ConsistencyException>().having(
          (e) => e.code,
          'code',
          BrowserErrorCodes.consistencyUserAgentMismatch,
        ),
      ),
    );
  });

  test('rejects client hint mismatches', () {
    expect(
      () => guard.verify(
        expected: _snapshot(hints: const <String, String>{'sec-ch-ua': 'a'}),
        actual: _snapshot(hints: const <String, String>{'sec-ch-ua': 'b'}),
      ),
      throwsA(
        isA<ConsistencyException>().having(
          (e) => e.code,
          'code',
          BrowserErrorCodes.consistencyClientHintsMismatch,
        ),
      ),
    );
  });

  test('rejects an expired snapshot', () {
    expect(
      () => guard.verify(
        expected: _snapshot(
          expiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
        ),
        actual: _snapshot(),
      ),
      throwsA(
        isA<ConsistencyException>().having(
          (e) => e.code,
          'code',
          BrowserErrorCodes.consistencyExpired,
        ),
      ),
    );
  });
}
