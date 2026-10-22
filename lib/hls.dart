import 'dart:convert';

/// One sub-range of an HTTP resource, from `#EXT-X-BYTERANGE`.
final class HlsByteRange {
  const HlsByteRange(this.start, this.length);

  final int start;
  final int length;

  int get end => start + length - 1;
}

enum HlsEncryption { none, aes128, unsupported }

/// An `#EXT-X-KEY` state. It applies to every segment that follows it until
/// the next key tag.
final class HlsKey {
  const HlsKey({required this.method, this.uri, this.iv, this.keyFormat});

  static const HlsKey clear = HlsKey(method: HlsEncryption.none);

  final HlsEncryption method;
  final Uri? uri;
  final List<int>? iv;
  final String? keyFormat;
}

/// An `#EXT-X-MAP` initialisation section (fMP4).
final class HlsInitSection {
  const HlsInitSection({required this.uri, this.range, this.key});

  final Uri uri;
  final HlsByteRange? range;
  final HlsKey? key;
}

final class HlsSegment {
  const HlsSegment({
    required this.uri,
    required this.duration,
    required this.sequence,
    required this.key,
    this.range,
  });

  final Uri uri;
  final double duration;
  final int sequence;
  final HlsKey key;
  final HlsByteRange? range;
}

/// A playable rendition advertised by a master playlist.
final class HlsVariant {
  const HlsVariant({
    required this.uri,
    required this.bandwidth,
    this.resolution,
    this.codecs,
    this.name,
  });

  final Uri uri;
  final int bandwidth;
  final String? resolution;
  final String? codecs;
  final String? name;

  /// `1080P`, `720P`, or `1500 kbps` when the stream carries no resolution.
  String get label {
    final value = resolution?.trim() ?? '';
    if (value.isNotEmpty) {
      final parts = value.split('x');
      if (parts.length == 2) {
        final height = int.tryParse(parts[1]);
        if (height != null && height > 0) return '${height}P';
      }
      return value;
    }
    if (bandwidth > 0) return '${(bandwidth / 1000).round()} kbps';
    return '未标注清晰度';
  }

  String get detail {
    final parts = <String>[];
    final value = resolution?.trim() ?? '';
    if (value.isNotEmpty) parts.add(value);
    if (bandwidth > 0) parts.add('${(bandwidth / 1000).round()} kbps');
    final codec = _shortCodec(codecs);
    if (codec.isNotEmpty) parts.add(codec);
    return parts.join(' · ');
  }

  static String _shortCodec(String? value) {
    if (value == null || value.isEmpty) return '';
    if (value.contains('avc1')) return 'H.264';
    if (value.contains('hvc1') || value.contains('hev1')) return 'H.265';
    if (value.contains('av01')) return 'AV1';
    return '';
  }
}

/// A parsed HLS playlist. Either [variants] (master) or [segments] (media)
/// is non-empty; a master is never expanded implicitly.
final class HlsPlaylist {
  const HlsPlaylist({
    required this.baseUri,
    required this.variants,
    required this.segments,
    required this.targetDuration,
    required this.unsupportedReason,
    required this.separateAudio,
    this.init,
  });

  final Uri baseUri;
  final List<HlsVariant> variants;
  final List<HlsSegment> segments;
  final double targetDuration;
  final HlsInitSection? init;

  /// Non-null when the playlist uses encryption this app cannot remove.
  final String? unsupportedReason;

  /// True when the master playlist references audio as a separate rendition.
  /// The video variant then contains no audio track.
  final bool separateAudio;

  bool get isMaster => variants.isNotEmpty;
  bool get isMedia => segments.isNotEmpty;

  /// fMP4 segments already form MP4 boxes; plain TS segments need a remux.
  bool get isFragmentedMp4 =>
      init != null ||
      segments.any((segment) {
        final path = segment.uri.path.toLowerCase();
        return path.endsWith('.m4s') ||
            path.endsWith('.mp4') ||
            path.endsWith('.cmfv');
      });

