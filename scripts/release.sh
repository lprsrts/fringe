#!/usr/bin/env bash
# Build a release into dist/: Fringe-<version>-macos-arm64.dmg (Developer ID signed,
# notarized, stapled), fringe-cli-<version>-aarch64-apple-darwin.tar.gz (signed and
# notarized) and SHA256SUMS. Publishing (git tag, gh release, the Homebrew tap) is
# left to you; the script prints the commands.
#
#   FRINGE_SIGN_IDENTITY   signing identity; default: the one Developer ID Application
#                          identity in the keychain
#   FRINGE_NOTARY_PROFILE  notarytool keychain profile (default fringe-notary), made with
#                          xcrun notarytool store-credentials
#   FRINGE_NOTARIZE=0      sign and package, but skip notarization (a local dry run)
#   FRINGE_ALLOW_DIRTY=1   allow uncommitted changes (the build number counts commits,
#                          so a dirty release isn't reproducible)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist="$root/dist"
version="$(awk -F'"' '/^version *=/ { print $2; exit }' "$root/Cargo.toml")"
profile="${FRINGE_NOTARY_PROFILE:-fringe-notary}"
notarize="${FRINGE_NOTARIZE:-1}"

if [[ "${FRINGE_ALLOW_DIRTY:-0}" != 1 && -n "$(git -C "$root" status --porcelain)" ]]; then
    echo "error: uncommitted changes; commit them or set FRINGE_ALLOW_DIRTY=1" >&2
    exit 1
fi

identity="${FRINGE_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identities="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p')"
    if [[ "$(printf '%s' "$identities" | grep -c .)" != 1 ]]; then
        echo "error: expected exactly one Developer ID Application identity, found:" >&2
        printf '%s\n' "${identities:-  (none)}" >&2
        echo "set FRINGE_SIGN_IDENTITY to choose one" >&2
        exit 1
    fi
    identity="$identities"
fi
echo "signing as: $identity"

if [[ "$notarize" == 1 ]] && ! xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
    echo "error: no notarytool profile \"$profile\"; run" >&2
    echo "  xcrun notarytool store-credentials $profile --apple-id <Apple ID> --team-id <team id>" >&2
    echo "or set FRINGE_NOTARIZE=0 for a dry run" >&2
    exit 1
fi

notarize_file() {
    local file="$1" out id
    out="$(xcrun notarytool submit "$file" --keychain-profile "$profile" --wait --output-format plist)"
    id="$(plutil -extract id raw - <<<"$out")"
    # The log lists warnings even for an accepted submission.
    xcrun notarytool log "$id" --keychain-profile "$profile" "$dist/notary-$(basename "$file").json" >/dev/null
    if [[ "$(plutil -extract status raw - <<<"$out")" != Accepted ]]; then
        echo "error: notarization of $(basename "$file") failed; see $dist/notary-$(basename "$file").json" >&2
        exit 1
    fi
}

# The notices ship in the app and the tarball, so they must match Cargo.lock.
python3 "$root/scripts/third-party-licenses.py" --check

rm -rf "$dist"
mkdir -p "$dist"

# App: build with paths remapped, sign with the hardened runtime and a timestamp.
FRINGE_RELEASE=1 FRINGE_SIGN_IDENTITY="$identity" "$root/scripts/bundle.sh"
app="$root/target/Fringe.app"
codesign --verify --strict --verbose=2 "$app"
for bin in "$app/Contents/MacOS/Fringe" "$root/target/release/fringe-cli"; do
    # Scan the raw bytes: strings skips __LINKEDIT (debug-map stabs live there), and
    # `strings | grep -q` under pipefail reports SIGPIPE as "no match".
    if LC_ALL=C grep -a -q -F -- "$HOME" "$bin"; then
        echo "error: $bin still contains paths under $HOME" >&2
        exit 1
    fi
done

# DMG: the app and a link to /Applications. Only the DMG is notarized and stapled; its
# ticket covers the app inside, so Gatekeeper can check the app offline once mounted.
dmg="$dist/Fringe-$version-macos-arm64.dmg"
stage="$(mktemp -d)"
chmod 755 "$stage"   # mktemp makes it 0700, which would become the volume root
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Fringe.app"
ln -s /Applications "$stage/Applications"
diskutil image create from --format UDZO --volumeName "Fringe $version" "$stage" "$dmg" >/dev/null
codesign --force --timestamp --sign "$identity" "$dmg"

# CLI: a bare Mach-O can be notarized (inside a zip) but not stapled; Gatekeeper
# looks the ticket up online the first time it runs.
cli="$root/target/release/fringe-cli"
codesign --force --options runtime --timestamp --identifier com.asympton.fringe.cli --sign "$identity" "$cli"
cli_tar="$dist/fringe-cli-$version-aarch64-apple-darwin.tar.gz"
tar -czf "$cli_tar" -C "$root/target/release" fringe-cli \
    -C "$root" LICENSE-MIT LICENSE-APACHE THIRD-PARTY-LICENSES.txt

if [[ "$notarize" == 1 ]]; then
    notarize_file "$dmg"
    xcrun stapler staple "$dmg"
    cli_zip="$(mktemp -d)/fringe-cli.zip"
    ditto -c -k "$cli" "$cli_zip"
    notarize_file "$cli_zip"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
else
    echo "notarization skipped (FRINGE_NOTARIZE=0): not for distribution"
fi

(cd "$dist" && shasum -a 256 "$(basename "$dmg")" "$(basename "$cli_tar")" > SHA256SUMS)
echo
echo "built in $dist:"
ls -1 "$dist"
cat <<NEXT

To publish:
  git tag -a v$version -m "Fringe $version" && git push origin v$version
  gh release create v$version "$dmg" "$cli_tar" "$dist/SHA256SUMS" --title "Fringe $version"
NEXT
