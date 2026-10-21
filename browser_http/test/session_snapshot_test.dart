import 'package:browser_http/browser_http.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SessionSnapshot round-trips through JSON', () {
    final now = DateTime.utc(2026, 1, 1);
    final snapshot = SessionSnapshot(
      profileId: 'safari_ios_18',
      origin: Uri.parse('https://example.com'),
      userAgent: 'UA',
      clientHints: const <String, String>{'sec-ch-ua-platform': '"iOS"'},
      cookies: <BrowserCookie>[
        BrowserCookie(
          name: 'cf_clearance',
          value: 'token',
          domain: '.example.com',
          expires: now.add(const Duration(minutes: 30)),
        ),
      ],
      localStorage: const <String, Map<String, String>>{
        'https://example.com': <String, String>{'k': 'v'},
      },
      egressIpHash: 'abc',
      createdAt: now,
      expiresAt: now.add(const Duration(minutes: 30)),
    );

    final restored = SessionSnapshot.fromJson(snapshot.toJson());

    expect(restored.profileId, snapshot.profileId);
    expect(restored.origin, snapshot.origin);
    expect(restored.userAgent, snapshot.userAgent);
    expect(restored.clientHints, snapshot.clientHints);
    expect(restored.cookies, snapshot.cookies);
    expect(restored.localStorage, snapshot.localStorage);
    expect(restored.egressIpHash, snapshot.egressIpHash);
    expect(restored.createdAt, snapshot.createdAt);
    expect(restored.expiresAt, snapshot.expiresAt);
  });

  test('cookie matching respects domain, path and secure', () {
    const cookie = BrowserCookie(
      name: 'a',
      value: 'b',
      domain: '.example.com',
      secure: true,
    );

    expect(cookie.matches(Uri.parse('https://api.example.com/x')), isTrue);
    expect(cookie.matches(Uri.parse('http://api.example.com/x')), isFalse);
    expect(cookie.matches(Uri.parse('https://other.com/x')), isFalse);
  });
}
