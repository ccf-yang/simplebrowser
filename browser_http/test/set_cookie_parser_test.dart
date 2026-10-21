import 'package:browser_http/src/domain/cookies/set_cookie_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final origin = Uri.parse('https://www.example.com/account/login?x=1');

  group('parseSetCookie', () {
    test('parses name/value and applies the RFC default path', () {
      final cookie = parseSetCookie('sid=abc123; HttpOnly', origin)!;

      expect(cookie.name, 'sid');
      expect(cookie.value, 'abc123');
      expect(cookie.path, '/account');
      expect(cookie.httpOnly, isTrue);
      expect(cookie.secure, isFalse);
      expect(cookie.domain, isNull);
      expect(cookie.expires, isNull);
    });

    test('parses every attribute case-insensitively', () {
      final cookie = parseSetCookie(
        'a=b; Path=/; Domain=.Example.COM; Secure; HttpOnly; SameSite=none',
        origin,
      )!;

      expect(cookie.path, '/');
      expect(cookie.domain, '.example.com');
      expect(cookie.secure, isTrue);
      expect(cookie.httpOnly, isTrue);
      expect(cookie.sameSite, 'None');
    });

    test('Max-Age takes precedence over Expires', () {
      final cookie = parseSetCookie(
        'a=b; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Max-Age=3600',
        origin,
      )!;

      expect(cookie.expires, isNotNull);
      expect(
        cookie.expires!.isAfter(DateTime.now().toUtc()),
        isTrue,
        reason: 'Max-Age=3600 must be relative to now',
      );
    });

    test('Max-Age=0 expires the cookie immediately', () {
      final cookie = parseSetCookie('a=b; Max-Age=0', origin)!;

      expect(cookie.isExpired, isTrue);
    });

    test('parses IMF-fixdate, RFC 850 and asctime Expires values', () {
      final imf = parseSetCookie(
        'a=b; Expires=Wed, 21 Oct 2015 07:28:00 GMT',
        origin,
      )!;
      final rfc850 = parseSetCookie(
        'a=b; Expires=Wednesday, 21-Oct-15 07:28:00 GMT',
        origin,
      )!;
      final asctime = parseSetCookie(
        'a=b; Expires=Wed Oct 21 07:28:00 2015',
        origin,
      )!;

      expect(imf.expires, DateTime.utc(2015, 10, 21, 7, 28));
      expect(rfc850.expires, DateTime.utc(2015, 10, 21, 7, 28));
      expect(asctime.expires, DateTime.utc(2015, 10, 21, 7, 28));
    });

    test('keeps values containing "="', () {
      final cookie = parseSetCookie('token=a=b=c; Path=/', origin)!;

      expect(cookie.name, 'token');
      expect(cookie.value, 'a=b=c');
    });

    test('rejects malformed headers instead of throwing', () {
      expect(parseSetCookie('', origin), isNull);
      expect(parseSetCookie('=novalue', origin), isNull);
      expect(parseSetCookie('bad name=value', origin), isNull);
      expect(parseSetCookie('no-equals', origin), isNull);
    });

    test('ignores unknown attributes and invalid SameSite values', () {
      final cookie = parseSetCookie(
        'a=b; Priority=High; SameSite=Sideways',
        origin,
      )!;

      expect(cookie.sameSite, isNull);
    });
  });
}
