#!/bin/bash
# Render the edge light offscreen and check the overlay window; nothing is shown.
set -euo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
test_directory="$(mktemp -d /tmp/sway-edge-light-tests.XXXXXX)"
test_arch="$(uname -m)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
cd "$project_directory"
xcrun swiftc -target "$test_arch-apple-macos13.0" -sdk "$sdk_path" \
    -swift-version 5 -warnings-as-errors -parse-as-library \
    -module-cache-path "$test_directory/ModuleCache" \
    Sway/Overlay.swift Tests/edge_light_regressions.swift \
    -framework AppKit -o "$test_directory/edge-light-regressions"
"$test_directory/edge-light-regressions"
