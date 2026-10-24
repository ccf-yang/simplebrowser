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
  });

  /// Native WebView session id (`WebViewSession.id`), so a host with several
  /// windows knows which page is playing.
  final String sessionId;

  /// One of `enter` (a tapped video now owns the screen), `tap` (the user
  /// touched the picture, so the host should show or hide its controls),
  /// `seeking` (a horizontal drag is previewing a target), `state` (position or
  /// pause changed) or `exit` (the window was closed).
  final String kind;

  final bool paused;

  /// Playhead, in seconds.
  final double position;

  /// Length, in seconds; 0 while the page has not loaded metadata yet.
  final double duration;

  bool get isEnter => kind == 'enter';
  bool get isExit => kind == 'exit';
  bool get isState => kind == 'state';

  /// A tap on the picture — the host's show/hide switch for its control layer.
  bool get isTap => kind == 'tap';

  /// Where a horizontal drag would land if the finger lifted now.
  bool get isSeeking => kind == 'seeking';

  factory WebViewVideoEvent.fromJson(Map<String, Object?> json) =>
      WebViewVideoEvent(
        sessionId: (json['sessionId'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? 'state',
        paused: json['paused'] as bool? ?? true,
        position: (json['position'] as num?)?.toDouble() ?? 0,
        duration: (json['duration'] as num?)?.toDouble() ?? 0,
      );

  @override
  String toString() =>
      '$kind ${position.toStringAsFixed(1)}/'
      '${duration.toStringAsFixed(1)}${paused ? ' paused' : ''}';
}
