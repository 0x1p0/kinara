#!/bin/bash
# Synthetic touch sequences built from measured contact shapes. Opens no
# window, starts no trackpad device and changes nothing on this Mac.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/kinara-palm-tests.XXXXXX)"
test_arch="$(uname -m)"
cd "$project_dir"
xcrun swiftc -D KINARA_GESTURE_TESTS -warnings-as-errors \
    -target "$test_arch-apple-macos13.0" -module-cache-path "$test_dir/module-cache" \
    Kinara/PalmRejectionManager.swift Tests/palm_rejection_regressions.swift \
    -o "$test_dir/palm-rejection-regressions"
"$test_dir/palm-rejection-regressions"
printf 'Test executable: %s\n' "$test_dir"
