#!/usr/bin/env bash
# Build and wrap the Swift executable in target/Fringe.app and sign it. With
# FRINGE_SIGN_IDENTITY set to a Developer ID Application identity, it signs with the
# hardened runtime and a secure timestamp, ready for notarization (scripts/release.sh);
# without it, it signs ad hoc for local use.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$root/swift/.build/release/Fringe"
app="$root/target/Fringe.app"

"$root/scripts/build.sh"

# Take the minimum OS from the binary and the version from Cargo.toml, so
# Info.plist can't drift from either.
min_os="$(vtool -show-build "$bin" | awk '/minos/ { print $2; exit }')"
version="$(awk -F'"' '/^version *=/ { print $2; exit }' "$root/Cargo.toml")"
# The build number counts commits, so it only grows; Sparkle and the App Store both
# compare CFBundleVersion. A source tarball has no history: pass FRINGE_BUILD_NUMBER.
build="${FRINGE_BUILD_NUMBER:-$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)}"
year="$(date +%Y)"

# The build-environment keys Xcode writes into every app it builds. App Store Connect
# reads them to tell which Xcode and SDK made a build and rejects bundles without them
# (as made with a "beta version of Xcode", or ITMS-90058), so give the toolchain that
# swift build used. With only the Command Line Tools there is no Xcode version to give;
# the keys are left out and scripts/appstore.sh refuses the bundle.
dt_keys=""
if xcode="$(xcodebuild -version 2>/dev/null)"; then
    xcode_version="$(awk '/^Xcode / { print $2; exit }' <<<"$xcode")"
    xcode_build="$(awk '/^Build version / { print $3; exit }' <<<"$xcode")"
    sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
    sdk_build="$(xcrun --sdk macosx --show-sdk-build-version)"
    # Xcode 27.2 is "2720", 16.4.1 is "1641".
    dt_xcode="$(awk -F. '{ printf "%d%d%d", $1, $2, $3 }' <<<"$xcode_version")"
    while IFS='=' read -r key value; do
        dt_keys+="    <key>$key</key>"$'\n'"    <string>$value</string>"$'\n'
    done <<KEYS
BuildMachineOSBuild=$(sw_vers -buildVersion)
DTCompiler=com.apple.compilers.llvm.clang.1_0
DTPlatformBuild=$sdk_build
DTPlatformName=macosx
DTPlatformVersion=$sdk_version
DTSDKBuild=$sdk_build
DTSDKName=macosx$sdk_version
DTXcode=$dt_xcode
DTXcodeBuild=$xcode_build
KEYS
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Fringe"
# Drop the debug map (stabs naming every object file under swift/.build); symbols
# needed for crash reports stay.
strip -S "$app/Contents/MacOS/Fringe"
# The icon, compiled from icon/AppIcon.icon by icon/build.sh: Assets.car carries the
# Liquid Glass icon, AppIcon.icns the flat fallback.
cp "$root/icon/compiled/Assets.car" "$root/icon/compiled/AppIcon.icns" "$app/Contents/Resources/"
# The licenses: Fringe's own and those of the crates it links.
cp "$root/LICENSE-MIT" "$root/LICENSE-APACHE" "$root/THIRD-PARTY-LICENSES.txt" "$app/Contents/Resources/"

# ITSAppUsesNonExemptEncryption: Fringe uses no encryption, which answers App Store
# Connect's export-compliance question for every build.
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Fringe</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
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
    <string>${build}</string>
${dt_keys}    <key>ITSAppUsesNonExemptEncryption</key>
    <false/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.education</string>
    <key>LSMinimumSystemVersion</key>
    <string>${min_os}</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © ${year} Alper Saritas</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

identity="${FRINGE_SIGN_IDENTITY:--}"
if [[ "$identity" == "-" ]]; then
    codesign --force --sign - "$app"
else
    # No entitlements: the app needs no hardened-runtime exceptions (no JIT, no
    # unsigned libraries, no debugging). The timestamp needs a network connection.
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
echo "$app"
