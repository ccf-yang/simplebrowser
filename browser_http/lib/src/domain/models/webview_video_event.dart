/// What the page's video is doing, as the injected video script sees it.
///
/// The player window is host UI: the page owns the picture and the sound, the
/// host owns the bar that sits over it. This is the one channel between them —
/// the script reports when a video was tapped (`enter`), when the window was
/// closed (`exit`), and where the playhead is (`state`).
final class WebViewVideoEvent {
  const WebViewVideoEvent({
    required this.sessionId,
    required this.kind,
    this.paused = true,
    this.position = 0,
    this.duration = 0,
    this.width = 0,
    this.height = 0,
    this.url = '',
    this.rate = 1,
  });

  /// Native WebView session id (`WebViewSession.id`), so a host with several
  /// windows knows which page is playing.
  final String sessionId;

  /// One of `enter` (a tapped video now owns the screen), `tap` (the user
  /// touched the picture, so the host should show or hide its controls),
  /// `seeking` (a horizontal drag is previewing a target), `speed` (a long
  /// press started or ended 2× playback), `state` (position or pause changed)
  /// or `exit` (the window was closed).
  final String kind;

  final bool paused;

  /// Playhead, in seconds.
  final double position;

  /// Length, in seconds; 0 while the page has not loaded metadata yet.
  final double duration;

  /// Picture size in pixels, as the page reports it; 0 until metadata loads.
  /// A host that takes a frame out of the picture needs the aspect ratio.
  final double width;
  final double height;

  /// The media the page is playing. Normally `currentSrc`; for a blob-backed
  /// MSE player, the newest playlist that frame fetched, which is the address
  /// a downloader can actually use. Empty until the script knows one.
  final String url;

  /// Playback rate while a long press holds the picture at 2×.
  final double rate;

  bool get isEnter => kind == 'enter';
  bool get isExit => kind == 'exit';
  bool get isState => kind == 'state';

  /// A tap on the picture — the host's show/hide switch for its control layer.
  bool get isTap => kind == 'tap';

  /// Where a horizontal drag would land if the finger lifted now.
  bool get isSeeking => kind == 'seeking';

  /// A long press holding the picture at 2×, or its release.
  bool get isSpeed => kind == 'speed';

  factory WebViewVideoEvent.fromJson(Map<String, Object?> json) =>
      WebViewVideoEvent(
        sessionId: (json['sessionId'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? 'state',
        paused: json['paused'] as bool? ?? true,
        position: (json['position'] as num?)?.toDouble() ?? 0,
        duration: (json['duration'] as num?)?.toDouble() ?? 0,
        width: (json['width'] as num?)?.toDouble() ?? 0,
        height: (json['height'] as num?)?.toDouble() ?? 0,
        url: (json['url'] as String?) ?? '',
        rate: (json['rate'] as num?)?.toDouble() ?? 1,
      );

  @override
  String toString() =>
      '$kind ${position.toStringAsFixed(1)}/'
      '${duration.toStringAsFixed(1)}${paused ? ' paused' : ''}';
}
