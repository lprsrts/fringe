#!/usr/bin/env bash
# Offscreen renders of chosen app window states, for checking the UI without opening it.
# Compiles the app's Swift sources (all but FringeMain.swift) with scripts/ui-shots/UIShots.swift
# into a headless harness that drives AppState, renders the window offscreen (never shown,
# activated or sent input) and writes target/ui-shots/<name>.png.
#
# usage: scripts/ui-shots.sh [NAME_PREFIX]   (e.g. sim- or sim-default)
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$root"
out="target/ui-shots"; mkdir -p "$out"
[[ -f target/release/libfringe_core.a ]] || cargo build --release --lib
find swift/Sources/Fringe -name '*.swift' ! -name FringeMain.swift | sort > "$out/sources.txt"
# shellcheck disable=SC2046
DEVELOPER_DIR=/Library/Developer/CommandLineTools swiftc -parse-as-library -O -target arm64-apple-macos26.0 \
    -I swift/Sources/CFringeCore/include -L target/release -lfringe_core -lc++ \
    $(cat "$out/sources.txt") scripts/ui-shots/UIShots.swift -o "$out/fringe-ui-shots"
# Fixed locale, language, accent colour and appearance, so the shots do not follow the
# machine's settings. The harness keeps its own defaults domain (fringe-ui-shots).
"$out/fringe-ui-shots" "$out" ${1:+"$1"} \
    -AppleLocale en_US -AppleLanguages '(en)' -AppleAccentColor 4 -AppleInterfaceStyle Dark
