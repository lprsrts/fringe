#!/bin/sh
# Builds fringe_wasm with SIMD128 into ../web/src/pkg (ES module that the
# browser viewer in ../web bundles) and pkg-simd/ (for
# `node bench.mjs 3 pkg-simd`). With --plain, also a build without SIMD into
# pkg/ for comparison. site/wrangler.jsonc runs this before every deploy.
#
# Needs a Rust toolchain with the wasm32-unknown-unknown target (Homebrew's
# rust has none) and wasm-bindgen-cli 0.2.130. Uses $CARGO if set, else
# rustup's stable toolchain in $RUSTUP_HOME when there is one, else cargo on
# PATH; wasm-bindgen is looked up on PATH and in $CARGO_HOME/bin.
set -eu
cd "$(dirname "$0")"

toolchain="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/stable-$(uname -m | sed 's/arm64/aarch64/')-apple-darwin/bin"
if [ -z "${CARGO:-}" ] && [ -x "$toolchain/cargo" ]; then
  CARGO="$toolchain/cargo"
  export RUSTC="$toolchain/rustc"
fi
CARGO=${CARGO:-cargo}
PATH="$PATH:${CARGO_HOME:-$HOME/.cargo}/bin"

RUSTFLAGS="-C target-feature=+simd128" CARGO_TARGET_DIR=target-simd \
  "$CARGO" build --release --target wasm32-unknown-unknown
out=target-simd/wasm32-unknown-unknown/release/fringe_wasm.wasm
wasm-bindgen --target web --no-typescript --out-dir ../web/src/pkg "$out"
wasm-bindgen --target nodejs --out-dir pkg-simd "$out"

if [ "${1:-}" = "--plain" ]; then
  "$CARGO" build --release --target wasm32-unknown-unknown
  wasm-bindgen --target nodejs --out-dir pkg target/wasm32-unknown-unknown/release/fringe_wasm.wasm
fi
