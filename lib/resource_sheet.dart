import 'package:browser_http/browser_http.dart';
import 'package:flutter/material.dart';

import 'resources.dart';
import 'theme.dart';

/// What the resource picker asks the page to do after it closes.
class ResourceSheetResult {
  const ResourceSheetResult(this.downloads, {this.openDownloads = false});

  final List<SniffedResource> downloads;
  final bool openDownloads;
}

/// Lists the images and direct video files the current document already
/// loaded. Selection is per URL; the sheet returns the chosen set, and the
/// host owns the actual queue.
class ResourceSheet extends StatefulWidget {
  const ResourceSheet({
    super.key,
    required this.controller,
    this.userAgent,
  });

  final BrowserController controller;
  final String? userAgent;

  @override
  State<ResourceSheet> createState() => _ResourceSheetState();
}

class _ResourceSheetState extends State<ResourceSheet> {
  final Set<String> _selected = <String>{};
  List<SniffedResource> _items = const <SniffedResource>[];
  bool _loading = true;
  String? _error;
  int _filter = 0; // all / images / videos

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await SniffedResource.scan(widget.controller);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        final present = items.map((item) => item.url).toSet();
        _selected.removeWhere((url) => !present.contains(url));
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  List<SniffedResource> get _visible => switch (_filter) {
    1 => _items.where((item) => item.kind == ResourceKind.image).toList(),
    2 => _items.where((item) => item.kind == ResourceKind.video).toList(),
    _ => _items,
  };

  List<SniffedResource> get _chosen => _items
      .where((item) => item.downloadable && _selected.contains(item.url))
      .toList();

  bool get _allVisibleSelected {
    final visible = _visible.where((item) => item.downloadable).toList();
    return visible.isNotEmpty &&
        visible.every((item) => _selected.contains(item.url));
  }

  void _toggle(SniffedResource resource) {
    if (!resource.downloadable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('M3U8 是流式播放列表，这一版还不支持下载'),
        ),
      );
      return;
    }
    setState(() {
      if (!_selected.remove(resource.url)) _selected.add(resource.url);
    });
  }

  void _toggleAll() {
    setState(() {
      final visible = _visible.where((item) => item.downloadable);
      if (_allVisibleSelected) {
        for (final item in visible) {
          _selected.remove(item.url);
        }
      } else {
        for (final item in visible) {
          _selected.add(item.url);
        }
      }
    });
  }

  void _submit() {
    final chosen = _chosen;
    if (chosen.isEmpty) return;
    Navigator.of(context).pop(ResourceSheetResult(chosen));
  }

  @override
  Widget build(BuildContext context) {
    final images = _items.where((item) => item.kind == ResourceKind.image).length;
    final videos = _items.length - images;
    final chosen = _chosen.length;

    return Container(
      height: MediaQuery.sizeOf(context).height * 0.88,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
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
                          'Resources',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _loading
                              ? '正在扫描当前页面…'
                              : '${_items.length} 个资源 · $images 图片 · $videos 视频',
                          style: const TextStyle(
                            fontSize: 10,
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _RoundButton(
                    icon: Icons.download_rounded,
                    tooltip: 'Downloads',
                    onTap: () => Navigator.of(context).pop(
                      const ResourceSheetResult(
                        <SniffedResource>[],
                        openDownloads: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _RoundButton(
                    icon: Icons.refresh_rounded,
                    tooltip: 'Rescan',
                    onTap: _loading ? null : () => _scan(),
                  ),
                  const SizedBox(width: 6),
                  _RoundButton(
                    icon: Icons.close_rounded,
                    tooltip: 'Close',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: Row(
                children: <Widget>[
                  _FilterPill(
                    label: 'All',
                    count: _items.length,
                    selected: _filter == 0,
                    onTap: () => setState(() => _filter = 0),
                  ),
                  const SizedBox(width: 6),
                  _FilterPill(
                    label: 'Images',
                    count: images,
                    selected: _filter == 1,
                    onTap: () => setState(() => _filter = 1),
                  ),
                  const SizedBox(width: 6),
                  _FilterPill(
                    label: 'Videos',
                    count: videos,
                    selected: _filter == 2,
                    onTap: () => setState(() => _filter = 2),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _visible.isEmpty ? null : _toggleAll,
                    child: Text(_allVisibleSelected ? 'Clear' : 'Select all'),
                  ),
                ],
              ),
            ),
            if (_loading) const LinearProgressIndicator(
              minHeight: 2,
              color: AppColors.ink,
              backgroundColor: AppColors.line,
            ),
            Expanded(child: _buildBody()),
            _buildFooter(chosen),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.search_off_rounded,
                size: 34,
                color: AppColors.faint,
              ),
              const SizedBox(height: 10),
              const Text(
                '扫描失败',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, color: AppColors.muted),
              ),
              const SizedBox(height: 14),
              FilledButton(onPressed: _scan, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    final visible = _visible;
    if (visible.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _items.isEmpty
                ? '这个页面还没有发现图片或视频。\n先让页面加载一会儿，再刷新扫描。'
                : '当前分类没有资源。',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 11.5,
              height: 1.6,
              color: AppColors.muted,
            ),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 10),
      itemCount: visible.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final resource = visible[index];
        return _ResourceTile(
          resource: resource,
          selected: _selected.contains(resource.url),
          headers: _headersFor(resource),
          onTap: () => _toggle(resource),
        );
      },
    );
  }

  Map<String, String> _headersFor(SniffedResource resource) {
    return <String, String>{
      if (resource.pageUrl.isNotEmpty) 'Referer': resource.pageUrl,
      if (widget.userAgent != null && widget.userAgent!.isNotEmpty)
        'User-Agent': widget.userAgent!,
    };
  }

  Widget _buildFooter(int chosen) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 9, 18, 8),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              chosen == 0 ? '选择要保存的图片或视频' : '已选 $chosen 项 · 默认存入相册',
              style: const TextStyle(fontSize: 10.5, color: AppColors.muted),
            ),
          ),
          FilledButton.icon(
            onPressed: chosen == 0 ? null : _submit,
            icon: const Icon(Icons.download_rounded, size: 16),
            label: Text(chosen == 0 ? 'Download' : 'Download $chosen'),
          ),
        ],
      ),
    );
  }
}

