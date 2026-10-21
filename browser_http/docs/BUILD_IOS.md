# Building for iOS

The package ships Dart/Swift sources and compiles the Rust core during the Xcode
build. No prebuilt binary is required for development.

## Requirements

| Tool | Version |
|---|---|
| Flutter | ≥ 3.22 |
| Xcode | ≥ 15 (Swift 5.9) |
| Rust | ≥ 1.98 (edition 2024) |
| iOS deployment target | 15.0 |

Rust 1.98 is not in a stable release at the time of writing; use a beta or a
newer stable once available.

```sh
# Install the iOS targets once per machine.
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
```

## How the build is wired

1. `flutter build ios` runs CocoaPods.
2. `ios/browser_http.podspec` declares a `before_compile` script phase.
3. `rust/build_ios.sh` reads `PLATFORM_NAME` and `ARCHS`, runs
   `cargo build --release --target …`, and writes
   `$SYMROOT/$CONFIGURATION$EFFECTIVE_PLATFORM_NAME/libbrowser_http_core.a`
   (a `lipo` merge on simulator builds). This is the app target's
   `BUILT_PRODUCTS_DIR`, which `-force_load` also references.
4. `OTHER_LDFLAGS` links the archive with `-force_load`, because Dart resolves
   the bridge symbols at runtime and there are no link-time references.

`cargo` must be on `PATH` for Xcode's build environment. When building from a
GUI/CI setup where `PATH` is not inherited, add it to `ios/.xcode.env.local`:

```sh
export PATH="$HOME/.cargo/bin:$PATH"
```

(cargokit is not used: it would add a fetched dependency and a second build
system for no benefit in an iOS-only package.)

## Verifying a build

```sh
cd example
# The example intentionally commits no Xcode project; generate it once.
flutter create --platforms=ios .
flutter pub get
flutter build ios --no-codesign
```

Expected: the build phase prints `Wrote …/libbrowser_http_core.a`, and the app
links without undefined `frb_*` symbols. A missing symbol means `force_load` or
the script phase was dropped.

## Optional: prebuilt XCFramework

For consumers that cannot install Rust, publish a binary artifact:

```sh
# after a successful device + simulator build
xcodebuild -create-xcframework \
  -library rust/target/aarch64-apple-ios/release/libbrowser_http_core.a \
  -library rust/target/aarch64-apple-ios-sim/release/libbrowser_http_core.a \
  -output dist/browser_http_core.xcframework
```

Then add a `browser_http_prebuilt.podspec` variant that sets
`s.vendored_frameworks` and removes the script phase. Keep the source-build
podspec as the default so the two can never drift apart silently.

## What still needs a Mac

The following checks cannot run on Linux and must be executed on macOS with
Xcode:

- `cargo build --target aarch64-apple-ios` (BoringSSL compilation).
- `flutter build ios` / simulator run.
- Wire-level JA3/JA4 comparison against the collector described in
  `tool/README.md`.
