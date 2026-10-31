#!/bin/bash
set -euo pipefail
project_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_directory="$(mktemp -d /tmp/sway-brightness-tests.XXXXXX)"
test_arch="$(uname -m)"
cd "$project_directory"
xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
    -target "$test_arch-apple-macos13.0" -module-cache-path "$test_directory/ModuleCache" \
    Sway/BrightnessController.swift Sway/ExternalDisplayDDC.swift Tests/brightness_regressions.swift \
    -framework CoreGraphics -framework IOKit -o "$test_directory/brightness-regressions"
"$test_directory/brightness-regressions"
printf 'Test executable: %s\n' "$test_directory/brightness-regressions"
