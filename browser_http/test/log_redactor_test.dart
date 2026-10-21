import 'package:browser_http/browser_http.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const redactor = LogRedactor();

  group('LogRedactor', () {
    test('masks sensitive headers case-insensitively', () {
      final result = redactor.headers(<String, String>{
        'Authorization': 'Bearer secret',
        'Cookie': 'session=abc',
        'Set-Cookie': 'a=b',
        'Accept': 'text/html',
      });

      expect(result['Authorization'], '<redacted>');
      expect(result['Cookie'], '<redacted>');
      expect(result['Set-Cookie'], '<redacted>');
      expect(result['Accept'], 'text/html');
    });

    test('masks sensitive query parameters and drops the fragment', () {
      final uri = redactor.uri(
        Uri.parse('https://x.test/a?token=abc&page=2#frag'),
      );

      expect(uri.queryParameters['token'], '<redacted>');
      expect(uri.queryParameters['page'], '2');
      expect(uri.fragment, isEmpty);
    });

    test('custom mask and custom sensitive set', () {
      const custom = LogRedactor(
        sensitiveHeaders: <String>{'x-secret'},
        mask: '***',
      );
      final result = custom.headers(<String, String>{
        'X-Secret': 'v',
        'Authorization': 'keep-me',
      });

      expect(result['X-Secret'], '***');
      expect(result['Authorization'], 'keep-me');
    });
  });
}
