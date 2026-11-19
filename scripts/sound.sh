#!/usr/bin/env bash
# Offline check of the puzzle sounds (design 4.6): renders every sound recipe and representative
# reveals from the app's own Audio/ files to target/sound/wav, asserts the loudness, limiter,
# timing and signal rules, counts allocations on the render path and drives the real audio
# source node through AVAudioEngine's offline rendering. Plays nothing; opens no window.
# The report is also written to target/sound/report.txt.
#
# usage: scripts/sound.sh [PROTOTYPE_WAV_DIR]   (compare against the prototype's renders)
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$root"
out="target/sound"; mkdir -p "$out"
set +e
scripts/sound/build.sh "$out" ${1:+"$1"} 2>&1 | tee "$out/report.txt"
status=${PIPESTATUS[0]}
set -e
echo "report: $out/report.txt, files: $out/wav"
exit "$status"
