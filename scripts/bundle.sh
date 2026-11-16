#!/usr/bin/env bash
# Build and wrap the Swift executable in target/Fringe.app, ad-hoc signed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$root/swift/.build/release/Fringe"
app="$root/target/Fringe.app"

"$root/scripts/build.sh"

# Take the minimum OS from the binary and the version from Cargo.toml, so
# Info.plist can't drift from either.
min_os="$(vtool -show-build "$bin" | awk '/minos/ { print $2; exit }')"
version="$(awk -F'"' '/^version *=/ { print $2; exit }' "$root/Cargo.toml")"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Fringe"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Fringe</string>
    <key>CFBundleIdentifier</key>
    <string>com.asympton.fringe</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Fringe</string>
    <key>CFBundleDisplayName</key>
    <string>Fringe</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>${min_os}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
echo "$app"
