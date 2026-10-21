import 'package:browser_http/browser_http.dart';
import 'package:flutter_test/flutter_test.dart';

Stream<SseEvent> _parse(List<String> lines) =>
    SseParser.parse(Stream<String>.fromIterable(lines));

void main() {
  group('SseParser', () {
    test('dispatches a simple event', () async {
      final events = await _parse(<String>['data: hello', '']).toList();

      expect(events, hasLength(1));
      expect(events.single.data, 'hello');
      expect(events.single.event, isNull);
      expect(events.single.id, isNull);
    });

    test('joins multi-line data with newlines', () async {
      final events = await _parse(<String>[
        'data: first',
        'data: second',
        '',
      ]).toList();

      expect(events.single.data, 'first\nsecond');
    });

    test('parses event, id and retry', () async {
      final events = await _parse(<String>[
        'event: update',
        'id: 42',
        'retry: 3000',
        'data: payload',
        '',
      ]).toList();

      expect(events.single.event, 'update');
      expect(events.single.id, '42');
      expect(events.single.retry, const Duration(seconds: 3));
    });

    test('id and retry persist, event does not', () async {
      final events = await _parse(<String>[
        'id: 7',
        'retry: 1000',
        'event: a',
        'data: one',
        '',
        'data: two',
        '',
      ]).toList();

      expect(events, hasLength(2));
      expect(events[0].id, '7');
      expect(events[1].id, '7');
      expect(events[1].retry, const Duration(seconds: 1));
      expect(events[1].event, isNull);
    });

    test('ignores comments and keep-alives', () async {
      final events = await _parse(<String>[
        ': keep-alive',
        'data: real',
        '',
      ]).toList();

      expect(events.single.data, 'real');
    });

    test('does not dispatch an event without data', () async {
      final events = await _parse(<String>['event: ping', '']).toList();

      expect(events, isEmpty);
    });

    test('handles values containing colons', () async {
      final events = await _parse(<String>['data: a:b:c', '']).toList();

      expect(events.single.data, 'a:b:c');
    });

    test('emits a trailing event at stream close', () async {
      final events = await _parse(<String>['data: tail']).toList();

      expect(events.single.data, 'tail');
    });
  });
}
