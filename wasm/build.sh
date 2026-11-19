#!/bin/sh
# Builds fringe_wasm with SIMD128 into ../web/pkg (ES module for the browser
# viewer) and pkg-simd/ (for `node bench.mjs 3 pkg-simd`). With --plain, also a
# build without SIMD into pkg/ for comparison.
#
# Needs a rustup toolchain with the wasm32-unknown-unknown target and
# wasm-bindgen-cli 0.2.130 on PATH; set CARGO (and RUSTC) to that toolchain's
# binaries if the default cargo has no wasm std.
set -eu
cd "$(dirname "$0")"
CARGO=${CARGO:-cargo}

RUSTFLAGS="-C target-feature=+simd128" CARGO_TARGET_DIR=target-simd \
  "$CARGO" build --release --target wasm32-unknown-unknown
out=target-simd/wasm32-unknown-unknown/release/fringe_wasm.wasm
wasm-bindgen --target web --no-typescript --out-dir ../web/pkg "$out"
wasm-bindgen --target nodejs --out-dir pkg-simd "$out"

if [ "${1:-}" = "--plain" ]; then
  "$CARGO" build --release --target wasm32-unknown-unknown
  wasm-bindgen --target nodejs --out-dir pkg target/wasm32-unknown-unknown/release/fringe_wasm.wasm
fi
