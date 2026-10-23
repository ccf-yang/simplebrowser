/// A link the user pressed and held inside a WebView.
///
/// WebKit has no way to ask the host for a second browsing window: its own
/// long-press menu offers a preview and a copy, nothing more. The injected page
/// script therefore reports the held anchor, and the host decides what to offer
/// for it — in this browser, opening it in another window.
final class WebViewLinkPress {
  const WebViewLinkPress({
    required this.sessionId,
    required this.url,
    this.text = '',
  });

  /// Native WebView session id (`WebViewSession.id`), so a host with several
  /// windows knows which page the link was held in.
  final String sessionId;

  /// The anchor's resolved `href`, absolute and already normalised by the page.
  final String url;

  /// The link's visible text, collapsed to one line and capped by the script.
  final String text;

  /// Parsed [url], or `null` when the page reported something unparseable.
  Uri? get uri => Uri.tryParse(url);

  factory WebViewLinkPress.fromJson(Map<String, Object?> json) =>
      WebViewLinkPress(
        sessionId: (json['sessionId'] as String?) ?? '',
        url: (json['url'] as String?) ?? '',
        text: (json['text'] as String?) ?? '',
      );
}
