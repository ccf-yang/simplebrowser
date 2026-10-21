import Foundation
import Flutter
import WebKit

/// Bridges `WebViewPort` to real WKWebView instances.
///
/// All WKWebView access happens on the main thread. Headless sessions are
/// created but not attached to the window; visible sessions are hosted by a
/// `UiKitView` through `BrowserChallengePlatformViewFactory`.
final class WebViewBridge {
    private var sessions: [String: WebViewHolder] = [:]

    /// Looks up an existing session so `UiKitView` can host the *same*
    /// WKWebView that will later export clearance cookies.
    func webView(for id: String) -> WKWebView? {
        sessions[id]?.webView
    }

    /// Loads a URL into a session that is already displayed by a platform view.
    func loadForDisplay(id: String, url: URL) {
        sessions[id]?.webView.load(URLRequest(url: url))
    }

    /// Resolves `args["id"]` or reports a Flutter error and returns `nil`.
    private func session(_ args: [String: Any],
                         _ result: @escaping FlutterResult) -> WebViewHolder? {
        guard let id = args["id"] as? String, let holder = sessions[id] else {
            result(FlutterError(code: "webview.session",
                                message: "unknown session",
                                details: nil))
            return nil
        }
        return holder
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "create":
            let userAgent = args["userAgent"] as? String
            let headless = args["headless"] as? Bool ?? true
            let holder = WebViewHolder(headless: headless)
            if let userAgent { holder.webView.customUserAgent = userAgent }
            let id = UUID().uuidString
            sessions[id] = holder
            result(id)

        case "load":
            guard let id = args["id"] as? String,
                  let holder = sessions[id],
                  let raw = args["url"] as? String,
                  let url = URL(string: raw) else {
                result(FlutterError(code: "webview.load", message: "bad arguments", details: nil))
                return
            }
            holder.load(url) { error in
                if let error {
                    result(FlutterError(code: "webview.load",
                                        message: error.localizedDescription,
                                        details: nil))
                } else {
                    result([
                        "url": holder.webView.url?.absoluteString ?? raw,
                        "status": holder.lastStatusCode ?? 0,
                        "title": holder.webView.title ?? "",
                    ])
                }
            }

        case "navigate":
            guard let id = args["id"] as? String,
                  let holder = sessions[id],
                  let raw = args["url"] as? String,
                  let url = URL(string: raw) else {
                result(FlutterError(code: "webview.navigate", message: "bad arguments", details: nil))
                return
            }
            holder.webView.load(URLRequest(url: url))
            result(nil)

        case "goBack":
            guard let holder = session(args, result) else { return }
            if holder.webView.canGoBack { holder.webView.goBack() }
            result(nil)

        case "goForward":
            guard let holder = session(args, result) else { return }
            if holder.webView.canGoForward { holder.webView.goForward() }
            result(nil)

        case "reload":
            guard let holder = session(args, result) else { return }
            holder.webView.reload()
            result(nil)

        case "canGoBack":
            guard let holder = session(args, result) else { return }
            result(holder.webView.canGoBack)

        case "canGoForward":
            guard let holder = session(args, result) else { return }
            result(holder.webView.canGoForward)

        case "currentUrl":
            guard let holder = session(args, result) else { return }
            if let url = holder.webView.url?.absoluteString {
                result(url)
            } else {
                result(nil)
            }

        case "currentTitle":
            guard let holder = session(args, result) else { return }
            if let title = holder.webView.title {
                result(title)
            } else {
                result(nil)
            }

        case "lastStatus":
            guard let holder = session(args, result) else { return }
            if let status = holder.lastStatusCode {
                result(status)
            } else {
                result(nil)
            }

        case "resourceTimings":
            guard let holder = session(args, result) else { return }
            holder.resourceTimings { entries in result(entries) }

        case "evaluate":
            guard let id = args["id"] as? String,
                  let holder = sessions[id],
                  let script = args["script"] as? String else {
                result(FlutterError(code: "webview.script", message: "bad arguments", details: nil))
                return
            }
            holder.webView.evaluateJavaScript(script) { value, error in
                if let error {
                    result(FlutterError(code: "webview.script",
                                        message: error.localizedDescription,
                                        details: nil))
                } else {
                    result(value)
                }
            }

        case "exportCookies":
            guard let id = args["id"] as? String,
                  let holder = sessions[id] else {
                result(FlutterError(code: "webview.load", message: "unknown session", details: nil))
                return
            }
            holder.exportCookies { cookies in result(cookies) }

        case "exportLocalStorage":
            guard let id = args["id"] as? String,
                  let holder = sessions[id],
                  let origin = args["origin"] as? String else {
                result(FlutterError(code: "webview.script", message: "bad arguments", details: nil))
                return
            }
            holder.exportLocalStorage(origin: origin) { value in result(value) }

        case "importLocalStorage":
            guard let id = args["id"] as? String,
                  let holder = sessions[id],
                  let origin = args["origin"] as? String,
                  let url = URL(string: origin),
                  let values = args["values"] as? [String: String] else {
                result(FlutterError(code: "webview.script", message: "bad arguments", details: nil))
                return
            }
            holder.load(url) { error in
                if let error {
                    result(FlutterError(code: "webview.load",
                                        message: error.localizedDescription,
                                        details: nil))
                    return
                }
                holder.importLocalStorage(values) { result(nil) }
            }

        case "currentUserAgent":
            guard let id = args["id"] as? String,
                  let holder = sessions[id] else {
                result(FlutterError(code: "webview.load", message: "unknown session", details: nil))
                return
            }
            holder.webView.evaluateJavaScript("navigator.userAgent") { value, _ in
                result(value as? String ?? "")
            }

        case "dispose":
            if let id = args["id"] as? String {
                sessions.removeValue(forKey: id)
            }
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

/// Hosts an existing `WebViewHolder` in the Flutter widget tree.
///
/// Nothing is clicked or scripted here: the user interacts with a real
/// WKWebView rendered by the system.
final class BrowserChallengePlatformViewFactory: NSObject, FlutterPlatformViewFactory {
    private let bridge: WebViewBridge

    init(bridge: WebViewBridge) {
        self.bridge = bridge
        super.init()
    }

    func create(withFrame frame: CGRect,
                viewIdentifier viewId: Int64,
                arguments args: Any?) -> FlutterPlatformView {
        BrowserChallengePlatformView(frame: frame, bridge: bridge, args: args as? [String: Any])
    }

    func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
        FlutterStandardMessageCodec.sharedInstance()
    }
}

final class BrowserChallengePlatformView: NSObject, FlutterPlatformView {
    private let container = UIView()

