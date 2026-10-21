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

    /// Forwards page-script network events to the Dart side. Set by the
    /// plugin; events carry the owning session id.
    var onNetworkEvent: (([String: Any]) -> Void)?

    /// Forwards navigation decisions (page jumps, blocked external schemes) to
    /// the Dart side; events carry the owning session id.
    var onNavigationEvent: (([String: Any]) -> Void)?

    /// Looks up an existing session so `UiKitView` can host the *same*
    /// WKWebView that will later export clearance cookies.
    func webView(for id: String) -> WKWebView? {
        sessions[id]?.webView
    }

    /// Loads a URL into a session that is already displayed by a platform view.
    func loadForDisplay(id: String, url: URL) {
        sessions[id]?.loadInApp(URLRequest(url: url))
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

    /// Builds a request carrying the caller-supplied headers (UA overrides go
    /// through `customUserAgent`, so they are not part of this map).
    private func request(for url: URL, headers: Any?) -> URLRequest {
        var request = URLRequest(url: url)
        if let fields = headers as? [String: Any] {
            for (name, value) in fields {
                if let text = value as? String, !text.isEmpty {
                    request.setValue(text, forHTTPHeaderField: name)
                }
            }
        }
        return request
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "create":
            let userAgent = args["userAgent"] as? String
            let headless = args["headless"] as? Bool ?? true
            let id = UUID().uuidString
            let holder = WebViewHolder(id: id, headless: headless)
            holder.onNetworkEvent = { [weak self] event in
                self?.onNetworkEvent?(event)
            }
            holder.onNavigationEvent = { [weak self] event in
                self?.onNavigationEvent?(event)
            }
            if let userAgent { holder.webView.customUserAgent = userAgent }
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
            holder.load(request(for: url, headers: args["headers"])) { error in
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
            holder.loadInApp(request(for: url, headers: args["headers"]))
            result(nil)

        case "setUserAgent":
            guard let holder = session(args, result) else { return }
            holder.webView.customUserAgent = args["userAgent"] as? String
            result(nil)

        case "setNavigationPolicy":
            guard let holder = session(args, result) else { return }
            holder.blockExternalNavigations = args["blockExternal"] as? Bool
                ?? holder.blockExternalNavigations
            holder.reissueUserTaps = args["reissueTaps"] as? Bool
                ?? holder.reissueUserTaps
            result(nil)

        case "setDebugOverlay":
            guard let id = args["id"] as? String,
                  let holder = sessions[id] else {
                result(FlutterError(code: "webview.debug",
                                    message: "unknown session",
                                    details: nil))
                return
            }
            holder.setDebugOverlay(
                enabled: args["enabled"] as? Bool ?? false,
                source: args["source"] as? String ?? "",
                displaySize: (args["displaySize"] as? NSNumber)?.doubleValue ?? 50
            ) { ok in result(ok) }

        case "setDebugDisplaySize":
            guard let holder = session(args, result) else { return }
            if let size = (args["displaySize"] as? NSNumber)?.doubleValue {
                holder.setDebugDisplaySize(size)
            }
            result(nil)

        case "setCookie":
            guard let id = args["id"] as? String,
                  let holder = sessions[id],
                  let raw = args["url"] as? String,
                  let host = URL(string: raw)?.host,
                  let header = args["cookie"] as? String else {
                result(FlutterError(code: "webview.cookie", message: "bad arguments", details: nil))
                return
            }
            let store = holder.webView.configuration.websiteDataStore.httpCookieStore
            let group = DispatchGroup()
            for pair in header.split(separator: ";") {
                let item = String(pair)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separator = item.firstIndex(of: "=") else { continue }
                let name = String(item[..<separator])
                    .trimmingCharacters(in: .whitespaces)
                let value = String(item[item.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces)
                if name.isEmpty { continue }
                let properties: [HTTPCookiePropertyKey: Any] = [
                    .domain: host,
                    .path: "/",
                    .name: name,
                    .value: value,
                ]
                if let cookie = HTTPCookie(properties: properties) {
                    group.enter()
                    store.setCookie(cookie) { group.leave() }
                }
            }
            group.notify(queue: .main) { result(nil) }

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

    func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol) {
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

/// Breaks the WKUserContentController -> handler -> holder retain cycle so a
/// disposed session can actually be deallocated.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

/// Owns one WKWebView and its navigation completion.
final class WebViewHolder: NSObject, WKNavigationDelegate, WKUIDelegate,
                          WKScriptMessageHandler {
    let id: String
    let webView: WKWebView
    let headless: Bool
    var onNetworkEvent: (([String: Any]) -> Void)?
    /// Page jumps reported to the host: allowed, re-issued, blocked, committed,
    /// failed.
    var onNavigationEvent: (([String: Any]) -> Void)?
    private var loadCompletion: ((Error?) -> Void)?
    fileprivate var lastStatusCode: Int?

    private static let networkHandlerName = "browserHttpNet"

    /// Cancels any navigation whose scheme is not http(s)/in-app, so a link can
    /// never hand the URL over to another app (`baidu://`, `weixin://`,
    /// `itms-apps://`, `tel:` …).
    var blockExternalNavigations = true

    /// iOS opens the matching app when a *user tap* moves the main frame to a
    /// URL registered as a Universal Link. Re-issuing the identical request
    /// from code keeps the page inside this browser.
    var reissueUserTaps = true

    /// Requests this holder re-issued itself; their policy call must be allowed
    /// untouched or the re-issue would cancel itself forever.
    private var programmaticURLs: Set<String> = []

    /// Method and trigger of the last main-frame action, reused by the response
    /// and commit callbacks so a log row reads like the request it belongs to.
    private var lastMethod = "GET"
    private var lastNavigationType = "other"

    /// Scripts every document gets: the fetch/XHR hooks plus, while the debug
    /// console is open, the eruda bundle.
    private var userScripts: [InjectedScript] = []
    private(set) var debugOverlayEnabled = false
    private var debugSource = ""
    private var debugDisplaySize = 50.0

    /// One `WKUserScript` tagged as debug overlay or not, so the overlay can be
    /// swapped without rebuilding the request-hook script.
    private struct InjectedScript {
        let script: WKUserScript
        let isDebugOverlay: Bool
    }

    /// Schemes WebKit may load inside this browser. Anything else is an exit.
    private static let inAppSchemes: Set<String> = [
        "http", "https", "about", "data", "blob", "file", "void", "javascript",
    ]

    init(id: String, headless: Bool) {
        self.id = id
        self.headless = headless
        let config = WKWebViewConfiguration()
        // Persistent store is mandatory: ephemeral stores break clearance reuse.
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self

        // Inject the fetch/XHR hooks before the first document script runs.
        // The handler is weak so the holder can be released when the session
        // is disposed.
        userScripts.append(InjectedScript(
            script: WKUserScript(
                source: WebViewHolder.networkScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false),
            isDebugOverlay: false))
        applyUserScripts()
        webView.configuration.userContentController.add(
            WeakScriptMessageHandler(delegate: self),
            name: WebViewHolder.networkHandlerName)

        // Visible WebViews are user-driven (challenge page or browser tab);
        // swipe back/forward should behave like Safari.
        webView.allowsBackForwardNavigationGestures = !headless
    }

    /// Replaces the controller's script list with `userScripts`.
    ///
    /// `WKUserContentController` only offers `removeAllUserScripts()`, so the
    /// whole list is rebuilt whenever the debug overlay is switched on or off.
    /// Applies to the next document; the current one is handled by the explicit
    /// `evaluateJavaScript` calls in `setDebugOverlay`.
    private func applyUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        for entry in userScripts {
            controller.addUserScript(entry.script)
        }
    }

    private func rebuildDebugScript() {
        userScripts.removeAll { $0.isDebugOverlay }
        guard debugOverlayEnabled, !debugSource.isEmpty else { return }
        userScripts.append(InjectedScript(
            script: WKUserScript(
                source: WebViewHolder.debugBundle(
                    source: debugSource, displaySize: debugDisplaySize),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true),
            isDebugOverlay: true))
    }

    /// Turns the persistent debug console on or off for *all later documents*.
    ///
    /// A `WKUserScript` survives navigations, which is what keeps eruda visible
    /// no matter how deep the user clicks into a site. The currently loaded
    /// document is patched immediately as well.
    func setDebugOverlay(enabled: Bool, source: String, displaySize: Double,
                         completion: @escaping (Bool) -> Void) {
        debugOverlayEnabled = enabled
        if enabled, !source.isEmpty { debugSource = source }
        debugDisplaySize = displaySize
        rebuildDebugScript()
        applyUserScripts()

        guard enabled else {
            webView.evaluateJavaScript("try{eruda.hide()}catch(e){};0;") { _, _ in
                completion(true)
            }
            return
        }

        let bundle = WebViewHolder.debugBundle(
            source: debugSource, displaySize: debugDisplaySize)
        webView.evaluateJavaScript(bundle) { value, error in
            if error != nil {
                completion(false)
                return
            }
            // The boot snippet ends with 'ok'; a page without a JS context
            // returns nil, which the caller can retry after the load commits.
            completion((value as? String)?.contains("ok") ?? false)
        }
    }

    /// Re-registers the debug user script with a new panel size.
    ///
    /// Cheap on purpose: the bundle is only concatenated again, nothing is
    /// evaluated, so dragging the split does not re-initialise eruda.
    func setDebugDisplaySize(_ size: Double) {
        guard debugOverlayEnabled else { return }
        debugDisplaySize = size
        rebuildDebugScript()
        applyUserScripts()
    }

    /// The eruda bundle followed by the snippet that shows it and prints the
    /// jump that produced this document.
    private static func debugBundle(source: String, displaySize: Double) -> String {
        let boot = String(
            format: debugBootTemplate,
            String(format: "%.1f", displaySize),
            String(format: "%.1f", displaySize)
        )
        return source + "\n" + boot
    }

    /// Two `%@` placeholders: the display size for `init` and for `config.set`.
    ///
    /// Runs at document end on every frame of type main, so a page reload, a
    /// link tap or a redirect all get a working console without any help from
    /// Dart. `%1$@`/`%2$@` are the same value; keeping both lets a future change
    /// separate the initial size from the live one.
    private static let debugBootTemplate = #"""
    (function () {
      if (!window.eruda) { return 'no-bundle'; }
      try {
        window.__bhDebugLog = function (text, level) {
          try {
            var fn = level === 'error' ? console.error
                     : level === 'warn' ? console.warn : console.log;
            fn.call(console, '[跳转] ' + text);
          } catch (e) {}
        };
        if (!window.__bhEruda) {
          eruda.init({ defaults: { displaySize: %@ } });
          try { eruda.get('entryBtn').hide(); } catch (e) {}
          window.__bhEruda = true;
          var from = document.referrer || '';
          window.__bhDebugLog(location.href + (from ? '  ←  ' + from : ''));
        } else {
          eruda.show();
        }
        eruda.get().config.set('displaySize', %@);
        eruda.show('console');
      } catch (e) { return 'error:' + e; }
      return 'ok';
    })();
    """#

    // -----------------------------------------------------------------------
    // Navigation policy: stay inside the app, report every jump
    // -----------------------------------------------------------------------

    /// Reports one navigation to the host.
    private func reportNavigation(kind: String, url: URL, method: String,
                                  mainFrame: Bool, type: String,
                                  status: Int? = nil, message: String? = nil) {
        var body: [String: Any] = [
            "kind": kind,
            "url": url.absoluteString,
            "method": method,
            "mainFrame": mainFrame,
            "navigationType": type,
            "ts": Int(Date().timeIntervalSince1970 * 1000),
        ]
        if let status { body["status"] = status }
        if let message { body["message"] = message }
        body["sessionId"] = id
        onNavigationEvent?(body)
    }

    private static func navigationTypeName(_ type: WKNavigationType) -> String {
        switch type {
        case .linkActivated: return "link"
        case .formSubmitted: return "form"
        case .backForward: return "backForward"
        case .reload: return "reload"
        case .formResubmitted: return "formResubmit"
        @unknown default: return "other"
        }
    }

    /// Loads a URL the way Safari's address bar does: from code, never as the
    /// continuation of a user gesture, so Universal Links stay in-app.
    ///
    /// The URL is remembered so its own policy call is allowed instead of being
    /// cancelled by the tap handling above.
    func loadInApp(_ request: URLRequest) {
        if let url = request.url { programmaticURLs.insert(url.absoluteString) }
        webView.load(request)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = (url.scheme ?? "").lowercased()
        let method = (navigationAction.request.httpMethod ?? "GET").uppercased()
        // `targetFrame == nil` is a `target="_blank"` / `window.open` request.
        let targetsMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let opensWindow = navigationAction.targetFrame == nil
        let type = Self.navigationTypeName(navigationAction.navigationType)
        if targetsMainFrame || opensWindow {
            lastMethod = method
            lastNavigationType = type
        }

        // A load this holder started itself (address bar, re-issue, back/forward
        // of a queued URL): let it through once, untouched.
        if programmaticURLs.remove(url.absoluteString) != nil {
            reportNavigation(kind: "start", url: url, method: method,
                             mainFrame: targetsMainFrame, type: type,
                             message: "in-app load")
            decisionHandler(.allow)
            return
        }

        // baidu://, weixin://, itms-apps://, tel:, … would leave the app.
        if blockExternalNavigations, !Self.inAppSchemes.contains(scheme) {
            decisionHandler(.cancel)
            reportNavigation(kind: "blocked", url: url, method: method,
                             mainFrame: targetsMainFrame, type: type,
                             message: "external app jump blocked")
            return
        }

        // Universal links: iOS hands the app's own domain over to that app when
        // a *user tap* moves the main frame. Re-issuing the identical GET from
        // code is the only public way to keep the navigation in-process.
        // Subframes are never re-issued: their content belongs in the frame.
        let isTap = navigationAction.navigationType == .linkActivated
            || navigationAction.navigationType == .formSubmitted
        let isWebURL = scheme == "http" || scheme == "https"
        if blockExternalNavigations, reissueUserTaps, isTap, isWebURL,
           method == "GET",
           targetsMainFrame || opensWindow,
           navigationAction.request.httpBody == nil {
            decisionHandler(.cancel)
            reportNavigation(kind: "in-app", url: url, method: method,
                             mainFrame: targetsMainFrame, type: type,
                             message: "tap reloaded in-app (no external app)")
            DispatchQueue.main.async { [weak self] in
                self?.loadInApp(navigationAction.request)
            }
            return
        }

        reportNavigation(kind: "start", url: url, method: method,
                         mainFrame: targetsMainFrame, type: type)
        decisionHandler(.allow)
    }

    /// page -> Dart bridge. WebKit calls this on the main thread.
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == WebViewHolder.networkHandlerName,
              var body = message.body as? [String: Any] else { return }
        body["sessionId"] = id
        onNetworkEvent?(body)
    }

    /// Keeps `target="_blank"` / `window.open` inside this browser. Returning
    /// nil tells WebKit not to create a new window, and nothing is handed to
    /// Safari or another app.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            loadInApp(navigationAction.request)
        }
        return nil
    }

    func load(_ url: URL, completion: @escaping (Error?) -> Void) {
        load(URLRequest(url: url), completion: completion)
    }

    func load(_ request: URLRequest, completion: @escaping (Error?) -> Void) {
        lastStatusCode = nil
        loadCompletion = completion
        if let url = request.url { programmaticURLs.insert(url.absoluteString) }
        webView.load(request)
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
            if navigationResponse.isForMainFrame, let url = response.url {
                let redirect = [301, 302, 303, 307, 308].contains(response.statusCode)
                reportNavigation(
                    kind: redirect ? "redirect" : "response",
                    url: url,
                    method: lastMethod,
                    mainFrame: true,
                    type: lastNavigationType,
                    status: response.statusCode)
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        programmaticURLs.removeAll()
        if let url = webView.url {
            reportNavigation(
                kind: "committed",
                url: url,
                method: lastMethod,
                mainFrame: true,
                type: lastNavigationType,
                status: lastStatusCode)
        }
        loadCompletion?(nil)
        loadCompletion = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        programmaticURLs.removeAll()
        reportFailure(url: webView.url, error: error)
        loadCompletion?(error)
        loadCompletion = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        programmaticURLs.removeAll()
        reportFailure(url: webView.url, error: error)
        loadCompletion?(error)
        loadCompletion = nil
    }

    /// A failed navigation often has no URL yet; `about:blank` keeps the row
    /// readable instead of dropping the event.
    private func reportFailure(url: URL?, error: Error) {
        reportNavigation(
            kind: "failed",
            url: url ?? URL(string: "about:blank")!,
            method: lastMethod,
            mainFrame: true,
            type: lastNavigationType,
            message: error.localizedDescription)
    }

    /// Hooks `fetch`, `XMLHttpRequest` and `sendBeacon` and forwards method,
    /// URL, caller headers and body to the host. This is what makes POST
    /// bodies visible: WebKit never exposes them to `WKNavigationDelegate`.
    private static let networkScript = #"""
    (function () {
      if (window.__browserHttpNetInstalled) { return; }
      window.__browserHttpNetInstalled = true;
      var MAX_BODY = 65536;
      var pageTag = Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 8);
      var seq = 0;

      function send(payload) {
        try {
          var handler = window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers.browserHttpNet;
          if (handler) { handler.postMessage(payload); }
        } catch (e) {}
      }

      function absolute(url) {
        try { return new URL(String(url), document.baseURI || location.href).href; }
        catch (e) { return String(url); }
      }

      function headerObject(headers) {
        var out = {};
        if (!headers) { return out; }
        try {
          if (typeof Headers !== 'undefined' && headers instanceof Headers) {
            headers.forEach(function (value, name) { out[name] = String(value); });
            return out;
          }
          if (Array.isArray(headers)) {
            headers.forEach(function (pair) {
              if (pair && pair.length >= 2) { out[String(pair[0])] = String(pair[1]); }
            });
            return out;
          }
          if (typeof headers === 'object') {
            Object.keys(headers).forEach(function (name) {
              out[name] = String(headers[name]);
            });
          }
        } catch (e) {}
        return out;
      }

      function bodyText(body) {
        if (body === null || body === undefined) { return null; }
        try {
          if (typeof body === 'string') { return body.slice(0, MAX_BODY); }
          if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) {
            return body.toString().slice(0, MAX_BODY);
          }
          if (typeof FormData !== 'undefined' && body instanceof FormData) {
            var parts = [];
            body.forEach(function (value, name) {
              parts.push(name + '=' + (typeof value === 'string' ? value : '[file]'));
            });
            return parts.join('&').slice(0, MAX_BODY);
          }
          if (typeof Blob !== 'undefined' && body instanceof Blob) {
            return '[Blob ' + body.size + ' bytes]';
          }
          if (typeof ArrayBuffer !== 'undefined' && body instanceof ArrayBuffer) {
            return '[ArrayBuffer ' + body.byteLength + ' bytes]';
          }
          if (typeof ArrayBuffer !== 'undefined' && ArrayBuffer.isView &&
              ArrayBuffer.isView(body)) {
            return '[Binary ' + body.byteLength + ' bytes]';
          }
          return String(body).slice(0, MAX_BODY);
        } catch (e) { return '[unreadable body]'; }
      }

      function emit(payload) {
        payload.page = pageTag;
        send(payload);
      }

      if (typeof window.fetch === 'function') {
        var originalFetch = window.fetch;
        window.fetch = function (input, init) {
          init = init || {};
          var id = ++seq;
          var started = Date.now();
          var url = '';
          var method = 'GET';
          var headers = {};
          try {
            if (typeof Request !== 'undefined' && input instanceof Request) {
              url = input.url;
              method = (init.method || input.method || 'GET').toUpperCase();
              headers = headerObject(input.headers);
            } else {
              url = String(input);
              method = (init.method || 'GET').toUpperCase();
            }
          } catch (e) { url = String(input); }
          if (init.headers) {
            var extra = headerObject(init.headers);
            Object.keys(extra).forEach(function (name) { headers[name] = extra[name]; });
          }
          emit({
            phase: 'request',
            id: id,
            ts: started,
            method: method,
            url: absolute(url),
            headers: headers,
            body: bodyText(init.body)
          });
          return originalFetch.apply(this, arguments).then(function (response) {
            var responseHeaders = headerObject(response.headers);
            var size = null;
            try {
              var length = responseHeaders['content-length'];
              size = length ? parseInt(length, 10) : null;
            } catch (e) {}
            emit({
              phase: 'response',
              id: id,
              ts: Date.now(),
              status: response.status,
              headers: responseHeaders,
              size: size,
              duration: Date.now() - started
            });
            // Read a small textual body from a clone so the page's own stream
            // is untouched. Binary and large responses are skipped.
            var canReadBody = true;
            try {
              var contentType = responseHeaders['content-type'] || '';
              if (contentType &&
                  !/(json|text|xml|javascript|html|urlencoded)/i.test(contentType)) {
                canReadBody = false;
              }
              var declared = responseHeaders['content-length'];
              if (declared && parseInt(declared, 10) > 262144) {
                canReadBody = false;
              }
            } catch (e) {}
            if (canReadBody && typeof response.clone === 'function') {
              try {
                response.clone().text().then(function (text) {
                  emit({
                    phase: 'response-body',
                    id: id,
                    ts: Date.now(),
                    responseBody: String(text).slice(0, MAX_BODY)
                  });
                }, function () {});
              } catch (e) {}
            }
            return response;
          }, function (error) {
            emit({
              phase: 'error',
              id: id,
              ts: Date.now(),
              message: String(error && error.message ? error.message : error),
              duration: Date.now() - started
            });
            throw error;
          });
        };
      }

      if (typeof window.XMLHttpRequest === 'function') {
        var XHR = window.XMLHttpRequest;
        var originalOpen = XHR.prototype.open;
        var originalSend = XHR.prototype.send;
        var originalSetHeader = XHR.prototype.setRequestHeader;
        XHR.prototype.open = function (method, url) {
          this.__bhMeta = {
            method: String(method || 'GET').toUpperCase(),
            url: absolute(url),
            headers: {},
            started: Date.now()
          };
          return originalOpen.apply(this, arguments);
        };
        XHR.prototype.setRequestHeader = function (name, value) {
          if (this.__bhMeta) { this.__bhMeta.headers[String(name)] = String(value); }
          return originalSetHeader.apply(this, arguments);
        };
        XHR.prototype.send = function (body) {
          var meta = this.__bhMeta || {
            method: 'GET',
            url: location.href,
            headers: {},
            started: Date.now()
          };
          var id = ++seq;
          var xhr = this;
          xhr.__bhActiveId = id;
          emit({
            phase: 'request',
            id: id,
            ts: meta.started,
            method: meta.method,
            url: meta.url,
            headers: meta.headers,
            body: bodyText(body)
          });
          try {
            xhr.addEventListener('loadend', function () {
              if (xhr.__bhActiveId !== id) { return; }
              var responseHeaders = {};
              try {
                var raw = xhr.getAllResponseHeaders() || '';
                raw.trim().split(/[\r\n]+/).forEach(function (line) {
                  var index = line.indexOf(':');
                  if (index > 0) {
                    responseHeaders[line.slice(0, index).trim()] =
                      line.slice(index + 1).trim();
                  }
                });
              } catch (e) {}
              var size = null;
              var responseBody = null;
              try {
                var text = null;
                try { text = xhr.responseText; } catch (e) { text = null; }
                if (typeof text === 'string') {
                  size = text.length;
                  responseBody = text.slice(0, MAX_BODY);
                } else if (xhr.response && typeof xhr.response.byteLength === 'number') {
                  size = xhr.response.byteLength;
                }
              } catch (e) {}
              emit({
                phase: 'response',
                id: id,
                ts: Date.now(),
                status: xhr.status,
                headers: responseHeaders,
                size: size,
                responseBody: responseBody,
                duration: Date.now() - meta.started
              });
            });
          } catch (e) {}
          return originalSend.apply(this, arguments);
        };
      }

      if (navigator.sendBeacon) {
        var originalBeacon = navigator.sendBeacon.bind(navigator);
        navigator.sendBeacon = function (url, data) {
          emit({
            phase: 'request',
            id: ++seq,
            ts: Date.now(),
            method: 'POST',
            url: absolute(url),
            headers: {},
            body: bodyText(data)
          });
          return originalBeacon(url, data);
        };
      }
    })();
    """#

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
