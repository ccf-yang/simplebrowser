# Architecture

Status: Stage 5 (implementation). P0 feature set is wired end to end; the iOS
build and wire-level fingerprint verification are tracked in `docs/BUILD_IOS.md`
and `tool/README.md`.

## 1. Module ↔ requirement mapping

| Module | Location | Requirements |
|---|---|---|
| M1 Public API | `lib/src/api/*` (incl. `browser_view.dart`) | 4, 7, 10, 12 |
| M2 Domain | `lib/src/domain/*` | 8, 9, 11 |
| M3 Ports | `lib/src/ports/*` | boundaries for all |
| M4 Composition root | `lib/src/composition/*`, `lib/src/adapters/*` | wiring, 13 |
| M5 Profile registry (Rust) | `rust/src/api/profile.rs` | 1, 2, 3, 5 |
| M6 Transport (Rust) | `rust/src/api/transport.rs` | 1, 2, 4 |
| M7 Cookie helper (Rust) | `rust/src/api/cookie.rs` | 6 |
| M8 WKWebView bridge (Swift) | `ios/Classes/WebViewAdapter.swift` | 10, 12 |
| M9 Cookie/Keychain (Swift) | `ios/Classes/*.swift` | 6, 11 |
| M10 Build & distribution | podspec, cargokit, CI | 13 |
| M11 Tests & fixtures | `test/`, `integration_test/`, `tool/` | acceptance of all |

## 2. Layering

```
Flutter UI
   │
BrowserClient / BrowserSession / ChallengeController / BrowserChallengeView   (M1)
   │
domain: models · ConsistencyGuard · LogRedactor · errors                      (M2)
   │
ports: Transport · Cookie · WebView · Vault · LogSink                         (M3)
   │
adapters (only layer allowed to touch FFI / MethodChannel)                    (M4)
   ├── Rust: wreq client (M6) + profiles (M5) + cookie helper (M7)
   └── Swift: WKWebView (M8) + WKHTTPCookieStore + Keychain (M9)
```

Rules: dependencies point inward; `api/` never imports `adapters/`; browser
constants live only in Rust.

## 3. Contracts

### 3.1 Dart ports

```dart
abstract interface class TransportPort {
  Future<TransportResponse> send(TransportRequest req, {CancelToken? cancelToken});
  Future<TransportStream> openStream(TransportRequest req, {CancelToken? cancelToken});
  Future<ProfileInfo> profileInfo(String profileId);
  Future<List<ProfileSummary>> listProfiles();
  Future<void> close();
}

abstract interface class CookiePort {
  Future<List<BrowserCookie>> get(Uri uri);
  Future<void> setAll(Uri uri, List<BrowserCookie> cookies);
  Future<void> merge(Uri uri, List<BrowserCookie> cookies);
  Future<void> removeAll(Uri uri);
  Future<void> clear();
}

abstract interface class WebViewPort {
  Future<WebViewSession> create({required String userAgent, bool headless = true});
  bool get isVisibleModeSupported;
}
```

`CancelToken` must expose `addListener` so the adapter can abort the native
request (implemented in `transport_port.dart`).

### 3.2 Rust FFI (flutter_rust_bridge)

```rust
pub async fn send(req: TransportRequest) -> Result<TransportResponse, String>;
pub async fn open_stream(
    req: TransportRequest,
    sink: StreamSink<StreamEvent>,   // head | data | end
) -> Result<(), String>;
pub fn profile_info(profile_id: String) -> Result<ProfileInfo, String>;
pub fn list_profiles() -> Vec<ProfileSummary>;
pub fn parse_set_cookie(set_cookie: String, url: String) -> Result<Vec<CookieData>, String>;
pub fn cancel(request_id: String);
```

- `send` is async; the runtime is Tokio multi-thread.
- Every request carries `id`; `cancel(id)` flips a `CancellationToken`.
- Errors are `"<code>:<message>"`; Dart splits on the first `:` and maps to a
  typed `BrowserHttpException`.
- `#[frb(init)]` calls `setup_default_user_utils()`.

### 3.3 Swift MethodChannels

Already scaffolded:

- `browser_http/webview`: `create`, `load`, `navigate`, `goBack`, `goForward`,
  `reload`, `canGoBack`, `canGoForward`, `currentUrl`, `currentTitle`,
  `lastStatus`, `resourceTimings`, `evaluate`, `exportCookies`,
  `exportLocalStorage`, `importLocalStorage`, `currentUserAgent`, `dispose`
- Platform views: `browser_http/challenge_view` (challenge) and
  `browser_http/browser_view` (demo browser tab). Both host the same
  `WebViewHolder`; the browser tab is simply user-driven.
- `browser_http/cookies`: `get`, `setAll`, `merge`, `removeAll`, `clear`
- `browser_http/vault`: `read`, `write`, `delete`

All WKWebView calls are dispatched to the main thread; all channel results are
returned exactly once.

## 4. Data models

| Model | Owner | Notes |
|---|---|---|
| `TransportRequest` | Dart | ordered headers, profile id, proxy, timeout, id |
| `TransportResponse` | Dart/Rust | ordered headers, bytes, optional fingerprint metadata |
| `ProfileInfo` | Rust | UA + client hints + family |
| `ProfileSummary` | Rust | id, family, browser name/version, iOS-compatible flag |
| `BrowserCookie` | Dart | name/value/domain/path/expires/secure/httpOnly/sameSite |
| `SessionSnapshot` | Dart | origin, profile, UA, hints, cookies, localStorage, egress hash, TTL |
| `RequestLogEvent` | Dart | redacted, stable schema |