  List<HlsVariant> get sortedVariants =>
      List<HlsVariant>.of(variants)
        ..sort((a, b) => b.bandwidth.compareTo(a.bandwidth));

  static HlsPlaylist parse(String text, Uri baseUri) {
    if (!text.trimLeft().startsWith('#EXTM3U')) {
      throw const FormatException('服务器返回的不是 M3U8 播放列表');
    }

    final lines = <String>[];
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isNotEmpty) lines.add(line);
    }

    final variants = <HlsVariant>[];
    final segments = <HlsSegment>[];
    final rangeEnds = <String, int>{};
    HlsInitSection? init;
    HlsKey key = HlsKey.clear;
    String? pendingVariantAttrs;
    String? pendingRange;
    double pendingDuration = 0;
    double targetDuration = 0;
    int mediaSequence = 0;
    String? unsupported;
    var separateAudio = false;

    for (final line in lines) {
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        pendingVariantAttrs = line.substring(line.indexOf(':') + 1);
        continue;
      }
      if (line.startsWith('#EXT-X-I-FRAME-STREAM-INF:')) continue;

      if (line.startsWith('#EXT-X-MEDIA:')) {
        final attrs = _attributes(line.substring(line.indexOf(':') + 1));
        if ((attrs['TYPE'] ?? '').toUpperCase() == 'AUDIO' &&
            (attrs['URI'] ?? '').isNotEmpty) {
          separateAudio = true;
        }
        continue;
      }

      if (line.startsWith('#EXT-X-KEY:')) {
        final attrs = _attributes(line.substring(line.indexOf(':') + 1));
        final method = (attrs['METHOD'] ?? '').toUpperCase();
        if (method == 'NONE') {
          key = HlsKey.clear;
        } else if (method == 'AES-128') {
          final format = (attrs['KEYFORMAT'] ?? '').trim();
          if (format.isNotEmpty && format.toLowerCase() != 'identity') {
            unsupported ??= '检测到 DRM 密钥（$format），暂不支持下载';
            key = const HlsKey(method: HlsEncryption.unsupported);
          } else {
            final uriText = attrs['URI'] ?? '';
            key = HlsKey(
              method: HlsEncryption.aes128,
              uri: uriText.isEmpty ? null : baseUri.resolve(uriText),
              iv: _parseIv(attrs['IV']),
              keyFormat: format.isEmpty ? null : format,
            );
          }
        } else {
          unsupported ??= method.startsWith('SAMPLE-AES')
              ? '这个视频使用 SAMPLE-AES 加密（$method），暂不支持下载'
              : '不支持的加密方式 ${method.isEmpty ? '未知' : method}';
          key = const HlsKey(method: HlsEncryption.unsupported);
        }
        continue;
      }

      if (line.startsWith('#EXT-X-MAP:')) {
        final attrs = _attributes(line.substring(line.indexOf(':') + 1));
        final uriText = attrs['URI'] ?? '';
        if (uriText.isNotEmpty) {
          final uri = baseUri.resolve(uriText);
          init = HlsInitSection(
            uri: uri,
            range: _parseRange(attrs['BYTERANGE'], uri, rangeEnds),
            key: key,
          );
        }
        continue;
      }

      if (line.startsWith('#EXT-X-BYTERANGE:')) {
        pendingRange = line.substring(line.indexOf(':') + 1).trim();
        continue;
      }

      if (line.startsWith('#EXTINF:')) {
        final value = line.substring(line.indexOf(':') + 1);
        final comma = value.indexOf(',');
        pendingDuration = double.tryParse(
              (comma >= 0 ? value.substring(0, comma) : value).trim(),
            ) ??
            0;
        continue;
      }

      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        mediaSequence = int.tryParse(
              line.substring(line.indexOf(':') + 1).trim(),
            ) ??
            0;
        continue;
      }

      if (line.startsWith('#EXT-X-TARGETDURATION:')) {
        targetDuration = double.tryParse(
              line.substring(line.indexOf(':') + 1).trim(),
            ) ??
            0;
        continue;
      }

      if (line.startsWith('#')) continue;

      final uri = baseUri.resolve(line);
      if (pendingVariantAttrs != null) {
        final attrs = _attributes(pendingVariantAttrs);
        variants.add(
          HlsVariant(
            uri: uri,
            bandwidth: int.tryParse(attrs['BANDWIDTH'] ?? '') ?? 0,
            resolution: _nullIfEmpty(attrs['RESOLUTION']),
            codecs: _nullIfEmpty(attrs['CODECS']),
            name: _nullIfEmpty(attrs['NAME']),
          ),
        );
        pendingVariantAttrs = null;
        continue;
      }

      HlsByteRange? range;
      if (pendingRange != null) {
        range = _parseRange(pendingRange, uri, rangeEnds);
        pendingRange = null;
      }
      segments.add(
        HlsSegment(
          uri: uri,
          duration: pendingDuration,
          sequence: mediaSequence + segments.length,
          key: key,
          range: range,
        ),
      );
      pendingDuration = 0;
    }

    return HlsPlaylist(
      baseUri: baseUri,
      variants: variants,
      segments: segments,
      targetDuration: targetDuration,
      unsupportedReason: unsupported,
      separateAudio: separateAudio,
      init: init,
    );
  }

  /// `AUDIO="aac",BANDWIDTH=...,CODECS="avc1.4d401f,mp4a.40.2"` → map.
  /// Quoted values may contain commas, so the scanner has to track quotes.
  static Map<String, String> _attributes(String text) {
    final result = <String, String>{};
    var index = 0;
    while (index < text.length) {
      final equals = text.indexOf('=', index);
      if (equals < 0) break;
      final name = text.substring(index, equals).trim();
      index = equals + 1;
      String value;
      if (index < text.length && text[index] == '"') {
        final end = text.indexOf('"', index + 1);
        if (end < 0) {
          value = text.substring(index + 1);
          index = text.length;
        } else {
          value = text.substring(index + 1, end);
          index = end + 1;
        }
      } else {
        var end = text.indexOf(',', index);
        if (end < 0) end = text.length;
        value = text.substring(index, end).trim();
        index = end;
      }
      if (name.isNotEmpty) result[name] = value;
      if (index < text.length && text[index] == ',') index++;
    }
    return result;
  }

  static HlsByteRange? _parseRange(
    String? text,
    Uri uri,
    Map<String, int> ends,
  ) {
    if (text == null || text.isEmpty) return null;
    final at = text.indexOf('@');
    final length = int.tryParse(
      (at >= 0 ? text.substring(0, at) : text).trim(),
    );
    if (length == null || length <= 0) return null;
    final key = uri.toString();
    final start = at >= 0
        ? int.tryParse(text.substring(at + 1).trim()) ?? 0
        : ends[key] ?? 0;
    ends[key] = start + length;
    return HlsByteRange(start, length);
  }

  static List<int>? _parseIv(String? text) {
    if (text == null) return null;
    var value = text.trim();
    if (value.startsWith('0x') || value.startsWith('0X')) {
      value = value.substring(2);
    }
    if (value.isEmpty || value.length > 32) return null;
    value = value.padLeft(32, '0');
    final bytes = <int>[];
    for (var i = 0; i < 32; i += 2) {
      final byte = int.tryParse(value.substring(i, i + 2), radix: 16);
      if (byte == null) return null;
      bytes.add(byte);
    }
    return bytes;
  }

  static String? _nullIfEmpty(String? value) {
    final text = value?.trim() ?? '';
    return text.isEmpty ? null : text;
  }
}

/// AES-128 IV when `#EXT-X-KEY` omits one: the media sequence number as a
/// 128-bit big-endian integer.
List<int> hlsSequenceIv(int sequence) {
  final iv = List<int>.filled(16, 0);
  for (var i = 0; i < 8; i++) {
    iv[15 - i] = (sequence >> (8 * i)) & 0xff;
  }
  return iv;
}
