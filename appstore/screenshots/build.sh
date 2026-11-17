#!/usr/bin/env bash
# Rebuild the Mac App Store screenshots (2880 x 1800, PNG, sRGB, no alpha, no added text)
# from the real app: compiles the app's Swift sources (all but FringeMain.swift) with
# Screenshots.swift into a headless harness, which solves each example scene at final
# quality, renders the app window offscreen at 2x (never shown, activated or sent input)
# and writes 01-*.png ... 05-*.png next to this script.
#
# usage: appstore/screenshots/build.sh [PREFIX]   (PREFIX, e.g. 03, renders only that shot)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
out="appstore/screenshots"
work="target/appstore-screenshots"
mkdir -p "$work"

[[ -f target/release/libfringe_core.a ]] || cargo build --release --lib

find swift/Sources/Fringe -name '*.swift' ! -name FringeMain.swift | sort > "$work/sources.txt"
# shellcheck disable=SC2046
swiftc -parse-as-library -O -target arm64-apple-macos26.0 \
    -I swift/Sources/CFringeCore/include \
    -L target/release -lfringe_core -lc++ \
    $(cat "$work/sources.txt") "$out/Screenshots.swift" \
    -o "$work/fringe-screenshots"

# Fixed locale, language, accent colour and appearance, so the numbers and the Export
# button do not follow the build machine's settings.
"$work/fringe-screenshots" "$out" ${1:+"$1"} \
    -AppleLocale en_US -AppleLanguages '(en)' -AppleAccentColor 4 -AppleInterfaceStyle Dark

for f in "$out"/0*.png; do
    sips -g pixelWidth -g pixelHeight -g hasAlpha -g space "$f" | tail -n +2 | tr -s ' ' | paste -sd ' ' - | sed "s|^|$(basename "$f"): |"
done
