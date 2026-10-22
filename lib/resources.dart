import 'package:browser_http/browser_http.dart';

/// A resource the current document has already loaded or linked to.
///
/// WebKit exposes no response bodies for subresources, so every entry is a URL
/// plus whatever metadata the DOM or the Performance API provides. Direct files
/// are downloadable; `blob:`/MSE streams never leave the page and HLS
/// playlists are listed but not fetched in this version.
enum ResourceKind { image, video }

final class SniffedResource {
  const SniffedResource({
    required this.url,
    required this.pageUrl,
    required this.kind,
    this.title = '',
    this.poster = '',
    this.width,
    this.height,
    this.size,
    this.hls = false,
  });

  final String url;
  final String pageUrl;
  final ResourceKind kind;
  final String title;
  final String poster;
  final int? width;
  final int? height;
  final int? size;

  /// `.m3u8` (Apple HLS). Listed, visibly unsupported, never downloaded.
  final bool hls;

  bool get downloadable => !hls;

  String get host => Uri.tryParse(url)?.host ?? '';

  /// Last path segment with the query stripped, safe for a file name.
  String get fileName {
    final uri = Uri.tryParse(url);
    final segments = uri?.pathSegments;
    var name = (segments == null || segments.isEmpty) ? '' : segments.last;
    try {
      name = Uri.decodeComponent(name);
    } on Object {
      // Keep the raw segment.
    }
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]+'), '_').trim();
    if (name.isEmpty) {
      return kind == ResourceKind.image ? 'image' : 'video';
    }
    if (name.length > 90) {
      final dot = name.lastIndexOf('.');
      final ext = dot > 0 && name.length - dot <= 6 ? name.substring(dot) : '';
      name = name.substring(0, 90 - ext.length) + ext;
    }
    return name;
  }

  String get displayName {
    final clean = title.trim();
    return clean.isEmpty ? fileName : clean;
  }

  /// `1200×800 · 640 KB`, omitting what the page did not report.
  String get metaLabel {
    final parts = <String>[];
    if (width != null && height != null && width! > 0 && height! > 0) {
      parts.add('${width!}×${height!}');
    }
    if (hls) {
      parts.add('M3U8 · 暂不支持');
    } else if (size != null && size! > 0) {
      parts.add(_bytes(size!));
    }
    return parts.join(' · ');
  }

  static String _bytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
    return '$bytes B';
  }

  /// The resource set of the current page.
  ///
  /// DOM order comes first because it carries poster/dimension metadata;
  /// Performance entries fill in resources that are not elements (lazy
  /// images, media fetched by scripts).
  static Future<List<SniffedResource>> scan(BrowserController browser) async {
    final raw = await browser.evaluate(_scanScript);
    if (raw is! Map) return const <SniffedResource>[];
    final page = browser.url ?? (raw['page']?.toString() ?? '');
    final items = raw['items'];
    if (items is! List) return const <SniffedResource>[];

    final result = <SniffedResource>[];
    for (final entry in items) {
      if (entry is! Map) continue;
      final url = entry['url']?.toString() ?? '';
      if (!url.startsWith('http://') && !url.startsWith('https://')) continue;
      final kind = entry['kind'] == 'video'
          ? ResourceKind.video
          : ResourceKind.image;
      result.add(
        SniffedResource(
          url: url,
          pageUrl: page,
          kind: kind,
          title: entry['title']?.toString() ?? '',
          poster: entry['poster']?.toString() ?? '',
          width: _int(entry['w']),
          height: _int(entry['h']),
          size: _int(entry['size']),
          hls: entry['hls'] == true,
        ),
      );
    }
    return result;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }

  static const String _scanScript = r'''
(function () {
  try {
    var page = location.href;
    var items = [], seen = {}, images = 0, videos = 0;
    var IMAGE_LIMIT = 320, VIDEO_LIMIT = 120;
    var imageExt = /\.(?:jpe?g|png|webp|gif|bmp|avif|heic)(?:$|[?#])/i;
    var videoExt = /\.(?:mp4|m4v|mov|webm|mkv|m3u8)(?:$|[?#])/i;
    var hlsExt = /\.m3u8(?:$|[?#])/i;

    function abs(value) {
      if (!value || typeof value !== 'string') return '';
      value = value.trim();
      if (!value || value.indexOf('data:') === 0 ||
          value.indexOf('blob:') === 0) return '';
      try { return new URL(value, document.baseURI).href; } catch (e) { return ''; }
    }

    function push(value, kind, meta) {
      var url = abs(value);
      if (!url || (url.indexOf('http://') !== 0 && url.indexOf('https://') !== 0)) return;
      if (kind === 'image' && images >= IMAGE_LIMIT) return;
      if (kind === 'video' && videos >= VIDEO_LIMIT) return;
      var key = kind + '\n' + url;
      if (seen[key]) return;
      seen[key] = true;
      if (kind === 'image') images++; else videos++;
      meta = meta || {};
      var entry = { url: url, kind: kind };
      if (meta.title) entry.title = String(meta.title).slice(0, 160);
      if (meta.poster) entry.poster = abs(meta.poster);
      if (meta.w > 0) entry.w = Math.round(meta.w);
      if (meta.h > 0) entry.h = Math.round(meta.h);
      if (meta.size > 0) entry.size = Math.round(meta.size);
      if (hlsExt.test(url)) entry.hls = true;
      items.push(entry);
    }

    function bestFromSrcset(text) {
      if (!text) return '';
      var best = '', bestWidth = -1;
      var parts = String(text).split(',');
      for (var i = 0; i < parts.length; i++) {
        var bits = parts[i].trim().split(/\s+/);
        if (!bits[0]) continue;
        var width = parseFloat(bits[1]) || 0;
        if (width >= bestWidth) { bestWidth = width; best = bits[0]; }
      }
      return best;
    }

    var imgs = document.querySelectorAll('img');
    for (var i = 0; i < imgs.length; i++) {
      var img = imgs[i];
      var src = img.currentSrc || img.src;
      var source = img.getAttribute('srcset');
      var best = bestFromSrcset(source);
      if (best) src = best;
      if (!src) {
        src = img.getAttribute('data-src') || img.getAttribute('data-original') ||
              img.getAttribute('data-lazy-src') || img.getAttribute('data-url') || '';
      }
      push(src, 'image', {
        title: img.alt || img.getAttribute('aria-label') || img.title,
        w: img.naturalWidth, h: img.naturalHeight
      });
      var lazy = img.getAttribute('data-original') || img.getAttribute('data-lazy-src') ||
                 img.getAttribute('data-src');
      if (lazy && lazy !== src) {
        push(lazy, 'image', { title: img.alt || img.title });
      }
    }

    var sources = document.querySelectorAll('picture source[srcset]');
    for (var j = 0; j < sources.length && j < 200; j++) {
      push(bestFromSrcset(sources[j].getAttribute('srcset')), 'image', {});
    }

    var metas = document.querySelectorAll('meta[property="og:image"],meta[name="twitter:image"],meta[property="og:video"],meta[property="og:video:url"]');
    for (var k = 0; k < metas.length; k++) {
      var content = metas[k].getAttribute('content');
      var prop = (metas[k].getAttribute('property') || metas[k].getAttribute('name') || '');
      push(content, prop.indexOf('video') >= 0 ? 'video' : 'image', {});
    }

    var styled = document.querySelectorAll('[style*="background"]');
    for (var m = 0; m < styled.length && m < 300; m++) {
      var style = styled[m].getAttribute('style') || '';
      var match = style.match(/url\((['"]?)([^)'"]+)\1\)/);
      if (match) push(match[2], 'image', {});
    }

    var vids = document.querySelectorAll('video');
    for (var n = 0; n < vids.length; n++) {
      var vid = vids[n];
      var vsrc = vid.currentSrc || vid.src ||
                 vid.getAttribute('data-src') || '';
      push(vsrc, 'video', {
        title: vid.title || vid.getAttribute('aria-label'),
        poster: vid.poster,
        w: vid.videoWidth, h: vid.videoHeight
      });
      var inner = vid.querySelectorAll('source[src]');
      for (var p = 0; p < inner.length; p++) {
        push(inner[p].src || inner[p].getAttribute('src'), 'video', {
          title: vid.title || vid.getAttribute('aria-label'),
          poster: vid.poster, w: vid.videoWidth, h: vid.videoHeight
        });
      }
    }

    var audios = document.querySelectorAll('audio source[src], audio[src]');
    for (var q = 0; q < audios.length; q++) {
      var asrc = audios[q].src || audios[q].getAttribute('src');
      if (videoExt.test(asrc)) push(asrc, 'video', { title: 'audio track' });
    }

    var links = document.querySelectorAll('a[href]');
    for (var r = 0; r < links.length && r < 2000; r++) {
      var href = links[r].getAttribute('href');
      if (!href) continue;
      if (videoExt.test(href)) push(href, 'video', { title: links[r].textContent });
      else if (imageExt.test(href)) push(href, 'image', { title: links[r].textContent });
    }

    try {
      var perf = performance.getEntriesByType('resource');
      for (var s = 0; s < perf.length; s++) {
        var entry = perf[s];
        var url = entry.name;
        if (!url || url.indexOf('http') !== 0) continue;
        var measured = entry.encodedBodySize || entry.transferSize || 0;
        if (hlsExt.test(url)) push(url, 'video', { size: measured });
        else if (videoExt.test(url)) push(url, 'video', { size: measured });
        else if (imageExt.test(url)) push(url, 'image', { size: measured });
        else if (entry.initiatorType === 'img') push(url, 'image', { size: measured });
        else if (entry.initiatorType === 'video') push(url, 'video', { size: measured });
      }
    } catch (e) {}

    return { page: page, title: document.title, items: items };
  } catch (error) {
    return { error: String(error), items: [] };
  }
})()
''';
}
