#!/bin/bash
# Exercise Now Playing parsing, formatting, and player choice as pure logic.
# Never sends Apple Events, queries MediaRemote, makes requests, or opens windows.
set -euo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
test_directory="$(mktemp -d /tmp/kinara-now-playing-tests.XXXXXX)"
test_arch="$(uname -m)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
cd "$project_directory"
xcrun swiftc -target "$test_arch-apple-macos13.0" -sdk "$sdk_path" \
    -swift-version 5 -warnings-as-errors -parse-as-library \
    -module-cache-path "$test_directory/ModuleCache" \
    Kinara/NowPlaying.swift Kinara/HUDMotion.swift Tests/now_playing_regressions.swift \
    -framework AppKit -o "$test_directory/now-playing-regressions"
"$test_directory/now-playing-regressions"
