#!/bin/bash
# Local signing uses the existing Keychain key. CI invokes the precompiled
# helper on a fresh, approval-gated runner without any package installation.
set -euo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
cd "$project_directory"
version="$(bash scripts/release-version.sh "${2:-}")"
release_directory="$(cd -- "$1" && pwd)"
archive="Kinara-$version-macos-universal.zip"
test -s "$release_directory/$archive"
if [[ -e "$release_directory/appcast.xml" ]]; then
    printf 'Refusing to replace an existing signed feed.\n' >&2
    exit 2
fi
feed_directory="$(mktemp -d "$project_directory/build/UpdateFeed.XXXXXX")"
xcrun swiftc -swift-version 5 -warnings-as-errors scripts/sign-update.swift -o "$feed_directory/sign-update"
xcrun swiftc -swift-version 5 -warnings-as-errors scripts/verify-update-feed.swift -o "$feed_directory/verify-update"
"$feed_directory/sign-update" "$release_directory" Sway/Info.plist "releases/v$version.md" "v$version"
"$feed_directory/verify-update" "$release_directory/appcast.xml" "$release_directory/$archive" Sway/Info.plist
(
    cd "$release_directory"
    shasum -a 256 -c SHA256SUMS.txt
)
