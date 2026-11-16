#!/usr/bin/env bash
# Rebuild icon/AppIcon.icns: solve the nanojet scene with the release CLI, frame the
# field in the macOS icon shape and pack every size into an .icns.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cargo build --release --bin fringe-cli --manifest-path "$root/Cargo.toml"
"$root/target/release/fringe-cli" solve "$root/icon/nanojet.json" -o "$work/field.png" \
    --quality final --quantity intensity --colormap inferno --gamma 0.8 --width 1024 --quiet
swift "$root/icon/compose.swift" "$work/field.png" "$work/icon.png"

set="$work/AppIcon.iconset"
mkdir "$set"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$work/icon.png" --out "$set/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$work/icon.png" --out "$set/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o "$root/icon/AppIcon.icns"
cp "$work/icon.png" "$root/icon/AppIcon.png"
echo "$root/icon/AppIcon.icns"
