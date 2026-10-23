import 'dart:async';

import 'package:browser_http/browser_http.dart';
import 'package:flutter/material.dart';

import 'hls.dart';
import 'resources.dart';
import 'theme.dart';

/// What the resource picker asks the page to do after it closes.
class ResourceSheetResult {
  const ResourceSheetResult(
    this.downloads, {
    this.openDownloads = false,
    this.webdav = false,
  });

  final List<SniffedResource> downloads;
  final bool openDownloads;

  /// Queue the selection for WebDAV instead of the photo album.
  final bool webdav;
}

/// Lists the images and direct video files the current document already
/// loaded. Selection is per URL; the sheet returns the chosen set, and the
/// host owns the actual queue.
class ResourceSheet extends StatefulWidget {
  const ResourceSheet({
    super.key,
    required this.controller,
    required this.history,
    this.userAgent,
    this.onLoadVariants,
    this.webdavSummary = '未配置',
    this.webdavReady = false,
    this.initialToWebDav = false,
  });

  final BrowserController controller;
  final String? userAgent;

  /// Accumulated results across rescans. Owned by the page so the list outlives
  /// this sheet; the switch flips [SniffHistory.record].
  final SniffHistory history;

  /// Reads the master playlist behind an `.m3u8` row. The host wires this to
  /// the download manager so it reuses the browser's cookies and UA.
  final Future<List<HlsVariant>> Function(SniffedResource resource)?
      onLoadVariants;

  /// Where the upload would go, and whether a target is configured at all.
  final String webdavSummary;
  final bool webdavReady;
  final bool initialToWebDav;

  @override
  State<ResourceSheet> createState() => _ResourceSheetState();
}

class _ResourceSheetState extends State<ResourceSheet> {
  final Set<String> _selected = <String>{};
  final Map<String, HlsVariant> _variants = <String, HlsVariant>{};
  List<SniffedResource> _items = const <SniffedResource>[];
  bool _loading = true;
  String? _error;
  int _filter = 0; // all / images / videos
  late bool _toWebDav =
      widget.webdavReady && widget.initialToWebDav;

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
      final scanned = await SniffedResource.scan(widget.controller);
      if (!mounted) return;
      // Recording keeps earlier pages in the list; off means the sheet mirrors
      // exactly what the current document has loaded.
      final items = widget.history.merge(scanned);
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

  void _setRecordHistory(bool value) {
    setState(() => widget.history.record = value);
    // Turning it off discards the accumulated rows, and _scan prunes the
    // selection down to what is left on screen.
    unawaited(_scan());
  }

  void _clearHistory() {
    setState(() {
      widget.history.clear();
      _selected.clear();
    });
    unawaited(_scan());
  }

  List<SniffedResource> get _visible => switch (_filter) {
    1 => _items.where((item) => item.kind == ResourceKind.image).toList(),
    2 => _items.where((item) => item.kind == ResourceKind.video).toList(),
    _ => _items,
  };

  List<SniffedResource> get _chosen => _items
      .where((item) => _selected.contains(item.url))
      .toList();

  List<SniffedResource> get _choices => _items
      .where((item) => _selected.contains(item.url))
      .map((item) {
        final variant = _variants[item.url];
        return variant == null
            ? item
            : item.withHlsVariant(variant.uri.toString(), variant.label);
      })
      .toList();

  bool get _allVisibleSelected {
    final visible = _visible.where((item) => item.downloadable).toList();
    return visible.isNotEmpty &&
        visible.every((item) => _selected.contains(item.url));
  }

  void _toggle(SniffedResource resource) {
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
    final chosen = _choices;
    if (chosen.isEmpty) return;
    Navigator.of(context).pop(
      ResourceSheetResult(chosen, webdav: _toWebDav),
    );
  }

  Future<void> _pickVariant(SniffedResource resource) async {
    final loader = widget.onLoadVariants;
    if (loader == null) return;
    final chosen = await showModalBottomSheet<_VariantChoice>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: AppColors.ink.withAlpha(88),
      builder: (_) => _VariantSheet(
        resource: resource,
        variants: loader(resource),
        current: _variants[resource.url],
      ),
    );
    if (!mounted || chosen == null) return;
    setState(() {
      if (chosen.variant == null) {
        _variants.remove(resource.url);
      } else {
        _variants[resource.url] = chosen.variant!;
      }
      _selected.add(resource.url);
    });
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
                              : '${_items.length} 个资源 · $images 图片 · $videos 视频'
                                    '${widget.history.record ? ' · 含历史' : ''}',
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
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: Row(
                children: <Widget>[
                  _TogglePill(
                    icon: Icons.history_rounded,
                    label: '记录历史',
                    on: widget.history.record,
                    onTap: () => _setRecordHistory(!widget.history.record),
                  ),
                  const SizedBox(width: 6),
                  _TogglePill(
                    icon: Icons.cloud_upload_outlined,
                    label: '存到 WebDAV',
                    on: _toWebDav,
                    enabled: widget.webdavReady,
                    onTap: () => setState(() => _toWebDav = !_toWebDav),
                  ),
                  if (!widget.webdavReady) ...<Widget>[
                    const SizedBox(width: 6),
                    const Flexible(
                      child: Text(
                        '未配置，去 设置 → WebDAV 存储',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 9.5, color: AppColors.faint),
                      ),
                    ),
                  ],
                  if (widget.history.record && !widget.history.isEmpty) ...<
                    Widget
                  >[
                    const Spacer(),
                    TextButton(
                      onPressed: _clearHistory,
                      child: const Text('清空历史'),
                    ),
                  ],
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
          variantLabel: resource.hls
              ? (_variants[resource.url]?.label ?? '自动')
              : null,
          onVariantTap: resource.hls && widget.onLoadVariants != null
              ? () => unawaited(_pickVariant(resource))
              : null,
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
    final target = _toWebDav
        ? '已选 $chosen 项 · 本机下载后传 ${widget.webdavSummary}，传完删本地'
        : chosen == 0
        ? '选择要保存的图片或视频'
        : '已选 $chosen 项 · M3U8 会自动转成 MP4';
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
              target,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10.5, color: AppColors.muted),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: chosen == 0 ? null : _submit,
            icon: Icon(
              _toWebDav
                  ? Icons.cloud_upload_outlined
                  : Icons.download_rounded,
              size: 16,
            ),
            label: Text(
              chosen == 0
                  ? 'Download'
                  : _toWebDav
                  ? '上传 $chosen'
                  : '下载 $chosen',
            ),
          ),
        ],
      ),
    );
  }
}

