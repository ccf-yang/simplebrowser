import 'package:browser_http/browser_http.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WebResourceTiming', () {
    test('parses Performance API fields', () {
      final timing = WebResourceTiming.fromJson(<String, Object?>{
        'url': 'https://example.com/app.js',
        'initiatorType': 'script',
        'duration': 12.5,
        'transferSize': 1024,
        'encodedBodySize': 900,
      });

      expect(timing.url, 'https://example.com/app.js');
      expect(timing.initiatorType, 'script');
      expect(timing.duration, 12.5);
      expect(timing.transferSize, 1024);
      expect(timing.encodedBodySize, 900);
    });

    test('tolerates missing optional fields', () {
      final timing = WebResourceTiming.fromJson(<String, Object?>{
        'url': 'https://example.com/font.woff2',
        'initiatorType': 'css',
        'duration': null,
        'transferSize': null,
        'encodedBodySize': null,
      });

      expect(timing.initiatorType, 'css');
      expect(timing.duration, 0);
      expect(timing.transferSize, isNull);
      expect(timing.encodedBodySize, isNull);
    });

    test('round-trips through toJson', () {
      const timing = WebResourceTiming(
        url: 'https://example.com/a.css',
        initiatorType: 'link',
        duration: 3.25,
        transferSize: 256,
        encodedBodySize: 128,
      );

      final decoded = WebResourceTiming.fromJson(timing.toJson());

      expect(decoded.url, timing.url);
      expect(decoded.initiatorType, timing.initiatorType);
      expect(decoded.duration, timing.duration);
      expect(decoded.transferSize, timing.transferSize);
      expect(decoded.encodedBodySize, timing.encodedBodySize);
    });
  });
}
