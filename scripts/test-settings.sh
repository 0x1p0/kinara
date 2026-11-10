#!/bin/bash
# Deterministic regression checks for the production settings model.
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
test_directory="$(mktemp -d /tmp/sway-settings-tests.XXXXXX)"
test_arch="$(uname -m)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
cd "$project_directory"

# Compile the real dependencies. The harness only initializes settings with
# isolated preferences and never calls shortcut or login registration setters.
# No AppDelegate, touch monitor, bridge, or hardware controller is linked.
xcrun swiftc -target "$test_arch-apple-macos13.0" -sdk "$sdk_path" \
    -swift-version 5 -warnings-as-errors -parse-as-library \
    -module-cache-path "$test_directory/ModuleCache" \
    Sway/TrackpadSettings.swift Sway/HapticFeedback.swift Sway/Overlay.swift Sway/LoginItemManager.swift Sway/HotkeyManager.swift \
    Tests/settings_regressions.swift \
    -framework AppKit -framework SwiftUI -framework Carbon -framework ServiceManagement \
    -o "$test_directory/settings-regressions"
"$test_directory/settings-regressions"
printf 'Test executable: %s\n' "$test_directory/settings-regressions"
