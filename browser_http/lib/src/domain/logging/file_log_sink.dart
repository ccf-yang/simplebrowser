import 'dart:convert';
import 'dart:io';

import '../../ports/log_sink.dart';
import 'request_log.dart';

/// Buffered JSONL sink with size-based rotation.
///
/// Takes an explicit [directory] so the package does not depend on
/// `path_provider`; callers pass `getApplicationSupportDirectory()`.
final class FileLogSink implements LogSink {
  FileLogSink({
    required this.directory,
    this.fileName = 'browser_http.log',
    this.maxBytes = 10 * 1024 * 1024,
    this.maxFiles = 3,
  });

  final Directory directory;
  final String fileName;
  final int maxBytes;
  final int maxFiles;

  IOSink? _sink;
  int _written = 0;

  File get _file => File('${directory.path}/$fileName');

  @override
  void add(RequestLogEvent event) {
    // Errors are swallowed on purpose: logging must never fail a request.
    try {
      final sink = _sink ??= _open();
      final line = '${jsonEncode(event.toJson())}\n';
      sink.write(line);
      _written += line.length;
      if (_written >= maxBytes) {
        _rotate();
      }
    } on Object {
      // ignore
    }
  }

  IOSink _open() {
    directory.createSync(recursive: true);
    final file = _file;
    _written = file.existsSync() ? file.lengthSync() : 0;
    return file.openWrite(mode: FileMode.append);
  }

  void _rotate() {
    _sink?.flush();
    _sink?.close();
    _sink = null;
    for (var i = maxFiles - 1; i >= 1; i--) {
      final from = File('${directory.path}/$fileName.$i');
      final to = File('${directory.path}/$fileName.${i + 1}');
      if (from.existsSync()) {
        if (to.existsSync()) to.deleteSync();
        from.renameSync(to.path);
      }
    }
    if (_file.existsSync()) {
      _file.renameSync('${_file.path}.1');
    }
    _sink = _open();
  }

  @override
  Future<void> close() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
  }
}
