import '../adapters/ios_adapters.dart';
import '../api/browser_profile.dart';
import '../api/browser_session.dart';
import '../domain/logging/log_redactor.dart';
import '../ports/log_sink.dart';

/// Package entry point.
///
/// This is the composition root: the only place that knows which adapters
/// exist. Public API classes stay adapter-agnostic.
final class BrowserHttp {
  const BrowserHttp._();

  /// Creates a session backed by the iOS native adapters.
  ///
  /// Defaults to [BrowserProfile.safariIos18] because that is the only family
  /// whose network stack matches WKWebView on iOS.
  static BrowserSession session({
    BrowserProfile profile = BrowserProfile.safariIos18,
    LogSink? logSink,
    LogRedactor? redactor,
  }) {
    final adapters = IosAdapters();
    return BrowserSession(
      profile: profile,
      transport: adapters.transport,
      cookies: adapters.cookies,
      vault: adapters.vault,
      webView: adapters.webView,
      logSink: logSink,
      redactor: redactor,
    );
  }
}
