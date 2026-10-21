# SimpleBrowser

A small iOS test browser built on **browser_http**. It browses with a real
`WKWebView` and, on demand, replays the current URL through the native
fingerprint engine so you can inspect the actual request/response metadata.

## What it shows

- **URL bar** — Go / back / forward / reload. Links are clicked inside the
  WKWebView itself (real user navigation).
- **WebView tab** — main-frame URL, title, HTTP status, history flags and the
  page's `PerformanceResourceTiming` entries. WebKit does not expose
  subresource headers or bodies to host apps.
- **Engine tab** — `BrowserSession.capture(currentUrl)` through the Rust
  (wreq/BoringSSL) transport: ordered request headers including the shared
  cookie jar's `Cookie`, profile user-agent/client hints, response status,
  ordered response headers, elapsed time, body size and preview.
- **Log tab** — live `RequestLogEvent`s (start / redirect / response / error).

Both engines use the same persistent `WKWebsiteDataStore`, so cookies obtained
by browsing are reused by the native capture and vice versa.

## Repository layout

```
simplebrowser/
├── lib/main.dart              # the browser app
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
