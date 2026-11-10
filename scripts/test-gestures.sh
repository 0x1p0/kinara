#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/kinara-gesture-tests.XXXXXX)"
test_arch="$(uname -m)"
# Keep the tiny executables available for inspection; no user files are removed.
cd "$project_dir"
xcrun swiftc -D KINARA_GESTURE_TESTS -warnings-as-errors \
    -target "$test_arch-apple-macos13.0" -module-cache-path "$test_dir/module-cache" \
    Kinara/PalmRejectionManager.swift Tests/gesture_regressions.swift \
    -o "$test_dir/gesture-regressions"
"$test_dir/gesture-regressions"
xcrun clang -Wall -Wextra -Werror -target "$test_arch-apple-macos13.0" \
    Tests/bridge_regressions.c -framework CoreFoundation -o "$test_dir/bridge-regressions"
"$test_dir/bridge-regressions"
printf 'Test executables: %s\n' "$test_dir"
