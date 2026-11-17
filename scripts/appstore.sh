#!/usr/bin/env bash
# Build a Mac App Store upload package: dist/Fringe-<version>-appstore.pkg, the app
# sandboxed (appstore/Fringe.entitlements), the provisioning profile embedded, signed
# with the Apple Distribution identity and wrapped in an installer package signed with
# the Mac Installer Distribution identity. Uploading is off by default; the script
# prints the command.
#
#   FRINGE_PROVISIONING_PROFILE        the Mac App Store Connect profile for
#                                      com.asympton.fringe (required)
#   FRINGE_APPSTORE_APP_IDENTITY       app signing identity; default: the one Apple
#                                      Distribution (or 3rd Party Mac Developer
#                                      Application) identity in the keychain
#   FRINGE_APPSTORE_INSTALLER_IDENTITY installer signing identity; default: the one
#                                      3rd Party Mac Developer Installer (or Mac
#                                      Installer Distribution) identity in the keychain
#   FRINGE_APPSTORE_DRY=1              sign ad hoc with the entitlements, no profile,
#                                      unsigned package: a sandboxed build to try out,
#                                      not for upload
#   FRINGE_APPSTORE_APP                re-sign this Fringe.app instead of building one
#   FRINGE_APPSTORE_UPLOAD=1           validate and upload with altool, as
#                                      FRINGE_APPSTORE_APPLE_ID with the app-specific
#                                      password in the keychain item
#                                      FRINGE_APPSTORE_KEYCHAIN_ITEM (default
#                                      fringe-appstore)
#   FRINGE_ALLOW_DIRTY=1               allow uncommitted changes
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist="$root/dist"
version="$(awk -F'"' '/^version *=/ { print $2; exit }' "$root/Cargo.toml")"
bundle_id=com.asympton.fringe
entitlements="$root/appstore/Fringe.entitlements"
dry="${FRINGE_APPSTORE_DRY:-0}"
upload="${FRINGE_APPSTORE_UPLOAD:-0}"
keychain_item="${FRINGE_APPSTORE_KEYCHAIN_ITEM:-fringe-appstore}"
profile="${FRINGE_PROVISIONING_PROFILE:-}"

if [[ "$dry" == 1 && "$upload" == 1 ]]; then
    echo "error: a dry run (FRINGE_APPSTORE_DRY=1) can't be uploaded" >&2
    exit 1
fi

