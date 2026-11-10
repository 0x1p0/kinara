#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/kinara-control-tests.XXXXXX)"
test_arch="$(uname -m)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
cd "$project_dir"
xcrun clang -target "$test_arch-apple-macos13.0" -isysroot "$sdk_path" \
    -Wall -Wextra -Werror -c Kinara/MultitouchBridge.c -o "$test_dir/MultitouchBridge.o"
sources=()
for source in Kinara/*.swift; do
    if [[ "$source" != "Kinara/KinaraApp.swift" ]]; then sources+=("$source"); fi
done
xcrun swiftc -D KINARA_AUDIO_TESTS -D KINARA_CONTROL_TESTS -swift-version 5 -warnings-as-errors -O \
    -target "$test_arch-apple-macos13.0" -sdk "$sdk_path" -module-cache-path "$test_dir/module-cache" \
    -import-objc-header Kinara/Kinara-Bridging-Header.h \
    "${sources[@]}" Tests/control_model_regressions.swift "$test_dir/MultitouchBridge.o" \
    -framework AppKit -framework SwiftUI -framework CoreAudio -framework IOKit \
    -framework Carbon -framework ServiceManagement -o "$test_dir/control-model-regressions"
"$test_dir/control-model-regressions"
printf 'Test executable: %s\n' "$test_dir/control-model-regressions"
