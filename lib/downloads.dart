import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:browser_http/browser_http.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'hls.dart';
import 'resources.dart';
import 'webdav.dart';

enum DownloadStatus {
  queued,
  running,
  saving,
  saved,
  downloaded,
  uploading,
  uploaded,
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
    DownloadStatus.uploading => '上传中',
    DownloadStatus.uploaded => '已传服务器',
    DownloadStatus.failed => '失败',
    DownloadStatus.cancelled => '已取消',
  };

  bool get terminal =>
      this == DownloadStatus.saved ||
      this == DownloadStatus.downloaded ||
      this == DownloadStatus.uploaded ||
      this == DownloadStatus.failed ||
      this == DownloadStatus.cancelled;

  bool get active =>
      this == DownloadStatus.queued ||
      this == DownloadStatus.running ||
      this == DownloadStatus.saving ||
      this == DownloadStatus.uploading;
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
    this.webdav = false,
    this.webdavPath,
    this.webdavError,
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

  /// Send this to WebDAV once it is on local disk, then delete the local copy.
  final bool webdav;
  String? webdavPath;
  String? webdavError;

  /// Upload progress, kept apart from the download counters so a row can show
  /// "downloading 4/9 MB" and later "uploading 2/9 MB" without lying.
  int uploadSent = 0;
  int? uploadTotal;

  CancelToken? cancelToken;

  String get host => Uri.tryParse(url)?.host ?? '';

  double? get progress {
    if (webdav && uploadTotal != null) {
      final value = uploadTotal!;
      if (value > 0) {
        return (uploadSent / value).clamp(0.0, 1.0).toDouble();
      }
    }
    final segments = segmentsTotal;
    if (segments != null && segments > 0) {
      return ((segmentsDone ?? 0) / segments).clamp(0.0, 1.0).toDouble();
    }
    final value = total;
    if (value == null || value <= 0) return null;
    return (received / value).clamp(0.0, 1.0).toDouble();
  }

  String get sizeLabel {
    if (webdav) {
      final value = uploadTotal;
      if (value != null && value > 0) {
        return '上传 ${formatBytes(uploadSent)} / ${formatBytes(value)}';
      }
    }
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

  /// Raw segments kept because the merge refused them: the row gets one more
  /// attempt instead of making the user pull the whole video down again.
  bool get remuxable {
    final value = path;
    if (value == null ||
        status != DownloadStatus.downloaded ||
        kind != ResourceKind.video) {
      return false;
    }
    return value.toLowerCase().endsWith('.ts');
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
    'webdav': webdav,
    'webdavPath': webdavPath,
    'webdavError': webdavError,
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
      webdav: json['webdav'] == true,
      webdavPath: json['webdavPath']?.toString(),
      webdavError: json['webdavError']?.toString(),
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

  /// Legacy names carry a 13-digit epoch; the readable timestamp does not,
  /// because `20261023-213456` is the information the library wants to show.
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

  /// Target for items flagged `webdav`. Null or unconfigured means those items
  /// fail with a hint instead of silently staying local.
  WebDavConfig? webdavConfig;

  static const MethodChannel _media =
      MethodChannel('browser_http/media');

  /// Below this a file is not worth slicing: the probe alone would cost more
  /// than the parallel windows save. Images almost always take this path out.
  static const int _parallelMinimumBytes = 2 * 1024 * 1024;
  static const int _minimumWindowBytes = 1024 * 1024;
  static const int _maximumWindowBytes = 4 * 1024 * 1024;

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

  /// The app's Documents directory. iOS gives no usable `$HOME`, so anything
  /// the page stores as JSON resolves its path through here instead.
  Future<String?> documentsDirectory() => _documentsPath();

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
        final missing = path == null || !await File(path).exists();
        // An uploaded row deliberately has no local file any more: the record
        // is the remote path, so it survives the restart.
        if (missing && item.status != DownloadStatus.uploaded) continue;
        if (missing) item.path = null;
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

  void enqueueAll(
    Iterable<SniffedResource> resources, {
    String? userAgent,
    bool webdav = false,
  }) {
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
        webdav: webdav,
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
      ..webdavError = null
      ..uploadSent = 0
      ..uploadTotal = null
      ..cancelToken = null;
    _queue.add(item);
    _notify(force: true);
    unawaited(_pump());
  }

  /// Ids currently being merged in place, so a double tap cannot start two
  /// exports of the same file.
  final Set<String> _remuxing = <String>{};

  /// Re-runs the container merge on a stream that was kept as raw segments, so
  /// a fixed remuxer can be tested without pulling the whole video again. The
  /// row shows what this attempt said, either way.
  Future<void> remuxExisting(DownloadItem item) async {
    final source = item.path;
    if (source == null || !item.remuxable || _remuxing.contains(item.id)) {
      return;
    }
    final file = File(source);
    if (!await file.exists()) {
      item
        ..path = null
        ..photoError = '原文件已不在 App 里';
      await _persist();
      _notify(force: true);
      return;
    }

    _remuxing.add(item.id);
    item
      ..status = DownloadStatus.saving
      ..photoError = null;
    _notify(force: true);

    // Same timestamp prefix, new container: the row and the offline library
    // keep sorting where the user left them.
    final directory = source.substring(0, source.lastIndexOf('/'));
    final target = File('$directory/${_nameStem(source)}.mp4');
    String? failure;
    try {
      final status = await _media.invokeMethod<String>(
        'remuxToMp4',
        <String, Object?>{
          'source': source,
          'destination': target.path,
        },
      );
      final text = status ?? '';
      if (text.startsWith('ok') &&
          await target.exists() &&
          await target.length() > 1024) {
        try {
          await file.delete();
        } on Object {
          // The MP4 is the file that matters now.
        }
        final detail = text.startsWith('ok:') ? text.substring(3).trim() : '';
        item
          ..path = target.path
          ..savedToPhotos = false;
        await _saveLocally(
          item,
          target,
          _MediaFile(
            target,
            saveable: true,
            note: detail.isEmpty ? null : detail,
          ),
        );
      } else {
        final probe = await _sniffContainer(file);
        failure = _withoutErrorPrefix(
          text.isEmpty ? '转封装失败' : text,
        );
        item.photoError = '转 MP4 失败：$failure（${probe.diagnosis}）';
      }
    } on MissingPluginException {
      failure = '当前构建不支持视频转封装';
    } on PlatformException catch (error) {
      failure = _withoutErrorPrefix(error.message ?? '转封装失败');
    } on Object catch (error) {
      failure = '$error';
    }
    if (failure != null) {
      item
        ..status = DownloadStatus.downloaded
        ..photoError = '转 MP4 失败：$failure';
    }
    _remuxing.remove(item.id);
    await _persist();
    _notify(force: true);
  }

  /// File name without its extension, keeping the timestamp prefix.
  static String _nameStem(String path) {
    final name = path.substring(path.lastIndexOf('/') + 1);
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
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

  /// Empties the offline library: every stored file goes, together with the
  /// history rows that pointed at it. Already-saved Photos copies are not
  /// touched, and files belonging to a running task are left alone.
  /// Returns the first error hit, or null when nothing failed.
  Future<String?> clearOffline() async {
    final dir = await _downloadDir();
    if (dir == null) return '找不到应用目录';

    final busy = <String>{
      for (final item in items)
        if (item.status.active && item.path != null) item.path!,
    };
    String? error;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final segments = entity.uri.pathSegments;
        final name = segments.isEmpty ? '' : segments.last;
        // Dot-prefixed names are in-flight HLS temporaries; not the user's.
        if (name.isEmpty || name.startsWith('.')) continue;
        if (busy.contains(entity.path)) continue;
        try {
          await entity.delete();
        } on Object catch (failure) {
          error ??= failure is FileSystemException
              ? failure.message
              : failure.toString();
        }
      }
    } on FileSystemException catch (failure) {
      error ??= failure.message;
    }

    final before = items.length;
    items.removeWhere((item) => item.status.terminal);
    _notify(force: true);
    if (items.length != before) await _persist();
    return error;
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
      ..webdavError = null
      ..uploadSent = 0
      ..uploadTotal = null
      ..cancelToken = token;
    _notify(force: true);

    File? file;
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
        // Direct file: parallel Range slices when the server supports them,
        // one streamed connection otherwise (and as the retry path).
        file = await _downloadFile(item, uri, headers, token);
      }

      if (token.isCancelled) throw const _DownloadCancelled();

      if (item.webdav) {
        await _uploadStage(item, file);
      } else {
        await _saveLocally(item, file, hlsResult);
      }
    } on Object catch (error) {
      final cancelled = token.isCancelled || error is _DownloadCancelled;
      // The file helpers delete their own partial output, so what is left here
      // is the HLS concatenation file.
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

  /// Photos is the default landing spot; HLS results that the native remuxer
  /// refused to write stay in the app directory with the reason on the row.
  Future<void> _saveLocally(
    DownloadItem item,
    File file,
    _MediaFile? hlsResult,
  ) async {
    item.status = DownloadStatus.saving;
    _notify(force: true);
    if (hlsResult != null && !hlsResult.saveable) {
      item
        ..status = DownloadStatus.downloaded
        ..photoError = hlsResult.note;
      return;
    }
    final saved = await _saveToPhotos(file, item);
    final detail = hlsResult?.note;
    if (saved == 'ok') {
      item
        ..status = DownloadStatus.saved
        ..savedToPhotos = true
        // A merge that had to drop data says so on the row; silence here would
        // turn a short video into a mystery.
        ..photoError = detail;
    } else {
      item
        ..status = DownloadStatus.downloaded
        ..photoError = _joinNotes(
          saved == 'denied'
              ? '相册权限未开启，文件留在 App 内'
              : '存相册失败：$saved',
          detail,
        );
    }
  }

  /// Notes stack instead of replacing each other: the segments that were
  /// dropped and the reason the container was refused are both facts the user
  /// needs, in one line.
  static String? _joinNotes(String? first, String? second) {
    final parts = <String>[
      if (first != null && first.isNotEmpty) first,
      if (second != null && second.isNotEmpty) second,
    ];
    return parts.isEmpty ? null : parts.join('；');
  }

  /// Download finished locally, now push it to the server and drop the local
  /// copy. Failures keep the file in the app so nothing is lost on a bad token
  /// or an asleep NAS; the row says why.
  Future<void> _uploadStage(DownloadItem item, File file) async {
    final config = webdavConfig;
    if (config == null || !config.ready) {
      item
        ..status = DownloadStatus.downloaded
        ..webdavError = '未配置 WebDAV 地址，文件留在 App 内';
      return;
    }
    item.status = DownloadStatus.uploading;
    _notify(force: true);
    final failure = await _push(
      config,
      file.path,
      _remoteNameFor(item, file),
      onProgress: (sent, total) {
        if (item.cancelToken?.isCancelled ?? false) {
          throw const _DownloadCancelled();
        }
        item
          ..uploadSent = sent
          ..uploadTotal = total;
        _notify();
      },
      onDone: (remote, skipped) {
        item
          ..webdavPath = remote
          ..webdavError = skipped ? '服务器已有同名同大小文件，未重复上传' : null;
      },
    );
    if (failure != null) {
      item
        ..status = DownloadStatus.downloaded
        ..webdavError = failure;
      return;
    }
    await _finishUpload(item, file, config);
  }

  /// Optional Photos copy first, then remove the local file. `path` goes null
  /// so the offline library and the player stop pointing at a deleted file.
  Future<void> _finishUpload(
    DownloadItem item,
    File file,
    WebDavConfig config,
  ) async {
    if (config.alsoPhotos && await file.exists()) {
      final saved = await _saveToPhotos(file, item);
      if (saved != 'ok') {
        item.photoError = saved == 'denied'
            ? '相册权限未开启'
            : '存相册失败：$saved';
      } else {
        item.savedToPhotos = true;
      }
    }
    if (await file.exists()) {
      try {
        await file.delete();
      } on Object {
        // The upload succeeded; a stuck temp file is not worth failing the row.
      }
    }
    item
      ..path = null
      ..uploadSent = item.uploadTotal ?? item.uploadSent
      ..status = DownloadStatus.uploaded;
    _notify(force: true);
  }

  /// The remote name is the local one, timestamp prefix and all, so a file on
  /// the NAS says when it was captured. Only the old unreadable 13-digit epoch
  /// gets dropped, and only for records taken before names carried a date.
  String _remoteNameFor(DownloadItem item, File file) {
    final segments = file.uri.pathSegments;
    final raw = segments.isEmpty ? item.fileName : segments.last;
    final match = RegExp(r'^\d{13}_').firstMatch(raw);
    return match == null ? raw : raw.substring(match.end);
  }

  /// Shared upload path: build the target directory, skip an identical file,
  /// otherwise pick a non-colliding name and stream it up. Null means stored.
  Future<String?> _push(
    WebDavConfig config,
    String localPath,
    String name, {
    void Function(int sent, int total)? onProgress,
    void Function(String remote, bool skipped)? onDone,
  }) async {
    WebDavClient? client;
    try {
      client = WebDavClient(config);
      final dir = normalizeRemotePath(config.savePath);
      await client.ensureDir(dir);
      final size = await File(localPath).length();
      final target = joinRemote(dir, name);
      final existing = await client.stat(target);
      var remote = target;
      var skipped = false;
      if (existing != null) {
        if (existing == size) {
          skipped = true;
        } else {
          remote = await client.uniquePath(dir, name);
        }
      }
      if (!skipped) {
        await client.uploadFile(localPath, remote, onProgress: onProgress);
      }
      onDone?.call(remote, skipped);
      return null;
    } on _DownloadCancelled {
      // Let the queue's own cleanup delete the local file and mark cancelled.
      rethrow;
    } on WebDavException catch (error) {
      return error.message;
    } on Object catch (error) {
      return _friendlyError(error);
    } finally {
      client?.close();
    }
  }

  /// Upload a file the offline library already has on disk. Returns null on
  /// success, or the reason it did not land. The local copy is kept.
  Future<String?> uploadOffline(
    OfflineFile file, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final config = webdavConfig;
    if (config == null || !config.ready) return '未配置 WebDAV 地址';
    return _push(
      config,
      file.path,
      file.displayName,
      onProgress: onProgress,
    );
  }

  /// Direct file download with as much parallelism as the server allows.
  ///
  /// A `Range: bytes=0-0` probe decides: 206 with a real total means the file
  /// can be sliced, so several connections pull fixed windows into one
  /// pre-sized file. Anything else (Range ignored, size unknown, tiny files,
  /// image downloads) streams on a single connection instead, which is also
  /// what a failed slice falls back to so a dropped worker never loses the
  /// whole transfer.
  Future<File> _downloadFile(
    DownloadItem item,
    Uri uri,
    List<OrderedHeader> headers,
    CancelToken token,
  ) async {
    // Images arrive in one round trip already, so paying a probe request for
    // them would only make them slower.
    if (item.kind == ResourceKind.image) {
      return _downloadStreamed(item, uri, headers, token);
    }
    try {
      final ranged = await _downloadRanged(item, uri, headers, token);
      if (ranged != null) return ranged;
      await _discardPartial(item);
    } on Object {
      // Cancellation is final; every other failure just retries in one piece.
      if (token.isCancelled) throw const _DownloadCancelled();
      await _discardPartial(item);
    }
    return _downloadStreamed(item, uri, headers, token);
  }

  Future<File?> _downloadRanged(
    DownloadItem item,
    Uri uri,
    List<OrderedHeader> headers,
    CancelToken token,
  ) async {
    final probe = await _probeFile(uri, headers, token);
    final total = probe.total;
    if (!probe.sliceable ||
        total == null ||
        total < _parallelMinimumBytes ||
        token.isCancelled) {
      return null;
    }
    final contentType = probe.contentType;
    if (_isPageType(contentType)) {
      throw const FormatException('服务器返回了网页而不是媒体文件');
    }

    final dir = await _downloadDir();
    if (dir == null) throw const FileSystemException('找不到应用目录');
    await dir.create(recursive: true);

    final name = _fileNameFor(item, contentType);
    final file = File('${dir.path}/${_stampPrefix()}_$name');
    item
      ..path = file.path
      ..total = total
      ..received = 0;
    _notify(force: true);

    // One handle for the whole transfer: FileMode.write truncates, so this is
    // also where the file takes its final length. APFS keeps the holes free
    // until the bytes actually arrive.
    final handle = await file.open(mode: FileMode.write);
    await handle.truncate(total);

    final window = _windowBytes(total);
    final pieces = (total + window - 1) ~/ window;
    var nextPiece = 0;
    Object? failure;

    // A RandomAccessFile writes at its own position, so the workers take turns
    // on the shared handle. Only the network runs in parallel; a local
    // positioned write is over in microseconds.
    var writeTail = Future<void>.value();
    Future<void> writeAt(int position, Uint8List bytes) async {
      final previous = writeTail;
      final done = Completer<void>();
      // Queue behind whoever holds the handle. The chain itself never carries
      // an error, so one broken write cannot stall the rest.
      writeTail = done.future;
      await previous;
      try {
        await handle.setPosition(position);
        await handle.writeFrom(bytes);
      } finally {
        done.complete();
      }
    }

    Future<void> runWorker() async {
      while (failure == null) {
        if (token.isCancelled) return;
        final piece = nextPiece++;
        if (piece >= pieces) return;
        final start = piece * window;
        final length = math.min(window, total - start);
        try {
          final bytes = await _fetchBytesRetry(
            uri,
            headers,
            token,
            range: HlsByteRange(start, length),
          );
          if (bytes.length != length) {
            throw const FormatException('分片长度与 Range 不符');
          }
          await writeAt(start, bytes);
          item.received += length;
          _notify();
        } on Object catch (error) {
          if (token.isCancelled) return;
          failure ??= error;
          return;
        }
      }
    }

    try {
      final workerCount = math.min(_parallelWorkers(total), pieces);
      await Future.wait(<Future<void>>[
        for (var i = 0; i < workerCount; i++) runWorker(),
      ]);

      if (token.isCancelled) throw const _DownloadCancelled();
      // A window that still failed after its retries: give up on slicing and
      // let the caller pull the whole file in one pass.
      if (failure != null) return null;
      await handle.flush();
      return file;
    } finally {
      try {
        await handle.close();
      } on Object {
        // The handle may already be broken; the length is on disk either way.
      }
    }
  }

  Future<File> _downloadStreamed(
    DownloadItem item,
    Uri uri,
    List<OrderedHeader> headers,
    CancelToken token,
  ) async {
    final response = await session.openStream(
      TransportRequest(
        method: 'GET',
        uri: uri,
        profileId: session.profile.id,
        headers: headers,
      ),
      cancelToken: token,
    );
    IOSink? sink;
    try {
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      final contentType =
          (response.header('content-type') ?? '').toLowerCase().trim();
      if (_isPageType(contentType)) {
        throw const FormatException('服务器返回了网页而不是媒体文件');
      }

      final rawLength = response.header('content-length');
      final length = rawLength == null
          ? null
          : int.tryParse(rawLength.split(';').first.trim());
      item.total = length != null && length > 0 ? length : null;

      final dir = await _downloadDir();
      if (dir == null) throw const FileSystemException('找不到应用目录');
      await dir.create(recursive: true);

      final name = _fileNameFor(item, contentType);
      final file = File('${dir.path}/${_stampPrefix()}_$name');
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
      return file;
    } on Object {
      try {
        await sink?.flush();
        await sink?.close();
      } on Object {
        // The sink may already be broken by the aborted socket.
      }
      await _discardPartial(item);
      rethrow;
    }
  }

  /// Forgets a half-written file so a retry starts from nothing.
  Future<void> _discardPartial(DownloadItem item) async {
    final path = item.path;
    item
      ..path = null
      ..received = 0;
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on Object {
      // Best effort; an orphaned partial file is unreachable anyway.
    }
  }

  static bool _isPageType(String contentType) {
    return contentType.startsWith('text/html') ||
        contentType.startsWith('application/json') ||
        contentType.startsWith('text/plain');
  }

  static int _parallelWorkers(int total) {
    if (total >= 64 * 1024 * 1024) return 8;
    if (total >= 8 * 1024 * 1024) return 6;
    if (total >= 3 * 1024 * 1024) return 4;
    return 2;
  }

  /// Size of one Range window: enough pieces to keep every worker busy,
  /// small enough that four or eight of them in memory at once is nothing.
  static int _windowBytes(int total) {
    final perWorker = total / (_parallelWorkers(total) * 3);
    if (perWorker <= _minimumWindowBytes) return _minimumWindowBytes;
    return math.min(perWorker.ceil(), _maximumWindowBytes);
  }

  /// Asks the server for one byte. The answer decides whether the file can be
  /// sliced and how long it is, so the body is dropped as soon as the headers
  /// and the first chunk have been seen.
  Future<_FileProbe> _probeFile(
    Uri uri,
    List<OrderedHeader> headers,
    CancelToken token,
  ) async {
    final response = await session.openStream(
      TransportRequest(
        method: 'GET',
        uri: uri,
        profileId: session.profile.id,
        headers: <OrderedHeader>[
          ...headers,
          const OrderedHeader('Range', 'bytes=0-0'),
        ],
      ),
      cancelToken: token,
    );
    final contentType =
        (response.header('content-type') ?? '').toLowerCase().trim();
    int? total;
    var sliceable = false;
    if (response.statusCode == 206) {
      final range = (response.header('content-range') ?? '').trim();
      final match = RegExp(r'/(\d+)\s*$').firstMatch(range);
      final parsed = int.tryParse(match?.group(1) ?? '');
      if (parsed != null && parsed > 0) {
        total = parsed;
        sliceable = true;
      }
    }

    var seen = 0;
    await for (final chunk in response.body) {
      if (token.isCancelled) throw const _DownloadCancelled();
      seen += chunk.length;
      // A server that ignores Range would otherwise hand over the whole file
      // just for it to be thrown away.
      if (sliceable || seen >= 64 * 1024) break;
    }

    if (!sliceable) {
      final rawLength = response.header('content-length');
      final length = rawLength == null
          ? null
          : int.tryParse(rawLength.split(';').first.trim());
      total = length != null && length > 0 ? length : null;
    }
    return _FileProbe(
      total: total,
      contentType: contentType,
      sliceable: sliceable,
    );
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
    final stamp = _stampPrefix();
    final temp = File(
      '${dir.path}/.${stamp}_$base.${fmp4 ? 'mp4' : 'ts'}',
    );
    item
      ..path = temp.path
      ..segmentsTotal = playlist.segments.length
      ..segmentsDone = 0;
    _notify(force: true);

    final keys = <String, Uint8List>{};
    String? skipNote;
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

      // Segments are small, so a wider batch hides per-request latency better
      // than a bigger buffer; the sink still writes them in playlist order.
      const window = 6;
      final badPieces = <int>[];
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
          var bytes = chunks[i];
          // A CDN that refuses one request out of three hundred answers 200
          // with a page, and that page wedged into the middle of the stream is
          // enough for the demuxer to call the whole file unreadable. Ask once
          // more, then drop the piece: a short jump in the video beats a file
          // that will not open at all.
          if (!_pieceIsMedia(bytes, fmp4: fmp4)) {
            bytes = await _fetchSegment(batch[i], headers, token, keys);
            if (!_pieceIsMedia(bytes, fmp4: fmp4)) {
              badPieces.add(start + i + 1);
              bytes = Uint8List(0);
            }
          }
          if (bytes.isNotEmpty) {
            sink.add(bytes);
            item.received += bytes.length;
          }
          item.segmentsDone = start + i + 1;
          _notify();
        }
      }
      if (badPieces.length > 3 &&
          badPieces.length * 5 > playlist.segments.length) {
        throw FormatException(
          '服务器拒掉了 ${badPieces.length} 个分片，多半是防盗链或登录过期',
        );
      }
      skipNote = badPieces.isEmpty
          ? null
          : '已跳过 ${badPieces.length} 个异常分片'
                '${badPieces.length <= 6 ? '（第 ${badPieces.join('、')} 段）' : ''}';
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

    // What is on disk decides, not what the playlist claimed: several CDNs
    // serve fMP4 behind `.ts` names, and AVFoundation will not open a
    // "transport stream" whose first box is `ftyp`. Sniffing the bytes also
    // turns a blind remux failure into a line that says what was downloaded.
    final probe = await _sniffContainer(temp);
    if (probe.isMp4 || fmp4) {
      // init section + fragments already form a complete fragmented MP4; only
      // the name is rough.
      final out = File('${dir.path}/${stamp}_$base.mp4');
      await temp.rename(out.path);
      item.path = out.path;
      return _MediaFile(out, saveable: true, note: skipNote);
    }

    final out = File('${dir.path}/${stamp}_$base.mp4');
    item.status = DownloadStatus.saving;
    _notify(force: true);
    String? note;
    if (probe.isText) {
      // A login wall or a hotlink guard that answers 200 with a page.
      note = '分片内容不是视频，开头是「${probe.textPreview}」';
    } else {
      try {
        final status = await _media.invokeMethod<String>(
          'remuxToMp4',
          <String, Object?>{
            'source': temp.path,
            'destination': out.path,
          },
        );
        final text = status ?? '';
        if (text.startsWith('ok') &&
            await out.exists() &&
            await out.length() > 1024) {
          try {
            await temp.delete();
          } on Object {
            // The MP4 is what matters; the TS copy can be cleaned later.
          }
          item.path = out.path;
          // "ok: …" means the native side had to throw away part of the
          // stream to make the file; the row has to say so, or a video that
          // ends early looks like a bug in the player.
          final detail = text.startsWith('ok:') ? text.substring(3).trim() : '';
          return _MediaFile(
            out,
            saveable: true,
            note: _joinNotes(
              skipNote,
              detail.isEmpty ? null : detail,
            ),
          );
        }
        note = '${text.isEmpty ? '转封装失败' : text}（${probe.diagnosis}）';
      } on MissingPluginException {
        note = '当前构建不支持视频转封装';
      } on PlatformException catch (error) {
        note = '${error.message ?? '转封装失败'}（${probe.diagnosis}）';
      } on Object catch (error) {
        note = '$error';
      }
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
      note: _joinNotes(
        skipNote,
        '已保留原始分片文件，转 MP4 失败：$message（可点「转 MP4」就地重试）',
      ),
    );
  }

  /// Is this piece of the stream media data at all? Transport streams start
  /// with the 0x47 sync byte (again one packet later), fragmented MP4 with a
  /// box header, and everything else — an HTML error page, a JSON refusal, a
  /// zero-byte reply — is not something to append to a video.
  static bool _pieceIsMedia(Uint8List bytes, {required bool fmp4}) {
    if (bytes.length < 4) return false;
    if (bytes[0] == 0x47) {
      // One sync byte is luck; the next packet grid is the evidence. Short
      // pieces cannot be checked that far, and they are taken on trust.
      if (bytes.length < 2 * 208) return true;
      for (final stride in const <int>[188, 192, 204, 208, 194]) {
        if (bytes.length > stride * 2 && bytes[stride] == 0x47) return true;
      }
      return false;
    }
    if (bytes.length > 12 && bytes[4] == 0x66) {
      final type = String.fromCharCodes(bytes.sublist(4, 8));
      if (type == 'ftyp' || type == 'styp') return true;
    }
    if (bytes.length > 12) {
      final type = String.fromCharCodes(bytes.sublist(4, 8));
      if (fmp4 &&
          (type == 'moof' || type == 'sidx' || type == 'free' || type == 'mdat')) {
        return true;
      }
    }
    return false;
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

/// The moment a file was captured, in its name: `20261023-213456_片段.mp4`.
///
/// The native bridge prefixes its own failures with `error: `, which reads
/// like a stack trace in a download row. The reason is the useful part.
String _withoutErrorPrefix(String text) =>
    text.startsWith('error: ') ? text.substring('error: '.length) : text;

/// CDN names repeat (`1.mp4`, `video.ts`) and a millisecond epoch is unreadable,
/// so the offline library and the WebDAV target both carry the local time
/// instead. Nothing parses this prefix back, which is why the same string can
/// be uploaded to the server untouched.
String _stampPrefix([DateTime? at]) {
  final time = at ?? DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}${two(time.month)}${two(time.day)}'
      '-${two(time.hour)}${two(time.minute)}${two(time.second)}';
}

