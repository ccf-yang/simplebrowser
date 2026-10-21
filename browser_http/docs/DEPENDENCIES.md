# Dependency verification log

Status of every native dependency. Update this file whenever a dependency is
bumped.

## wreq 0.16.1 — VERIFIED

| Property | Value |
|---|---|
| License | Apache-2.0 |
| Edition / MSRV | 2024 / Rust 1.98 |
| TLS backend | `btls` / `btls-sys` / `tokio-btls` 0.5.6 (BoringSSL fork) |
| Emulation | `ClientBuilder::emulation()` = `TlsOptions` + `Http2Options` + `OrigHeaderMap` |
| Header order/case | Native support via `OrigHeaderMap` |
| HTTP/2 control | Pseudo-header order, initial stream id, window sizes |
| Proxies | `Proxy::http/https/all`, `basic_auth`, rotating proxies |
| WebSocket | `ws` feature |
| JA3/JA4 export | Not exposed; `keylog` only |

## wreq-util 0.2.0 — VERIFIED

| Property | Value |
|---|---|
| License | Apache-2.0 |
| Depends on | `wreq 0.16.1` |
| Profiles | Chrome 100–154, Safari 26.x, Firefox 152, OkHttp, Opera |
| Safari iOS presets | `safari_ios_16.5`, `17.2`, `17.4.1`, `18.1.1`, `26`, `26.2` |
| PQ curves | Safari `CURVES_2` and Chrome `CURVES_3` include `X25519MLKEM768` |

Known upstream bug: `safari_ios_26_2` ships a mismatched UA
(`CPU iPhone OS 18_7 ... Version/26.2`). Prefer `SafariIos26` or
`SafariIos18_1_1`, or override the UA.

## btls 0.5.6 — VERIFIED (static)

| Property | Value |
|---|---|
| License | MIT (`btls-sys`), Apache-2.0 (`btls`/`tokio-btls`) + BoringSSL |
| iOS targets | Explicitly mapped in `btls-sys/build/main.rs`: `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios` |
| PQ | `X25519MLKEM768` available (post-quantum patch applied) |
| `prefix-symbols` | Supported on Mach-O |
| Packaging | BoringSSL sources are included in the published crate |

Still unverified: an actual `cargo build --target aarch64-apple-ios` on macOS
with Xcode installed. This is the only remaining dependency risk.

## netty (transitive) — VERIFIED

Apache-2.0, hyper fork, protocol layer only. Never depend on it directly.

## flutter_rust_bridge 2.13.0 — VERIFIED

Pinned exactly in both `pubspec.yaml` and `rust/Cargo.toml`. The codegen CLI
must also be 2.13.0.

## Build verification

Toolchain used: Rust 1.100.0-beta.7 (stable 1.94 is too old for the 1.98
MSRV). Build dependencies: `build-essential cmake ninja-build pkg-config
libclang-dev clang git perl go`.

`cargo test` result: **7 passed, 0 failed** (profile mapping, UA/client hints,
duplicate header preservation, invalid header rejection).

## Underlying protocol / crypto

| Component | License |
|---|---|
| BoringSSL | BoringSSL/OpenSSL licenses |
| netty / netty-proto | Apache-2.0 |

## flutter_rust_bridge_codegen 2.13.0 — VERIFIED

Installed with `cargo install flutter_rust_bridge_codegen --version 2.13.0
--locked` from the internal cargo mirror; `--version` reports 2.13.0.

Bindings were generated into `lib/src/ffi/` and `rust/src/frb_generated.rs`,
then `cargo test` still passed (7/7). Codegen requires a Dart/Flutter binary
for its preflight check; in headless Linux containers run it on a machine with
the SDK, or provide `dart`/`flutter` shims only for the generation step.
