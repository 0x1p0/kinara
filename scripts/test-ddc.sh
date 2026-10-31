#!/bin/bash
# Exercise DDC/CI packets, display matching and bus pacing with in-memory
# monitors, never hardware: no IORegistry walk or I2C transfer runs.
set -euo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
test_directory="$(mktemp -d /tmp/sway-ddc-tests.XXXXXX)"
test_arch="$(uname -m)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
cd "$project_directory"
# The app ships universal; the Intel slice must keep compiling.
for arch in arm64 x86_64; do
    xcrun swiftc -target "$arch-apple-macos13.0" -sdk "$sdk_path" \
        -swift-version 5 -warnings-as-errors -typecheck \
        -module-cache-path "$test_directory/ModuleCache" Sway/ExternalDisplayDDC.swift
done
xcrun swiftc -target "$test_arch-apple-macos13.0" -sdk "$sdk_path" \
    -swift-version 5 -warnings-as-errors -parse-as-library \
    -module-cache-path "$test_directory/ModuleCache" \
    Sway/ExternalDisplayDDC.swift Tests/ddc_regressions.swift \
    -framework CoreGraphics -framework IOKit -o "$test_directory/ddc-regressions"
"$test_directory/ddc-regressions"
