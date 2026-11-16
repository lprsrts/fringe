#!/usr/bin/env bash
# Build the Rust static library, then the Swift app that links against it.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# For a release (FRINGE_RELEASE=1), keep the build machine's paths out of the binary:
# panic locations in dependencies otherwise carry the full Cargo registry path under
# the home folder. Only release builds do this, because changing RUSTFLAGS rebuilds
# everything and would make every switch with a plain `cargo test` a full rebuild.
if [[ "${FRINGE_RELEASE:-0}" == 1 ]]; then
    cargo_home="${CARGO_HOME:-$HOME/.cargo}"
    export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$cargo_home=/cargo --remap-path-prefix=$(rustc --print sysroot)=/rustc --remap-path-prefix=$root=/fringe"
fi

cargo build --release --lib --manifest-path "$root/Cargo.toml"
# A release also ships the CLI, built with the same flags.
if [[ "${FRINGE_RELEASE:-0}" == 1 ]]; then
    cargo build --release --bin fringe-cli --manifest-path "$root/Cargo.toml"
fi

# Package.swift links ../target/release/libfringe_core.a.
#
# The app's minimum macOS has to be at least what the Rust standard library
# was compiled for: Homebrew's rustc ships std and compiler_builtins built
# with a 26.0 deployment target, and MACOSX_DEPLOYMENT_TARGET can't lower
# that because those objects come prebuilt. A lower floor in Package.swift
# makes ld warn about every one of them.
(cd "$root/swift" && swift build -c release)
