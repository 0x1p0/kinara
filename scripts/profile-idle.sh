#!/bin/bash
# Bounded read-only paused lifecycle profile; no saved preferences or hardware
# levels are changed. Run in a normal macOS graphical login session.
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
profile_directory="$project_directory/build/IdleProfile"
profile_arch="$(uname -m)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
if [[ "${sdk_version%%.*}" -lt 26 ]]; then
    printf 'Profiling Kinara requires Xcode 26 or later (macOS 26 SDK).\n' >&2
    exit 2
fi
mkdir -p "$profile_directory/ModuleCache"
cd "$project_directory"

xcrun clang -target "$profile_arch-apple-macos13.0" -isysroot "$sdk_path" \
    -Wall -Wextra -Werror -O2 -c Sway/MultitouchBridge.c \
    -o "$profile_directory/MultitouchBridge.o"

sources=()
for source in Sway/*.swift; do
    if [[ "$source" != "Sway/SwayApp.swift" ]]; then sources+=("$source"); fi
done

xcrun swiftc -target "$profile_arch-apple-macos13.0" -sdk "$sdk_path" \
    -swift-version 5 -warnings-as-errors -O -parse-as-library \
    -module-cache-path "$profile_directory/ModuleCache" \
    -import-objc-header Sway/Sway-Bridging-Header.h \
    "${sources[@]}" Tests/IdleProfile.swift "$profile_directory/MultitouchBridge.o" \
    -framework AppKit -framework SwiftUI -framework CoreAudio \
    -framework IOKit -framework Carbon -framework ServiceManagement \
    -o "$profile_directory/SwayIdleProfile"

"$profile_directory/SwayIdleProfile"
