import 'package:flutter/material.dart';

import 'downloads.dart';
import 'resources.dart';
import 'theme.dart';

/// Download queue and history. Completed image/video files are already in
/// Photos; this list is the record of what happened and what still needs a
/// retry.
class DownloadsSheet extends StatelessWidget {
  const DownloadsSheet({super.key, required this.manager});

  final DownloadManager manager;

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
          listenable: manager,
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
                  padding: const EdgeInsets.fromLTRB(18, 12, 12, 8),
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
                              manager.items.isEmpty
                                  ? '图片和视频下载后自动存入相册'
                                  : '${manager.items.length} 项 · '
                                      '${manager.activeCount} 进行中 · '
                                      '${manager.finishedCount} 已完成',
                              style: const TextStyle(
                                fontSize: 10,
                                color: AppColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: manager.finishedCount == 0
                            ? null
                            : manager.clearFinished,
                        child: const Text('Clear'),
                      ),
                      const SizedBox(width: 4),
                      _CloseButton(
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: manager.items.isEmpty
                      ? const _EmptyDownloads()
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                          itemCount: manager.items.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 7),
                          itemBuilder: (context, index) {
                            final item = manager.items[index];
                            return _DownloadTile(
                              item: item,
                              onCancel: () => manager.cancel(item),
                              onRetry: () => manager.retry(item),
                              onRemove: () => manager.remove(item),
                              onPlay: !item.playable
                                  ? null
                                  : () async {
                                      final error = await manager.play(item);
                                      if (error != null && context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content: Text('播放失败：$error'),
                                          ),
                                        );
                                      }
                                    },
                              onShare:
                                  item.path == null || !item.status.terminal
                                  ? null
                                  : () async {
                                      final error = await manager.share(item);
                                      if (error != null && context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content: Text('导出失败：$error'),
                                          ),
                                        );
                                      }
                                    },
                            );
                          },
                        ),
                ),
              ],
            );
          },
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
  });

  final DownloadItem item;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final VoidCallback onRemove;
  final VoidCallback? onPlay;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    final isActive = item.status.active;
    final canRetry = item.status == DownloadStatus.failed ||
        item.status == DownloadStatus.cancelled;
    final subtitle = switch (item.status) {
      DownloadStatus.running => item.sizeLabel,
      DownloadStatus.saving =>
        item.hls ? '分片已下载，正在合并成 MP4…' : item.sizeLabel,
      DownloadStatus.saved => '已存入相册${item.sizeLabel.isEmpty ? '' : ' · ${item.sizeLabel}'}',
      DownloadStatus.downloaded => item.hls
          ? (item.photoError ?? '视频已下载，未存入相册')
          : (item.photoError ?? '文件已下载，未存入相册'),
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
            if (item.status == DownloadStatus.running ||
                item.status == DownloadStatus.saving)
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

class _MiniButton extends StatelessWidget {
  const _MiniButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

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
            child: Icon(icon, size: 15, color: AppColors.muted),
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
