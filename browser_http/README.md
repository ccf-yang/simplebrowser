# browser_http

Browser-faithful HTTP client for Flutter on **iOS**.

It is not a browser engine. It is a two-engine design:

- **Native transport** (Rust + wreq/BoringSSL) — real TLS (JA3/JA4) and
  HTTP/2 fingerprints, ordered headers, cookie jar, proxy support.
- **WKWebView bridge** (Swift) — runs real JavaScript, hands interactive
  Cloudflare/Turnstile challenges to the user, and exports the resulting
  identity (cookies + localStorage + UA + client hints) back to the session.

The session keeps the two engines *consistent*, which is what makes challenge
results reusable by subsequent native requests.

## Status

`0.1.0` — **alpha**. The native transport, cookie bridge, session snapshot,
challenge WebView and request log are implemented. The iOS build (BoringSSL
cross-compile, device run) and wire-level JA3/JA4 verification still need a Mac;
see `docs/BUILD_IOS.md` and `tool/README.md`.

## Install

```yaml
dependencies:
  browser_http:
    git:
      url: https://github.com/REPLACE_ME/browser_http
```

## Usage

```dart
import 'package:browser_http/browser_http.dart';

final session = BrowserHttp.session(
  profile: BrowserProfile.safariIos18,
);

final client = BrowserClient(session: session);
final response = await client.get(Uri.parse('https://example.com'));
```

Challenge flow:

```dart
final response = await session.get(Uri.parse('https://example.com'));

if (session.challenge.isChallenge(response)) {
  final result = await session.challenge.ensureClearance(
    Uri.parse('https://example.com'),
  );
  if (result.resolved) {
    await session.get(Uri.parse('https://example.com'));
  } else if (result.needsUserInteraction) {
    // Show BrowserChallengeView; the user completes the check themselves.
    // The widget calls back with a ChallengeResult once clearance is present.
  }
}
```

`BrowserChallengeView` hosts a real `WKWebView` backed by the persistent
`WKWebsiteDataStore`, so the clearance it obtains is the same cookie jar the
native transport reads on the next request. Interactive challenges are never
clicked programmatically.

### Demo browser (hybrid capture)

The companion app **SimpleBrowser** builds exactly this hybrid: a URL bar, a real
WKWebView the user browses and clicks in, and a diagnostics panel. The pattern
is shown below; `example/` is a minimal API usage demo.

- **WebView tab** — main-frame URL/title/status plus Performance API resource
  timings. WebKit does not expose subresource headers or bodies to host apps.
- **Engine tab** — runs the current URL through the native fingerprint
  transport (`BrowserSession.capture`) and shows ordered request headers
  (including the shared-jar `Cookie`), profile UA/client hints, response
  status, ordered response headers, elapsed time and a body preview.
- **Log tab** — live `RequestLogEvent`s from the shared `StreamLogSink`.

Both panes use the same persistent `WKWebsiteDataStore`, so cookies obtained
by browsing are visible to the native capture and vice versa.

```dart
final controller = BrowserController(session: session);
// Host BrowserView(controller: controller) in the widget tree; the user then
// navigates by clicking links inside the real WKWebView.
await controller.start(initialUri: Uri.parse('https://example.com'));

final captured = await session.capture(
  Uri.parse(controller.url ?? 'https://example.com'),
);
print(captured.response.statusCode);
```

Server-Sent Events:

```dart
final sse = SseClient(session: session);
final token = CancelToken();

await for (final event in sse.connect(
  Uri.parse('https://example.com/events'),
  cancelToken: token,
  lastEventId: lastSeenId, // for manual reconnects
)) {
  print('${event.event}: ${event.data}');
}
```

The connection uses the same native transport (cookies, proxy, fingerprint) as
normal requests. Reconnection policy is left to the app; the parser preserves
`id`/`retry` fields so a reconnect can resume correctly.

## Design rules

1. Dependencies point inward: `api/` never imports `adapters/` or FFI.
2. Browser constants (UA, header order, TLS/H2 parameters) live only in
   `rust/src/api/profile.rs`.
3. Every cross-language call supports a timeout, cancellation, and a stable
   error code.

## Build (source)

Requires:

- Rust **>= 1.98** (edition 2024; `wreq` requires it)
- `cmake`, `perl`, `pkg-config`, `libclang` (BoringSSL build deps)
- Xcode 15+ and CocoaPods
- iOS targets: `rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios`

The Rust core is compiled by a CocoaPods script phase; there is no prebuilt
binary to download. Full details, including the required Rust targets and the
`ios/.xcode.env.local` PATH setup, are in `docs/BUILD_IOS.md`.

```bash
# Only after changing a public Rust signature (CLI must be 2.13.0):
flutter_rust_bridge_codegen generate

cd example && flutter build ios --no-codesign
```

## Verify fingerprints

See `tool/README.md`.

## License

MIT.