# Resolves a signing identity to "SHA1<tab>name". With a wanted value (a 40-hex SHA-1
# or an exact name) it must match exactly one valid identity; without one, exactly one
# identity whose name starts with one of the prefixes. Prints nothing when there are
# none or several: two certificates with the same name (an old one and its renewal)
# can only be told apart by hash. Installer identities aren't code signing
# identities, so the installer search can't filter with -p codesigning.
find_identity() {
    local policy="$1" wanted="$2"; shift 2
    local hash name prefix found=()
    while IFS=$'\t' read -r hash name; do
        if [[ -n "$wanted" ]]; then
            if [[ "$hash" == "$wanted" || "$name" == "$wanted" ]]; then found+=("$hash"$'\t'"$name"); fi
            continue
        fi
        for prefix in "$@"; do
            if [[ "$name" == "$prefix"* ]]; then found+=("$hash"$'\t'"$name"); fi
        done
    done < <(security find-identity -v ${policy:+-p "$policy"} \
        | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "\(.*\)"$/\1	\2/p' | sort -u)
    if (( ${#found[@]} == 1 )); then printf '%s' "${found[0]}"; fi
}

app_identity=""        # the SHA-1 codesign signs with
app_name=""
installer_identity=""
team=""
if [[ "$dry" != 1 ]]; then
    # Collect everything that's missing before failing, so one run lists it all.
    missing=()
    app_row="$(find_identity codesigning "${FRINGE_APPSTORE_APP_IDENTITY:-}" \
        "Apple Distribution: " "3rd Party Mac Developer Application: ")"
    app_identity="${app_row%%$'\t'*}"
    app_name="${app_row#*$'\t'}"
    if [[ -z "$app_row" ]]; then
        missing+=("an Apple Distribution certificate (signs the app). Create it in Xcode >
    Settings > Accounts > Manage Certificates > + > Apple Distribution, or at
    https://developer.apple.com/account/resources/certificates/add (Apple
    Distribution, with a CSR from Keychain Access). If several are installed, set
    FRINGE_APPSTORE_APP_IDENTITY to the SHA-1 of one (security find-identity -v);
    if it is set, it matches no valid identity, or more than one.")
    fi
    installer_row="$(find_identity "" "${FRINGE_APPSTORE_INSTALLER_IDENTITY:-}" \
        "3rd Party Mac Developer Installer: " "Mac Installer Distribution: ")"
    installer_identity="${installer_row#*$'\t'}"
    installer_identity="${installer_row:+$installer_identity}"
    if [[ -z "$installer_identity" ]]; then
        missing+=("a Mac Installer Distribution certificate (signs the .pkg; it shows up as
    \"3rd Party Mac Developer Installer: ...\"). Create it in Xcode > Settings >
    Accounts > Manage Certificates > + > Mac Installer Distribution, or at
    https://developer.apple.com/account/resources/certificates/add. If several are
    installed, set FRINGE_APPSTORE_INSTALLER_IDENTITY to its exact name (if it is set,
    it matches no valid identity, or more than one).")
    fi
    if [[ -z "$profile" || ! -f "$profile" ]]; then
        missing+=("the Mac App Store provisioning profile${profile:+ ($profile does not exist)}.
    Register the explicit App ID $bundle_id under Identifiers, then at
    https://developer.apple.com/account/resources/profiles/add choose Distribution >
    Mac App Store Connect, that App ID and the Apple Distribution certificate;
    download it and set FRINGE_PROVISIONING_PROFILE to the .provisionprofile.")
    fi
    if (( ${#missing[@]} )); then
        echo "error: can't build for the Mac App Store; missing:" >&2
        for item in "${missing[@]}"; do printf '  - %s\n' "$item" >&2; done
        echo "set FRINGE_APPSTORE_DRY=1 to build an ad hoc signed sandboxed app instead" >&2
        exit 1
    fi
    echo "signing app as: $app_name ($app_identity)"
    echo "signing package as: $installer_identity"

    # The team is the identity's, as in "Apple Distribution: Name (TEAMID)".
    team="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$app_name")"
    if [[ -z "$team" ]]; then
        echo "error: no team ID in the identity name \"$app_name\"" >&2
        exit 1
    fi

    # Check the profile before signing: App Store Connect rejects a mismatch only
    # after the upload. A Mac App Store profile names no devices (a development
    # profile lists them, a Developer ID one provisions all of them).
    profile_plist="$(security cms -D -i "$profile")"
    profile_get() { plutil -extract "$1" raw -o - - <<<"$profile_plist" 2>/dev/null || true; }
    profile_has() { plutil -extract "$1" xml1 -o /dev/null - <<<"$profile_plist" 2>/dev/null; }
    problems=()
    [[ "$(profile_get Platform.0)" == OSX ]] || problems+=("not a macOS profile")
    [[ "$(profile_get TeamIdentifier.0)" == "$team" ]] \
        || problems+=("team $(profile_get TeamIdentifier.0), not $team")
    [[ "$(profile_get Entitlements.com\\.apple\\.application-identifier)" == "$team.$bundle_id" ]] \
        || problems+=("App ID $(profile_get Entitlements.com\\.apple\\.application-identifier), not $team.$bundle_id")
    ! profile_has ProvisionedDevices && ! profile_has ProvisionsAllDevices \
        || problems+=("a development or Developer ID profile, not a Mac App Store one")
    [[ "$(profile_get Entitlements.com\\.apple\\.security\\.get-task-allow)" != true ]] \
        || problems+=("a development profile (get-task-allow)")
    expires="$(profile_get ExpirationDate)"
    [[ "$(date -u +%Y-%m-%dT%H:%M:%SZ)" < "$expires" ]] || problems+=("expired $expires")
    # The profile must name the very certificate the app is signed with.
    profile_sha1s="$(i=0; while cert="$(profile_get DeveloperCertificates.$i)" && [[ -n "$cert" ]]; do
        base64 -D <<<"$cert" | shasum -a 1 | awk '{ print toupper($1) }'; i=$((i + 1)); done)"
    if [[ -z "$profile_sha1s" ]]; then
        problems+=("lists no certificates")
    elif ! grep -qx -- "$app_identity" <<<"$profile_sha1s"; then
        problems+=("doesn't include the certificate of \"$app_name\" ($app_identity)")
    fi
    if (( ${#problems[@]} )); then
        echo "error: $profile doesn't fit:" >&2
        printf '  - %s\n' "${problems[@]}" >&2
        exit 1
    fi
    echo "profile: $(profile_get Name) ($(profile_get UUID)), expires $expires"
fi

if [[ "$upload" == 1 && -z "${FRINGE_APPSTORE_APPLE_ID:-}" ]]; then
    echo "error: FRINGE_APPSTORE_UPLOAD=1 needs FRINGE_APPSTORE_APPLE_ID (and the keychain item $keychain_item)" >&2
    exit 1
fi

# Build, or take a given bundle. bundle.sh signs ad hoc here; the app is re-signed below.
if [[ -n "${FRINGE_APPSTORE_APP:-}" ]]; then
    source_app="$FRINGE_APPSTORE_APP"
else
    if [[ "$dry" != 1 && "${FRINGE_ALLOW_DIRTY:-0}" != 1 && -n "$(git -C "$root" status --porcelain)" ]]; then
        echo "error: uncommitted changes; commit them or set FRINGE_ALLOW_DIRTY=1" >&2
        exit 1
    fi
    # The notices ship in the app, so they must match Cargo.lock.
    python3 "$root/scripts/third-party-licenses.py" --check
    FRINGE_RELEASE=1 FRINGE_SIGN_IDENTITY=- "$root/scripts/bundle.sh"
    source_app="$root/target/Fringe.app"
fi
if [[ "$(plutil -extract CFBundleIdentifier raw -o - "$source_app/Contents/Info.plist")" != "$bundle_id" ]]; then
    echo "error: $source_app is not $bundle_id" >&2
    exit 1
fi
# bundle.sh leaves out Xcode's DT* keys when built without Xcode; App Store Connect
# rejects a bundle that lacks them.
if ! plutil -extract DTXcode raw -o - "$source_app/Contents/Info.plist" >/dev/null 2>&1; then
    if [[ "$dry" == 1 ]]; then
        echo "warning: Info.plist has no DTXcode/DTSDK* keys; rebuild with scripts/bundle.sh under Xcode before uploading" >&2
    else
        echo "error: Info.plist has no DTXcode/DTSDK* keys; build with Xcode selected (xcode-select -p)" >&2
        exit 1
    fi
fi

# Sign a copy, so target/Fringe.app stays the plain build the other scripts expect.
out="$dist/appstore"
app="$out/Fringe.app"
rm -rf "$out"
mkdir -p "$out"
ditto --noextattr --noqtn "$source_app" "$app"
# productbuild stores extended attributes as AppleDouble (._*) files in the payload;
# App Store Connect rejects quarantined files (ITMS-91109), and an app package should
# carry none. com.apple.provenance can't be removed from inside a process the system
# tracks (some terminals and agents), so only quarantine is fatal.
xattr -cr "$app" 2>/dev/null || true
attrs="$(xattr -r "$app")"
if grep -q ': com\.apple\.quarantine$' <<<"$attrs"; then
    echo "error: files in $app are quarantined" >&2
    exit 1
fi
if [[ -n "$attrs" ]]; then
    echo "warning: $(grep -c . <<<"$attrs") extended attributes left on $app ($(sed 's/.*: //' <<<"$attrs" | sort -u | paste -sd, -)); they become ._* files in the package" >&2
fi

if [[ "$dry" == 1 ]]; then
    codesign --force --options runtime --entitlements "$entitlements" --sign - "$app"
else
    # -X: a downloaded profile is quarantined, and that would end up in the package.
    cp -X "$profile" "$app/Contents/embedded.provisionprofile"
    # The base entitlements plus the two the profile authorizes; without them a build
    # with an embedded profile can't go to TestFlight. They name the team, so they're
    # added here rather than kept in appstore/.
    signed_entitlements="$out/Fringe.entitlements"
    cp "$entitlements" "$signed_entitlements"
    plutil -insert com\\.apple\\.application-identifier -string "$team.$bundle_id" "$signed_entitlements"
    plutil -insert com\\.apple\\.developer\\.team-identifier -string "$team" "$signed_entitlements"
    # No secure timestamp: Apple re-signs App Store apps, and only Developer ID
    # signatures need one. The hardened runtime isn't required here either, but costs
    # nothing (the app needs no exceptions) and matches the Developer ID build.
    codesign --force --options runtime --timestamp=none --entitlements "$signed_entitlements" \
        --sign "$app_identity" "$app"
fi

codesign --verify --strict --verbose=2 "$app"
echo "entitlements:"
signed="$(codesign -d --entitlements - --xml "$app" 2>/dev/null)"
plutil -p - <<<"$signed"
if [[ "$(plutil -extract com\\.apple\\.security\\.app-sandbox raw -o - - <<<"$signed")" != true ]]; then
    echo "error: the signed app isn't sandboxed" >&2
    exit 1
fi
# Fringe has no network access, and App Review asks about entitlements it doesn't use.
if grep -q 'com\.apple\.security\.network\.' <<<"$signed"; then
    echo "error: the signed app has a network entitlement" >&2
    exit 1
fi

# The package installs the app into /Applications; App Store Connect takes nothing else.
if [[ "$dry" == 1 ]]; then
    pkg="$dist/Fringe-$version-appstore-unsigned.pkg"
    productbuild --component "$app" /Applications "$pkg"
    echo "dry run (FRINGE_APPSTORE_DRY=1): ad hoc signed, no profile, unsigned package; not for upload"
else
    pkg="$dist/Fringe-$version-appstore.pkg"
    productbuild --component "$app" /Applications --sign "$installer_identity" "$pkg"
    pkgutil --check-signature "$pkg"
fi
echo
echo "built: $app"
echo "       $pkg"

# altool authenticates with an app-specific password kept in the keychain, or with an
# App Store Connect API key (AuthKey_<id>.p8 in ~/.appstoreconnect/private_keys).
apple_id="${FRINGE_APPSTORE_APPLE_ID:-<Apple ID>}"
auth=(-u "$apple_id" -p "@keychain:$keychain_item")
if [[ "$upload" == 1 ]]; then
    xcrun altool --validate-app "$pkg" "${auth[@]}"
    xcrun altool --upload-package "$pkg" "${auth[@]}" --show-progress
    echo "uploaded; it shows up in App Store Connect > TestFlight once processed"
elif [[ "$dry" != 1 ]]; then
    cat <<NEXT

To upload (or set FRINGE_APPSTORE_UPLOAD=1), with an app-specific password from
account.apple.com stored once by
  xcrun altool --store-password-in-keychain-item $keychain_item -u $apple_id
run
  xcrun altool --validate-app "$pkg" -u $apple_id -p @keychain:$keychain_item
  xcrun altool --upload-package "$pkg" -u $apple_id -p @keychain:$keychain_item
or, with an App Store Connect API key, replace the -u/-p arguments with
  --api-key <key id> --api-issuer <issuer id>
NEXT
fi
