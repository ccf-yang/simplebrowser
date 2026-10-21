/// Browser family a profile belongs to.
///
/// On iOS, only the `safari` family can be paired with WKWebView, because the
/// WebView's network stack is Apple's. Mixing families inside one session is
/// rejected by [ConsistencyGuard].
enum BrowserFamily { safari, chrome, firefox }

/// A named fingerprint profile.
///
/// This type only carries an identifier and a family. The user agent, header
/// order, TLS parameters and HTTP/2 settings all live in the native core
/// (`rust/src/api/profile.rs`); keeping them out of Dart is what guarantees
/// the two engines cannot drift apart.
final class BrowserProfile {
  const BrowserProfile._({required this.id, required this.family});

  /// Identifier understood by the native core. Must be kept in sync with
  /// `rust/src/api/profile.rs`.
  final String id;

  final BrowserFamily family;

  /// Default profile: the only family that is consistent with WKWebView.
  static const BrowserProfile safariIos26 =
      BrowserProfile._(id: 'safari_ios_26', family: BrowserFamily.safari);

  /// Safari 18, for devices that have not updated to iOS 26.
  static const BrowserProfile safariIos18 =
      BrowserProfile._(id: 'safari_ios_18_1_1', family: BrowserFamily.safari);

  /// Safari 17, for older iOS targets.
  static const BrowserProfile safariIos17 =
      BrowserProfile._(id: 'safari_ios_17_4_1', family: BrowserFamily.safari);

  /// Chrome on Windows. Use for API-only traffic; never for a session that
  /// must reuse a WKWebView clearance.
  static const BrowserProfile chromeWindows149 =
      BrowserProfile._(id: 'chrome_windows_149', family: BrowserFamily.chrome);

  static const BrowserProfile chromeWindows144 =
      BrowserProfile._(id: 'chrome_windows_144', family: BrowserFamily.chrome);

  /// Chrome on Android.
  static const BrowserProfile chromeAndroid149 =
      BrowserProfile._(id: 'chrome_android_149', family: BrowserFamily.chrome);

  static const BrowserProfile chromeAndroid144 =
      BrowserProfile._(id: 'chrome_android_144', family: BrowserFamily.chrome);

  static const List<BrowserProfile> values = <BrowserProfile>[
    safariIos26,
    safariIos18,
    safariIos17,
    chromeWindows149,
    chromeWindows144,
    chromeAndroid149,
    chromeAndroid144,
  ];

  static BrowserProfile byId(String id) {
    for (final profile in values) {
      if (profile.id == id) return profile;
    }
    throw ArgumentError.value(id, 'id', 'Unknown browser profile');
  }

  /// Creates a reference to a profile by native id.
  ///
  /// Adding a profile in Rust does not require a Dart change as long as the id
  /// follows the `<family>_<platform>_<version>` convention. The native core
  /// remains the authority: an unknown id fails at the first call.
  factory BrowserProfile.fromId(String id) {
    final family = id.startsWith('safari')
        ? BrowserFamily.safari
        : id.startsWith('chrome')
            ? BrowserFamily.chrome
            : id.startsWith('firefox')
                ? BrowserFamily.firefox
                : null;
    if (family == null) {
      throw ArgumentError.value(id, 'id', 'Unknown profile family');
    }
    return BrowserProfile._(id: id, family: family);
  }

  @override
  String toString() => 'BrowserProfile($id)';
}
