#!/usr/bin/env bash
# Build the app and run its schema self-test: every example scene from the core must
# decode into the Swift model, re-encode to the same JSON, pass the core's check and
# decode again to the same value. No window opens.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$root/scripts/build.sh"

bin_dir="$(cd "$root/swift" && swift build -c release --show-bin-path)"
bin="$bin_dir/Fringe"
if [[ ! -x "$bin" ]]; then
    echo "check-schema: no app binary at $bin" >&2
    exit 1
fi

"$bin" --self-test-schema
