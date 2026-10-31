#!/bin/bash
# Exercise the per-app volume mixer, process ownership rules, gain clamping and
# request queue with hand-built buffers only. Never creates a process tap or
# aggregate device, changes audio routing, or triggers a permission prompt.
set -euo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
test_directory="$(mktemp -d /tmp/sway-app-volume-tests.XXXXXX)"
test_arch="$(uname -m)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
cd "$project_directory"
xcrun swiftc -D SWAY_APP_VOLUME_TESTS -target "$test_arch-apple-macos13.0" -sdk "$sdk_path" \
    -swift-version 5 -warnings-as-errors -parse-as-library -O \
    -module-cache-path "$test_directory/ModuleCache" \
    Sway/AppVolumeController.swift Tests/app_volume_regressions.swift \
    -framework AppKit -framework CoreAudio -o "$test_directory/app-volume-regressions"
"$test_directory/app-volume-regressions"