    init(frame: CGRect, bridge: WebViewBridge, args: [String: Any]?) {
        super.init()
        container.frame = frame
        container.backgroundColor = .white
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        guard let id = args?["id"] as? String,
              let webView = bridge.webView(for: id) else { return }

        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)

        if let raw = args?["url"] as? String, let url = URL(string: raw) {
            bridge.loadForDisplay(id: id, url: url)
        }
    }

    func view() -> UIView { container }
}

/// Owns one WKWebView and its navigation completion.
final class WebViewHolder: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let headless: Bool
    private var loadCompletion: ((Error?) -> Void)?
    fileprivate var lastStatusCode: Int?

    init(headless: Bool) {
        self.headless = headless
        let config = WKWebViewConfiguration()
        // Persistent store is mandatory: ephemeral stores break clearance reuse.
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        // Visible WebViews are user-driven (challenge page or browser tab);
        // swipe back/forward should behave like Safari.
        webView.allowsBackForwardNavigationGestures = !headless
    }

    func load(_ url: URL, completion: @escaping (Error?) -> Void) {
        lastStatusCode = nil
        loadCompletion = completion
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView,
                 didStartProvisionalNavigation navigation: WKNavigation!) {
        // Do not report the previous page's status while the new one loads.
        lastStatusCode = nil
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse {
            lastStatusCode = response.statusCode
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadCompletion?(nil)
        loadCompletion = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadCompletion?(error)
        loadCompletion = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadCompletion?(error)
        loadCompletion = nil
    }

    /// Subresource metadata from the page's Performance API.
    ///
    /// WebKit does not expose request/response headers for subresources; this
    /// is the fullest set of facts available to a host app without jailbreak
    /// or private APIs.
    func resourceTimings(completion: @escaping ([[String: Any]]) -> Void) {
        let script = """
        (function() {
          var out = [];
          try {
            var entries = performance.getEntriesByType('resource') || [];
            for (var i = 0; i < entries.length; i++) {
              var e = entries[i];
              out.push({
                url: e.name,
                initiatorType: e.initiatorType || '',
                duration: e.duration || 0,
                transferSize: e.transferSize || 0,
                encodedBodySize: e.encodedBodySize || 0,
              });
            }
          } catch (e) {}
          return JSON.stringify(out);
        })();
        """
        webView.evaluateJavaScript(script) { value, _ in
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                completion([])
                return
            }
            completion(entries)
        }
    }

    func exportCookies(completion: @escaping ([[String: Any]]) -> Void) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            completion(cookies.map { cookie in
                var dict: [String: Any] = [
                    "name": cookie.name,
                    "value": cookie.value,
                    "domain": cookie.domain,
                    "path": cookie.path,
                    "secure": cookie.isSecure,
                    "httpOnly": cookie.isHTTPOnly,
                ]
                if let expires = cookie.expiresDate {
                    dict["expires"] = ISO8601DateFormatter().string(from: expires)
                }
                return dict
            })
        }
    }

    func importLocalStorage(_ values: [String: String],
                            completion: @escaping () -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let json = String(data: data, encoding: .utf8) else {
            completion()
            return
        }
        let script = """
        (function() {
          try {
            var values = \(json);
            for (var k in values) {
              if (Object.prototype.hasOwnProperty.call(values, k)) {
                localStorage.setItem(k, values[k]);
              }
            }
          } catch (e) {}
        })();
        """
        webView.evaluateJavaScript(script) { _, _ in completion() }
    }

    func exportLocalStorage(origin: String, completion: @escaping ([String: String]) -> Void) {
        let script = """
        (function() {
          var out = {};
          try {
            for (var i = 0; i < localStorage.length; i++) {
              var k = localStorage.key(i);
              out[k] = localStorage.getItem(k);
            }
          } catch (e) {}
          return JSON.stringify(out);
        })();
        """
        webView.evaluateJavaScript(script) { value, _ in
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                completion([:])
                return
            }
            completion(dict)
        }
    }
}
