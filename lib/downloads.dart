import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:browser_http/browser_http.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'resources.dart';

enum DownloadStatus {
  queued,
  running,
  saving,
  saved,
  downloaded,
  failed,
  cancelled,
}

extension DownloadStatusLabel on DownloadStatus {
  String get label => switch (this) {
    DownloadStatus.queued => '等待中',
    DownloadStatus.running => '下载中',
    DownloadStatus.saving => '正在存入相册',
    DownloadStatus.saved => '已存相册',
    DownloadStatus.downloaded => '已下载',
    DownloadStatus.failed => '失败',
    DownloadStatus.cancelled => '已取消',
  };

  bool get terminal =>
      this == DownloadStatus.saved ||
      this == DownloadStatus.downloaded ||
      this == DownloadStatus.failed ||
      this == DownloadStatus.cancelled;

  bool get active =>
      this == DownloadStatus.queued ||
      this == DownloadStatus.running ||
      this == DownloadStatus.saving;
}

/// One queued item. Download bytes land in the app container first and are
/// then handed to Photos by file URL, so large videos never cross the method
/// channel in one buffer.
final class DownloadItem {
  DownloadItem({
    required this.id,
    required this.url,
    required this.pageUrl,
    required this.kind,
    required this.fileName,
    required this.createdAt,
    this.userAgent,
    this.status = DownloadStatus.queued,
    this.received = 0,
    this.total,
    this.path,
    this.error,
    this.photoError,
    this.savedToPhotos = false,
  });

  final String id;
  final String url;
  final String pageUrl;
  final ResourceKind kind;
  final String fileName;
  final DateTime createdAt;
  final String? userAgent;

  DownloadStatus status;
  int received;
  int? total;
  String? path;
  String? error;
  String? photoError;
  bool savedToPhotos;
  CancelToken? cancelToken;

  String get host => Uri.tryParse(url)?.host ?? '';

  double? get progress {
    final value = total;
    if (value == null || value <= 0) return null;
    return (received / value).clamp(0.0, 1.0).toDouble();
  }

  String get sizeLabel {
    final value = total;
    if (value == null || value <= 0) {
      return received > 0 ? _bytes(received) : '';
    }
    return '${_bytes(received)} / ${_bytes(value)}';
  }

  static String _bytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
    return '$bytes B';
  }

  String get displayName {
    final name = fileName.trim();
    return name.isEmpty ? (kind == ResourceKind.image ? 'image' : 'video') : name;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'url': url,
    'pageUrl': pageUrl,
    'kind': kind.name,
    'fileName': fileName,
    'createdAt': createdAt.toIso8601String(),
    'status': status.name,
    'received': received,
    'total': total,
    'path': path,
    'error': error,
    'photoError': photoError,
    'savedToPhotos': savedToPhotos,
  };

  static DownloadItem? fromJson(Map<Object?, Object?> json) {
    final id = json['id']?.toString();
    final url = json['url']?.toString();
    final fileName = json['fileName']?.toString();
    if (id == null || url == null || fileName == null) return null;
    final kind = json['kind']?.toString() == 'video'
        ? ResourceKind.video
        : ResourceKind.image;
    final statusName = json['status']?.toString() ?? '';
    final status = DownloadStatus.values.firstWhere(
      (value) => value.name == statusName,
      orElse: () => DownloadStatus.downloaded,
    );
    final created = DateTime.tryParse(json['createdAt']?.toString() ?? '');
    return DownloadItem(
      id: id,
      url: url,
      pageUrl: json['pageUrl']?.toString() ?? '',
      kind: kind,
      fileName: fileName,
      createdAt: created ?? DateTime.now(),
      status: status,
      received: _asInt(json['received']) ?? 0,
      total: _asInt(json['total']),
      path: json['path']?.toString(),
      error: json['error']?.toString(),
      photoError: json['photoError']?.toString(),
      savedToPhotos: json['savedToPhotos'] == true,
    );
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }
}

/// Sequential download queue with retry, cancellation and auto-save to Photos.
final class DownloadManager extends ChangeNotifier {
  DownloadManager({required this.session, this.onFinished});

  final BrowserSession session;

  /// Called once per item when it reaches a terminal state, on the UI isolate.
  final void Function(DownloadItem item)? onFinished;

  static const MethodChannel _media =
      MethodChannel('browser_http/media');

  final List<DownloadItem> items = <DownloadItem>[];
  final List<DownloadItem> _queue = <DownloadItem>[];
  bool _pumping = false;
  bool _disposed = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  int _counter = 0;

