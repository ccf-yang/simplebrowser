import 'dart:async';

import 'package:flutter/material.dart';

import 'downloads.dart';
import 'resources.dart';
import 'theme.dart';

/// Download queue plus the files that actually live in the app container.
///
/// Saving to Photos leaves the original behind; the offline tab is where the
/// user can replay, export or delete those originals and see what they cost.
class DownloadsSheet extends StatefulWidget {
  const DownloadsSheet({super.key, required this.manager});

  final DownloadManager manager;

  @override
  State<DownloadsSheet> createState() => _DownloadsSheetState();
}

class _DownloadsSheetState extends State<DownloadsSheet> {
  int _tab = 0;
  List<OfflineFile>? _offline;

  /// The offline library starts out empty-looking and stays that way until the
  /// eye is pressed. These files are not deleted or moved — the list is simply
  /// not drawn, the count is not shown, and 「清空文件」 refuses to work on what
  /// is not on screen, so a first glance at the phone reveals nothing.
  bool _offlineHidden = true;

  /// One offline file at a time: the sheet shows a bar on that row only.
  String? _uploadingPath;
  double? _uploadProgress;

  DownloadManager get _manager => widget.manager;

  bool get _webDavReady => _manager.webdavConfig?.ready ?? false;

  @override
  void initState() {
    super.initState();
    // Read once up front so the tab can show its count without a spinner.
    unawaited(_loadOffline());
  }

  int get _offlineTotal => (_offline ?? const <OfflineFile>[])
      .fold<int>(0, (sum, file) => sum + file.size);

  Future<void> _loadOffline() async {
    final files = await _manager.listOffline();
    if (!mounted) return;
    setState(() => _offline = files);
  }

  void _selectTab(int tab) {
    if (_tab == tab) return;
    setState(() => _tab = tab);
    if (tab == 1) unawaited(_loadOffline());
  }

  /// The eye: hide the library again, or show what is on disk.
  void _toggleOfflineVisible() {
    final revealing = _offlineHidden;
    setState(() => _offlineHidden = !revealing);
    // A download can have finished while the list was hidden, so opening it
    // re-scans instead of showing a stale shelf.
    if (revealing) unawaited(_loadOffline());
  }

