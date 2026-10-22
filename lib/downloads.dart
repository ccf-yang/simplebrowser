import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:browser_http/browser_http.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'hls.dart';
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
    DownloadStatus.saving => '正在处理视频',
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
    this.hls = false,
    this.hlsVariant,
    this.hlsVariantLabel,
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

  /// `.m3u8` playlist. [hlsVariant] is the chosen rendition URL, or null to
  /// take the highest bandwidth the master playlist advertises.
  final bool hls;
  final String? hlsVariant;

  /// Resolved from the master playlist when the download starts, so the
  /// label is filled in even for the automatic choice.
  String? hlsVariantLabel;

  DownloadStatus status;
  int received;
  int? total;
  int? segmentsDone;
  int? segmentsTotal;
  String? path;
  String? error;
  String? photoError;
  bool savedToPhotos;
  CancelToken? cancelToken;

  String get host => Uri.tryParse(url)?.host ?? '';

  double? get progress {
    final segments = segmentsTotal;
    if (segments != null && segments > 0) {
      return ((segmentsDone ?? 0) / segments).clamp(0.0, 1.0).toDouble();
    }
    final value = total;
    if (value == null || value <= 0) return null;
    return (received / value).clamp(0.0, 1.0).toDouble();
  }

  String get sizeLabel {
    final segments = segmentsTotal;
    if (segments != null) {
      return '${formatBytes(received)} · ${segmentsDone ?? 0}/$segments 段';
    }
    final value = total;
    if (value == null || value <= 0) {
      return received > 0 ? formatBytes(received) : '';
    }
    return '${formatBytes(received)} / ${formatBytes(value)}';
  }

  bool get playable {
    final value = path;
    if (value == null || !status.terminal || kind != ResourceKind.video) {
      return false;
    }
    final lower = value.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.ts');
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
    'hls': hls,
    'hlsVariant': hlsVariant,
    'hlsVariantLabel': hlsVariantLabel,
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
      hls: json['hls'] == true,
      hlsVariant: json['hlsVariant']?.toString(),
      hlsVariantLabel: json['hlsVariantLabel']?.toString(),
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

/// Human readable byte count shared by the queue and the offline library.
String formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
  return '$bytes B';
}

/// One finished file sitting in `Documents/Downloads`.
///
/// The download list is history; this is the actual storage. Files stay here
/// after being saved to Photos so they can be replayed, exported or deleted.
final class OfflineFile {
  const OfflineFile({
    required this.file,
    required this.name,
    required this.size,
    required this.modified,
  });

  final File file;
  final String name;
  final int size;
  final DateTime modified;

  String get path => file.path;

  String get extension {
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  bool get isVideo => const <String>{
    'mp4', 'm4v', 'mov', 'ts', 'webm', 'mkv',
  }.contains(extension);

  bool get isImage => const <String>{
    'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'avif', 'heic', 'heif',
  }.contains(extension);

  /// AVPlayer covers these; webm/mkv need a codec iOS does not ship.
  bool get playable =>
      const <String>{'mp4', 'm4v', 'mov', 'ts'}.contains(extension);

  /// The downloader prefixes files with an epoch stamp; hide it in the UI.
  String get displayName {
    final match = RegExp(r'^\d{13}_').firstMatch(name);
    return match == null ? name : name.substring(match.end);
  }

  String get sizeLabel => formatBytes(size);
}

/// Sequential download queue with retry, cancellation and auto-save to Photos.
///
/// Plain files stream straight to disk. HLS playlists go through a second
/// path: fetch the playlist chain, pick a rendition, fetch/decrypt segments
/// in small batches, concatenate, then remux TS into MP4 natively.
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

  String? _documentsDir;
  Future<String?>? _documentsDirPending;

  /// iOS app processes have no usable HOME, so the Documents path can only be
  /// resolved natively (and is cached for the life of the manager).
  Future<String?> _documentsPath() async {
    final cached = _documentsDir;
    if (cached != null) return cached;
    final path = await (_documentsDirPending ??= _resolveDocumentsPath());
    if (path == null) _documentsDirPending = null;
    return path;
  }

