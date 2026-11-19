#!/bin/sh
# Offline test of the app's puzzle sounds, built with the Command Line Tools (no Xcode). Nothing
# is played through a speaker and no window is opened. Run through scripts/sound.sh.
#
# 1. Type-checks the standalone audio files under Swift 6 strict concurrency and Swift 5.
# 2. fringe-sound-offline compiles the app's Audio/SynthVoice.swift and Audio/SoundPalette.swift
#    as they are, renders every recipe and representative reveals to WAV, asserts design 4.6
#    (loudness, limiter, dark-not-louder, timing caps, peaks, clicks, silent tails) and reports
#    the laptop-speaker model. Given a directory of the prototype's renders, it compares them.
# 3. alloc-check counts heap allocations on the render path (interposed malloc family).
# 4. engine-check compiles the five audio files (with Models/SoundSettings.swift) and drives
#    SoundEngine's source node through AVAudioEngine's offline manual rendering mode, plus the
#    settings and system reads and the engine's laziness.
#
# usage: build.sh OUT_DIR [PROTOTYPE_WAV_DIR]     Exit status 1 = a check failed.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
app="$here/../../swift/Sources/Fringe"
out="$1"
proto="${2:-}"
[ -n "$out" ] || { echo "usage: build.sh OUT_DIR [PROTOTYPE_WAV_DIR]" >&2; exit 2; }
mkdir -p "$out/bin"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
TARGET="-target arm64-apple-macos26.0"
DSP="$app/Audio/SynthVoice.swift $app/Audio/SoundPalette.swift"
ALL="$DSP $app/Models/SoundSettings.swift $app/Audio/SystemSoundPreferences.swift $app/Audio/SoundEngine.swift"

echo "TYPE CHECK ($(swiftc --version 2>&1 | head -1))"
# shellcheck disable=SC2086
swiftc -typecheck $TARGET -swift-version 6 -strict-concurrency=complete -warnings-as-errors -module-name Fringe $ALL
echo "- Swift 6, complete concurrency checking, warnings as errors: ok"
# shellcheck disable=SC2086
swiftc -typecheck $TARGET -swift-version 5 -warnings-as-errors -module-name Fringe $ALL
echo "- Swift 5, warnings as errors: ok"
echo ""

# shellcheck disable=SC2086
swiftc -O -swift-version 5 $TARGET $DSP "$here/Analysis.swift" "$here/main.swift" -o "$out/bin/fringe-sound-offline"
clang -dynamiclib -O2 -mmacosx-version-min=26.0 "$here/alloc-check/count.c" -o "$out/bin/libcount.dylib"
# shellcheck disable=SC2086
swiftc -O -swift-version 5 $TARGET $DSP "$here/alloc-check/main.swift" \
    -o "$out/bin/alloc-check" -L"$out/bin" -lcount -Xlinker -rpath -Xlinker @executable_path
# shellcheck disable=SC2086
swiftc -O -swift-version 5 $TARGET $ALL "$here/engine-check/main.swift" -o "$out/bin/engine-check"
rm -rf "$out/wav"
mkdir -p "$out/wav"
status=0
"$out/bin/fringe-sound-offline" "$out/wav" ${proto:+"$proto"} || status=1
echo ""
echo "RENDER PATH AND ENGINE"
"$out/bin/alloc-check" || status=1
"$out/bin/engine-check" || status=1
exit $status