/// What the concatenated segment file really holds, read off its first bytes.
///
/// The playlist only *claims* a container: `.ts` names hide fMP4/CMAF streams
/// often enough that trusting it turned every such download into an
/// "unreadable video track" from AVFoundation.
final class _ContainerProbe {
  const _ContainerProbe({
    required this.isMp4,
    required this.isTs,
    required this.isText,
    required this.size,
    required this.byteHint,
    required this.textPreview,
    required this.stride,
  });

  final bool isMp4;
  final bool isTs;
  final bool isText;
  final int size;

  /// First bytes as hex, for the case where none of the three flags fits.
  final String byteHint;
  final String textPreview;

  /// Packet length the transport-stream sync bytes repeat at (usually 188).
  final int stride;

  bool get aligned => stride == 0 || size % stride == 0;

  String get summary {
    if (isMp4) return 'MP4';
    if (isTs) return aligned ? 'MPEG-TS' : 'MPEG-TS 长度不对齐';
    if (isText) return '文本';
    return '未知容器';
  }

  /// One line that survives a screenshot: what was on disk when the remuxer
  /// gave up, so the failure can be told apart from a broken CDN answer.
  String get diagnosis => <String>[
    summary,
    formatBytes(size),
    byteHint.isEmpty ? '空文件' : byteHint,
    if (isTs && !aligned) '不是 $stride 的整数倍',
  ].join(' · ');
}

