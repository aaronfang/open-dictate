#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR/core"

echo "[1/2] Build Rust FFI (universal macOS) ..."
cargo build -p core-ffi --release

echo "[2/2] Generate Swift bindings ..."
# Requires `uniffi-bindgen` available via cargo.
if ! command -v uniffi-bindgen >/dev/null 2>&1; then
  echo "uniffi-bindgen not found. Installing to ~/.cargo/bin ..."
  cargo install uniffi_bindgen --locked || cargo install uniffi_bindgen
fi

OUT_DIR="$ROOT_DIR/apps/macos/Sources/OpenDictateCoreGenerated"
mkdir -p "$OUT_DIR"

uniffi-bindgen generate "$ROOT_DIR/core/core-ffi/src/open_dictate_core.udl" \
  --language swift \
  --out-dir "$OUT_DIR"

echo "Done. Swift bindings in: $OUT_DIR"

