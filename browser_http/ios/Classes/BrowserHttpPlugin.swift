import Flutter
import UIKit

/// Registers the platform channels:
/// - `browser_http/cookies`  -> WKHTTPCookieStore
/// - `browser_http/vault`    -> Keychain
/// - `browser_http/webview`  -> WKWebView challenge surface
/// - `browser_http/media`    -> save downloaded images/videos to Photos
public final class BrowserHttpPlugin: NSObject, FlutterPlugin {
  private static var instance: BrowserHttpPlugin?

  private let cookieBridge = CookieBridge()
  private let vaultBridge = KeychainVault()
  private let webViewBridge = WebViewBridge()
  private let mediaBridge = MediaBridge()
  private let webChannel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger, registrar: FlutterPluginRegistrar) {
    webChannel = FlutterMethodChannel(
      name: "browser_http/webview", binaryMessenger: messenger)
    super.init()

    // Page-script network events (fetch/XHR/beacon) are pushed upstream on the
    // same channel the Dart side already listens to.
    webViewBridge.onNetworkEvent = { [weak self] event in
      self?.webChannel.invokeMethod("pageNetworkEvent", arguments: event)
    }

    // Navigation decisions (page jumps, blocked external schemes) travel the
    // same way, so the app can list every jump in its log.
    webViewBridge.onNavigationEvent = { [weak self] event in
      self?.webChannel.invokeMethod("navigationEvent", arguments: event)
    }

    let cookies = FlutterMethodChannel(
      name: "browser_http/cookies", binaryMessenger: messenger)
    cookies.setMethodCallHandler { [weak self] call, result in
      self?.cookieBridge.handle(call, result: result)
    }

    let vault = FlutterMethodChannel(
      name: "browser_http/vault", binaryMessenger: messenger)
    vault.setMethodCallHandler { [weak self] call, result in
      self?.vaultBridge.handle(call, result: result)
    }

    // Downloaded images/videos are saved through Photos, never through a
    // second in-memory copy of the body.
    let media = FlutterMethodChannel(
      name: "browser_http/media", binaryMessenger: messenger)
    media.setMethodCallHandler { [weak self] call, result in
      self?.mediaBridge.handle(call, result: result)
    }

    webChannel.setMethodCallHandler { [weak self] call, result in
      self?.webViewBridge.handle(call, result: result)
    }

    let factory = BrowserChallengePlatformViewFactory(bridge: webViewBridge)
    registrar.register(factory, withId: "browser_http/challenge_view")
    // Same surface, separate id: a browser tab is just a visible WKWebView
    // driven by navigation commands instead of a challenge completion.
    registrar.register(factory, withId: "browser_http/browser_view")
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = BrowserHttpPlugin(
      messenger: registrar.messenger(), registrar: registrar)
    instance = plugin
  }
}
