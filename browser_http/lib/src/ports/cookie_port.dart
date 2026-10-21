import '../domain/models/browser_cookie.dart';

/// Cookie storage shared by the native transport and WKWebView.
abstract interface class CookiePort {
  Future<List<BrowserCookie>> get(Uri uri);

  /// Replaces all cookies that match [uri] with [cookies].
  Future<void> setAll(Uri uri, List<BrowserCookie> cookies);

  /// Merges cookies, keeping the newest value per (name, domain, path).
  Future<void> merge(Uri uri, List<BrowserCookie> cookies);

  Future<void> removeAll(Uri uri);

  /// Destroys every stored cookie. Called on logout.
  Future<void> clear();
}