  Future<String?> _resolveDocumentsPath() async {
    String? path;
    try {
      path = await _media.invokeMethod<String>('documentsPath');
    } on MissingPluginException {
      // Test host or another platform; fall through to HOME below.
    } on PlatformException {
      // Fall through.
    } on Object {
      // Fall through.
    }
    if (path == null || path.isEmpty) {
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) path = '$home/Documents';
    }
    if (path == null || path.isEmpty) return null;
    _documentsDir = path;
    return path;
  }

  Future<File?> _indexFile() async {
    final dir = await _documentsPath();
    if (dir == null) return null;
    return File('$dir/downloads.json');
  }

  Future<Directory?> _downloadDir() async {
    final dir = await _documentsPath();
    if (dir == null) return null;
    return Directory('$dir/Downloads');
  }

  /// Restores the list of finished downloads. A file that disappeared is
  /// dropped rather than shown as a broken row.
  Future<void> load() async {
    final file = await _indexFile();
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
    var added = 0;
    for (final resource in resources) {
      final item = DownloadItem(
        id: 'dl-${DateTime.now().microsecondsSinceEpoch}-${_counter++}',
        url: resource.url,
        pageUrl: resource.pageUrl,
        kind: resource.kind,
        fileName: resource.fileName,
        createdAt: DateTime.now(),
        userAgent: userAgent,
        hls: resource.hls,
        hlsVariant: resource.hlsVariantUrl,
        hlsVariantLabel: resource.hlsVariantLabel,
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
      ..segmentsDone = null
      ..segmentsTotal = null
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

  /// Reads a master playlist and returns its renditions, highest first.
  /// An empty list means the URL points at a media playlist (or is not HLS).
  Future<List<HlsVariant>> loadVariants(
    String url, {
    String? userAgent,
    String? pageUrl,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return const <HlsVariant>[];
    }
    final headers = <OrderedHeader>[
      if (userAgent != null && userAgent.isNotEmpty)
        OrderedHeader('User-Agent', userAgent),
      if (pageUrl != null && pageUrl.isNotEmpty)
        OrderedHeader('Referer', pageUrl),
      const OrderedHeader(
        'Accept',
        'application/vnd.apple.mpegurl,video/*,*/*;q=0.8',
      ),
    ];
    final playlist = HlsPlaylist.parse(
      await _fetchText(uri, headers, CancelToken())
          .timeout(const Duration(seconds: 20)),
      uri,
    );
    return playlist.isMaster ? playlist.sortedVariants : const <HlsVariant>[];
  }

  /// Opens the system player on a completed file.
  Future<String?> play(DownloadItem item) => playPath(item.path);

  Future<String?> playPath(String? path) async {
    if (path == null || path.isEmpty || !await File(path).exists()) {
      return '文件不存在';
    }
    try {
      final status = await _media.invokeMethod<String>(
        'playFile',
        <String, Object?>{'path': path},
      );
      return status == 'ok' ? null : (status ?? '无法播放');
    } on MissingPluginException {
      return '当前构建不支持内置播放';
    } on PlatformException catch (error) {
      return error.message ?? '无法播放';
    } on Object catch (error) {
      return error.toString();
    }
  }

  /// Opens the system share sheet so the file can go to Files, AirDrop, etc.
  Future<String?> share(DownloadItem item) => sharePath(item.path);

  Future<String?> sharePath(String? path) async {
    if (path == null || path.isEmpty || !await File(path).exists()) {
      return '文件不存在';
    }
    try {
      final status = await _media.invokeMethod<String>(
        'shareFile',
        <String, Object?>{'path': path},
      );
      return status == 'ok' ? null : (status ?? '无法分享');
    } on MissingPluginException {
      return '当前构建不支持导出';
    } on PlatformException catch (error) {
      return error.message ?? '无法分享';
    } on Object catch (error) {
      return error.toString();
    }
  }

  /// Files actually stored in `Documents/Downloads`, newest first.
  /// Hidden names are in-flight HLS temporaries and are skipped.
  Future<List<OfflineFile>> listOffline() async {
    final dir = await _downloadDir();
    if (dir == null || !await dir.exists()) return const <OfflineFile>[];
    final files = <OfflineFile>[];
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final segments = entity.uri.pathSegments;
        final name = segments.isEmpty ? '' : segments.last;
        if (name.isEmpty || name.startsWith('.')) continue;
        try {
          final stat = await entity.stat();
          if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
            continue;
          }
          files.add(
            OfflineFile(
              file: entity,
              name: name,
              size: stat.size,
              modified: stat.modified,
            ),
          );
        } on Object {
          // The file vanished mid-scan; just leave it out.
        }
      }
    } on FileSystemException {
      return const <OfflineFile>[];
    }
    files.sort((a, b) => b.modified.compareTo(a.modified));
    return files;
  }

  /// Deletes the bytes and any history rows that point at them.
  Future<String?> deleteOffline(OfflineFile file) async {
    try {
      if (await file.file.exists()) await file.file.delete();
    } on Object catch (error) {
      return error is FileSystemException
          ? (error.message)
          : error.toString();
    }
    final before = items.length;
    items.removeWhere((item) => item.path == file.path);
    _notify(force: true);
    if (items.length != before) await _persist();
    return null;
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
      ..segmentsDone = null
      ..segmentsTotal = null
      ..path = null
      ..error = null
      ..photoError = null
      ..savedToPhotos = false
      ..cancelToken = token;
    _notify(force: true);

    File? file;
    IOSink? sink;
    _MediaFile? hlsResult;
    try {
      final uri = Uri.tryParse(item.url);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        throw const FormatException('无效的资源地址');
      }
      final headers = _headersFor(item);

      if (item.hls || uri.path.toLowerCase().endsWith('.m3u8')) {
        hlsResult = await _downloadHls(item, uri, headers, token);
        file = hlsResult.file;
      } else {
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

        final dir = await _downloadDir();
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
      }

      if (token.isCancelled) throw const _DownloadCancelled();

      item.status = DownloadStatus.saving;
      _notify(force: true);
      if (hlsResult != null && !hlsResult.saveable) {
        item
          ..status = DownloadStatus.downloaded
          ..photoError = hlsResult.note;
      } else {
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

  Future<_MediaFile> _downloadHls(
    DownloadItem item,
    Uri rootUri,
    List<OrderedHeader> headers,
    CancelToken token,
  ) async {
    var playlist = HlsPlaylist.parse(
      await _fetchText(rootUri, headers, token),
      rootUri,
    );
    if (playlist.isMaster) {
      final variants = playlist.sortedVariants;
      if (variants.isEmpty) {
        throw const FormatException('播放列表没有可选的清晰度');
      }
      HlsVariant? selected;
      final wanted = item.hlsVariant;
      if (wanted != null) {
        for (final variant in variants) {
          if (variant.uri.toString() == wanted) {
            selected = variant;
            break;
          }
        }
      }
      selected ??= variants.first;
      item.hlsVariantLabel ??= selected.label;
      playlist = HlsPlaylist.parse(
        await _fetchText(selected.uri, headers, token),
        selected.uri,
      );
      if (playlist.isMaster) {
        throw const FormatException('M3U8 嵌套层数过多');
      }
    }

    final unsupported = playlist.unsupportedReason;
    if (unsupported != null) throw FormatException(unsupported);
    if (playlist.segments.isEmpty) {
      throw const FormatException('播放列表里没有可下载的分片');
    }

    final dir = await _downloadDir();
    if (dir == null) throw const FileSystemException('找不到应用目录');
    await dir.create(recursive: true);

    final fmp4 = playlist.isFragmentedMp4;
    final base = _hlsBaseName(item);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final temp = File(
      '${dir.path}/.${stamp}_$base.${fmp4 ? 'mp4' : 'ts'}',
    );
    item
      ..path = temp.path
      ..segmentsTotal = playlist.segments.length
      ..segmentsDone = 0;
    _notify(force: true);

    final keys = <String, Uint8List>{};
    IOSink? sink;
    try {
      sink = temp.openWrite();
      final init = playlist.init;
      if (init != null) {
        var bytes = await _fetchBytes(
          init.uri,
          headers,
          token,
          range: init.range,
        );
        final initKey = init.key;
        if (initKey != null && initKey.method == HlsEncryption.aes128) {
          bytes = await _decryptHls(
            bytes,
            initKey,
            0,
            keys,
            headers,
            token,
          );
        }
        sink.add(bytes);
        item.received += bytes.length;
      }

      const window = 4;
      for (var start = 0; start < playlist.segments.length; start += window) {
        if (token.isCancelled) throw const _DownloadCancelled();
        final end = (start + window) < playlist.segments.length
            ? start + window
            : playlist.segments.length;
        final batch = playlist.segments.sublist(start, end);
        final chunks = await Future.wait(<Future<Uint8List>>[
          for (final segment in batch)
            _fetchSegment(segment, headers, token, keys),
        ]);
        if (token.isCancelled) throw const _DownloadCancelled();
        for (var i = 0; i < chunks.length; i++) {
          sink.add(chunks[i]);
          item.received += chunks[i].length;
          item.segmentsDone = start + i + 1;
          _notify();
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
    } on Object {
      try {
        await sink?.close();
      } on Object {
        // The partial file is deleted below either way.
      }
      sink = null;
      try {
        if (await temp.exists()) await temp.delete();
      } on Object {
        // Best effort.
      }
      item
        ..path = null
        ..segmentsDone = null
        ..segmentsTotal = null;
      rethrow;
    }

    if (token.isCancelled) {
      try {
        await temp.delete();
      } on Object {
        // Best effort.
      }
      item.path = null;
      throw const _DownloadCancelled();
    }

    if (fmp4) {
      // init + fragments already form a complete MP4; only the name is rough.
      final out = File('${dir.path}/${stamp}_$base.mp4');
      await temp.rename(out.path);
      item.path = out.path;
      return _MediaFile(out, saveable: true);
    }

    final out = File('${dir.path}/${stamp}_$base.mp4');
    item.status = DownloadStatus.saving;
    _notify(force: true);
    String? note;
    try {
      final status = await _media.invokeMethod<String>(
        'remuxToMp4',
        <String, Object?>{
          'source': temp.path,
          'destination': out.path,
        },
      );
      if (status == 'ok' && await out.exists() && await out.length() > 1024) {
        try {
          await temp.delete();
        } on Object {
          // The MP4 is what matters; the TS copy can be cleaned later.
        }
        item.path = out.path;
        return _MediaFile(out, saveable: true);
      }
      note = status ?? '转封装失败';
    } on MissingPluginException {
      note = '当前构建不支持视频转封装';
    } on PlatformException catch (error) {
      note = error.message ?? '转封装失败';
    } on Object catch (error) {
      note = '$error';
    }

    // Keep the TS, but drop the leading dot so the offline library lists it.
    var fallback = temp;
    try {
      fallback = await temp.rename('${dir.path}/${stamp}_$base.ts');
    } on Object {
      // Renaming is cosmetic; the hidden temp name still plays.
    }
    item.path = fallback.path;
    final message = note.startsWith('error: ')
        ? note.substring('error: '.length)
        : note;
    return _MediaFile(
      fallback,
      saveable: false,
      note: '已保留 TS 文件，转 MP4 失败：$message',
    );
  }

  Future<Uint8List> _fetchSegment(
    HlsSegment segment,
    List<OrderedHeader> headers,
    CancelToken token,
    Map<String, Uint8List> keys,
  ) async {
    var bytes = await _fetchBytesRetry(
      segment.uri,
      headers,
      token,
      range: segment.range,
    );
    final key = segment.key;
    if (key.method == HlsEncryption.unsupported) {
      throw const FormatException('这个视频使用了暂不支持的 DRM 加密');
    }
    if (key.method == HlsEncryption.aes128) {
      bytes = await _decryptHls(
        bytes,
        key,
        segment.sequence,
        keys,
        headers,
        token,
      );
    }
    return bytes;
  }

  Future<Uint8List> _decryptHls(
    Uint8List data,
    HlsKey key,
    int sequence,
    Map<String, Uint8List> keys,
    List<OrderedHeader> headers,
    CancelToken token,
  ) async {
    final uri = key.uri;
    if (uri == null) throw const FormatException('加密分片缺少密钥地址');
    var keyBytes = keys[uri.toString()];
    if (keyBytes == null) {
      keyBytes = await _fetchBytes(uri, headers, token);
      keys[uri.toString()] = keyBytes;
    }
    if (keyBytes.length != 16) {
      throw FormatException('密钥长度异常（${keyBytes.length} 字节）');
    }
    final iv = key.iv ?? hlsSequenceIv(sequence);
    try {
      final out = await _media.invokeMethod<Uint8List>(
        'aesDecrypt',
        <String, Object?>{
          'data': data,
          'key': keyBytes,
          'iv': Uint8List.fromList(iv),
        },
      );
      if (out == null || out.isEmpty) {
        throw const FormatException('AES 解密返回空数据');
      }
      return out;
    } on MissingPluginException {
      throw const FormatException('当前构建不支持 AES 解密');
    } on PlatformException catch (error) {
      throw FormatException('AES 解密失败：${error.message ?? error.code}');
    }
  }

  Future<Uint8List> _fetchBytesRetry(
    Uri uri,
    List<OrderedHeader> headers,
    CancelToken token, {
    HlsByteRange? range,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _fetchBytes(uri, headers, token, range: range);
      } on FormatException {
        rethrow;
      } on Object {
        if (token.isCancelled || attempt >= 2) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 450));
      }
    }
  }

  Future<Uint8List> _fetchBytes(
    Uri uri,
    List<OrderedHeader> headers,
    CancelToken token, {
    HlsByteRange? range,
  }) async {
    final response = await session.openStream(
      TransportRequest(
        method: 'GET',
        uri: uri,
        profileId: session.profile.id,
        headers: <OrderedHeader>[
          ...headers,
          if (range != null)
            OrderedHeader('Range', 'bytes=${range.start}-${range.end}'),
        ],
      ),
      cancelToken: token,
    );
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.body) {
      if (token.isCancelled) throw const _DownloadCancelled();
      builder.add(chunk);
    }
    var bytes = builder.takeBytes();
    if (range != null) {
      if (response.statusCode == 200) {
        // The server ignored Range; slice the full body ourselves.
        if (range.end >= bytes.length) {
          throw const FormatException('Range 请求返回的长度不足');
        }
        bytes = Uint8List.sublistView(bytes, range.start, range.end + 1);
      } else if (bytes.length > range.length) {
        bytes = Uint8List.sublistView(bytes, 0, range.length);
      }
    }
    return bytes;
  }

  Future<String> _fetchText(
    Uri uri,
    List<OrderedHeader> headers,
    CancelToken token,
  ) async {
    final bytes = await _fetchBytes(uri, headers, token);
    final text = utf8.decode(bytes, allowMalformed: true);
    if (!text.trimLeft().startsWith('#EXTM3U')) {
      throw const FormatException('服务器返回的不是 M3U8 播放列表');
    }
    return text;
  }

  List<OrderedHeader> _headersFor(DownloadItem item) {
    return <OrderedHeader>[
      if (item.userAgent != null && item.userAgent!.isNotEmpty)
        OrderedHeader('User-Agent', item.userAgent!),
      if (item.pageUrl.isNotEmpty)
        OrderedHeader('Referer', item.pageUrl),
      OrderedHeader(
        'Accept',
        item.hls
            ? 'application/vnd.apple.mpegurl,video/*,*/*;q=0.8'
            : item.kind == ResourceKind.image
                ? 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8'
                : 'video/*,*/*;q=0.8',
      ),
    ];
  }

  String _hlsBaseName(DownloadItem item) {
    var name = item.fileName.trim();
    if (name.isEmpty) name = 'video';
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]+'), '_').trim();
    if (name.isEmpty) name = 'video';
    if (name.length > 60) name = name.substring(0, 60);
    return name;
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
    final file = await _indexFile();
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

final class _MediaFile {
  const _MediaFile(this.file, {required this.saveable, this.note});

  final File file;
  final bool saveable;
  final String? note;
}

final class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}