  Future<void> _notice(String title, String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        content: Text(
          message,
          style: const TextStyle(fontSize: 12, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirm(
    String title,
    String message, {
    String confirmLabel = '清空',
  }) async {
    if (!mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        content: Text(
          message,
          style: const TextStyle(fontSize: 12, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _clearRecords() async {
    final count = _manager.finishedCount;
    if (count == 0) return;
    if (!await _confirm(
      '清空下载记录？',
      '$count 条已结束的记录会从列表里移除。\nApp 内的文件和相册里的内容都不会被删除。',
    )) {
      return;
    }
    _manager.clearFinished();
  }

  Future<void> _clearOffline() async {
    // The button is greyed out while hidden; this is the second lock, because
    // deleting files nobody can see is the one mistake hiding exists to prevent.
    if (_offlineHidden) return;
    final files = _offline ?? const <OfflineFile>[];
    if (files.isEmpty) return;
    if (!await _confirm(
      '清空离线库？',
      '${files.length} 个文件 · ${formatBytes(_offlineTotal)} 会从 App 里删除，'
          '同时清空下载记录。\n相册里已保存的副本不受影响，正在下载的任务会跳过。',
    )) {
      return;
    }
    final error = await _manager.clearOffline();
    await _loadOffline();
    if (error != null) await _notice('部分文件未能删除', error);
  }

  Future<void> _playOffline(OfflineFile file) async {
    final error = await _manager.playPath(file.path);
    if (error != null) await _notice('播放失败', error);
  }

  Future<void> _shareOffline(OfflineFile file) async {
    final error = await _manager.sharePath(file.path);
    if (error != null) await _notice('导出失败', error);
  }

  Future<void> _deleteOffline(OfflineFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          '删除本地文件？',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        content: Text(
          '${file.displayName}\n'
          '${file.sizeLabel} · 删除后无法恢复，已存入相册的副本不受影响。',
          style: const TextStyle(fontSize: 12, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final error = await _manager.deleteOffline(file);
    if (error != null) {
      await _notice('删除失败', error);
      return;
    }
    await _loadOffline();
  }

  void _openImage(OfflineFile file) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withAlpha(230),
      builder: (context) {
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: InteractiveViewer(
                  maxScale: 4,
                  child: Center(
                    child: Image.file(file.file, fit: BoxFit.contain),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Material(
                    color: Colors.white.withAlpha(30),
                    shape: const CircleBorder(),
                    child: IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 20,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.sizeOf(context).height * 0.82,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: _manager,
          builder: (context, _) {
            return Column(
              children: <Widget>[
                const SizedBox(height: 8),
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.line2,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 12, 6),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const Text(
                              'Downloads',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.3,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              _subtitle(),
                              style: const TextStyle(
                                fontSize: 10,
                                color: AppColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_tab == 0)
                        TextButton(
                          onPressed: _manager.finishedCount == 0
                              ? null
                              : () => unawaited(_clearRecords()),
                          child: const Text('清空记录'),
                        )
                      else ...<Widget>[
                        TextButton(
                          onPressed: _offlineHidden ||
                                  (_offline ?? const <OfflineFile>[]).isEmpty
                              ? null
                              : () => unawaited(_clearOffline()),
                          child: const Text('清空文件'),
                        ),
                        const SizedBox(width: 2),
                        _MiniButton(
                          icon: _offlineHidden
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                          tooltip: _offlineHidden
                              ? '显示离线库'
                              : '隐藏离线库内容',
                          onTap: _toggleOfflineVisible,
                        ),
                        const SizedBox(width: 2),
                        _MiniButton(
                          icon: Icons.refresh_rounded,
                          tooltip: '重新扫描',
                          onTap: () => unawaited(_loadOffline()),
                        ),
                      ],
                      const SizedBox(width: 4),
                      _CloseButton(
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                  child: Row(
                    children: <Widget>[
                      _TabChip(
                        label: '任务',
                        count: _manager.items.length,
                        active: _tab == 0,
                        onTap: () => _selectTab(0),
                      ),
                      const SizedBox(width: 7),
                      _TabChip(
                        label: '离线库',
                        count: _offlineHidden ? null : _offline?.length,
                        active: _tab == 1,
                        onTap: () => _selectTab(1),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _tab == 0 ? _buildQueue() : _buildOffline(),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  String _subtitle() {
    if (_tab == 1) {
      // Worded exactly like the empty library, so the hidden state adds nothing
      // a first glance can pick up on.
      if (_offlineHidden) return 'App 内还没有文件';
      final files = _offline;
      if (files == null) return '正在读取 App 内的文件…';
      if (files.isEmpty) return 'App 内还没有文件';
      return '${files.length} 个文件 · ${formatBytes(_offlineTotal)} · '
          '${_webDavReady ? '可传到 ${_manager.webdavConfig?.summary ?? ''}' : '已存相册的原件仍在这里'}';
    }
    if (_manager.items.isEmpty) return '图片和视频下载后自动存入相册';
    return '${_manager.items.length} 项 · '
        '${_manager.activeCount} 进行中 · '
        '${_manager.finishedCount} 已完成';
  }

  Widget _buildQueue() {
    if (_manager.items.isEmpty) return const _EmptyDownloads();
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      itemCount: _manager.items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 7),
      itemBuilder: (context, index) {
        final item = _manager.items[index];
        return _DownloadTile(
          item: item,
          onCancel: () => _manager.cancel(item),
          onRetry: () => _manager.retry(item),
          onRemove: () => _manager.remove(item),
          onRemux: !item.remuxable
              ? null
              : () {
                  unawaited(_manager.remuxExisting(item));
                },
          onPlay: !item.playable
              ? null
              : () async {
                  final error = await _manager.play(item);
                  if (error != null) await _notice('播放失败', error);
                },
          onShare: item.path == null || !item.status.terminal
              ? null
              : () async {
                  final error = await _manager.share(item);
                  if (error != null) await _notice('导出失败', error);
                },
        );
      },
    );
  }

  Future<void> _uploadOffline(OfflineFile file) async {
    if (_uploadingPath != null) return;
    setState(() {
      _uploadingPath = file.path;
      _uploadProgress = null;
    });
    final error = await _manager.uploadOffline(
      file,
      onProgress: (sent, total) {
        if (!mounted || total <= 0) return;
        setState(() => _uploadProgress = (sent / total).clamp(0.0, 1.0));
      },
    );
    if (!mounted) return;
    setState(() {
      _uploadingPath = null;
      _uploadProgress = null;
    });
    if (error != null) {
      await _notice('上传失败', error);
      return;
    }
    await _notice(
      '已传到服务器',
      '${file.displayName} 已上传到 ${_manager.webdavConfig?.summary ?? ''}，'
      '本地副本保留。',
    );
  }

  Widget _buildOffline() {
    // Hidden draws the ordinary empty shelf: the same picture, the same words,
    // so a first glance cannot tell the two apart.
    if (_offlineHidden) return const _EmptyOffline();
    final files = _offline;
    if (files == null) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.ink,
          ),
        ),
      );
    }
    if (files.isEmpty) return const _EmptyOffline();
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      itemCount: files.length,
      separatorBuilder: (_, __) => const SizedBox(height: 7),
      itemBuilder: (context, index) {
        final file = files[index];
        final uploading = _uploadingPath == file.path;
        return _OfflineTile(
          file: file,
          onOpen: file.isImage
              ? () => _openImage(file)
              : file.playable
                  ? () => unawaited(_playOffline(file))
                  : null,
          onShare: () => unawaited(_shareOffline(file)),
          onDelete: () => unawaited(_deleteOffline(file)),
          onUpload: _webDavReady && !uploading
              ? () => unawaited(_uploadOffline(file))
              : null,
          uploading: uploading,
          progress: _uploadProgress,
        );
      },
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.count,
    required this.active,
    required this.onTap,
  });

  final String label;
  final int? count;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final foreground = active ? AppColors.onInk : AppColors.muted;
    return Material(
      color: active ? AppColors.ink : AppColors.wash,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: foreground,
                ),
              ),
              if (count != null) ...<Widget>[
                const SizedBox(width: 5),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: active ? AppColors.signal : AppColors.faint,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({
    required this.item,
    required this.onCancel,
    required this.onRetry,
    required this.onRemove,
    this.onPlay,
    this.onShare,
    this.onRemux,
  });

  final DownloadItem item;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final VoidCallback onRemove;
  final VoidCallback? onPlay;
  final VoidCallback? onShare;

  /// Re-merges a stream that was kept as raw `.ts` segments, without pulling
  /// the whole video down again.
  final VoidCallback? onRemux;

  @override
  Widget build(BuildContext context) {
    final isActive = item.status.active;
    final canRetry = item.status == DownloadStatus.failed ||
        item.status == DownloadStatus.cancelled;
    final subtitle = switch (item.status) {
      DownloadStatus.running => item.sizeLabel,
      DownloadStatus.saving =>
        item.hls ? '分片已下载，正在合并成 MP4…' : item.sizeLabel,
      DownloadStatus.uploading => item.sizeLabel,
      DownloadStatus.uploaded =>
        '${item.webdavPath ?? '已传服务器'}'
            '${item.webdavError == null ? '' : ' · ${item.webdavError}'}'
            '${item.photoError == null ? '' : ' · ${item.photoError}'}',
      DownloadStatus.saved =>
        '已存入相册${item.sizeLabel.isEmpty ? '' : ' · ${item.sizeLabel}'}'
            // A merge that had to drop data keeps saying so after the save.
            '${item.photoError == null ? '' : ' · ${item.photoError}'}',
      DownloadStatus.downloaded =>
        item.webdavError ??
        (item.hls
            ? (item.photoError ?? '视频已下载，未存入相册')
            : (item.photoError ?? '文件已下载，未存入相册')),
      DownloadStatus.failed => item.error ?? '下载失败',
      DownloadStatus.cancelled => '已取消',
      DownloadStatus.queued => '等待前面的任务',
    };

    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(13),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 9, 6, 9),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.line),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                _statusIcon(),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        item.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        [
                          item.kind == ResourceKind.image ? '图片' : '视频',
                          if (item.hls) 'M3U8',
                          if (item.hlsVariantLabel != null)
                            item.hlsVariantLabel!,
                          if (item.host.isNotEmpty) item.host,
                          if (item.webdav) '传服务器',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 9,
                          color: AppColors.muted,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 9,
                          height: 1.35,
                          color: item.status == DownloadStatus.failed
                              ? AppColors.danger
                              : AppColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onRemux != null) ...<Widget>[
                  _MiniButton(
                    icon: Icons.video_file_outlined,
                    tooltip: '转 MP4',
                    onTap: onRemux!,
                  ),
                  const SizedBox(width: 4),
                ],
                if (onPlay != null)
                  _MiniButton(
                    icon: Icons.play_circle_outline_rounded,
                    tooltip: '播放',
                    onTap: onPlay!,
                  ),
                if (onShare != null) ...<Widget>[
                  const SizedBox(width: 4),
                  _MiniButton(
                    icon: Icons.ios_share_rounded,
                    tooltip: '导出到文件',
                    onTap: onShare!,
                  ),
                ],
                const SizedBox(width: 4),
                if (isActive)
                  _MiniButton(
                    icon: Icons.close_rounded,
                    tooltip: 'Cancel',
                    onTap: onCancel,
                  )
                else if (canRetry)
                  _MiniButton(
                    icon: Icons.refresh_rounded,
                    tooltip: 'Retry',
                    onTap: onRetry,
                  )
                else
                  _MiniButton(
                    icon: Icons.delete_outline_rounded,
                    tooltip: 'Remove from list',
                    onTap: onRemove,
                  ),
              ],
            ),
            if (item.status.active && item.status != DownloadStatus.queued)
              Padding(
                padding: const EdgeInsets.fromLTRB(38, 7, 6, 0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: item.status == DownloadStatus.saving
                        ? null
                        : item.progress,
                    minHeight: 3,
                    color: AppColors.ink,
                    backgroundColor: AppColors.wash,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusIcon() {
    final (icon, color, background) = switch (item.status) {
      DownloadStatus.saved => (
        Icons.check_rounded,
        AppColors.signalInk,
        AppColors.signal,
      ),
      DownloadStatus.downloaded => (
        Icons.download_done_rounded,
        AppColors.ink,
        AppColors.wash,
      ),
      DownloadStatus.uploaded => (
        Icons.cloud_done_rounded,
        AppColors.signalInk,
        AppColors.signal,
      ),
      DownloadStatus.uploading => (
        Icons.cloud_upload_outlined,
        AppColors.ink,
        AppColors.wash,
      ),
      DownloadStatus.failed => (
        Icons.priority_high_rounded,
        AppColors.danger,
        AppColors.wash,
      ),
      DownloadStatus.cancelled => (
        Icons.remove_rounded,
        AppColors.muted,
        AppColors.wash,
      ),
      DownloadStatus.running || DownloadStatus.saving => (
        Icons.arrow_downward_rounded,
        AppColors.ink,
        AppColors.wash,
      ),
      DownloadStatus.queued => (
        Icons.schedule_rounded,
        AppColors.muted,
        AppColors.wash,
      ),
    };
    return Container(
      width: 29,
      height: 29,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: Icon(icon, size: 15, color: color),
    );
  }
}

class _OfflineTile extends StatelessWidget {
  const _OfflineTile({
    required this.file,
    required this.onOpen,
    required this.onShare,
    required this.onDelete,
    this.onUpload,
    this.uploading = false,
    this.progress,
  });

  final OfflineFile file;
  final VoidCallback? onOpen;
  final VoidCallback onShare;
  final VoidCallback onDelete;

  /// Null when no WebDAV target is configured.
  final VoidCallback? onUpload;
  final bool uploading;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 9, 6, 9),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.line),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  _thumbnail(),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          file.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          [
                            if (file.isVideo)
                              '视频'
                            else if (file.isImage)
                              '图片'
                            else
                              '文件',
                            file.sizeLabel,
                            _dateLabel(file.modified),
                            if (uploading) '上传中',
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 9,
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onOpen != null)
                    _MiniButton(
                      icon: file.isImage
                          ? Icons.zoom_in_rounded
                          : Icons.play_circle_outline_rounded,
                      tooltip: file.isImage ? '查看' : '播放',
                      onTap: onOpen!,
                    ),
                  const SizedBox(width: 4),
                  if (onUpload != null || uploading)
                    uploading
                        ? const _MiniButton(
                            icon: Icons.cloud_upload_outlined,
                            tooltip: '正在上传',
                            busy: true,
                          )
                        : _MiniButton(
                            icon: Icons.cloud_upload_outlined,
                            tooltip: '传到 WebDAV',
                            onTap: onUpload!,
                          ),
                  if (onUpload != null || uploading) const SizedBox(width: 4),
                  _MiniButton(
                    icon: Icons.ios_share_rounded,
                    tooltip: '导出到文件',
                    onTap: onShare,
                  ),
                  const SizedBox(width: 4),
                  _MiniButton(
                    icon: Icons.delete_outline_rounded,
                    tooltip: '删除本地文件',
                    onTap: onDelete,
                  ),
                ],
              ),
              if (uploading)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 6, 0),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 3,
                      color: AppColors.ink,
                      backgroundColor: AppColors.wash,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thumbnail() {
    final fallback = Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: AppColors.wash,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        file.isVideo
            ? Icons.movie_outlined
            : Icons.insert_drive_file_outlined,
        size: 17,
        color: AppColors.muted,
      ),
    );
    if (!file.isImage) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.file(
        file.file,
        width: 38,
        height: 38,
        fit: BoxFit.cover,
        cacheWidth: 152,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }

  String _dateLabel(DateTime time) {
    final local = time.toLocal();
    final now = DateTime.now();
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      final hour = local.hour.toString().padLeft(2, '0');
      final minute = local.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    }
    if (local.year == now.year) return '${local.month}月${local.day}日';
    return '${local.year}/${local.month}/${local.day}';
  }
}

class _EmptyDownloads extends StatelessWidget {
  const _EmptyDownloads();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.download_for_offline_outlined,
              size: 36,
              color: AppColors.faint,
            ),
            SizedBox(height: 10),
            Text(
              '还没有下载任务',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 5),
            Text(
              '打开网页后点右上角的资源按钮，勾选图片或视频。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                height: 1.5,
                color: AppColors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyOffline extends StatelessWidget {
  const _EmptyOffline();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.folder_open_rounded,
              size: 36,
              color: AppColors.faint,
            ),
            SizedBox(height: 10),
            Text(
              '离线库是空的',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 5),
            Text(
              '下载完成的图片和视频会留在 App 内。即使已经存进相册，'
              '也能在这里播放、导出或删除。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                height: 1.5,
                color: AppColors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  /// Greyed-out spinner slot for an action that is already running.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.wash,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: SizedBox(
            width: 29,
            height: 29,
            child: busy
                ? const Padding(
                    padding: EdgeInsets.all(7),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.muted,
                    ),
                  )
                : Icon(icon, size: 15, color: AppColors.muted),
          ),
        ),
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.wash,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: const SizedBox(
          width: 30,
          height: 30,
          child: Icon(Icons.close_rounded, size: 16, color: AppColors.muted),
        ),
      ),
    );
  }
}
