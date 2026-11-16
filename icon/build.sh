#!/usr/bin/env bash
# Rebuild the app icon: write the SVG layers, compile icon/AppIcon.icon with actool
# into icon/compiled (Assets.car for macOS 26, AppIcon.icns for older systems and
# Finder fallbacks) and render icon/preview.png. Needs Xcode; the compiled files are
# checked in, so bundling the app does not.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
icon="$root/icon"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 "$icon/layers.py"

xcrun actool "$icon/AppIcon.icon" --compile "$work" --platform macosx \
    --minimum-deployment-target 26.0 --target-device mac --app-icon AppIcon \
    --output-partial-info-plist "$work/partial.plist" >/dev/null
mkdir -p "$icon/compiled"
cp "$work/Assets.car" "$work/AppIcon.icns" "$icon/compiled/"

ictool="$(dirname "$(xcode-select -p)")/Applications/Icon Composer.app/Contents/Executables/ictool"
"$ictool" "$icon/AppIcon.icon" --export-image --output-file "$icon/preview.png" \
    --platform macOS --rendition Default --width 512 --height 512 --scale 1 >/dev/null
echo "$icon/compiled"
