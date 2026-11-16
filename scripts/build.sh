#!/usr/bin/env bash
# Build the Rust static library, then the Swift app that links against it.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cargo build --release --lib --manifest-path "$root/Cargo.toml"

# Package.swift links ../target/release/libfringe_core.a.
#
# The app's minimum macOS has to be at least what the Rust standard library
# was compiled for: Homebrew's rustc ships std and compiler_builtins built
# with a 26.0 deployment target, and MACOSX_DEPLOYMENT_TARGET can't lower
# that because those objects come prebuilt. A lower floor in Package.swift
# makes ld warn about every one of them.
(cd "$root/swift" && swift build -c release)
