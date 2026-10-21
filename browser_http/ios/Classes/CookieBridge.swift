import Foundation
import Flutter
import WebKit

/// Bridges `CookiePort` to `WKHTTPCookieStore`.
///
/// The WebView-based bridge uses the same persistent `WKWebsiteDataStore`, so
/// challenge clearances and native requests share one cookie jar.
final class CookieBridge {
    private let store = WKWebsiteDataStore.default().httpCookieStore

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "get":
            guard let url = url(from: args) else {
                result(FlutterError(code: "invalid_argument", message: "missing url", details: nil))
                return
            }
            store.getAllCookies { cookies in
                let matching = cookies.filter { Self.matches($0, url) }
                result(matching.map(Self.encode))
            }

        case "setAll", "merge":
            guard let url = url(from: args),
                  let raw = args["cookies"] as? [[String: Any]] else {
                result(FlutterError(code: "invalid_argument", message: "missing url/cookies", details: nil))
                return
            }
            store.getAllCookies { existing in
                let incoming = raw.compactMap { Self.decode($0, url: url) }
                let incomingKeys = Set(incoming.map(Self.key))
                let group = DispatchGroup()
                for cookie in existing where Self.matches(cookie, url) {
                    if call.method == "setAll" || incomingKeys.contains(Self.key(cookie)) {
                        group.enter()
                        self.store.delete(cookie) { group.leave() }
                    }
                }
                for cookie in incoming {
                    // An already-expired cookie (Max-Age=0) is a deletion. The
                    // cookie store drops it, so do not write it back.
                    if let expires = cookie.expiresDate, expires <= Date() {
                        continue
                    }
                    group.enter()
                    self.store.setCookie(cookie) { group.leave() }
                }
                // Reply only once the store is consistent; the next native
                // request reads it immediately.
                group.notify(queue: .main) { result(nil) }
            }

        case "removeAll":
            guard let url = url(from: args) else {
                result(FlutterError(code: "invalid_argument", message: "missing url", details: nil))
                return
            }
            store.getAllCookies { cookies in
                let group = DispatchGroup()
                for cookie in cookies where Self.matches(cookie, url) {
                    group.enter()
                    self.store.delete(cookie) { group.leave() }
                }
                group.notify(queue: .main) { result(nil) }
            }

        case "clear":
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            WKWebsiteDataStore.default().removeData(
                ofTypes: types, modifiedSince: .distantPast) {
                result(nil)
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func url(from args: [String: Any]) -> URL? {
        (args["url"] as? String).flatMap(URL.init(string:))
    }

    private static func matches(_ cookie: HTTPCookie, _ url: URL) -> Bool {
        guard let host = url.host else { return false }
        let domain = cookie.domain.hasPrefix(".")
            ? String(cookie.domain.dropFirst())
            : cookie.domain
        let hostMatches = host == domain || host.hasSuffix(".\(domain)")
        let pathMatches = url.path.hasPrefix(cookie.path)
        return hostMatches && pathMatches
    }

    private static func key(_ cookie: HTTPCookie) -> String {
        "\(cookie.name)@\(cookie.domain)\(cookie.path)"
    }

    private static func encode(_ cookie: HTTPCookie) -> [String: Any] {
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
        if let sameSite = cookie.sameSitePolicy?.rawValue {
            dict["sameSite"] = sameSite
        }
        return dict
    }

    private static func decode(_ dict: [String: Any], url: URL) -> HTTPCookie? {
        guard let name = dict["name"] as? String,
              let value = dict["value"] as? String else { return nil }

        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: (dict["domain"] as? String) ?? url.host ?? "",
            .path: (dict["path"] as? String) ?? "/",
        ]
        if dict["secure"] as? Bool == true { properties[.secure] = "TRUE" }
        // Note: HTTPCookie exposes no public HttpOnly property, so cookies
        // restored through HTTPCookie(properties:) lose that flag. Clearance
        // cookies are re-issued by the server; document this in the README.
        if let raw = dict["sameSite"] as? String,
           HTTPCookieStringPolicy(rawValue: raw) != nil {
            properties[.sameSitePolicy] = raw
        }
        if let raw = dict["expires"] as? String,
           let date = ISO8601DateFormatter().date(from: raw) {
            properties[.expires] = date
        }
        return HTTPCookie(properties: properties)
    }
}
