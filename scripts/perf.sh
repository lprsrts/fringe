#!/usr/bin/env bash
# Headless profiler: compiles the app's Swift sources (all but FringeMain.swift) with
# scripts/perf/Perf.swift into target/perf/fringe-perf, which builds the real window offscreen
# (never shown, activated or sent input), drives one scenario for a fixed time and reports
# CPU, frames, renders, solves, PerfProbe counters and memory. `sample` runs on the harness
# for 10 s from 20 s in. Each scenario runs in its own process, one after another.
#
# usage: scripts/perf.sh [-s SECONDS] [-o OUT_DIR] [SCENARIO...]
#   scenarios: harness-null idle idle-driven idle-window play-lens-1920 play-lens-1440 play-talbot-1920
#              play-talbot-1440 play-lens-1440-60fps play-lens-1920-60fps play-lens-1440-cpu play-inactive play-hidden play-occlusion drag pan pinch resize-window
#              resize-programmatic resize-fixed-aspect hover puzzle colours (default: all of these)
#              idle-long play-lens-long (5 minutes each; run by name)
#              diagnostics, run by name: drag-noinspector drag-nosolve resize-floor-empty resize-floor-stub
#              resize-floor-nocanvas resize-floor-notoolbar resize-floor-noinspector diag-minsize diag-extension
#              parity (GPU vs CPU colouring, §12 of the viewport design; no time limit)
#              look (the invalid-scene grey against SwiftUI's .saturation(0)), export (full-size exports),
#              transform (the pan/pinch overlay shift against a fresh draw),
#              sound (puzzle sound with the engine output at 0: when the engine starts and stops)
# FRINGE_PERF_NOSAMPLE=1 skips `sample`. Display-tick statistics always leave out sample's run.
# Each scenario prints PASS/FAIL per budget; harness-null runs first so the others can
# subtract the harness's own CPU. The exit status is non-zero if any budget failed.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$root"
seconds=60; out="target/perf"
while getopts "s:o:" opt; do
    case $opt in s) seconds=$OPTARG ;; o) out=$OPTARG ;; *) exit 2 ;; esac
done
shift $((OPTIND - 1))
mkdir -p "$out" target/perf
[[ -f target/release/libfringe_core.a ]] || cargo build --release --lib
find swift/Sources/Fringe -name '*.swift' ! -name FringeMain.swift | sort > target/perf/sources.txt
# shellcheck disable=SC2046
DEVELOPER_DIR=/Library/Developer/CommandLineTools swiftc -parse-as-library -O -target arm64-apple-macos26.0 \
    -I swift/Sources/CFringeCore/include -L target/release -lfringe_core -lc++ \
    $(cat target/perf/sources.txt) scripts/perf/Perf.swift scripts/perf/Parity.swift -o target/perf/fringe-perf
scenarios=("$@")
[[ ${#scenarios[@]} -gt 0 ]] || scenarios=(harness-null idle idle-driven idle-window play-lens-1920 play-lens-1440 play-talbot-1920 play-talbot-1440 play-lens-1440-60fps play-lens-1920-60fps play-lens-1440-cpu play-inactive play-hidden play-occlusion drag pan pinch resize-window resize-programmatic resize-fixed-aspect hover puzzle colours)
status=0
for s in "${scenarios[@]}"; do
    secs=$seconds
    [[ $s == *-long ]] && secs=300
    echo "== $s ($secs s)"
    # caffeinate keeps the display awake: its display link paces the frames.
    caffeinate -d -i target/perf/fringe-perf "$out" "$s" "$secs" \
        -AppleLocale en_US -AppleLanguages '(en)' -AppleAccentColor 4 -AppleInterfaceStyle Dark || status=1
done
exit $status
