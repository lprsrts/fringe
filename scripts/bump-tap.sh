#!/usr/bin/env bash
# Point the Homebrew tap (lprsrts/homebrew-tap) at a published release: the cask's
# version and DMG checksum, and the fringe-cli formula's source tarball and checksum.
# Run it after `gh release create`; it reads the checksums from the release itself,
# so it only works once the release is public.
#
#   scripts/bump-tap.sh [version]   default: the version in Cargo.toml
#
#   FRINGE_TAP_PUSH=0   show the change but don't commit or push
#   FRINGE_TAP_DIR      use this checkout of the tap instead of a fresh clone
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="lprsrts/fringe"
tap_repo="lprsrts/homebrew-tap"
version="${1:-$(awk -F'"' '/^version *=/ { print $2; exit }' "$root/Cargo.toml")}"
tag="v$version"
push="${FRINGE_TAP_PUSH:-1}"

# Both checksums come from GitHub, not dist/: what users download is what counts.
# `gh release view` also finds drafts (with the owner's token), so check the state and
# that the DMG downloads without credentials.
state="$(gh release view "$tag" --repo "$repo" --json isDraft,isPrerelease \
    --jq 'if .isDraft then "draft" elif .isPrerelease then "prerelease" else "published" end' 2>/dev/null)" || {
    echo "error: no release $tag in $repo; publish it first" >&2
    exit 1
}
if [[ "$state" != published ]]; then
    echo "error: $tag is a $state; the cask follows published releases only" >&2
    exit 1
fi
dmg="Fringe-$version-macos-arm64.dmg"
if ! curl -fsIL -o /dev/null "https://github.com/$repo/releases/download/$tag/$dmg"; then
    echo "error: $dmg is not publicly downloadable from $tag" >&2
    exit 1
fi
dmg_sha="$(gh release download "$tag" --repo "$repo" --pattern SHA256SUMS --output - | awk -v f="$dmg" '$2 == f { print $1 }')"
if [[ ! "$dmg_sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: $tag's SHA256SUMS has no entry for $dmg" >&2
    exit 1
fi
source_url="https://github.com/$repo/archive/refs/tags/$tag.tar.gz"
source_sha="$(curl -fsSL "$source_url" | shasum -a 256 | awk '{ print $1 }')"

work=""
if [[ -n "${FRINGE_TAP_DIR:-}" ]]; then
    # An existing checkout must be clean and current, so the commit holds only the
    # bump and goes on top of what is published.
    tap="$FRINGE_TAP_DIR"
    if [[ -n "$(git -C "$tap" status --porcelain)" ]]; then
        echo "error: $tap has uncommitted changes" >&2
        exit 1
    fi
    if [[ "$(git -C "$tap" branch --show-current)" != main ]]; then
        echo "error: $tap is not on main" >&2
        exit 1
    fi
    git -C "$tap" pull --quiet --ff-only
else
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    tap="$work/tap"
    gh repo clone "$tap_repo" "$tap" -- --quiet
fi

# Rewrite the top-level stanzas only (two-space indent), so a later bottle block's
# sha256 lines are left alone.
python3 - "$tap/Casks/fringe.rb" "$tap/Formula/fringe-cli.rb" "$version" "$dmg_sha" "$source_url" "$source_sha" <<'PY'
import re
import sys

cask, formula, version, dmg_sha, source_url, source_sha = sys.argv[1:]


def rewrite(path, subs):
    text = open(path).read()
    for pattern, value in subs:
        text, n = re.subn(pattern, lambda m: m.group(1) + value + m.group(2), text, count=1, flags=re.M)
        if n != 1:
            sys.exit(f"error: {path}: no line matches {pattern}")
    open(path, "w").write(text)


rewrite(cask, [(r'^(  version ")[^"]*(")', version), (r'^(  sha256 ")[^"]*(")', dmg_sha)])
rewrite(formula, [(r'^(  url ")[^"]*(")', source_url), (r'^(  sha256 ")[^"]*(")', source_sha)])
PY

files=(Casks/fringe.rb Formula/fringe-cli.rb)
if git -C "$tap" diff --quiet -- "${files[@]}"; then
    # Nothing to change here; still push a bump an earlier run committed but failed
    # to push.
    if [[ "$push" == 1 && -n "$(git -C "$tap" rev-list '@{upstream}..HEAD')" ]]; then
        git -C "$tap" push --quiet
        echo "pushed the pending bump to $tap_repo"
    else
        echo "the tap already points at $tag"
    fi
    exit 0
fi
git -C "$tap" --no-pager diff -- "${files[@]}"

if [[ "$push" != 1 ]]; then
    echo "not committed (FRINGE_TAP_PUSH=0)"
    exit 0
fi
git -C "$tap" commit --quiet --message "fringe $version" -- "${files[@]}"
git -C "$tap" push --quiet
echo "pushed fringe $version to $tap_repo; users get it with: brew update && brew upgrade --cask fringe"
