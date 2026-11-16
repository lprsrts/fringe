#!/usr/bin/env bash
# Rebuild the cover banner: solve art/banner/scene.json (a Gaussian beam through five
# glass beads, n = 1.5, that hand a nanojet down the chain) with FDTD at final quality,
# then compose art/banner/banner@2x.png (3168 x 792) and banner.png (1584 x 396, the
# LinkedIn cover size). Needs a release build of fringe-cli (cargo build --release).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
art="$root/art/banner"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# compose.swift colours the field itself; it reads only the .npy, but solve needs an -o.
"$root/target/release/fringe-cli" solve "$art/scene.json" -o "$work/field.png" --quality final \
    --npy "$work/field.npy" --quiet
swift -O "$art/compose.swift" "$work/field.npy" "$art/scene.json" "$root/icon/preview.png" "$art/banner@2x.png" >/dev/null
sips -z 396 1584 "$art/banner@2x.png" --out "$art/banner.png" >/dev/null
echo "$art/banner.png"
