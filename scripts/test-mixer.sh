#!/bin/bash
# Exercise the mixer's rules and its preview model. Never creates a process
# tap or aggregate device, changes audio routing, or triggers a permission
# prompt: the tap engine traps if a test ever reaches Core Audio.
set -euo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
test_directory="$(mktemp -d /tmp/sway-mixer-tests.XXXXXX)"
test_arch="$(uname -m)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
cd "$project_directory"
xcrun swiftc -D SWAY_APP_VOLUME_TESTS -D SWAY_MIXER_TESTS -target "$test_arch-apple-macos13.0" -sdk "$sdk_path" \
    -swift-version 5 -warnings-as-errors -parse-as-library -O \
    -module-cache-path "$test_directory/ModuleCache" \
    Sway/AppVolumeController.swift Sway/Mixer.swift Tests/mixer_regressions.swift \
    -framework AppKit -framework CoreAudio -o "$test_directory/mixer-regressions"
"$test_directory/mixer-regressions"
