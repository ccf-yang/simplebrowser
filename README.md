# SimpleBrowser

A small iOS test browser built on **browser_http**. It browses with a real
`WKWebView` and, on demand, replays the current URL through the native
fingerprint engine so you can inspect the actual request/response metadata.

## What it shows

- **URL bar** — no separate app header: back / forward / reload, an editable URL
  field with a clear button and Go action, and a request-header toggle.
- **Request headers** — optional User-Agent presets (Safari, Chrome, Edge,
  Firefox on phone and desktop), Referer (none or current origin) and a custom
  Cookie string. Save applies them and reloads the page so the next request
  carries the new headers.
- **WebView tab** — main-frame URL, title, HTTP status, history flags and the
  page's `PerformanceResourceTiming` entries. WebKit does not expose
  subresource headers or bodies to host apps.
- **Engine tab** — `BrowserSession.capture(currentUrl)` through the Rust
  (wreq/BoringSSL) transport: ordered request headers including the shared
  cookie jar's `Cookie`, profile user-agent/client hints, response status,
  ordered response headers, elapsed time, body size and preview.
- **Log tab** — live `RequestLogEvent`s (start / redirect / response / error).
- **Floating DevTools** — a semi-transparent circular button over the WebView
  opens an eruda-style dark panel with **网络 / 日志 / 页面** tabs. The network
  tab lists two kinds of rows:
  - **页面脚本请求** — `fetch` / `XMLHttpRequest` / `navigator.sendBeacon` calls
    observed by a `WKUserScript` injected at document start. This is how POST
    bodies and caller headers become visible: WebKit never hands them to
    `WKNavigationDelegate`. Tap one to inspect method, URL, request headers,
    request body, response status, response headers, timing and a truncated
    response body (small textual responses only), then copy it as cURL or replay
    it through the native engine.
  - **原生回放** — the current URL replayed through the Rust transport.

  The network tab keeps a history of captured packets; tap one to inspect the
  request line, ordered request headers (including the shared jar's `Cookie`),
  request body, actual identity, response headers and response body separately.
  Actions: copy as cURL, copy URL, copy request headers, copy request/response
  body and re-send the request. It auto-captures the current URL when opened and
  whenever the WebView navigates. Drag the panel's top handle to resize it.
  Tapping the button again closes the panel, clears the collected packets/logs
  and reloads the current page.
- **Resizable panel** — drag the divider above the tabs to resize the
  WebView/Engine/Log area.

Both engines use the same persistent `WKWebsiteDataStore`, so cookies obtained
by browsing are reused by the native capture and vice versa.

## Repository layout

```
simplebrowser/
├── lib/main.dart              # the browser app
├── lib/dev_panel.dart         # eruda-style floating DevTools panel
├── browser_http/              # vendored plugin (Dart + Swift + Rust)
├── .github/workflows/ios.yml  # unsigned IPA -> GitHub Releases
└── pubspec.yaml
```

`ios/` is not committed. CI generates it with `flutter create` and then
compiles the Rust core through the plugin's CocoaPods script phase.

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
