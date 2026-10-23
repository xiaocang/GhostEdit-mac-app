#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v cargo >/dev/null 2>&1; then
  echo "error: Rust is required to build Harper. Install Rust with rustup, then rebuild." >&2
  exit 1
fi

OUTPUT_DIR="$ROOT_DIR/build/harper"
mkdir -p "$OUTPUT_DIR"
TARGET_DIR="$ROOT_DIR/build/harper-target"
LIBRARIES=()
for arch in ${ARCHS:-$(uname -m)}; do
  case "$arch" in
    arm64) target=aarch64-apple-darwin ;;
    x86_64) target=x86_64-apple-darwin ;;
    *) echo "error: Unsupported Harper architecture: $arch" >&2; exit 1 ;;
  esac
  cargo build --locked --release --manifest-path "$ROOT_DIR/harper-bridge/Cargo.toml" --target-dir "$TARGET_DIR" --target "$target"
  LIBRARIES+=("$TARGET_DIR/$target/release/libharper_bridge.a")
done
/usr/bin/lipo -create "${LIBRARIES[@]}" -output "$OUTPUT_DIR/libharper_bridge.a"
cp "$ROOT_DIR/harper-bridge/include/harper_bridge.h" "$ROOT_DIR/harper-bridge/include/module.modulemap" "$OUTPUT_DIR/"
