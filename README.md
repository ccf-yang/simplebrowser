# SimpleBrowser

A small iOS test browser built on **browser_http**. It browses with a real
`WKWebView` and, on demand, replays the current URL through the native
fingerprint engine so you can inspect the actual request/response metadata.

## What it shows

- **URL bar** — no separate app header: back / forward, an always-editable URL
  field with a clear button and a Go action that turns into Reload when the
  field is not focused, plus settings and Eruda buttons.
- **Request headers** — a settings sheet with User-Agent presets (Safari,
  Chrome, Edge, Firefox on phone and desktop), Referer (none or current
  origin), a custom Cookie string and an info-panel switch. Save applies the
  headers and reloads the page so the next request carries them.
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
    with All / Warn / Error filters and a clear action.
- **Eruda** — the toolbar's terminal button overlays a half-screen eruda
  console above the WebView; drag its pill to change the split and tap the
  button again to close it. The bundle is shipped as an asset in CI with a CDN
  fallback.

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

1. Push this directory to a GitHub repository (default branch `main`).
2. Actions → **Build iOS IPA** → **Run workflow**.
3. When it finishes, download `simplebrowser-unsigned.ipa` from the run artifacts or
   from the `v0.1.0-1` release.

The workflow needs no signing secrets: it builds with code signing disabled.
Install the IPA on a device with a sideloading tool (AltStore, Sideloadly,
TrollStore, etc.) or re-sign it with your own certificate.

The first build is slow because BoringSSL is compiled from source; later runs
reuse the Rust cache.

## Notes

- The plugin declares iOS **15.0**; the workflow raises the generated app's
  deployment target to match.
- `NSAllowsArbitraryLoads` is enabled in CI so plain `http://` pages work in
  the WebView and the native engine.
- To update the vendored library, replace `browser_http/` with a newer copy and
  run `flutter pub get`.
