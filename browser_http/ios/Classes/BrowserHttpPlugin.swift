import Flutter
import UIKit

/// Registers the three platform channels:
/// - `browser_http/cookies`  -> WKHTTPCookieStore
/// - `browser_http/vault`    -> Keychain
/// - `browser_http/webview`  -> WKWebView challenge surface
public final class BrowserHttpPlugin: NSObject, FlutterPlugin {
  private static var instance: BrowserHttpPlugin?

  private let cookieBridge = CookieBridge()
  private let vaultBridge = KeychainVault()
  private let webViewBridge = WebViewBridge()

  init(messenger: FlutterBinaryMessenger, registrar: FlutterPluginRegistrar) {
    super.init()

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

    let web = FlutterMethodChannel(
      name: "browser_http/webview", binaryMessenger: messenger)
    web.setMethodCallHandler { [weak self] call, result in
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
