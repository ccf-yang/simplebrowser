import 'dart:convert';

import '../domain/errors.dart';
import '../domain/models/browser_cookie.dart';
import '../domain/models/transport.dart';
import '../ports/webview_port.dart';
import 'browser_session.dart';

/// How a challenge may be resolved.
enum ChallengeMode {
  /// Headless WKWebView only. Never prompts the user.
  headless,

  /// Requires a visible [BrowserChallengeView]; the user completes it.
  visible,

  /// Try headless first, then ask the app to show a visible view.
  auto,
}

/// Result of one resolution attempt.
enum ChallengeOutcome { resolved, needsUserInteraction, failed }

/// Outcome of [ChallengeController.ensureClearance].
final class ChallengeResult {
  const ChallengeResult({
    required this.outcome,
    required this.uri,
    this.cookies = const <BrowserCookie>[],
    this.reason,
  });

  final ChallengeOutcome outcome;
  final Uri uri;

  /// Cookies exported from the WebView (includes the clearance cookie).
  final List<BrowserCookie> cookies;

  /// Diagnostic message; never contains secrets.
  final String? reason;

  bool get resolved => outcome == ChallengeOutcome.resolved;

  /// True when the app should show a [BrowserChallengeView].
  bool get needsUserInteraction =>
      outcome == ChallengeOutcome.needsUserInteraction;
}

/// Detects and resolves browser challenges (Cloudflare Managed Challenge,
/// Turnstile, and similar).
///
/// This controller never synthesizes clicks. Interactive challenges must be
/// completed by a human in a visible WebView; the value it adds is keeping the
/// resulting identity usable by subsequent native requests.
final class ChallengeController {
  ChallengeController({required BrowserSession session}) : _session = session;

  final BrowserSession _session;

  static const Set<String> _clearanceCookies = <String>{
    'cf_clearance',
    '_abck',
    'datadome',
    'incap_ses',
  };

  /// Heuristic used by [BrowserSession] callers to decide whether a response
  /// is a challenge instead of the real resource.
  bool isChallenge(TransportResponse response) {
    final mitigated = response.header('cf-mitigated');
    if (mitigated != null && mitigated.toLowerCase() == 'challenge') return true;

    final server = response.header('server')?.toLowerCase() ?? '';
    final contentType = response.header('content-type')?.toLowerCase() ?? '';
    if (!contentType.contains('text/html')) return false;

    final body = utf8.decode(response.body, allowMalformed: true);
    if (body.contains('_cf_chl_opt') ||
        body.contains('/cdn-cgi/challenge-platform/') ||
        body.toLowerCase().contains('just a moment')) {
      return true;
    }
    if (response.statusCode == 403 && server.contains('cloudflare')) return true;
    return false;
  }

  /// Attempts to obtain a clearance for [uri].
  ///
  /// In [ChallengeMode.auto], a headless attempt is made first; if it fails,
  /// the caller receives [ChallengeOutcome.needsUserInteraction] and is
  /// expected to present a [BrowserChallengeView].
  Future<ChallengeResult> ensureClearance(
    Uri uri, {
    ChallengeMode mode = ChallengeMode.auto,
    Duration headlessTimeout = const Duration(seconds: 8),
  }) async {
    if (mode == ChallengeMode.headless || mode == ChallengeMode.auto) {
      final result = await _tryHeadless(uri, headlessTimeout);
      if (result.resolved || mode == ChallengeMode.headless) return result;
    }
    return ChallengeResult(
      outcome: ChallengeOutcome.needsUserInteraction,
      uri: uri,
      reason: mode == ChallengeMode.visible
          ? 'Visible challenge requested.'
          : 'Headless attempt did not obtain a clearance.',
    );
  }

  /// Called by [BrowserChallengeView] once the user says the challenge is
  /// complete. Exports the identity and adopts it into the session.
  Future<ChallengeResult> resolveFromVisibleSession(
    WebViewSession webViewSession,
    Uri uri,
  ) async {
    final cookies = await webViewSession.exportCookies(uri);
    final userAgent = await webViewSession.currentUserAgent();

    final info = await _session.profileInfo();
    if (userAgent != info.userAgent) {
      return ChallengeResult(
        outcome: ChallengeOutcome.failed,
        uri: uri,
        cookies: cookies,
        reason: 'WebView UA differs from the session profile UA.',
      );
    }
    if (!_hasClearance(cookies)) {
      return ChallengeResult(
        outcome: ChallengeOutcome.needsUserInteraction,
        uri: uri,
        cookies: cookies,
        reason: 'No clearance cookie yet; the challenge may still be open.',
      );
    }

    // localStorage stays in the persistent WKWebsiteDataStore, which the next
    // headless WebView and `BrowserSession.snapshot` both read.
    await _session.cookies.merge(uri, cookies);
    return ChallengeResult(
      outcome: ChallengeOutcome.resolved,
      uri: uri,
      cookies: cookies,
    );
  }

  Future<ChallengeResult> _tryHeadless(Uri uri, Duration timeout) async {
    final info = await _session.profileInfo();
    final webView = await _session.webView.create(
      userAgent: info.userAgent,
      headless: true,
    );
    try {
      await webView.load(uri, timeout: timeout);
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        final cookies = await webView.exportCookies(uri);
        if (_hasClearance(cookies) && !await _pageStillChallenged(webView)) {
          await _session.cookies.merge(uri, cookies);
          return ChallengeResult(
            outcome: ChallengeOutcome.resolved,
            uri: uri,
            cookies: cookies,
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      return ChallengeResult(
        outcome: ChallengeOutcome.failed,
        uri: uri,
        reason: 'Timed out after ${timeout.inSeconds}s in headless mode.',
      );
    } on WebViewException catch (error) {
      return ChallengeResult(
        outcome: ChallengeOutcome.failed,
        uri: uri,
        reason: error.message,
      );
    } finally {
      await webView.dispose();
    }
  }

  bool _hasClearance(List<BrowserCookie> cookies) {
    for (final cookie in cookies) {
      if (_clearanceCookies.contains(cookie.name)) return true;
    }
    return false;
  }

  Future<bool> _pageStillChallenged(WebViewSession webView) async {
    try {
      final result = await webView.evaluate(
        'document.documentElement.innerHTML.includes("_cf_chl_opt") '
        '|| location.pathname.includes("cdn-cgi/challenge-platform")',
      );
      return result == true;
    } on WebViewException {
      return false;
    }
  }
}
