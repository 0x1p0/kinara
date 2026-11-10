#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/kinara-audio-tests.XXXXXX)"
test_arch="$(uname -m)"
cd "$project_dir"
xcrun swiftc -D KINARA_AUDIO_TESTS -swift-version 5 -warnings-as-errors -O \
    -target "$test_arch-apple-macos13.0" -module-cache-path "$test_dir/module-cache" \
    Kinara/VolumeController.swift Tests/audio_regressions.swift \
    -framework CoreAudio -o "$test_dir/audio-regressions"
"$test_dir/audio-regressions"
printf 'Test executable: %s\n' "$test_dir/audio-regressions"
