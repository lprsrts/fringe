#!/usr/bin/env bash
# Rebuild the repo header: solve art/hero/scene.json (a Gaussian beam through a PEC
# double slit, 0.7 um slits at 5 um pitch, lambda = 1 um) with FDTD at final quality,
# then compose art/hero/hero.png (2560 x 1280, RGB, no text) and hero-1280.png
# (1280 x 640, the GitHub social preview upload). Needs a release build of fringe-cli
# (cargo build --release) and uv.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
art="$root/art/hero"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# compose.py colours the field itself; it reads only the .npy, but solve needs an -o.
"$root/target/release/fringe-cli" solve "$art/scene.json" -o "$work/field.png" --quality final \
    --npy "$work/field.npy" --quiet
uv run -q --no-project --with numpy --with pillow --with scipy python "$art/compose.py" \
    "$work/field.npy" "$art/hero.png" "$art/hero-1280.png"
echo "$art/hero.png"
