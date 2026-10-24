import AVFoundation
import Foundation
import Flutter
import UIKit
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

    /// Forwards "the user pressed and held this link" reports. The host decides
    /// what to offer — a second browsing window is a host concept, not a WebKit
    /// one, and WebKit's own preview menu has no such item.
    var onLinkPress: (([String: Any]) -> Void)?

    /// Forwards what the page's video is doing. The host draws the player
    /// controls, so it needs to know when a video was tapped and where it is.
    var onVideoEvent: (([String: Any]) -> Void)?

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
            holder.onLinkPress = { [weak self] event in
                self?.onLinkPress?(event)
            }
            holder.onVideoEvent = { [weak self] event in
                self?.onVideoEvent?(event)
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
            holder.asksAboutExternalJumps = args["askExternal"] as? Bool
                ?? holder.asksAboutExternalJumps
            if let allowed = args["allowSchemes"] as? [String] {
                holder.allowedExternalSchemes = Set(allowed.map { $0.lowercased() })
            }
            if let denied = args["denySchemes"] as? [String] {
                holder.deniedExternalSchemes = Set(denied.map { $0.lowercased() })
            }
            result(nil)

        case "openExternal":
            guard let holder = session(args, result) else { return }
            guard let raw = args["url"] as? String, let target = URL(string: raw),
                  let scheme = target.scheme, !scheme.isEmpty else {
                result(FlutterError(code: "webview.openExternal",
                                    message: "bad arguments", details: nil))
                return
            }
            // The user said yes to this one. Opening it from code, rather than
            // letting the cancelled navigation resume, is what keeps the answer
            // from becoming a no-op.
            holder.openExternal(target, scheme: scheme.lowercased(), method: "GET",
                                mainFrame: true, type: "host")
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

        case "snapshot":
            guard let holder = session(args, result) else { return }
            let requested = (args["maxWidth"] as? Int) ?? 360
            let width = CGFloat(requested > 0 ? requested : 360)
            holder.snapshot(maxWidth: width) { data in
                result(data == nil ? nil : FlutterStandardTypedData(bytes: data!))
            }

        case "captureVideoFrame":
            guard let holder = session(args, result) else { return }
            holder.captureVideoFrame { status in result(status) }

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
    /// A link the user pressed and held, so the host can offer its own
    /// "open in a new window" choice for it.
    var onLinkPress: (([String: Any]) -> Void)?
    /// The page's video: the player window opened/closed, or the playhead moved.
    var onVideoEvent: (([String: Any]) -> Void)?
    private var loadCompletion: ((Error?) -> Void)?
    fileprivate var lastStatusCode: Int?

    private static let networkHandlerName = "browserHttpNet"
    private static let tapHandlerName = "browserHttpTap"
    /// Playback of the page's own video, reported from the video script: the
    /// player window opened or closed, and where the playhead is.
    private static let videoHandlerName = "browserHttpVideo"

    /// Picture size last reported by the video script. A capture crops the
    /// WebView snapshot to that aspect inside the viewport, which leaves the
    /// black letterbox out of the saved frame.
    private var videoWidth: CGFloat = 0
    private var videoHeight: CGFloat = 0
    private var videoPosition: Double = 0
    private var videoUrl = ""
    private var videoReferer = ""

    /// Cancels any navigation whose scheme is not http(s)/in-app, so a link can
    /// never hand the URL over to another app (`baidu://`, `weixin://`,
    /// `itms-apps://`, `tel:` …).
    var blockExternalNavigations = true

    /// iOS opens the matching app when a *user tap* moves the main frame to a
    /// URL registered as a Universal Link. Re-issuing the identical request
    /// from code keeps the page inside this browser.
    var reissueUserTaps = true

    /// Protocols the user chose to allow ("总是允许 bilibili") — they may leave
    /// the app without being asked again.
    var allowedExternalSchemes: Set<String> = []

    /// Protocols the user banned for good ("不允许" in the jump dialog). Kept
    /// apart from `allowedExternalSchemes` because a refusal must outlive the
    /// page that asked, while the global switch is still a switch.
    var deniedExternalSchemes: Set<String> = []

    /// When true, an unranked protocol is reported to the host for its decision
    /// instead of being cancelled in silence. Off keeps the old behaviour for a
    /// host that has no dialog to show.
    var asksAboutExternalJumps = false

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
        // On an iPhone a <video> otherwise hands itself to the system player
        // the moment it starts, and that player is also what comes back when
        // the page resumes the element later: the picture leaves this WebView,
        // so the app can neither put its own controls around it nor keep it
        // from reappearing while the user scrolls. Inline playback keeps the
        // video in the page, where the video script can size it and the host
        // can draw a control bar over it.
        config.allowsInlineMediaPlayback = true
        // Nothing plays on its own — not on load and not when a page calls
        // play() on scroll. Sound starts from a tap or not at all.
        config.mediaTypesRequiringUserActionForPlayback = .all
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
        webView.configuration.userContentController.add(
            WeakScriptMessageHandler(delegate: self),
            name: WebViewHolder.tapHandlerName)
        webView.configuration.userContentController.add(
            WeakScriptMessageHandler(delegate: self),
            name: WebViewHolder.videoHandlerName)

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
        // The press-and-hold hook does not belong to the Page tab: opening a
        // link in another window is wanted whether or not anything is collected.
        controller.addUserScript(WKUserScript(
            source: WebViewHolder.tapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))
        // Video ownership is not a Page-tab setting: whichever pages are open,
        // a video must not be able to take the screen with the system player
        // the app cannot put controls around.
        controller.addUserScript(WKUserScript(
            source: WebViewHolder.videoScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))
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

    // MARK: - Thumbnail

    /// Renders what the WebView is showing into PNG data no wider than
    /// [maxWidth], for the host's task switcher.
    ///
    /// The host takes the picture of the window it is about to park, while that
    /// WebView is still on screen: `takeSnapshot` on a view attached to no
    /// window has nothing composited to read, so a card is a photograph of the
    /// moment the user left, not a live view of the background page.
    func snapshot(maxWidth: CGFloat, _ done: @escaping (Data?) -> Void) {
        let configuration = WKSnapshotConfiguration()
        if !webView.bounds.isEmpty { configuration.rect = webView.bounds }
        webView.takeSnapshot(with: configuration) { image, _ in
            guard let image, image.size.width > 0 else { done(nil); return }
            let scale = min(1, maxWidth / image.size.width)
            let size = CGSize(width: (image.size.width * scale).rounded(),
                              height: (image.size.height * scale).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let small = UIGraphicsImageRenderer(size: size, format: format)
                .image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            done(small.pngData())
        }
    }

    /// Saves the frame the player is showing to Photos.
    ///
    /// Three ways, tried in order: read the page's `<video>` through a canvas
    /// (full resolution); draw that frame onto a full-screen page canvas and
    /// photograph the page (a cross-origin picture taints the canvas, so it
    /// cannot be read back, but it can still be seen); decode the media file
    /// itself around the playhead, sampling twenty moments, and keep the first
    /// picture that is not black.
    ///
    /// A snapshot of the bare video element is never useful: the video layer
    /// is composited outside the page's drawing and comes back black.
    func captureVideoFrame(_ done: @escaping (String) -> Void) {
        evaluatePageFrame { [weak self] info in
            guard let self else { done("error: no view"); return }
            if let data = Self.imageData(fromDataURL: info.frame),
               !Self.isNearlyBlack(data) {
                self.saveFramePhoto(data, done)
                return
            }
            self.freezeAndSnapshot { [weak self] frozen in
                guard let self else { done("error: no view"); return }
                if let frozen, !Self.isNearlyBlack(frozen) {
                    self.saveFramePhoto(frozen, done)
                    return
                }
                self.captureVideoFrameRemotely(
                    userAgent: info.userAgent, page: info.page,
                    cookie: info.cookie, origin: info.origin, done)
            }
        }
    }

    private struct CaptureInfo {
        var frame = ""
        var userAgent = ""
        var page = ""
        var cookie = ""
        var origin = ""
    }

    private func evaluatePageFrame(_ done: @escaping (CaptureInfo) -> Void) {
        let script = """
        (function () {
          var out = {
            frame: '',
            ua: navigator.userAgent || '',
            page: location.href || '',
            cookie: document.cookie || '',
            origin: location.origin || ''
          };
          try {
            if (typeof window.__soCaptureFrame === 'function') {
              out.frame = window.__soCaptureFrame() || '';
            }
          } catch (e) {}
          return JSON.stringify(out);
        })()
        """
        webView.evaluateJavaScript(script) { value, _ in
            var info = CaptureInfo()
            if let text = value as? String,
               let data = text.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data),
               let body = parsed as? [String: Any] {
                info.frame = body["frame"] as? String ?? ""
                info.userAgent = body["ua"] as? String ?? ""
                info.page = body["page"] as? String ?? ""
                info.cookie = body["cookie"] as? String ?? ""
                info.origin = body["origin"] as? String ?? ""
            }
            done(info)
        }
    }

    /// Draws the current picture over the whole page and photographs that.
    /// The overlay is page content, so the compositor includes it. Returns nil
    /// when this frame has no picture to freeze (for example, a player inside
    /// an iframe), so bare page text is never saved as a screenshot.
    private func freezeAndSnapshot(_ done: @escaping (Data?) -> Void) {
        let script = """
        (function () {
          if (typeof window.__soFreezeFrame !== 'function') { return ''; }
          return window.__soFreezeFrame() || '';
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self else { done(nil); return }
            let text = value as? String ?? ""
            if let size = Self.parseSize(text) {
                self.snapshotFrozen(size, done)
                return
            }
            guard text == "pending" else {
                done(nil)
                return
            }
            self.pollFrozenSize(attempt: 0, done)
        }
    }

    /// Polls the top document for the size an iframe reported after being
    /// asked to freeze. The frame draws its own picture; the top only stretches
    /// it, so the host has to wait for the answer before photographing.
    private func pollFrozenSize(attempt: Int,
                                _ done: @escaping (Data?) -> Void) {
        let script = "window.__soFrozenSize ? window.__soFrozenSize() : ''"
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self else { done(nil); return }
            if let size = Self.parseSize(value as? String ?? "") {
                self.snapshotFrozen(size, done)
                return
            }
            if attempt >= 12 {
                self.unfreezeFrame()
                done(nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                self.pollFrozenSize(attempt: attempt + 1, done)
            }
        }
    }

    private static func parseSize(_ text: String) -> CGSize? {
        guard !text.isEmpty, text != "pending" else { return nil }
        if let data = text.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data),
           let body = parsed as? [String: Any],
           let width = (body["width"] as? NSNumber)?.doubleValue,
           let height = (body["height"] as? NSNumber)?.doubleValue,
           width > 0, height > 0 {
            return CGSize(width: width, height: height)
        }
        let parts = text.split(separator: ",")
        if parts.count == 2,
           let width = Double(parts[0]), let height = Double(parts[1]),
           width > 0, height > 0 {
            return CGSize(width: width, height: height)
        }
        return nil
    }

    private func snapshotFrozen(_ size: CGSize,
                                _ done: @escaping (Data?) -> Void) {
        // Give the compositor a frame to pick the canvas up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { done(nil); return }
            let configuration = WKSnapshotConfiguration()
            if !self.webView.bounds.isEmpty {
                configuration.rect = self.webView.bounds
            }
            self.webView.takeSnapshot(with: configuration) {
                [weak self] image, _ in
                guard let self else { done(nil); return }
                self.unfreezeFrame()
                guard let image else { done(nil); return }
                let picture = Self.cropped(
                    image, aspect: size.width / size.height)
                done(picture.jpegData(compressionQuality: 0.95))
            }
        }
    }

    private func unfreezeFrame() {
        webView.evaluateJavaScript(
            "window.__soUnfreezeFrame && window.__soUnfreezeFrame()",
            completionHandler: nil)
    }

    /// Cuts the letterbox off a frozen page photograph. The overlay centres
    /// the canvas, so the picture is the aspect-fitted rectangle in the middle.
    private static func cropped(_ image: UIImage, aspect: Double) -> UIImage {
        guard aspect > 0, let source = image.cgImage,
              source.width > 8, source.height > 8 else { return image }
        let width = CGFloat(source.width)
        let height = CGFloat(source.height)
        let imageAspect = Double(width / height)
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        if aspect > imageAspect {
            let fitted = (width / CGFloat(aspect)).rounded()
            rect = CGRect(x: 0, y: ((height - fitted) / 2).rounded(),
                          width: width, height: fitted)
        } else {
            let fitted = (height * CGFloat(aspect)).rounded()
            rect = CGRect(x: ((width - fitted) / 2).rounded(), y: 0,
                          width: fitted, height: height)
        }
        guard rect.width > 8, rect.height > 8,
              let piece = source.cropping(to: rect) else { return image }
        return UIImage(cgImage: piece, scale: image.scale,
                       orientation: image.imageOrientation)
    }

    /// An all-black frame tells the host nothing; it can mean the decoder has
    /// not produced this instant yet. Neighbours are sampled instead.
    private static func isNearlyBlack(_ data: Data) -> Bool {
        guard let image = UIImage(data: data), let source = image.cgImage else {
            return true
        }
        let width = 24, height = 24
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var maximum = 0
        var total = 0
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: base, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.draw(source, in: CGRect(x: 0, y: 0,
                                            width: width, height: height))
        }
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let value = (Int(pixels[index]) + Int(pixels[index + 1]) +
                         Int(pixels[index + 2])) / 3
            total += value
            if value > maximum { maximum = value }
        }
        return maximum < 24 && total / (width * height) < 12
    }

    private static func imageData(fromDataURL value: String) -> Data? {
        guard value.hasPrefix("data:image/"),
              let comma = value.firstIndex(of: ",") else { return nil }
        let encoded = String(value[value.index(after: comma)...])
        return Data(base64Encoded: encoded)
    }

    private func saveFramePhoto(_ data: Data, _ done: @escaping (String) -> Void) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "so-frame-\(formatter.string(from: Date())).jpg"
        MediaBridge.savePhotoData(data, filename: name, result: done)
    }

    /// Last resort: decode the media file itself around the playhead. The
    /// request carries the page's user agent, referer, cookies and origin, or
    /// the host will serve nothing. Twenty moments are sampled because one
    /// seek can land on a keyframe boundary or before the first picture.
    private func captureVideoFrameRemotely(
        userAgent: String,
        page: String,
        cookie: String,
        origin: String,
        _ done: @escaping (String) -> Void
    ) {
        guard let url = URL(string: videoUrl),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            done("error: 页面没有给出可以直接读取的视频地址")
            return
        }
        var headers: [String: String] = ["Accept": "*/*"]
        if !userAgent.isEmpty { headers["User-Agent"] = userAgent }
        let referer = videoReferer.isEmpty ? page : videoReferer
        if !referer.isEmpty { headers["Referer"] = referer }
        if !origin.isEmpty { headers["Origin"] = origin }
        var cookies = cookie
        if let stored = HTTPCookieStorage.shared.cookies(for: url),
           !stored.isEmpty {
            let found = HTTPCookie.requestHeaderFields(with: stored)["Cookie"]
            if let found, !found.isEmpty {
                cookies = cookies.isEmpty ? found : cookies + "; " + found
            }
        }
        if !cookies.isEmpty { headers["Cookie"] = cookies }

        let base = max(0, videoPosition)
        let offsets: [Double] = [
            0, 0.15, -0.15, 0.3, -0.3, 0.5, -0.5, 0.75, -0.75, 1.0,
            -1.0, 1.5, -1.5, 2.0, -2.0, 3.0, -3.0, 4.0, -4.0, 5.0
        ]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let asset = AVURLAsset(
                url: url,
                options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let tolerance = CMTime(seconds: 0.15, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            var fallback: Data?
            var lastError: Error?
            var failures = 0
            for offset in offsets {
                let seconds = max(0, base + offset)
                do {
                    let image = try generator.copyCGImage(
                        at: CMTime(seconds: seconds, preferredTimescale: 600),
                        actualTime: nil)
                    guard let data = UIImage(cgImage: image)
                        .jpegData(compressionQuality: 0.95) else { continue }
                    if fallback == nil { fallback = data }
                    if !Self.isNearlyBlack(data) {
                        DispatchQueue.main.async {
                            guard let self else {
                                done("error: no view")
                                return
                            }
                            self.saveFramePhoto(data, done)
                        }
                        return
                    }
                } catch {
                    lastError = error
                    failures += 1
                    if failures >= 5 && fallback == nil { break }
                }
            }
            DispatchQueue.main.async {
                guard let self else { done("error: no view"); return }
                if let fallback {
                    self.saveFramePhoto(fallback, done)
                    return
                }
                done("error: \(lastError?.localizedDescription ?? "无法读取这一帧")")
            }
        }
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

    /// One `proto://value` pair inside a query string. Protocol characters only,
    /// so a plain `key=value` never matches.
    private static let appLaunchPattern =
        "([A-Za-z][A-Za-z0-9+.\\-]{1,31})://([^&\\s\"'<>]{1,2048})"

    /// The app URL an "open in app" wrapper page is holding. Baidu keeps it in
    /// `boxer.baidu.com/scheme?scheme=baiduboxapp%3A%2F%2F…`; the short-video and
    /// shopping apps use their own keys (`redirect_url`, `targetUrl`, `d`, …), so
    /// the key name is not what identifies one — any non-web `proto://` inside the
    /// decoded query is an exit candidate.
    private static func appLaunchTarget(_ url: URL) -> URL? {
        guard let raw = url.query?.removingPercentEncoding,
              raw.contains("://") else { return nil }
        guard let regex = try? NSRegularExpression(pattern: appLaunchPattern) else {
            return nil
        }
        let search = NSRange(raw.startIndex..., in: raw)
        for match in regex.matches(in: raw, range: search) {
            guard let protoRange = Range(match.range(at: 1), in: raw),
                  let valueRange = Range(match.range(at: 2), in: raw) else { continue }
            let proto = String(raw[protoRange]).lowercased()
            // A page also passes its own endpoints through the query
            // (`?ws=wss://api.example.com`); those are not another app.
            if ["http", "https", "ws", "wss"].contains(proto) { continue }
            if let target = URL(string: "\(proto)://\(String(raw[valueRange]))") {
                return target
            }
        }
        return nil
    }

    /// The exit a navigation would perform, if any: a custom scheme straight away
    /// (`bilibili://video/BV…`), or the protocol carried by an https wrapper page.
    /// `nil` means this URL stays inside the browser.
    private static func externalJump(for url: URL) -> (target: URL, scheme: String)? {
        let scheme = (url.scheme ?? "").lowercased()
        if !scheme.isEmpty && !Self.inAppSchemes.contains(scheme) {
            return (url, scheme)
        }
        guard let target = Self.appLaunchTarget(url) else { return nil }
        return (target, (target.scheme ?? "").lowercased())
    }

    /// Whether a subframe request aims at another site than the page holding it.
    private static func isCrossOrigin(_ url: URL, against current: URL?) -> Bool {
        guard let host = current?.host?.lowercased(), !host.isEmpty else { return true }
        return url.host?.lowercased() != host
    }

    /// Hands a URL to the system. Only ever reached for a protocol the user has
    /// said yes to: WebKit's own `.allow` would have been the same hand-over, but
    /// it happens before the question is answered.
    func openExternal(_ target: URL, scheme: String, method: String,
                              mainFrame: Bool, type: String) {
        UIApplication.shared.open(target, options: [:]) { [weak self] opened in
            guard let self else { return }
            self.reportNavigation(
                kind: opened ? "external-open" : "blocked",
                url: target, method: method, mainFrame: mainFrame, type: type,
                message: opened ? "已交给 \(scheme) 应用"
                                : "本机没有应用处理 \(scheme)://")
        }
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

        // baidu://, bilibili://, weixin://, itms-apps://, tel: … and the https
        // pages whose query carries one. The navigation is always cancelled: WebKit
        // performing it *is* the hand-over, so it cannot be left in flight while a
        // dialog waits for an answer. What happens next is the host's call — a
        // protocol the user banned stays shut, one they allowed is opened from code,
        // and anything else is reported for its dialog.
        if blockExternalNavigations, let jump = Self.externalJump(for: url) {
            decisionHandler(.cancel)
            if deniedExternalSchemes.contains(jump.scheme) {
                reportNavigation(kind: "blocked", url: url, method: method,
                                 mainFrame: targetsMainFrame, type: type,
                                 message: "external app jump banned (\(jump.scheme)://)")
                return
            }
            if allowedExternalSchemes.contains(jump.scheme) {
                openExternal(jump.target, scheme: jump.scheme, method: method,
                             mainFrame: targetsMainFrame, type: type)
                return
            }
            if asksAboutExternalJumps {
                reportNavigation(kind: "ask", url: jump.target, method: method,
                                 mainFrame: targetsMainFrame, type: type,
                                 message: "external app jump")
                return
            }
            reportNavigation(kind: "blocked", url: url, method: method,
                             mainFrame: targetsMainFrame, type: type,
                             message: "external app jump blocked")
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
        // A click handler that sets `location.href` reaches WebKit as `.other`,
        // but iOS still holds that tap's gesture token, so it is exactly as able to
        // hand a Universal Link to another app as a plain link tap. It is re-issued
        // only once its document is on screen: re-issued *during* a load it doubles
        // the request and leaves the wrapper entry that made the first swipe back
        // show a blank screen.
        let settledScriptJump = isScriptJump && targetsMainFrame && !webView.isLoading
        // An app's "打开 App" button also lives inside a third-party iframe, and a
        // subframe navigation does not satisfy the main-frame clause above. A tap
        // aimed at another site belongs in this browser's main frame; same-origin
        // frame browsing is left alone, or every paginated iframe would hijack the
        // page it is embedded in.
        let crossOriginFrameTap = isGesture && !targetsMainFrame && !opensWindow
            && Self.isCrossOrigin(url, against: webView.url)
        if blockExternalNavigations, reissueUserTaps, isWebURL,
           method == "GET",
           isGesture || opensFromScript || settledScriptJump || crossOriginFrameTap,
           targetsMainFrame || opensWindow || crossOriginFrameTap,
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
        if message.name == WebViewHolder.tapHandlerName {
            guard var body = message.body as? [String: Any],
                  let url = body["url"] as? String, !url.isEmpty else { return }
            body["sessionId"] = id
            onLinkPress?(body)
            return
        }
        if message.name == WebViewHolder.videoHandlerName {
            guard var body = message.body as? [String: Any] else { return }
            if let width = (body["width"] as? NSNumber)?.doubleValue,
               width > 0, width.isFinite {
                videoWidth = CGFloat(width)
            }
            if let height = (body["height"] as? NSNumber)?.doubleValue,
               height > 0, height.isFinite {
                videoHeight = CGFloat(height)
            }
            if let position = (body["position"] as? NSNumber)?.doubleValue,
               position > 0, position.isFinite {
                videoPosition = position
            }
            if let url = body["url"] as? String, !url.isEmpty {
                videoUrl = url
            }
            if let referer = body["referer"] as? String, !referer.isEmpty {
                videoReferer = referer
            }
            if (body["kind"] as? String) == "exit" {
                videoWidth = 0
                videoHeight = 0
                videoPosition = 0
                videoUrl = ""
                videoReferer = ""
            }
            body["sessionId"] = id
            onVideoEvent?(body)
            return
        }
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
        // A new window must also stay in-app. `decidePolicyFor` has usually
        // already cancelled the request before WebKit gets here, so this is the
        // second gate, not the first, and it decides the same way.
        if navigationAction.targetFrame == nil,
           let url = navigationAction.request.url,
           !programmaticURLs.contains(url.absoluteString) {
            let method = (navigationAction.request.httpMethod ?? "GET").uppercased()
            let type = Self.navigationTypeName(navigationAction.navigationType)
            if blockExternalNavigations, let jump = Self.externalJump(for: url) {
                if deniedExternalSchemes.contains(jump.scheme) {
                    reportNavigation(kind: "blocked", url: url, method: method,
                                     mainFrame: true, type: type,
                                     message: "external app jump banned (new window)")
                } else if allowedExternalSchemes.contains(jump.scheme) {
                    openExternal(jump.target, scheme: jump.scheme, method: method,
                                 mainFrame: true, type: type)
                } else if asksAboutExternalJumps {
                    reportNavigation(kind: "ask", url: jump.target, method: method,
                                     mainFrame: true, type: type,
                                     message: "external app jump")
                } else {
                    reportNavigation(kind: "blocked", url: url, method: method,
                                     mainFrame: true, type: type,
                                     message: "external app jump blocked (new window)")
                }
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

    /// Reports a link the user pressed and held for half a second, then swallows
    /// the click that would otherwise follow, so the hold is never also a visit.
    ///
    /// WebKit's own link preview is suppressed for anchors (`contextmenu`) —
    /// it has no way to ask the host for a second window, and two menus over one
    /// gesture is worse than none. Text and images keep their normal long-press
    /// behaviour because only anchors are prevented.
    private static let tapScript = #"""
    (function () {
      if (window.__browserHttpTapInstalled) { return; }
      window.__browserHttpTapInstalled = true;
      var HOLD = 520, SLOP = 12;
      var timer = null, anchor = null, held = null, x0 = 0, y0 = 0;
      function linkOf(node) {
        while (node && node.nodeType === 1) {
          if (node.tagName === 'A' && node.href) { return node; }
          node = node.parentNode;
        }
        return null;
      }
      function reset() {
        if (timer) { clearTimeout(timer); timer = null; }
        anchor = null;
      }
      document.addEventListener('touchstart', function (e) {
        if (e.touches.length !== 1) { reset(); return; }
        var t = e.touches[0];
        x0 = t.clientX; y0 = t.clientY;
        var a = linkOf(t.target);
        if (!a) { reset(); return; }
        anchor = a;
        if (timer) { clearTimeout(timer); }
        timer = setTimeout(function () {
          timer = null;
          if (!anchor) { return; }
          held = anchor;
          var text = (anchor.textContent || anchor.title || '')
            .replace(/\s+/g, ' ').trim().slice(0, 140);
          window.webkit.messageHandlers.browserHttpTap.postMessage(
            {url: anchor.href, text: text});
        }, HOLD);
      }, {passive: true});
      document.addEventListener('touchmove', function (e) {
        if (!anchor || e.touches.length !== 1) { return; }
        var t = e.touches[0];
        if (Math.abs(t.clientX - x0) > SLOP || Math.abs(t.clientY - y0) > SLOP) {
          reset();
        }
      }, {passive: true});
      document.addEventListener('touchend', function (e) {
        if (held) { e.preventDefault(); held = null; }
        reset();
      }, false);
      document.addEventListener('touchcancel', function () { reset(); },
                                {passive: true});
      document.addEventListener('contextmenu', function (e) {
        if (linkOf(e.target)) { e.preventDefault(); }
      }, false);
    })();
    """#

    /// Owns the page's video: a tap on a video hands the picture to the app's
    /// player window instead of WebKit's system player, which the app cannot
    /// put controls around and which comes back on its own whenever the page
    /// resumes the element.
    ///
    /// The video keeps playing inside the page — stretched over the viewport,
    /// at the top of the stacking order — so every stream WebKit can play
    /// (progressive MP4, HLS, MSE) keeps working. The host draws the control
    /// layer over it and drives it through `window.__soVideo`; this script
    /// reports what the picture is doing and owns the touch gestures: tap to
    /// show or hide the controls, horizontal drag to seek, pinch to zoom,
    /// pull-down to leave.
    ///
    /// A video inside a cross-origin iframe cannot stretch past the frame, so
    /// the frame reports upwards and the *top* document stretches the iframe
    /// itself. Only a tap opens the window; nothing here reacts to a page that
    /// starts playing by itself.
    private static let videoScript = #"""
    (function () {
      if (window.__soVideoInstalled) { return; }
      window.__soVideoInstalled = true;
      var isTop = window.top === window;
      var video = null;        // the element this frame has taken over
      var theater = null;      // the element stretched over the viewport
      var savedStyle = null;   // its inline style before we changed it
      var savedControls = null;// its native controls flag, restored on exit
      var child = null;        // top frame: the frame whose video is showing
      var lifted = [];         // ancestors neutralised while the window is up

      // One finger: a tap, a horizontal seek or a pull-down. Two fingers zoom.
      var startX = 0, startY = 0, startTime = 0, lastDy = 0;
      var mode = '';           // '' | 'seek' | 'exit' | 'none' | 'pinch'
      var zoom = 1;
      var pinchStart = 0, pinchBase = 1;
      var seekTarget = 0;
      var moved = false;
      var suppressUntil = 0;   // a swipe must not end as a tap
      var lastPreview = 0;
      var lastUrl = '';        // the media source last reported
      var speedTimer = null;   // long press: still counting down
      var speedOn = false;     // 2x while the finger stays down
      var armedUntil = 0;      // a tap just asked a player to start
      var armedStrict = false; // the tap was not on a player: only a new play counts
      var armTimer = null;     // polling for the video that tap started
      var lastTapX = 0, lastTapY = 0;
      var tapX = 0, tapY = 0, tapMoved = true;
      var frozenChild = null;  // top frame: dimensions reported by an iframe
      var soloEl = null;       // the picture while the page is hidden
      var hidden = [];         // [element, property, previous inline value]
      var pausedOthers = [];   // videos stopped so nothing plays behind

      function report(message) {
        try {
          window.webkit.messageHandlers.browserHttpVideo.postMessage(message);
        } catch (e) {}
      }

      // The element's own media URL. An MP4 has one; a blob-backed MSE player
      // hands the element a blob that no downloader can open, so fall back to
      // the newest manifest this frame fetched.
      function mediaUrl() {
        if (!video) { return ''; }
        var direct = video.currentSrc || video.src || '';
        if (direct && direct.indexOf('blob:') !== 0) { return direct; }
        var entries = [];
        try { entries = performance.getEntriesByType('resource') || []; }
        catch (e) { entries = []; }
        var file = '';
        for (var i = entries.length - 1; i >= 0; i -= 1) {
          var name = entries[i].name || '';
          if (/\.m3u8(?:$|[?#])/i.test(name)) { return name; }
          if (!file && /\.(?:mp4|m4v|webm|mov)(?:$|[?#])/i.test(name)) {
            file = name;
          }
        }
        return file;
      }

      // Every video this document owns, crossing open shadow roots: custom
      // players keep both the picture and their controls in there, and a
      // plain `querySelectorAll` stops at the boundary.
      function allVideos() {
        var list = [];
        function walk(root) {
          var found = [];
          try { found = root.querySelectorAll('video'); } catch (e) {}
          for (var i = 0; i < found.length; i += 1) { list.push(found[i]); }
          var nodes = [];
          try { nodes = root.querySelectorAll('*'); } catch (e) {}
          for (var j = 0; j < nodes.length; j += 1) {
            if (nodes[j].shadowRoot) { walk(nodes[j].shadowRoot); }
          }
        }
        walk(document);
        return list;
      }

      function onScreen(el) {
        if (!el || el.tagName !== 'VIDEO') { return false; }
        var rect = null;
        try { rect = el.getBoundingClientRect(); } catch (e) { return false; }
        if (!rect || rect.width < 40 || rect.height < 40) { return false; }
        var style = null;
        try { style = window.getComputedStyle(el); } catch (e) {}
        if (style && (style.visibility === 'hidden' ||
                      style.display === 'none' || style.opacity === '0')) {
          return false;
        }
        return true;
      }

      // The tap lands on a control bar, a poster layer or a click catcher, not
      // on the <video>. Pick the picture under the finger; the largest one wins
      // when two players overlap.
      function videoAt(x, y) {
        var list = allVideos();
        var best = null, bestArea = 0;
        for (var i = 0; i < list.length; i += 1) {
          var el = list[i];
          if (!onScreen(el)) { continue; }
          var rect = el.getBoundingClientRect();
          if (x < rect.left - 2 || x > rect.right + 2 ||
              y < rect.top - 2 || y > rect.bottom + 2) { continue; }
          var area = rect.width * rect.height;
          if (area > bestArea) { best = el; bestArea = area; }
        }
        return best;
      }

      // A control row that sits just outside the picture: take the nearest
      // visible player, but only within a player-looking box.
      function videoNearPoint(x, y) {
        var list = allVideos();
        var best = null, bestArea = 0;
        for (var i = 0; i < list.length; i += 1) {
          var el = list[i];
          if (!onScreen(el)) { continue; }
          var rect = el.getBoundingClientRect();
          var dx = Math.max(rect.left - x, 0, x - rect.right);
          var dy = Math.max(rect.top - y, 0, y - rect.bottom);
          if (dx > 160 || dy > 160) { continue; }
          var area = rect.width * rect.height;
          if (area > bestArea) { best = el; bestArea = area; }
        }
        return best;
      }

      // The video inside the tapped element's player box. The controls and the
      // picture usually share one wrapper a few levels up.
      function videoNear(node) {
        var step = node;
        for (var depth = 0; step && depth < 8; depth += 1) {
          if (step.nodeType === 1) {
            if (step.tagName === 'VIDEO') { return step; }
            var inner = null;
            try { inner = step.querySelector('video'); } catch (e) {}
            if (inner) { return inner; }
          }
          step = step.parentElement ||
                 (step.getRootNode && step.getRootNode().host);
        }
        return null;
      }

      function playerish(node) {
        var step = node;
        for (var depth = 0; step && depth < 8; depth += 1) {
          if (step.nodeType === 1) {
            var name = String(step.className || '') + ' ' +
                       String(step.id || '') + ' ' +
                       String(step.getAttribute('aria-label') || '');
            if (/(player|video|play|dplayer|jwplayer|prism|bpx|artplayer|xgplayer|vjs)/i.test(name)) {
              return true;
            }
          }
          step = step.parentElement ||
                 (step.getRootNode && step.getRootNode().host);
        }
        return false;
      }

      // Whether a video is the one the user meant. A tap inside the picture
      // claims it outright — muted or not; a pick from the same player box has
      // to look like a player, be playing, or fill the screen.
      function worthTaking(el, node, direct) {
        if (!el || el.tagName !== 'VIDEO') { return false; }
        if (direct) { return true; }
        if (!el.paused || el.controls) { return true; }
        if (playerish(el) || playerish(node)) { return true; }
        var rect = el.getBoundingClientRect();
        return rect.width * rect.height >=
               window.innerWidth * window.innerHeight * 0.2;
      }

      // Adopts a video found through something other than a direct hit. Inside
      // an iframe the frame reports upwards and the top document stretches the
      // frame; dimensions and the media URL travel with it so the host can
      // still read a frame and download the stream.
      function handOver(el) {
        if (isTop) { enter(el); return; }
        video = el;
        watch(el);
        stretch(el);
        try {
          savedControls = el.controls;
          el.controls = false;
        } catch (e) {}
        report({kind: 'enter', paused: !!el.paused,
                position: el.currentTime || 0,
                duration: isFinite(el.duration) ? el.duration : 0,
                width: el.videoWidth || 0, height: el.videoHeight || 0,
                url: mediaUrl(), referer: location.href});
        play(el);
        try {
          parent.postMessage({__soVideo: 'enter',
                              width: el.videoWidth || 0,
                              height: el.videoHeight || 0,
                              url: mediaUrl(),
                              referer: location.href}, '*');
        } catch (e) {}
      }

      // A player may create its <video>, or only call play(), after the tap
      // reaches it. For a moment after a tap this frame watches for a video
      // that starts playing, so the player still opens; autoplay on page load
      // has no tap behind it and never gets here.
      function checkArmed() {
        armTimer = null;
        if (theater && document.contains(theater)) { armedUntil = 0; return; }
        if (Date.now() > armedUntil) { return; }
        var tapped = videoAt(lastTapX, lastTapY);
        if (armedStrict && tapped && tapped.__soPlaying) { tapped = null; }
        if (tapped && tapped !== video && !tapped.paused && onScreen(tapped)) {
          armedUntil = 0;
          handOver(tapped);
          return;
        }
        var list = allVideos();
        var best = null, bestArea = 0;
        for (var i = 0; i < list.length; i += 1) {
          var el = list[i];
          if (el === video || el.paused || !onScreen(el)) { continue; }
          if (armedStrict && el.__soPlaying) { continue; }
          var rect = el.getBoundingClientRect();
          var area = rect.width * rect.height;
          if (area > bestArea) { best = el; bestArea = area; }
        }
        if (best) {
          armedUntil = 0;
          handOver(best);
          return;
        }
        armTimer = setTimeout(checkArmed, 120);
      }

      function armForPlay(strict) {
        armedStrict = !!strict;
        armedUntil = Date.now() + 3000;
        if (armedStrict) {
          var list = allVideos();
          for (var i = 0; i < list.length; i += 1) {
            list[i].__soPlaying = !list[i].paused;
          }
        }
        if (!armTimer) { armTimer = setTimeout(checkArmed, 120); }
      }

      function state() {
        if (!video) { return; }
        var message = {
          kind: 'state',
          paused: !!video.paused,
          position: video.currentTime || 0,
          duration: isFinite(video.duration) ? video.duration : 0,
          width: video.videoWidth || 0,
          height: video.videoHeight || 0
        };
        var url = mediaUrl();
        if (url && url !== lastUrl) {
          lastUrl = url;
          message.url = url;
        }
        report(message);
      }

      // The host shows where a horizontal drag is heading before it commits.
      function preview(position, duration) {
        var now = Date.now();
        if (now - lastPreview < 80) { return; }
        lastPreview = now;
        report({
          kind: 'seeking',
          paused: !!(video && video.paused),
          position: position,
          duration: duration
        });
      }

      function play(el) {
        try {
          var started = el.play();
          if (started && started.catch) { started.catch(function () {}); }
        } catch (e) {}
      }

      function distance(touches) {
        var dx = touches[0].clientX - touches[1].clientX;
        var dy = touches[0].clientY - touches[1].clientY;
        return Math.sqrt(dx * dx + dy * dy);
      }

      // Zoom and the pull-down preview share one transform on the picture.
      function applyTransform(dy) {
        if (!theater) { return; }
        var value = 'scale(' + zoom + ')';
        if (dy) { value = 'translate(0px, ' + dy + 'px) ' + value; }
        theater.style.setProperty('transform', value, 'important');
      }

      function snapBack() {
        if (!theater) { return; }
        theater.style.setProperty('transition',
                                 'transform 0.18s ease-out', 'important');
        applyTransform(0);
        setTimeout(function () {
          if (theater) { theater.style.removeProperty('transition'); }
        }, 240);
      }

      // A fixed element is still laid out inside its nearest ancestor with a
      // transform, a filter or containment — which is exactly how a player
      // frame is usually built. Those ancestors are neutralised for as long as
      // the window is up and put back byte for byte on the way out.
      function liftContainers(node) {
        releaseContainers();
        while (node && node.nodeType === 1) {
          var cs = null;
          try { cs = window.getComputedStyle(node); } catch (e) {}
          var will = cs ? String(cs.willChange || '') : '';
          if (cs && (cs.transform !== 'none' || cs.filter !== 'none' ||
                     cs.perspective !== 'none' ||
                     (cs.contain && cs.contain !== 'none') ||
                     will.indexOf('transform') >= 0 ||
                     will.indexOf('filter') >= 0)) {
            lifted.push([node, node.getAttribute('style') || '']);
            node.style.setProperty('transform', 'none', 'important');
            node.style.setProperty('filter', 'none', 'important');
            node.style.setProperty('perspective', 'none', 'important');
            node.style.setProperty('contain', 'none', 'important');
            node.style.setProperty('will-change', 'auto', 'important');
          }
          node = node.parentNode;
        }
      }

      function releaseContainers() {
        for (var i = 0; i < lifted.length; i += 1) {
          var entry = lifted[i];
          if (entry[1] === '') { entry[0].removeAttribute('style'); }
          else { entry[0].setAttribute('style', entry[1]); }
        }
        lifted = [];
      }

      // The picture is the page's own <video>, so whatever else the page
      // paints stays around it: recommendation rails, a second player, a
      // panel that wins on stacking order. Hiding every element beside the
      // path from the video to <body>, and blacking the page out, leaves
      // exactly one picture on screen. Inline values are put back on exit.
      function solo(el) {
        restoreSolo();
        soloEl = el;
        var step = el;
        while (step && step.nodeType === 1) {
          var holder = step.parentNode;
          if (holder && holder.children) {
            for (var i = 0; i < holder.children.length; i += 1) {
              var kid = holder.children[i];
              if (kid === step) { continue; }
              hidden.push([kid, 'visibility', kid.style.visibility]);
              kid.style.setProperty('visibility', 'hidden', 'important');
            }
          }
          step = step.parentElement ||
                 (step.getRootNode && step.getRootNode().host);
        }
        var root = document.documentElement;
        if (root) {
          hidden.push([root, 'background', root.style.background]);
          root.style.setProperty('background', '#000', 'important');
        }
        if (document.body) {
          hidden.push([document.body, 'background',
                       document.body.style.background]);
          document.body.style.setProperty('background', '#000', 'important');
        }
        // A page can run a second, muted video behind the player; hidden or
        // not, it must not keep drawing or sounding.
        var list = allVideos();
        for (var j = 0; j < list.length; j += 1) {
          var other = list[j];
          if (other === el || other.paused) { continue; }
          pausedOthers.push(other);
          try { other.pause(); } catch (e) {}
        }
      }

      function restoreSolo() {
        for (var i = 0; i < hidden.length; i += 1) {
          var entry = hidden[i];
          if (entry[2]) { entry[0].style.setProperty(entry[1], entry[2]); }
          else { entry[0].style.removeProperty(entry[1]); }
        }
        hidden = [];
        pausedOthers = [];
        soloEl = null;
      }

      function stretch(el) {
        if (!el || savedStyle !== null) { return; }
        savedStyle = el.getAttribute('style') || '';
        liftContainers(el.parentNode);
        // Fixed positioning leaves the page's layout and any clipping wrapper
        // behind; touch-action:none keeps our gestures instead of scrolling the
        // page under the video. 100vh: the host draws its control layer over
        // the picture, the way a normal player does.
        el.setAttribute('style', savedStyle + ';'
          + 'position:fixed!important;top:0!important;left:0!important;'
          + 'right:0!important;bottom:auto!important;'
          + 'width:100vw!important;height:100vh!important;'
          + 'min-width:0!important;min-height:0!important;'
          + 'max-width:none!important;max-height:none!important;'
          + 'margin:0!important;padding:0!important;'
          + 'transform:none!important;object-fit:contain!important;'
          + 'background:#000!important;z-index:2147483647!important;'
          + 'touch-action:none!important;'
          + '-webkit-user-select:none!important;'
          + '-webkit-touch-callout:none!important;');
        theater = el;
        solo(el);
      }

      function release() {
        if (theater) {
          if (savedStyle === '') { theater.removeAttribute('style'); }
          else { theater.setAttribute('style', savedStyle); }
        }
        theater = null;
        savedStyle = null;
        releaseContainers();
        restoreSolo();
      }

      function stop() {
        if (video) { try { video.pause(); } catch (e) {} }
      }

      // Watch one element. Position updates arrive four times a second, the
      // pace a progress bar needs; the rest pin the bar to real playback.
      function watch(el) {
        if (el.__soVideoWatched) { return; }
        el.__soVideoWatched = true;
        var names = ['play', 'pause', 'seeked', 'ended', 'loadedmetadata'];
        for (var i = 0; i < names.length; i += 1) {
          el.addEventListener(names[i], function () {
            if (el === video) { state(); }
          }, false);
        }
        el.addEventListener('timeupdate', function () {
          if (el === video) { state(); }
        }, false);
      }

      function enter(el) {
        video = el;
        watch(el);
        stretch(el);
        // WebKit's own controls would sit under the host's control layer and
        // answer the same taps twice.
        try {
          savedControls = el.controls;
          el.controls = false;
        } catch (e) {}
        report({kind: 'enter', paused: !!el.paused,
                position: el.currentTime || 0,
                duration: isFinite(el.duration) ? el.duration : 0,
                width: el.videoWidth || 0, height: el.videoHeight || 0,
                url: mediaUrl()});
        play(el);
      }

      // Closes this frame's window. A frame under an iframe theater leaves the
      // reporting to the top document, which owns the iframe's style.
      function leave(reportExit) {
        cancelSpeed();
        endSpeed();
        stop();
        if (theater && savedControls !== null) {
          try { theater.controls = savedControls; } catch (e) {}
        }
        savedControls = null;
        zoom = 1;
        mode = '';
        moved = false;
        lastUrl = '';
        armedUntil = 0;
        armedStrict = false;
        if (armTimer) { clearTimeout(armTimer); armTimer = null; }
        release();
        if (reportExit !== false) { report({kind: 'exit'}); }
      }

      function close() {
        if (!isTop) {
          leave(false);
          try { parent.postMessage({__soVideo: 'exit'}, '*'); } catch (e) {}
          return;
        }
        if (child) {
          var inner = child;
          child = null;
          try { inner.postMessage({__soVideo: 'exit'}, '*'); } catch (e) {}
        }
        leave(true);
      }

      function seekTo(el, to) {
        var end = isFinite(el.duration) ? el.duration : 0;
        var target = Math.max(0, to);
        if (end > 0) { target = Math.min(target, Math.max(0, end - 0.25)); }
        try { el.currentTime = target; } catch (e) {}
        state();
      }

      function seek(el, by) {
        seekTo(el, (el.currentTime || 0) + by);
      }

      function toggle(el) {
        if (el.paused) { play(el); } else { try { el.pause(); } catch (e) {} }
        state();
      }

      // A long press while the picture is playing holds it at 2x. Every way
      // out of the hold goes through endSpeed(), so the rate can never stay
      // doubled after the finger is gone.
      function cancelSpeed() {
        if (speedTimer) { clearTimeout(speedTimer); speedTimer = null; }
      }

      function beginSpeed() {
        speedTimer = null;
        if (!video || video.paused) { return; }
        speedOn = true;
        moved = true;
        suppressUntil = Date.now() + 600;
        try { video.playbackRate = 2; } catch (e) {}
        report({kind: 'speed', rate: 2});
      }

      function endSpeed() {
        if (!speedOn) { return; }
        speedOn = false;
        if (video) { try { video.playbackRate = 1; } catch (e) {} }
        report({kind: 'speed', rate: 1});
      }

      // Players built from custom elements keep the video behind a shadow
      // root, where `target` has already been retargeted to the host; the
      // composed path still names the real element.
      function videoOf(node, event) {
        if (event && event.composedPath) {
          var path = event.composedPath();
          for (var i = 0; i < path.length; i += 1) {
            var step = path[i];
            if (step && step.nodeType === 1 && step.tagName === 'VIDEO') {
              return step;
            }
          }
        }
        while (node && node.nodeType === 1) {
          if (node.tagName === 'VIDEO') { return node; }
          node = node.parentNode;
        }
        return null;
      }

      // A tap on the playing picture is the host's show/hide switch. A tap on
      // the page before the window exists is the only way in — and it does not
      // have to land on the <video> itself: HLS players draw their own control
      // bar over it, so the picture under the finger (or in the same player
      // box) is what gets taken over.
      document.addEventListener('click', function (e) {
        if (theater && document.contains(theater)) {
          if (Date.now() < suppressUntil) { return; }
          if (e.cancelable) { e.preventDefault(); }
          e.stopPropagation();
          report({kind: 'tap'});
          return;
        }
        if (theater) { leave(false); }
        var el = videoOf(e.target, e);
        if (!el) {
          // A picture under the finger: that is the player, whatever element
          // the tap actually landed on (its own control bar, a title layer).
          if (videoAt(e.clientX, e.clientY)) {
            if (e.cancelable) { e.preventDefault(); }
            e.stopPropagation();
            handOver(videoAt(e.clientX, e.clientY));
            return;
          }
          // Anywhere else the page keeps working: tapping an author name or a
          // description is a link, not a play button. The watch only opens the
          // window if this very tap starts a video that was paused; a wrapper
          // that merely has "video" in its class never counts.
          lastTapX = e.clientX;
          lastTapY = e.clientY;
          armForPlay(true);
          return;
        }
        // The tap means "play this here". Letting the page see the same click
        // would let a click-to-toggle player undo the play() below inside the
        // same event, leaving the window open and paused.
        if (e.cancelable) { e.preventDefault(); }
        e.stopPropagation();
        if (isTop) {
          enter(el);
          return;
        }
        video = el;
        watch(el);
        stretch(el);
        try {
          savedControls = el.controls;
          el.controls = false;
        } catch (err) {}
        report({kind: 'enter', paused: !!el.paused,
                position: el.currentTime || 0,
                duration: isFinite(el.duration) ? el.duration : 0,
                width: el.videoWidth || 0, height: el.videoHeight || 0,
                url: mediaUrl(), referer: location.href});
        play(el);
        try {
          parent.postMessage({__soVideo: 'enter',
                              width: el.videoWidth || 0,
                              height: el.videoHeight || 0,
                              url: mediaUrl(),
                              referer: location.href}, '*');
        } catch (err) {}
      }, true);

      window.addEventListener('message', function (e) {
        var data = e.data;
        if (!data || !data.__soVideo) { return; }
        if (data.__soVideo === 'enter') {
          if (!isTop) { return; }
          child = e.source;
          var frames = document.getElementsByTagName('iframe');
          for (var i = 0; i < frames.length; i += 1) {
            if (frames[i].contentWindow === e.source) {
              stretch(frames[i]);
              break;
            }
          }
          report({kind: 'enter', paused: false, position: 0, duration: 0,
                  width: data.width || 0, height: data.height || 0,
                  url: data.url || '', referer: data.referer || ''});
          return;
        }
        if (data.__soVideo === 'frozen') {
          if (isTop) {
            frozenChild = {width: data.width || 0, height: data.height || 0};
          }
          return;
        }
        if (data.__soVideo === 'exit') {
          frozenChild = null;
          if (isTop) {
            child = null;
            release();
            report({kind: 'exit'});
          } else if (video) {
            leave(false);
          }
          return;
        }
        if (!isTop && data.__soVideo === 'capture') {
          var size = null;
          try { size = window.__soFreezeFrame ? window.__soFreezeFrame() : ''; }
          catch (e) { size = ''; }
          if (size) {
            var dims = null;
            try { dims = JSON.parse(size); } catch (e) { dims = null; }
            if (dims) {
              try {
                parent.postMessage({__soVideo: 'frozen',
                                    width: dims.width || 0,
                                    height: dims.height || 0}, '*');
              } catch (e) {}
            }
          }
          return;
        }
        if (!isTop && data.__soVideo === 'unfreeze') {
          if (window.__soUnfreezeFrame) { window.__soUnfreezeFrame(); }
          return;
        }
        if (!isTop && video) {
          if (data.__soVideo === 'seekBy') { seek(video, data.by || 0); }
          else if (data.__soVideo === 'seekTo') { seekTo(video, data.to || 0); }
          else if (data.__soVideo === 'toggle') { toggle(video); }
        }
      }, false);

      // A player's native control bar may start playback without dispatching
      // a click to the page. A short tap that lands on a picture (or on a
      // player box) arms the same watcher; a scroll never does, so dragging
      // the page cannot pop the window open.
      document.addEventListener('touchstart', function (e) {
        if (theater || e.touches.length !== 1) { return; }
        tapX = e.touches[0].clientX;
        tapY = e.touches[0].clientY;
        tapMoved = false;
      }, {passive: true, capture: true});

      document.addEventListener('touchmove', function (e) {
        if (theater || e.touches.length !== 1) { return; }
        var touch = e.touches[0];
        if (Math.abs(touch.clientX - tapX) > 12 ||
            Math.abs(touch.clientY - tapY) > 12) { tapMoved = true; }
      }, {passive: true, capture: true});

      document.addEventListener('touchend', function (e) {
        if (theater || tapMoved) { return; }
        lastTapX = tapX;
        lastTapY = tapY;
        armForPlay(!videoAt(tapX, tapY));
      }, {passive: true, capture: true});

      // Some players start the video from a touch handler and swallow the
      // click. A play event inside the armed window still opens the window.
      document.addEventListener('play', function (e) {
        if (theater && document.contains(theater)) { return; }
        if (Date.now() > armedUntil) { return; }
        var el = videoOf(null, e);
        if (!el || !onScreen(el)) { return; }
        armedUntil = 0;
        handOver(el);
      }, true);

      document.addEventListener('touchstart', function (e) {
        if (!theater) { return; }
        if (e.touches.length >= 2) {
          cancelSpeed();
          mode = 'pinch';
          pinchStart = distance(e.touches);
          pinchBase = zoom;
          moved = true;
          return;
        }
        if (e.touches.length !== 1) { return; }
        mode = '';
        moved = false;
        lastDy = 0;
        startX = e.touches[0].clientX;
        startY = e.touches[0].clientY;
        startTime = video ? (video.currentTime || 0) : 0;
        cancelSpeed();
        if (video && !video.paused) {
          speedTimer = setTimeout(beginSpeed, 420);
        }
      }, {passive: true, capture: true});

      document.addEventListener('touchmove', function (e) {
        if (!theater) { return; }
        if (speedOn) {
          if (e.cancelable) { e.preventDefault(); }
          return;
        }
        if (e.touches.length >= 2) {
          if (e.cancelable) { e.preventDefault(); }
          moved = true;
          if (mode !== 'pinch') {
            mode = 'pinch';
            pinchStart = distance(e.touches);
            pinchBase = zoom;
          }
          if (pinchStart > 0) {
            zoom = Math.min(3,
                Math.max(1, pinchBase * distance(e.touches) / pinchStart));
            applyTransform(0);
          }
          return;
        }
        if (mode === 'pinch' || e.touches.length !== 1) { return; }
        var touch = e.touches[0];
        var dx = touch.clientX - startX;
        var dy = touch.clientY - startY;
        if (!moved && Math.abs(dx) < 10 && Math.abs(dy) < 10) { return; }
        moved = true;
        cancelSpeed();
        if (mode === '') {
          if (Math.abs(dx) > Math.abs(dy)) { mode = 'seek'; }
          else if (dy > 0) { mode = 'exit'; }
          else { mode = 'none'; }
        }
        if (mode === 'seek') {
          if (e.cancelable) { e.preventDefault(); }
          var end = video && isFinite(video.duration) ? video.duration : 0;
          if (end > 0) {
            // A full screen width is two minutes; the bar shows the target
            // before the finger lifts.
            seekTarget = Math.max(0, Math.min(end,
                startTime + (dx / Math.max(1, window.innerWidth)) * 120));
            preview(seekTarget, end);
          }
        } else if (mode === 'exit') {
          if (e.cancelable) { e.preventDefault(); }
          lastDy = dy;
          applyTransform(Math.max(0, dy));
        }
      }, {passive: false, capture: true});

      document.addEventListener('touchend', function (e) {
        if (!theater) { return; }
        cancelSpeed();
        endSpeed();
        if (mode === 'pinch') {
          if (e.touches.length === 0) {
            mode = '';
            moved = false;
            suppressUntil = Date.now() + 350;
          }
          return;
        }
        if (e.touches.length > 0) { return; }
        if (mode === 'seek' && video) {
          seekTo(video, seekTarget);
        } else if (mode === 'exit') {
          if (lastDy > 96) { close(); }
          else { snapBack(); }
        }
        if (moved) { suppressUntil = Date.now() + 350; }
        mode = '';
        moved = false;
      }, {passive: true, capture: true});

      document.addEventListener('touchcancel', function () {
        cancelSpeed();
        endSpeed();
        if (mode === 'pinch' || mode === 'exit') { snapBack(); }
        mode = '';
        moved = false;
      }, {passive: true, capture: true});

      // A long hold must not raise WebKit's own menu over our picture.
      document.addEventListener('contextmenu', function (e) {
        if (theater) { e.preventDefault(); }
      }, true);

      // The system player must stay out of reach even if a page asks for it
      // directly: it is the thing that reappears over the page on its own.
      try {
        HTMLVideoElement.prototype.webkitEnterFullscreen = function () {};
        HTMLVideoElement.prototype.webkitExitFullscreen = function () {};
        HTMLVideoElement.prototype.webkitSetPresentationMode = function () {};
      } catch (e) {}
      // A page that takes its container full screen on its own would leave the
      // host's controls underneath the system player. The window it gets here
      // is the app's player, so these entry points do nothing.
      try {
        Element.prototype.requestFullscreen = function () {
          return Promise.reject(new Error('handled by host'));
        };
        Element.prototype.webkitRequestFullscreen = function () {};
        HTMLVideoElement.prototype.requestFullscreen = function () {
          return Promise.reject(new Error('handled by host'));
        };
      } catch (e) {}

      window.addEventListener('pagehide', function () {
        if (!theater) { return; }
        report({kind: 'exit'});
        // A frame under an iframe theater must let the top document put the
        // iframe back, or the frame would stay stretched over the page.
        if (!isTop) {
          try { parent.postMessage({__soVideo: 'exit'}, '*'); } catch (e) {}
        }
      });

      // When the canvas cannot be read back (a cross-origin stream taints it),
      // the frame is still drawn into a full-screen canvas and left on the
      // page: the host photographs the page, where the picture is now ordinary
      // page content, and the video layer is not involved. The host removes
      // the overlay as soon as the snapshot is taken.
      window.__soFreezeFrame = function () {
        if (child) {
          // The picture lives in a cross-origin frame: only that frame can
          // draw it. Ask it to freeze and let the host poll for the answer.
          frozenChild = null;
          try { child.postMessage({__soVideo: 'capture'}, '*'); } catch (e) {}
          return 'pending';
        }
        if (!video || !video.videoWidth || !video.videoHeight) { return ''; }
        if (video.readyState < 2) { return ''; }
        var width = video.videoWidth, height = video.videoHeight;
        var canvas = document.createElement('canvas');
        canvas.width = width;
        canvas.height = height;
        var context = null;
        try { context = canvas.getContext('2d', {willReadFrequently: true}); }
        catch (e) {}
        if (!context) {
          try { context = canvas.getContext('2d'); } catch (e) {}
        }
        if (!context) { return ''; }
        try { context.drawImage(video, 0, 0, width, height); }
        catch (e) { return ''; }
        var old = document.getElementById('__soFrozenFrame');
        if (old && old.parentNode) {
          try { if (old.close) { old.close(); } } catch (e) {}
          old.parentNode.removeChild(old);
        }
        var holder = null;
        try { holder = document.createElement('dialog'); } catch (e) {}
        if (!holder) { holder = document.createElement('div'); }
        holder.id = '__soFrozenFrame';
        holder.setAttribute('style',
          'position:fixed!important;top:0!important;left:0!important;' +
          'right:0!important;bottom:0!important;width:100vw!important;' +
          'height:100vh!important;max-width:none!important;' +
          'max-height:none!important;margin:0!important;padding:0!important;' +
          'border:0!important;border-radius:0!important;' +
          'background:#000!important;z-index:2147483647!important;' +
          'display:flex!important;align-items:center!important;' +
          'justify-content:center!important;overflow:hidden!important;' +
          'pointer-events:none!important;');
        canvas.setAttribute('style',
          'max-width:100%!important;max-height:100%!important;' +
          'width:auto!important;height:auto!important;' +
          'margin:0!important;padding:0!important;display:block!important;');
        holder.appendChild(canvas);
        document.documentElement.appendChild(holder);
        if (holder.showModal) {
          try { holder.showModal(); } catch (e) {}
        }
        return JSON.stringify({width: width, height: height});
      };

      window.__soUnfreezeFrame = function () {
        var holder = document.getElementById('__soFrozenFrame');
        if (holder && holder.close) { try { holder.close(); } catch (e) {} }
        if (holder && holder.parentNode) { holder.parentNode.removeChild(holder); }
        if (child) {
          try { child.postMessage({__soVideo: 'unfreeze'}, '*'); } catch (e) {}
        }
        frozenChild = null;
      };

      // The host polls this after asking an iframe to freeze: '' until the
      // frame says its picture is ready, then "width,height".
      window.__soFrozenSize = function () {
        if (!frozenChild) { return ''; }
        return frozenChild.width + ',' + frozenChild.height;
      };

      // Reading a frame from the element is the only way to get the picture
      // itself: a WebView snapshot sees the composited layers, and the video
      // layer is not one of them. A cross-origin file taints the canvas, so
      // this returns nothing and the host freezes the page or decodes the
      // stream instead.
      window.__soCaptureFrame = function () {
        if (!video || !video.videoWidth || !video.videoHeight) { return ''; }
        if (video.readyState < 2) { return ''; }
        var width = video.videoWidth, height = video.videoHeight;
        var scale = Math.min(1, 1920 / Math.max(width, height));
        var canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(width * scale));
        canvas.height = Math.max(1, Math.round(height * scale));
        var context = null;
        try { context = canvas.getContext('2d'); } catch (e) {}
        if (!context) { return ''; }
        try {
          context.drawImage(video, 0, 0, canvas.width, canvas.height);
        } catch (e) { return ''; }
        try { return canvas.toDataURL('image/jpeg', 0.95); }
        catch (e) { return ''; }
      };

      window.__soVideo = {
        seekBy: function (seconds) {
          if (child) {
            try { child.postMessage({__soVideo: 'seekBy', by: seconds}, '*'); }
            catch (e) {}
            return;
          }
          if (video) { seek(video, seconds); }
        },
        seekTo: function (seconds) {
          if (child) {
            try { child.postMessage({__soVideo: 'seekTo', to: seconds}, '*'); }
            catch (e) {}
            return;
          }
          if (video) { seekTo(video, seconds); }
        },
        toggle: function () {
          if (child) {
            try { child.postMessage({__soVideo: 'toggle'}, '*'); } catch (e) {}
            return;
          }
          if (video) { toggle(video); }
        },
        close: function () { close(); }
      };
    })();
    """#

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