/// Small on/off chip in the resource sheet's option row.
class _TogglePill extends StatelessWidget {
  const _TogglePill({
    required this.icon,
    required this.label,
    required this.on,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback onTap;

  /// Off rows are still tappable when disabled, so the host can explain why
  /// with its own hint; the visual just goes grey.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = on
        ? AppColors.signalLine
        : enabled
        ? AppColors.line2
        : AppColors.line;
    return Material(
      color: on ? AppColors.signalWash : AppColors.card,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(border: Border.all(color: color)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                icon,
                size: 12,
                color: on
                    ? AppColors.ink
                    : enabled
                    ? AppColors.muted
                    : AppColors.faint,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                  color: enabled ? AppColors.ink2 : AppColors.faint,
                ),
              ),
            ],
          ),
        ),
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
    this.variantLabel,
    this.onVariantTap,
  });

  final SniffedResource resource;
  final bool selected;
  final Map<String, String> headers;
  final VoidCallback onTap;

  /// Non-null only for HLS rows; shows the chosen rendition or `自动`.
  final String? variantLabel;
  final VoidCallback? onVariantTap;

  @override
  Widget build(BuildContext context) {
    return Material(
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
              if (variantLabel != null) ...<Widget>[
                const SizedBox(width: 6),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onVariantTap,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.wash,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          variantLabel!,
                          style: const TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: AppColors.ink2,
                          ),
                        ),
                        const SizedBox(width: 2),
                        const Icon(
                          Icons.tune_rounded,
                          size: 11,
                          color: AppColors.muted,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 8),
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 19,
                color: AppColors.ink,
              ),
            ],
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

final class _VariantChoice {
  const _VariantChoice(this.variant);

  const _VariantChoice.auto() : variant = null;

  final HlsVariant? variant;
}

/// Quality picker for one HLS row. Renditions come from the master playlist;
/// a plain media playlist only offers [auto].
class _VariantSheet extends StatelessWidget {
  const _VariantSheet({
    required this.resource,
    required this.variants,
    this.current,
  });

  final SniffedResource resource;
  final Future<List<HlsVariant>> variants;
  final HlsVariant? current;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.sizeOf(context).height * 0.55,
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
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    '清晰度',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    resource.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder<List<HlsVariant>>(
                future: variants,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.ink,
                            ),
                          ),
                          SizedBox(height: 10),
                          Text(
                            '正在读取清晰度列表…',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: AppColors.muted,
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  final list = snapshot.data ?? const <HlsVariant>[];
                  final error = snapshot.error;
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                    children: <Widget>[
                      _VariantTile(
                        title: '自动（最高画质）',
                        detail: list.isEmpty
                            ? '跟随播放列表默认的一档'
                            : '选择带宽最高的一档',
                        selected: current == null,
                        onTap: () => Navigator.of(context).pop(
                          const _VariantChoice.auto(),
                        ),
                      ),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 12, 10, 4),
                          child: Text(
                            '读取清晰度失败（引擎重试 3 次，又换了一条网络栈）：'
                            '$error\n'
                            '下载时会自动选择一档。「连接在建好前被关闭」多半是'
                            '手机上的代理节点断了或站点 CDN 掐的，关掉代理再试一次。',
                            style: const TextStyle(
                              fontSize: 10,
                              height: 1.5,
                              color: AppColors.danger,
                            ),
                          ),
                        ),
                      for (final variant in list)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: _VariantTile(
                            title: variant.label,
                            detail: variant.detail.isEmpty
                                ? variant.uri.host
                                : variant.detail,
                            selected: current?.uri.toString() ==
                                variant.uri.toString(),
                            onTap: () => Navigator.of(context).pop(
                              _VariantChoice(variant),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VariantTile extends StatelessWidget {
  const _VariantTile({
    required this.title,
    required this.detail,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.signalWash : AppColors.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(13, 11, 11, 11),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? AppColors.signalLine : AppColors.line,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (detail.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 9.5,
                          color: AppColors.muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 18,
                color: selected ? AppColors.ink : AppColors.faint,
              ),
            ],
          ),
        ),
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