  int get activeCount => items.where((item) => item.status.active).length;
  int get finishedCount => items.where((item) => item.status.terminal).length;

  File? get _indexFile {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return File('$home/Documents/downloads.json');
  }

  Directory? get _downloadDir {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return Directory('$home/Documents/Downloads');
  }

  /// Restores the list of finished downloads. A file that disappeared is
  /// dropped rather than shown as a broken row.
  Future<void> load() async {
    final file = _indexFile;
    if (file == null) return;
    try {
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return;
      final restored = <DownloadItem>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final item = DownloadItem.fromJson(entry);
        if (item == null) continue;
        final path = item.path;
        if (path == null || !await File(path).exists()) continue;
        if (item.status.active) item.status = DownloadStatus.downloaded;
        restored.add(item);
        if (restored.length >= 120) break;
      }
      if (_disposed) return;
      items
        ..clear()
        ..addAll(restored);
      notifyListeners();
    } on Object {
      // A corrupt index must not keep the browser from starting.
    }
  }

  void enqueueAll(Iterable<SniffedResource> resources, {String? userAgent}) {
    final accepted = resources.where((resource) => resource.downloadable);
    var added = 0;
    for (final resource in accepted) {
      final item = DownloadItem(
        id: 'dl-${DateTime.now().microsecondsSinceEpoch}-${_counter++}',
        url: resource.url,
        pageUrl: resource.pageUrl,
        kind: resource.kind,
        fileName: resource.fileName,
        createdAt: DateTime.now(),
        userAgent: userAgent,
      );
      items.insert(0, item);
      _queue.add(item);
      added++;
    }
    if (added == 0) return;
    _notify(force: true);
    unawaited(_pump());
  }

  void cancel(DownloadItem item) {
    if (!item.status.active) return;
    item.cancelToken?.cancel();
    if (item.status == DownloadStatus.queued) {
      _queue.remove(item);
      item.status = DownloadStatus.cancelled;
      _notify(force: true);
      unawaited(_persist());
    }
  }

  void retry(DownloadItem item) {
    if (!item.status.terminal) return;
    item
      ..status = DownloadStatus.queued
      ..received = 0
      ..total = null
      ..path = null
      ..error = null
      ..photoError = null
      ..savedToPhotos = false
      ..cancelToken = null;
    _queue.add(item);
    _notify(force: true);
    unawaited(_pump());
  }

  void remove(DownloadItem item) {
    if (item.status.active) cancel(item);
    _queue.remove(item);
    items.remove(item);
    _notify(force: true);
    unawaited(_persist());
  }

  void clearFinished() {
    items.removeWhere((item) => item.status.terminal);
    _notify(force: true);
    unawaited(_persist());
  }

  Future<void> _pump() async {
    if (_pumping || _disposed) return;
    _pumping = true;
    try {
      while (!_disposed) {
        DownloadItem? next;
        for (final item in _queue) {
          if (item.status == DownloadStatus.queued) {
            next = item;
            break;
          }
        }
        if (next == null) break;
        _queue.remove(next);
        await _run(next);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _run(DownloadItem item) async {
    final token = CancelToken();
    item
      ..status = DownloadStatus.running
      ..received = 0
      ..total = null
      ..path = null
      ..error = null
      ..photoError = null
      ..savedToPhotos = false
      ..cancelToken = token;
    _notify(force: true);

    File? file;
    IOSink? sink;
    try {
      final uri = Uri.tryParse(item.url);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        throw const FormatException('无效的资源地址');
      }
      final headers = <OrderedHeader>[
        if (item.userAgent != null && item.userAgent!.isNotEmpty)
          OrderedHeader('User-Agent', item.userAgent!),
        if (item.pageUrl.isNotEmpty)
          OrderedHeader('Referer', item.pageUrl),
        OrderedHeader(
          'Accept',
          item.kind == ResourceKind.image
              ? 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8'
              : 'video/*,*/*;q=0.8',
        ),
      ];
      final response = await session.openStream(
        TransportRequest(
          method: 'GET',
          uri: uri,
          profileId: session.profile.id,
          headers: headers,
        ),
        cancelToken: token,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }

      final contentType =
          (response.header('content-type') ?? '').toLowerCase().trim();
      if (contentType.startsWith('text/html') ||
          contentType.startsWith('application/json') ||
          contentType.startsWith('text/plain')) {
        throw const FormatException('服务器返回了网页而不是媒体文件');
      }

      final rawLength = response.header('content-length');
      final length = rawLength == null ? null : int.tryParse(
        rawLength.split(';').first.trim(),
      );
      item.total = length != null && length > 0 ? length : null;

      final dir = _downloadDir;
      if (dir == null) throw const FileSystemException('找不到应用目录');
      await dir.create(recursive: true);

      final name = _fileNameFor(item, contentType);
      file = File('${dir.path}/${DateTime.now().millisecondsSinceEpoch}_$name');
      item.path = file.path;
      sink = file.openWrite();

      await for (final chunk in response.body) {
        if (token.isCancelled) break;
        sink.add(chunk);
        item.received += chunk.length;
        _notify();
      }
      if (token.isCancelled) throw const _DownloadCancelled();
      await sink.flush();
      await sink.close();
      sink = null;

      item.status = DownloadStatus.saving;
      _notify(force: true);
      final saved = await _saveToPhotos(file, item);
      if (saved == 'ok') {
        item
          ..status = DownloadStatus.saved
          ..savedToPhotos = true;
      } else {
        item
          ..status = DownloadStatus.downloaded
          ..photoError = saved == 'denied'
              ? '相册权限未开启，文件留在 App 内'
              : '存相册失败：$saved';
      }
    } on Object catch (error) {
      try {
        await sink?.flush();
        await sink?.close();
      } on Object {
        // The sink may already be broken by the aborted socket.
      }
      sink = null;
      final cancelled = token.isCancelled || error is _DownloadCancelled;
      if (file != null) {
        try {
          if (await file.exists()) await file.delete();
        } on Object {
          // Best effort; the partial file is unreachable anyway.
        }
        item.path = null;
      }
      item.status =
          cancelled ? DownloadStatus.cancelled : DownloadStatus.failed;
      item.error = cancelled ? null : _friendlyError(error);
    } finally {
      item.cancelToken = null;
      await _persist();
      _notify(force: true);
      onFinished?.call(item);
    }
  }

  /// File names from a CDN often have no extension; Photos infers the type
  /// from it, so the content type decides when the path does not.
  String _fileNameFor(DownloadItem item, String contentType) {
    var name = item.fileName.trim();
    if (name.isEmpty) name = item.kind == ResourceKind.image ? 'image' : 'video';
    final dot = name.lastIndexOf('.');
    final existing = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
    const known = <String>{
      'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'avif', 'heic', 'heif',
      'mp4', 'm4v', 'mov', 'webm', 'mkv', 'ts',
    };
    if (known.contains(existing)) return name;
    final ext = switch (contentType.split(';').first.trim()) {
      'image/jpeg' => 'jpg',
      'image/png' => 'png',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      'image/avif' => 'avif',
      'image/heic' || 'image/heif' => 'heic',
      'video/mp4' => 'mp4',
      'video/quicktime' => 'mov',
      'video/webm' => 'webm',
      'video/x-matroska' => 'mkv',
      _ => item.kind == ResourceKind.image ? 'jpg' : 'mp4',
    };
    if (dot > 0) name = name.substring(0, dot);
    return '$name.$ext';
  }

  Future<String> _saveToPhotos(File file, DownloadItem item) async {
    try {
      final status = await _media.invokeMethod<String>(
        'saveToPhotos',
        <String, Object?>{
          'path': file.path,
          'type': item.kind == ResourceKind.video ? 'video' : 'photo',
          'filename': file.uri.pathSegments.last,
        },
      );
      return status ?? 'error: no response';
    } on MissingPluginException {
      return 'error: 当前构建不支持相册';
    } on PlatformException catch (error) {
      return 'error: ${error.message ?? error.code}';
    } on Object catch (error) {
      return 'error: $error';
    }
  }

  String _friendlyError(Object error) {
    if (error is FormatException) return error.message;
    if (error is HttpException) return error.message;
    if (error is FileSystemException) return error.message;
    if (error is BrowserHttpException) return error.message;
    return error.toString();
  }

  Future<void> _persist() async {
    final file = _indexFile;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      final data = <Object?>[
        for (final item in items)
          if (item.status.terminal) item.toJson(),
      ];
      await file.writeAsString(jsonEncode(data));
    } on Object {
      // Losing the index is annoying, not fatal.
    }
  }

  void _notify({bool force = false}) {
    if (_disposed) return;
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastNotify) < const Duration(milliseconds: 140)) {
      return;
    }
    _lastNotify = now;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _queue.clear();
    for (final item in items) {
      item.cancelToken?.cancel();
    }
    super.dispose();
  }
}

final class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}
