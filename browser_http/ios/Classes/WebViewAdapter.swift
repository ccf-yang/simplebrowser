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
            holder.webView.load(request(for: url, headers: args["headers"]))
            result(nil)

        case "setUserAgent":
            guard let holder = session(args, result) else { return }
            holder.webView.customUserAgent = args["userAgent"] as? String
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
    private var loadCompletion: ((Error?) -> Void)?
    fileprivate var lastStatusCode: Int?

    private static let networkHandlerName = "browserHttpNet"

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
        let controller = webView.configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: WebViewHolder.networkScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))
        controller.add(
            WeakScriptMessageHandler(delegate: self),
            name: WebViewHolder.networkHandlerName)

        // Visible WebViews are user-driven (challenge page or browser tab);
        // swipe back/forward should behave like Safari.
        webView.allowsBackForwardNavigationGestures = !headless
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
            webView.load(navigationAction.request)
        }
        return nil
    }

    func load(_ url: URL, completion: @escaping (Error?) -> Void) {
        load(URLRequest(url: url), completion: completion)
    }

    func load(_ request: URLRequest, completion: @escaping (Error?) -> Void) {
        lastStatusCode = nil
        loadCompletion = completion
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
