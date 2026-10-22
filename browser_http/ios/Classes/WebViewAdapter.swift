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
            ) { detail in result(detail) }

        case "setDebugDisplaySize":
            guard let holder = session(args, result) else { return }
            if let size = (args["displaySize"] as? NSNumber)?.doubleValue {
                holder.setDebugDisplaySize(size)
            }
            result(nil)

        case "setPageNetwork":
            guard let holder = session(args, result) else { return }
            holder.setPageNetwork(args["enabled"] as? Bool ?? true)
            result(nil)

        case "applyContentRuleList":
            guard let holder = session(args, result) else { return }
            guard let identifier = args["identifier"] as? String,
                  !identifier.isEmpty else {
                result(FlutterError(code: "webview.contentRules",
                                    message: "missing identifier",
                                    details: nil))
                return
            }
            holder.applyContentRuleList(
                identifier: identifier,
                encodedRules: args["encodedRules"] as? String
            ) { status in result(status) }

        case "setContentBlockingEnabled":
            guard let holder = session(args, result) else { return }
            holder.setContentBlockingEnabled(
                args["enabled"] as? Bool ?? true)
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

        case "stopLoading":
            guard let holder = session(args, result) else { return }
            holder.webView.stopLoading()
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

    /// When a URL was cancelled and re-issued. Guards against a cancel/re-issue
    /// loop when WebKit reports the reload with a normalised URL string.
    private var reissuedAt: [String: Date] = [:]

    // -----------------------------------------------------------------------
    // Page state: pushed to the host, never polled
    // -----------------------------------------------------------------------

    /// KVO tokens for the WKWebView properties a browser chrome needs.
    private var stateObservers: [NSKeyValueObservation] = []
    /// Last payload sent, so one property change produces one event.
    private var lastStateSignature = ""

    /// WebKit's `estimatedProgress` / `isLoading` / `url` / `title` /
    /// `canGoBack` / `canGoForward` are the only accurate source for a browser
    /// chrome, they are KVO compliant, and there is no delegate method for any
    /// of them. Observing them lets the address bar follow the page in the
    /// frame it changes instead of waiting for a poll.
    private func observeState() {
        stateObservers.append(webView.observe(\.estimatedProgress) {
            [weak self] _, _ in self?.publishState()
        })
        stateObservers.append(webView.observe(\.isLoading) {
            [weak self] _, _ in self?.publishState()
        })
        stateObservers.append(webView.observe(\.url) {
            [weak self] _, _ in self?.publishState()
        })
        stateObservers.append(webView.observe(\.title) {
            [weak self] _, _ in self?.publishState()
        })
        stateObservers.append(webView.observe(\.canGoBack) {
            [weak self] _, _ in self?.publishState()
        })
        stateObservers.append(webView.observe(\.canGoForward) {
            [weak self] _, _ in self?.publishState()
        })
    }

    /// Reports the WebView's current chrome state. Progress is quantised to 2%
    /// so a page with hundreds of subresources cannot flood the channel.
    /// A `state` event carries no decision, only what the page looks like now.
    private func publishState() {
        let urlText = webView.url?.absoluteString ?? ""
        let titleText = webView.title ?? ""
        let loading = webView.isLoading
        let progress = (webView.estimatedProgress * 50).rounded() / 50
        let canBack = webView.canGoBack
        let canForward = webView.canGoForward
        let status = lastStatusCode
        let signature = [
            urlText, titleText, loading ? "1" : "0", String(progress),
            canBack ? "1" : "0", canForward ? "1" : "0",
            status.map(String.init) ?? "-",
        ].joined(separator: "\u{1}")
        if signature == lastStateSignature { return }
        lastStateSignature = signature

        var body: [String: Any] = [
            "kind": "state",
            "url": urlText,
            "method": lastMethod,
            "mainFrame": true,
            "navigationType": "state",
            "ts": Int(Date().timeIntervalSince1970 * 1000),
            "loading": loading,
            "progress": progress,
            "title": titleText,
            "canGoBack": canBack,
            "canGoForward": canForward,
        ]
        if let status { body["status"] = status }
        body["sessionId"] = id
        onNavigationEvent?(body)
    }

    deinit {
        stateObservers.removeAll()
    }

    /// Method and trigger of the last main-frame action, reused by the response
    /// and commit callbacks so a log row reads like the request it belongs to.
    private var lastMethod = "GET"
    private var lastNavigationType = "other"

    private(set) var debugOverlayEnabled = false
    private var debugSource = ""
    private var debugDisplaySize = 50.0
    /// Page requests are observed only while the host shows the Page tab.
    private(set) var pageNetworkEnabled = true
    /// One console injection at a time; the bundle is large, so overlapping
    /// evaluations would race each other.
    private var debugInjecting = false

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

        // Install the fetch/XHR hooks (and nothing else yet). The handler is
        // weak so the holder can be released when the session is disposed.
        applyUserScripts()
        webView.configuration.userContentController.add(
            WeakScriptMessageHandler(delegate: self),
            name: WebViewHolder.networkHandlerName)

        // Visible WebViews are user-driven (challenge page or browser tab);
        // swipe back/forward should behave like Safari.
        webView.allowsBackForwardNavigationGestures = !headless
        observeState()
    }

    /// Rebuilds the page-request hook. The console is *not* a user script:
    /// WebKit applies a large script added at runtime to the next reload but
    /// not reliably to the next navigation, so it is evaluated from code on
    /// every commit instead (see `injectDebug`).
    private func applyUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        guard pageNetworkEnabled else { return }
        controller.addUserScript(WKUserScript(
            source: WebViewHolder.networkScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))
    }

    /// Enables or disables the page-script hook. The current document keeps the
    /// hook it already installed; its events are dropped in `didReceive`.
    func setPageNetwork(_ enabled: Bool) {
        guard pageNetworkEnabled != enabled else { return }
        pageNetworkEnabled = enabled
        applyUserScripts()
    }

    // MARK: - Content blocking

    /// Compiled WebKit content-blocker list, if the host has supplied one.
    private var contentRuleList: WKContentRuleList?
    private var contentRuleListAttached = false
    /// Off until the host explicitly enables it, so a WebView never blocks
    /// resources without its UI knowing.
    private(set) var contentBlockingEnabled = false

    /// Looks the list up in the shared store first (it survives launches), and
    /// compiles it only when [encodedRules] is supplied and no cache exists.
    ///
    /// Completion runs on the main thread with `ready`, `missing` or
    /// `error: …`; the host uses that to show whether blocking is live.
    func applyContentRuleList(
        identifier: String,
        encodedRules: String?,
        completion: @escaping (String) -> Void
    ) {
        let done: (String) -> Void = { status in
            DispatchQueue.main.async { completion(status) }
        }
        let install: (WKContentRuleList) -> Void = { [weak self] list in
            DispatchQueue.main.async {
                guard let self else {
                    done("missing-session")
                    return
                }
                self.installContentRuleList(list)
                done("ready")
            }
        }

        guard let store = WKContentRuleListStore.default() else {
            done("error: no rule store")
            return
        }
        store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
            if let list {
                install(list)
                return
            }
            guard let encodedRules, !encodedRules.isEmpty else {
                done("missing")
                return
            }
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: encodedRules
            ) { list, error in
                if let list {
                    install(list)
                } else {
                    done("error: \(error?.localizedDescription ?? "compile failed")")
                }
            }
        }
    }

    private func installContentRuleList(_ list: WKContentRuleList) {
        let controller = webView.configuration.userContentController
        if contentRuleListAttached, let old = contentRuleList {
            controller.remove(old)
        }
        contentRuleList = list
        contentRuleListAttached = false
        if contentBlockingEnabled {
            controller.add(list)
            contentRuleListAttached = true
        }
    }

    /// Adds or removes the compiled list. Safe to call before compilation: the
    /// flag is remembered and applied when the list arrives.
    func setContentBlockingEnabled(_ enabled: Bool) {
        contentBlockingEnabled = enabled
        let controller = webView.configuration.userContentController
        guard let list = contentRuleList else {
            contentRuleListAttached = false
            return
        }
        if enabled && !contentRuleListAttached {
            controller.add(list)
            contentRuleListAttached = true
        } else if !enabled && contentRuleListAttached {
            controller.remove(list)
            contentRuleListAttached = false
        }
    }

    /// Turns the debug console on or off. Once on, every document gets one:
    /// the currently loaded one right away, later ones from `didCommit`.
    ///
    /// The completion carries a short status: `ok`, `queued` (a document is
    /// loading, the commit injects it) or the reason the bundle could not run.
    func setDebugOverlay(enabled: Bool, source: String, displaySize: Double,
                         completion: @escaping (String) -> Void) {
        debugOverlayEnabled = enabled
        if enabled, !source.isEmpty { debugSource = source }
        debugDisplaySize = displaySize

        guard enabled else {
            webView.evaluateJavaScript("try{eruda.hide()}catch(e){};0;") { _, _ in
                completion(WebViewHolder.stamped("ok"))
            }
            return
        }
        guard !debugSource.isEmpty else {
            completion(WebViewHolder.stamped("bundle: empty"))
            return
        }

        injectDebug { detail in
            switch detail {
            case "ok", "already":
                completion(WebViewHolder.stamped("ok"))
            case "busy":
                completion(WebViewHolder.stamped("queued: document loading"))
            default:
                // A document that started while the bundle was parsed gets the
                // console from its own commit callback.
                completion(WebViewHolder.stamped("queued: \(detail)"))
            }
        }
    }

    /// Puts a visible console into the document loaded right now.
    ///
    /// Called when the switch flips on and from every main-frame commit.
    /// Evaluating the bundle here (instead of relying on a registered user
    /// script) is what makes it survive normal link taps, form posts,
    /// redirects and `window.open` alike.
    private func injectDebug(completion: ((String) -> Void)? = nil) {
        guard debugOverlayEnabled, !debugSource.isEmpty else {
            completion?("off")
            return
        }
        guard !debugInjecting else {
            completion?("busy")
            return
        }
        let url = webView.url?.absoluteString
        debugInjecting = true

        // A document that already has the console (reload, same-page route
        // change, or a second call for the same navigation) only needs to be
        // shown again; re-evaluating the bundle would replace `window.eruda`
        // with an uninitialised copy.
        webView.evaluateJavaScript(WebViewHolder.debugPresentScript) {
            [weak self] present, _ in
            guard let self else { return }
            if (present as? Bool) == true {
                self.debugInjecting = false
                self.webView.evaluateJavaScript(
                    WebViewHolder.debugShowScript
                ) { _, _ in completion?("already") }
                return
            }
            // `;0;` is mandatory: the bundle's own last value is its module
            // object, which cannot cross the WKWebView bridge.
            self.webView.evaluateJavaScript(
                WebViewHolder.erudaSourceScript(self.debugSource)
            ) { [weak self] _, error in
                guard let self else { return }
                if let error {
                    self.debugInjecting = false
                    completion?("bundle: \(error.localizedDescription)")
                    return
                }
                // A new navigation may have replaced the document while the
                // bundle was being evaluated; its commit injects itself.
                guard self.webView.url?.absoluteString == url else {
                    self.debugInjecting = false
                    completion?("navigated")
                    return
                }
                self.webView.evaluateJavaScript(
                    WebViewHolder.debugBoot(displaySize: self.debugDisplaySize)
                ) { [weak self] value, error in
                    guard let self else { return }
                    self.debugInjecting = false
                    if let error {
                        completion?("boot: \(error.localizedDescription)")
                        return
                    }
                    completion?((value as? String) ?? "nil")
                }
            }
        }
    }

    /// Live panel size for every following document and the current one.
    func setDebugDisplaySize(_ size: Double) {
        guard debugOverlayEnabled else { return }
        debugDisplaySize = size
        webView.evaluateJavaScript(
            "try{eruda.get().config.set('displaySize', "
                + WebViewHolder.jsNumber(size) + ")}catch(e){};0;"
        ) { _, _ in }
    }

    /// A locale-independent number literal for injected JavaScript.
    private static func jsNumber(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// The bundle with a serializable tail. `eruda.js` ends in a comment and its
    /// module object cannot cross the WKWebView bridge, so `;0;` is not
    /// optional.
    private static func erudaSourceScript(_ source: String) -> String {
        source + "\n;0;"
    }

    /// Baidu's "open in app" gateway is a plain https page whose query carries
    /// the real custom scheme. Treat any such wrapper as an exit.
    private static func isAppLaunchGateway(_ url: URL) -> Bool {
        guard let raw = url.query?.removingPercentEncoding?.lowercased(),
              raw.contains("://") else { return false }
        // The direct form is the one Baidu uses; the key scan covers siblings
        // such as `?url=weixin%3A%2F%2F…` or `?redirect=itms-apps://…`.
        if raw.contains("baiduboxapp://") { return true }
        for pair in raw.split(separator: "&") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<eq])
            guard ["scheme", "url", "target", "redirect", "redirecturl"].contains(key) else {
                continue
            }
            let value = pair[pair.index(after: eq)...]
            guard let sep = value.range(of: "://") else { continue }
            let proto = value[..<sep.lowerBound]
            if proto != "http" && proto != "https" { return true }
        }
        return false
    }

    /// Bumped whenever the native debug pipeline changes. Appended to every
    /// setDebugOverlay status so the host can tell a stale embedded framework
    /// from a real failure.
    static let debugBuildStamp = "n5"

    private static func stamped(_ detail: String) -> String {
        "\(detail)|\(debugBuildStamp)"
    }

    /// Whether the current document already has a live console, including its
    /// panel element. A page that replaces `documentElement` can leave
    /// `window.eruda` initialised while its host is gone; that has to count as
    /// absent so the next pass builds a fresh instance.
    private static let debugPresentScript = """
    (function () {
      try {
        var h = document.getElementById('eruda');
        return !!(window.__bhEruda && window.eruda && window.eruda._isInit &&
                  h && h.shadowRoot &&
                  h.shadowRoot.querySelector('.eruda-dev-tools'));
      } catch (e) { return false; }
    })()
    """

    /// Shows the console and forces the panel to paint.
    ///
    /// `eruda.show()` only flips `display:block`; the panel's opacity is then
    /// raised by a 50 ms timer through a `transition: opacity .3s`. That
    /// transition can stay at 0 — the panel is laid out (50% height, correct
    /// position) but fully transparent, which looks exactly like "only the
    /// white handle is there". Setting the final values inline with no
    /// transition sidesteps it and is harmless when the transition works.
    private static let debugShowScript = #"""
    try {
      window.eruda.show();
      try { window.eruda.show('console'); } catch (e) {}
      var host = document.getElementById('eruda');
      var panel = host && host.shadowRoot &&
                  host.shadowRoot.querySelector('.eruda-dev-tools');
      if (panel) {
        panel.style.transition = 'none';
        panel.style.display = 'block';
        panel.style.opacity = '1';
      }
    } catch (e) {}
    ;0;
    """#

    /// The snippet that shows the console and prints the jump that produced
    /// this document.
    private static func debugBoot(displaySize: Double) -> String {
        String(format: debugBootTemplate, jsNumber(displaySize))
    }

    /// One `%@` placeholder: the initial display size.
    ///
    /// `eruda.show('console')` only *selects* a tool; the panel itself stays
    /// `display:none` until `eruda.show()` is called without a name. Both are
    /// needed, and the `config.set` must not be allowed to abort the sequence.
    ///
    /// Runs once per document, from `didCommit`, so a reload, a link tap, a
    /// form post or a redirect all get a working console without host help.
    private static let debugBootTemplate = #"""
    (function () {
      if (!window.eruda) { return 'no-bundle'; }
      var size = %@;
      try {
        window.__bhDebugLog = function (text, level) {
          try {
            var fn = level === 'error' ? console.error
                     : level === 'warn' ? console.warn : console.log;
            fn.call(console, '[跳转] ' + text);
          } catch (e) {}
        };
        if (!window.__bhEruda || !window.eruda._isInit) {
          // A half-initialised instance from an earlier document can leave
          // its host behind; drop it before building a new one.
          try { var old = document.getElementById('eruda'); if (old) old.remove(); } catch (e) {}
          eruda.init({ defaults: { displaySize: size } });
          try { eruda.get('entryBtn').hide(); } catch (e) {}
          window.__bhEruda = true;
          var from = document.referrer || '';
          window.__bhDebugLog(location.href + (from ? '  ←  ' + from : ''));
        }
        eruda.show();
        try { eruda.get().config.set('displaySize', size); } catch (e) {}
        eruda.show('console');
        // The panel's reveal is an opacity transition; force the end state so
        // it cannot stay transparent (see debugShowScript).
        try {
          var host = document.getElementById('eruda');
          var panel = host && host.shadowRoot &&
                      host.shadowRoot.querySelector('.eruda-dev-tools');
          if (panel) {
            panel.style.transition = 'none';
            panel.style.display = 'block';
            panel.style.opacity = '1';
          }
        } catch (e) {}
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
        if let url = request.url {
            programmaticURLs.insert(url.absoluteString)
            markReissued(url)
        }
        webView.load(request)
    }

    /// Rebuilds a tapped request the way the page itself would have made it.
    ///
    /// `WKNavigationAction.request` carries the destination, method and body,
    /// but a programmatic `load` loses the referring document, and several
    /// Chinese sites answer a referer-less main-frame request with a blank or a
    /// different page. Re-adding it keeps a re-issued jump faithful.
    private func reissueRequest(_ action: WKNavigationAction) -> URLRequest {
        var request = action.request
        guard request.value(forHTTPHeaderField: "Referer") == nil,
              let from = webView.url?.absoluteString,
              from.hasPrefix("http"),
              action.sourceFrame != nil else {
            return request
        }
        request.setValue(from, forHTTPHeaderField: "Referer")
        return request
    }

    private func wasReissuedRecently(_ url: URL) -> Bool {
        guard let at = reissuedAt[url.absoluteString] else { return false }
        return Date().timeIntervalSince(at) < 2
    }

    private func markReissued(_ url: URL) {
        // `programmaticURLs` is cleared on commit; keep this map small too.
        if reissuedAt.count > 32 { reissuedAt.removeAll() }
        reissuedAt[url.absoluteString] = Date()
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

        // Baidu wraps its app jump in an https gateway
        // (`boxer.baidu.com/scheme?scheme=baiduboxapp%3A%2F%2F…`). That page is
        // itself a Universal Link, so iOS can leave the app before the final
        // custom-scheme hop is ever seen. Drop it here, whatever triggered it.
        if blockExternalNavigations, Self.isAppLaunchGateway(url) {
            decisionHandler(.cancel)
            reportNavigation(kind: "blocked", url: url, method: method,
                             mainFrame: targetsMainFrame, type: type,
                             message: "app-launch gateway blocked")
            return
        }

        // A page jump must never leave the app, but only a *gesture-backed* one
        // can actually be handed to another app: iOS fires the Universal Link
        // association for a tap, a form submit or a `window.open` (which keeps
        // the tap's gesture), never for a script navigation the user did not
        // activate. So:
        // - taps / GET form submits and script `window.open` are cancelled and
        //   re-issued from code, which is what keeps them in this browser;
        // - a plain in-main-frame `location =` is allowed through instead.
        //   Cancelling one and reloading it costs a second request for the same
        //   document *and* leaves the redirecting wrapper page in the
        //   back/forward list, so the first swipe back showed a blank screen.
        //   Allowed, WebKit does what Safari does: a redirect issued while the
        //   document is still loading replaces that entry.
        // Anything that is not http(s), and any URL whose query carries an app
        // scheme, is already cancelled above, whatever triggered it.
        // Back/forward and reload are left alone: those URLs are already inside
        // this browser. POST bodies pass through untouched.
        let trigger = navigationAction.navigationType
        let isGesture = trigger == .linkActivated || trigger == .formSubmitted
        let isScriptJump = trigger == .other
        let isWebURL = scheme == "http" || scheme == "https"
        let opensFromScript = isScriptJump && opensWindow
        if blockExternalNavigations, reissueUserTaps, isWebURL,
           method == "GET",
           isGesture || opensFromScript,
           targetsMainFrame || opensWindow,
           navigationAction.request.httpBody == nil {
            // The identical request is already in flight (a page that fires both
            // a tap and a `window.open`, or a double tap). Cancel it: allowing
            // would hand the Universal Link over, and a second load would put a
            // duplicate entry in the back/forward list. Once nothing is loading
            // the previous attempt is over, so the tap is honoured again instead
            // of silently doing nothing.
            if wasReissuedRecently(url), webView.isLoading {
                decisionHandler(.cancel)
                reportNavigation(kind: "in-app", url: url, method: method,
                                 mainFrame: targetsMainFrame, type: type,
                                 message: "duplicate jump kept out")
                return
            }
            markReissued(url)
            decisionHandler(.cancel)
            reportNavigation(kind: "in-app", url: url, method: method,
                             mainFrame: targetsMainFrame, type: type,
                             message: "reloaded in-app (no external app)")
            let reissued = reissueRequest(navigationAction)
            DispatchQueue.main.async { [weak self] in
                self?.loadInApp(reissued)
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
        // The hooks stay installed in documents loaded while the Page tab was
        // open; their events are dropped as soon as it closes.
        guard message.name == WebViewHolder.networkHandlerName,
              pageNetworkEnabled,
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
        // A new window must also stay in-app; a custom scheme is simply
        // dropped instead of being handed to `webView.load` or the system.
        if navigationAction.targetFrame == nil,
           let url = navigationAction.request.url,
           !programmaticURLs.contains(url.absoluteString) {
            let scheme = (url.scheme ?? "").lowercased()
            if blockExternalNavigations,
               !Self.inAppSchemes.contains(scheme) || Self.isAppLaunchGateway(url) {
                reportNavigation(
                    kind: "blocked", url: url,
                    method: (navigationAction.request.httpMethod ?? "GET").uppercased(),
                    mainFrame: true,
                    type: Self.navigationTypeName(navigationAction.navigationType),
                    message: "external app jump blocked (new window)")
            } else if !wasReissuedRecently(url) {
                loadInApp(navigationAction.request)
            }
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
        publishState()
    }

    /// The new document exists. This is the earliest point where the console
    /// can be put back into it, so every click, redirect or `window.open`
    /// keeps it without waiting for the load to finish.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // The new document is on screen: the address bar must show its URL now,
        // not when the last subresource finishes.
        publishState()
        if debugOverlayEnabled { injectDebug() }
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
                // The status is chrome data too (a 404 must be visible without
                // opening the console), and no KVO key path carries it.
                publishState()
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
        // `didCommit` already injected; this second pass only matters when the
        // page replaced its DOM or the first evaluation was still in flight.
        if debugOverlayEnabled { injectDebug() }
        loadCompletion?(nil)
        loadCompletion = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        programmaticURLs.removeAll()
        reportFailure(url: webView.url, error: error)
        publishState()
        loadCompletion?(error)
        loadCompletion = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        programmaticURLs.removeAll()
        reportFailure(url: webView.url, error: error)
        publishState()
        loadCompletion?(error)
        loadCompletion = nil
    }

    /// A failed navigation often has no URL yet; `about:blank` keeps the row
    /// readable instead of dropping the event.
    private func reportFailure(url: URL?, error: Error) {
        // `stopLoading()` and a navigation superseded mid-flight both fail with
        // NSURLErrorCancelled. That was the user's own action, not a dead page,
        // so it must not light up the failure state in the address bar.
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return
        }
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
