import 'dart:async';
import 'dart:collection';

import '../domain/logging/request_log.dart';

/// Destination for [RequestLogEvent]s.
///
/// Sinks are called synchronously from the request path, so they must never
/// block. Implementations that do I/O should buffer internally.
abstract interface class LogSink {
  void add(RequestLogEvent event);
  Future<void> close();
}

/// Default sink: a bounded in-memory ring buffer.
final class MemoryLogSink implements LogSink {
  MemoryLogSink({this.capacity = 200});

  final int capacity;
  final Queue<RequestLogEvent> _events = Queue<RequestLogEvent>();

  /// Oldest first.
  List<RequestLogEvent> get events => List<RequestLogEvent>.unmodifiable(_events);

  @override
  void add(RequestLogEvent event) {
    _events.addLast(event);
    while (_events.length > capacity) {
      _events.removeFirst();
    }
  }

  @override
  Future<void> close() async {
    _events.clear();
  }
}

/// Forwards events to a stream (e.g. for an in-app debug console).
final class StreamLogSink implements LogSink {
  StreamLogSink([int capacity = 200]) : _controller = StreamController<RequestLogEvent>.broadcast() {
    _controller.onListen = () {};
    _buffer = Queue<RequestLogEvent>();
    _capacity = capacity;
  }

  final StreamController<RequestLogEvent> _controller;
  late final Queue<RequestLogEvent> _buffer;
  late final int _capacity;

  Stream<RequestLogEvent> get stream => _controller.stream;

  @override
  void add(RequestLogEvent event) {
    if (_controller.isClosed) return;
    _buffer.addLast(event);
    while (_buffer.length > _capacity) {
      _buffer.removeFirst();
    }
    _controller.add(event);
  }

  @override
  Future<void> close() => _controller.close();
}