Future<_ContainerProbe> _sniffContainer(File file) async {
  var size = 0;
  var head = Uint8List(0);
  try {
    size = await file.length();
    if (size > 0) {
      final raf = await file.open();
      try {
        head = Uint8List(math.min(size, 64 * 1024));
        await raf.readInto(head, 0, head.length);
      } finally {
        await raf.close();
      }
    }
  } on Object {
    // Unreadable: the remuxer's own error still gets reported.
  }

  var isMp4 = false;
  if (head.length > 12) {
    isMp4 = head[4] == 0x66 &&
        head[5] == 0x74 &&
        head[6] == 0x79 &&
        head[7] == 0x70; // "ftyp"
  }

  var stride = 0;
  if (head.isNotEmpty && head[0] == 0x47) {
    for (final candidate in const <int>[188, 192, 194, 204, 208]) {
      if (head.length > candidate * 3 && head[candidate] == 0x47) {
        stride = candidate;
        break;
      }
    }
  }
  final isTs = stride > 0;

  var isText = false;
  var textPreview = '';
  if (!isMp4 && !isTs && head.isNotEmpty) {
    final first = Uint8List.sublistView(head, 0, math.min(head.length, 64));
    isText = first.every(
      (byte) => byte == 0x09 ||
          byte == 0x0a ||
          byte == 0x0d ||
          (byte >= 0x20 && byte < 0x7f),
    );
    if (isText) {
      textPreview = String.fromCharCodes(first)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (textPreview.length > 40) {
        textPreview = '${textPreview.substring(0, 40)}…';
      }
    }
  }

  final hex = head
      .sublist(0, math.min(head.length, 8))
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join(' ');
  return _ContainerProbe(
    isMp4: isMp4,
    isTs: isTs,
    isText: isText,
    size: size,
    byteHint: hex,
    textPreview: textPreview,
    stride: stride,
  );
}

final class _MediaFile {
  const _MediaFile(this.file, {required this.saveable, this.note});

  final File file;
  final bool saveable;
  final String? note;
}

/// What a `Range: bytes=0-0` probe answered: the real length of the file and
/// whether the server honours Range at all.
final class _FileProbe {
  const _FileProbe({
    required this.total,
    required this.contentType,
    required this.sliceable,
  });

  final int? total;
  final String contentType;
  final bool sliceable;
}

final class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}
