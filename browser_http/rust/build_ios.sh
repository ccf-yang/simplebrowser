#!/bin/sh
# Builds the Rust core for the iOS target(s) Xcode is currently asking for and
# places a single static library at $BUILT_PRODUCTS_DIR/libbrowser_http_core.a.
#
# Called from ios/browser_http.podspec as a "before compile" script phase.
# Requires: Xcode command line tools, a Rust toolchain with the iOS targets:
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

set -eu

cd "$(dirname "$0")"

# Xcode runs script phases with a sanitized PATH, which usually omits rustup's
# ~/.cargo/bin. Source the env file when present so `cargo` is found in CI.
if [ -f "${HOME}/.cargo/env" ]; then
  # shellcheck disable=SC1091
  . "${HOME}/.cargo/env"
fi
export PATH="${HOME}/.cargo/bin:/usr/local/bin:${PATH}"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found. Install Rust and the iOS targets." >&2
  exit 1
fi

if [ -z "${BUILT_PRODUCTS_DIR:-}" ] || [ -z "${PLATFORM_NAME:-}" ]; then
  echo "error: this script must be run from an Xcode build phase." >&2
  exit 1
fi

ARCHS="${ARCHS:-arm64}"
RELEASE_FLAG="--release"
PROFILE_DIR="release"

TARGETS=""
for arch in $ARCHS; do
  case "${PLATFORM_NAME}:${arch}" in
    iphoneos:arm64) TARGETS="$TARGETS aarch64-apple-ios" ;;
    iphonesimulator:arm64) TARGETS="$TARGETS aarch64-apple-ios-sim" ;;
    iphonesimulator:x86_64) TARGETS="$TARGETS x86_64-apple-ios" ;;
    *)
      echo "error: unsupported platform/arch ${PLATFORM_NAME}/${arch}" >&2
      exit 1
      ;;
  esac
done

# BoringSSL's build script picks these up for the deployment target.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"
# Keep build artifacts inside the plugin so incremental Xcode builds are fast.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$PWD/target}"

LIBS=""
for target in $TARGETS; do
  echo "Building browser_http_core for ${target}..."
  cargo build $RELEASE_FLAG --target "$target" --lib
  LIBS="$LIBS $CARGO_TARGET_DIR/$target/$PROFILE_DIR/libbrowser_http_core.a"
done

OUT="${BUILT_PRODUCTS_DIR}/libbrowser_http_core.a"
set -- $LIBS
if [ "$#" -eq 1 ]; then
  cp "$1" "$OUT"
else
  xcrun lipo -create $LIBS -output "$OUT"
fi

echo "Wrote $OUT"
