# So~

A small iOS test browser built on **browser_http** (the app is named `So~`,
`CFBundleDisplayName`/`CFBundleName` are patched in the build). It browses with
a real `WKWebView` and, on demand, replays the current URL through the native
fingerprint engine so you can inspect the actual request/response metadata.

## What it shows

- **URL bar** — no separate app header: back / forward, an always-editable URL
  field with a clear button and a Go action that turns into Reload when the
  field is not focused, plus settings and Eruda buttons.
- **Request headers** — a settings sheet with User-Agent presets (Safari,
  Chrome, Edge, Firefox on phone and desktop), Referer (none or current
  origin), a custom Cookie string, an info-panel switch and a "Stay in this
  app" switch. Save applies the headers and reloads the page so the next
  request carries them; the two switches apply immediately.
- **Info panel** — a resizable bottom panel with four tabs:
  - **WebView** — main-frame URL, title, HTTP status, history flags, the page's
    `PerformanceResourceTiming` entries and the shared cookie jar. WebKit does
    not expose subresource headers or bodies to host apps.
  - **Engine** — `BrowserSession.capture(currentUrl)` through the Rust
    (wreq/BoringSSL) transport: ordered request headers including the shared
    cookie jar's `Cookie`, profile user-agent/client hints, response status,
    ordered response headers, elapsed time, body size and preview. Copy as
    cURL, copy headers/bodies or re-send the request.
  - **Page** — `fetch` / `XMLHttpRequest` / `navigator.sendBeacon` calls
    observed by a `WKUserScript` injected at document start. This is how POST
    bodies and caller headers become visible: WebKit never hands them to
    `WKNavigationDelegate`. Tap a row to inspect method, URL, request headers,
    request body, response status, response headers, timing and a truncated
    response body (small textual responses only), then copy it as cURL or
    replay it through the native engine.
  - **Log** — live `RequestLogEvent`s (start / redirect / response / error)
    with All / Warn / Error filters and a clear action. Every navigation the
    WebView decides on is reported from Swift over `browser_http/webview`, so
    page loads, redirects, committed pages and blocked app jumps all show up
    here.
- **Eruda** — the toolbar's terminal button overlays a half-screen eruda
  console above the WebView; drag its pill to change the split and tap the
  circle in the pill to close it. The console lives in a `WKUserScript`
  registered at document end, so it survives every navigation and is only
  closed by that button; each page load prints
  `[跳转] <new url> ← <referrer>` into the console. The bundle is shipped as an
  asset in CI with a CDN fallback.

## Staying inside the app

`WKNavigationDelegate.decidePolicyFor navigationAction` owns the policy:

- Custom schemes (`baiduboxapp://`, `weixin://`, `tel:`, …) are cancelled and
  logged as a blocked jump, so a page can never hand the URL to another app.
- Link taps and form submissions that would leave as a Universal Link are
  cancelled and re-loaded from code, which is never the continuation of a user
  gesture — the tap stays in the WebView.
- Loads started by the app itself are registered in a small allow-set first, so
  they run once as ordinary in-app navigations.

Both behaviours are switchable in the settings sheet ("Stay in this app") and
take effect without a reload.

Both engines use the same persistent `WKWebsiteDataStore`, so cookies obtained
by browsing are reused by the native capture and vice versa.

## Repository layout

```
simplebrowser/
├── lib/main.dart              # browser app: toolbar, info panel, Eruda overlay
├── lib/settings_sheet.dart    # request identity + panel switch bottom sheet
├── lib/request_format.dart    # cURL builder and response-body previews
├── lib/theme.dart             # palette and Material theme
├── assets/eruda/              # eruda.js downloaded in CI (placeholder kept)
├── assets/appicon/            # iOS icon set copied into the generated project
├── browser_http/              # vendored plugin (Dart + Swift + Rust)
├── .github/workflows/ios.yml  # unsigned IPA -> GitHub Releases
└── pubspec.yaml
```

`ios/` is not committed. CI generates it with `flutter create`, copies
`assets/appicon/` into the fresh `AppIcon.appiconset`, and then compiles the
Rust core through the plugin's CocoaPods script phase.

## Build the IPA on GitHub

The workflow only runs on `workflow_dispatch`, so pushing commits builds
nothing by itself.

1. Push this directory to a GitHub repository (default branch `main`).
2. Actions → **Build iOS IPA** → **Run workflow**.
3. When it finishes, download `so-<version>.ipa` from the run artifacts or from
   the matching release.

The workflow needs no signing secrets: it builds with code signing disabled.
Install the IPA on a device with a sideloading tool (AltStore, Sideloadly,
TrollStore, etc.) or re-sign it with your own certificate.

The same steps run locally against a macOS host over SSH: `flutter create` the
`ios/` project, patch the deployment target and `Info.plist` (name `So~`,
`NSAllowsArbitraryLoads`), `pod install`, add
`-Wl,-force_load,"${BUILT_PRODUCTS_DIR}/libbrowser_http_core.a"` to
`Release.xcconfig`, then `xcodebuild` with signing off. It needs `cargo` with
the three iOS targets, `go`, `cmake` and Xcode, because the CocoaPods script
phase compiles the Rust core. The first build is slow because BoringSSL is
compiled from source; later runs reuse `browser_http/rust/target`.

## Notes

- The plugin declares iOS **15.0**; the workflow raises the generated app's
  deployment target to match.
- `NSAllowsArbitraryLoads` is enabled in CI so plain `http://` pages work in
  the WebView and the native engine.
- To update the vendored library, replace `browser_http/` with a newer copy and
  run `flutter pub get`.
