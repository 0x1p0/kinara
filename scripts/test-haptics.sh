#!/bin/bash
# Exercise timing and pattern delivery with a fake clock/performer, never hardware.
set -euo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
test_directory="$(mktemp -d /tmp/kinara-haptic-tests.XXXXXX)"
test_arch="$(uname -m)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
cd "$project_directory"
xcrun swiftc -target "$test_arch-apple-macos13.0" -sdk "$sdk_path" \
    -swift-version 5 -warnings-as-errors -parse-as-library \
    -module-cache-path "$test_directory/ModuleCache" \
    Kinara/HapticFeedback.swift Tests/haptic_regressions.swift \
    -framework AppKit -o "$test_directory/haptic-regressions"
"$test_directory/haptic-regressions"
