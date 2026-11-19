#!/bin/sh
# Builds pkg/ (baseline wasm32) and pkg-simd/ (+simd128) for node, then
# `node bench.mjs 3 pkg-simd`. Needs a rustup toolchain with the
# wasm32-unknown-unknown target and wasm-bindgen-cli 0.2.130 on PATH; set CARGO
# to that toolchain's cargo if the default one has no wasm std.
set -eu
cd "$(dirname "$0")"
CARGO=${CARGO:-cargo}
"$CARGO" build --release --target wasm32-unknown-unknown
wasm-bindgen --target nodejs --out-dir pkg target/wasm32-unknown-unknown/release/fringe_wasm.wasm
RUSTFLAGS="-C target-feature=+simd128" CARGO_TARGET_DIR=target-simd \
  "$CARGO" build --release --target wasm32-unknown-unknown
wasm-bindgen --target nodejs --out-dir pkg-simd target-simd/wasm32-unknown-unknown/release/fringe_wasm.wasm
