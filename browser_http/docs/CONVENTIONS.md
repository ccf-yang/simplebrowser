# Engineering conventions

## Architecture rules (non-negotiable)

1. **Dependencies point inward.** `api/` may import `domain/` and `ports/`
   only. It must never import `adapters/`, `dart:ffi`, or
   `package:flutter/services.dart`.
2. **One source of truth for browser constants.** User agents, client hints,
   header order and TLS/HTTP2 parameters live in
   `rust/src/api/profile.rs`. Dart and Swift must never hard-code them.
3. **Every cross-language call is cancellable and bounded.** It carries a
   timeout, supports cancellation, and maps native errors onto the stable codes
   in `lib/src/domain/errors.dart`. A native crash must never take down the
   Dart isolate.

## Naming

| Kind | Convention | Example |
|---|---|---|
| Files | `snake_case.dart` | `browser_session.dart` |
| Ports | `<Thing>Port` | `TransportPort` |
| Adapters | `<Platform><Thing>Adapter` | `_RustTransportAdapter` |
| Public API | Noun | `BrowserSession` |
| Errors | `<Thing>Exception` | `ConsistencyException` |
| Log phases | lowercase enum | `challengeResolved` |

## Logging

- Every event is a `RequestLogEvent` with a stable schema.
- `authorization`, `proxy-authorization`, `cookie`, `set-cookie`, `x-api-key`
  and `x-auth-token` are redacted **in the domain layer**, before any sink.
- `debug` level (fingerprint metadata) is opt-in.
- Sinks must never block or throw into the request path.

## Configuration precedence

`per-request > session > profile default`.

Overriding the user agent, client hints or profile per request is **rejected**:
it would break `ConsistencyGuard` and invalidate challenge clearances.

## Error handling

- All errors are `sealed BrowserHttpException` with a stable `code`.
- Native returns `code: message`; Dart parses it and rethrows a typed error.
- No error message may contain a cookie, token or proxy credential.

## Generated FFI bindings

- Source of truth: `rust/src/api/**`. Never hand-edit anything under
  `lib/src/ffi/` or `rust/src/frb_generated.rs`.
- Regenerate after changing a `pub` Rust signature:

  ```sh
  flutter_rust_bridge_codegen generate
  ```

- The CLI version must match `flutter_rust_bridge` in both `pubspec.yaml` and
  `rust/Cargo.toml` (currently **2.13.0**).
- `lib/src/ffi/**` is committed so plugin consumers do not need the codegen
  toolchain. It is excluded from analyzer lints.
- If `flake.nix`/CI has no Dart SDK, the generator can still be run with the
  SDK on the developer machine; do not silence errors by editing generated
  files.

After `flutter_rust_bridge_codegen generate`, check `rust/src/lib.rs`: the
generator may re-insert `mod frb_generated;` above the crate-level `//!` docs,
which Rust rejects. Move the `mod` declaration below `pub mod api;` (as it is
now) before building.