class _ResourceTile extends StatelessWidget {
  const _ResourceTile({
    required this.resource,
    required this.selected,
    required this.headers,
    required this.onTap,
  });

  final SniffedResource resource;
  final bool selected;
  final Map<String, String> headers;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = resource.downloadable;
    return Opacity(
      opacity: enabled ? 1 : 0.62,
      child: Material(
        color: selected ? AppColors.signalWash : AppColors.card,
        borderRadius: BorderRadius.circular(13),
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 7, 10, 7),
            decoration: BoxDecoration(
              border: Border.all(
                color: selected ? AppColors.signalLine : AppColors.line,
              ),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Row(
              children: <Widget>[
                _thumbnail(),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        resource.displayName,
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
                          resource.kind == ResourceKind.image ? '图片' : '视频',
                          if (resource.host.isNotEmpty) resource.host,
                          if (resource.metaLabel.isNotEmpty) resource.metaLabel,
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
                const SizedBox(width: 8),
                Icon(
                  !enabled
                      ? Icons.lock_outline_rounded
                      : selected
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                  size: 19,
                  color: enabled ? AppColors.ink : AppColors.faint,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _thumbnail() {
    final raw = resource.kind == ResourceKind.image
        ? resource.url
        : resource.poster;
    final fallback = Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: AppColors.wash,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(
        resource.kind == ResourceKind.image
            ? Icons.image_outlined
            : Icons.movie_outlined,
        size: 19,
        color: AppColors.faint,
      ),
    );
    if (raw.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: Image.network(
        raw,
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        headers: headers,
        errorBuilder: (_, __, ___) => fallback,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : fallback,
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.ink : AppColors.wash,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(
          '$label $count',
          style: TextStyle(
            fontSize: 10,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? AppColors.onInk : AppColors.muted,
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.wash,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: SizedBox(
            width: 30,
            height: 30,
            child: Icon(
              icon,
              size: 16,
              color: onTap == null ? AppColors.faint : AppColors.muted,
            ),
          ),
        ),
      ),
    );
  }
}