## 5. Flows

### 5.1 Normal request

```
BrowserClient.send
  → BrowserSession.send(id, profile check, log start)
  → CookiePort.get(uri) → "cookie" header appended last
  → TransportPort.send → FFI → wreq client
  → TransportResponse → log response → http.StreamedResponse
```

wreq clients are cached per `(profileId, proxyUrl)`; a session owns its clients.

### 5.2 Challenge flow

```
response.isChallenge()
  → ChallengeController.ensureClearance(mode: auto)
      → WebViewPort.create(headless, UA = ProfileInfo.userAgent)
      → load(uri), poll 500ms:
            clearance cookie present AND page no longer challenged?
      → yes: export cookies + localStorage → CookiePort.merge → snapshot → Vault.write
      → no : return needsUserInteraction
  → app shows BrowserChallengeView (visible WKWebView, persistent data store)
  → user completes the check
  → resolveFromVisibleSession: verify UA == profile UA, export, merge, persist
  → retry the original request through the native transport
```

Never synthesizes clicks. The user is the only one who can pass an interactive
challenge.

### 5.2a Browsing and capture (hybrid)

```
BrowserController.start
  → WebViewPort.create(headless: false, UA = ProfileInfo.userAgent)
  → UiKitView('browser_http/browser_view') hosts that WKWebView
  → user clicks links; poll every 800ms for url/title/status/history
  → Performance API resource timings (no subresource headers/bodies on iOS)

BrowserSession.capture(uri)
  → CookiePort.get(uri) → Cookie header
  → TransportPort.send → Rust engine (TLS/H2/header order)
  → CapturedExchange{ ordered request headers, profile, elapsed, response }
```

The two sides share `WKWebsiteDataStore`, so the capture of a page is made
with the cookies the WebView just obtained. Capture is a diagnostic view of the
*native* request; it is not a wire tap on the WebView.

### 5.3 Session restore

```
Vault.read(key) → SessionSnapshot
  → TransportPort.profileInfo(profileId)
  → ConsistencyGuard.verify(expected: snapshot, actual: current identity)
  → import localStorage into the persistent WKWebsiteDataStore
  → CookiePort.merge(snapshot.origin, snapshot.cookies)
```

Restore fails loudly (`ConsistencyException`) instead of silently degrading
into a session that no longer matches its cookies.

### 5.4 Cookie source of truth

**Decision: `WKWebsiteDataStore` is the single persistent source of truth.**
`CookiePort` is a cache-aside facade over `WKHTTPCookieStore`:

- read: Dart cache → miss → channel `get`
- write: channel `merge`/`setAll` first, then update the cache
- native transport: Dart injects the `cookie` header; wreq's built-in cookie
  store is **disabled** so two jars never diverge

This is what makes clearances obtained by the WebView usable by native requests.

## 6. Threading model

| Layer | Thread / isolate | Rule |
|---|---|---|
| Public API | Flutter UI isolate | never blocks |
| frb | worker isolate | async, cancellable |
| Rust | Tokio multi-thread runtime | one runtime per plugin |
| WKWebView | main thread | all access via main queue |
| Cookie store | background completion → main | never synchronous |
| Logging | caller thread | sinks must not block |

## 7. Error model

Native returns `<code>:<message>`. Dart mapping:

| Native code | Dart type |
|---|---|
| `transport.*` | `TransportException` |
| `fingerprint.*` | `FingerprintException` |
| `challenge.*` | `ChallengeRequiredException` |
| `consistency.*` | `ConsistencyException` |
| `vault.*` | `VaultException` |
| `webview.*` | `WebViewException` |
| `cancelled` | `CancelledException` |

Panics are caught at the FFI boundary and reported as
`transport.panic:<message>`; they must never unwind into Dart.

## 8. Consistency guard enforcement points

1. `BrowserSession.send` rejects a request whose `profileId` differs.
2. `ChallengeController.resolveFromVisibleSession` requires
   `navigator.userAgent == ProfileInfo.userAgent`.
3. `BrowserSession.restore` verifies profile, UA, client hints, egress hash and
   expiry.
4. Per-request UA / client-hint overrides are rejected.
5. A proxy change invalidates the snapshot (egress hash mismatch).

## 9. Open decisions

| # | Decision | Recommendation |
|---|---|---|
| D1 | Cookie jar owner | **WKWebsiteDataStore** (section 5.4) |
| D2 | Fingerprint observability (req 12) | Export *configured* TLS/H2 parameters in debug builds; measure real values with an external collector. Do not promise wire-level JA3 from inside the app. |
| D3 | Profile source | Use `wreq-util::Emulation` presets, wrapped by our Rust registry; override the known `safari_ios_26_2` UA bug. |
| D4 | Streaming API | frb `StreamSink` for SSE/WebSocket (P1); P0 only needs buffered send. |
| D5 | Proxy pool | P1; wreq already supports `Proxy` + `basic_auth`; session-level egress binding added on top. |
