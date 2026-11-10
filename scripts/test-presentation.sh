#!/bin/bash
set -euo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
test_directory="$(mktemp -d /tmp/sway-presentation-tests.XXXXXX)"
test_arch="$(uname -m)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
cd "$project_directory"
xcrun swiftc -target "$test_arch-apple-macos13.0" -sdk "$sdk_path" \
    -swift-version 5 -warnings-as-errors -parse-as-library \
    -module-cache-path "$test_directory/ModuleCache" \
    Sway/AppPresentation.swift Tests/presentation_regressions.swift \
    -framework AppKit -framework SwiftUI -o "$test_directory/presentation-regressions"
if [[ "${1:-}" == "--live" ]]; then
    # Match the production app's bundle/lifecycle. The fixture starts its
    # checks from a real button click because recent macOS can deny unsolicited
    # activation by a terminal's child process.
    test_bundle="$test_directory/Kinara Presentation Test.app"
    mkdir -p "$test_bundle/Contents/MacOS"
    cp "$test_directory/presentation-regressions" "$test_bundle/Contents/MacOS/PresentationTest"
    test_plist="$test_bundle/Contents/Info.plist"
    plutil -create xml1 "$test_plist"
    plutil -insert CFBundleIdentifier -string com.sway.presentationtest "$test_plist"
    plutil -insert CFBundleName -string 'Kinara Presentation Test' "$test_plist"
    plutil -insert CFBundleExecutable -string PresentationTest "$test_plist"
    plutil -insert CFBundlePackageType -string APPL "$test_plist"
    plutil -insert LSUIElement -bool YES "$test_plist"
    plutil -insert LSMinimumSystemVersion -string 13.0 "$test_plist"
    codesign --force --sign - "$test_bundle"
    printf 'Click Run focus test in the safe preview window (within 60 seconds).\n'
    /usr/bin/open -n -W --stdout "$test_directory/results.log" --stderr "$test_directory/errors.log" "$test_bundle" --args --live
    cat "$test_directory/results.log" "$test_directory/errors.log"
    grep -Eq '^[0-9]+ presentation assertions passed\.' "$test_directory/results.log"
else
    "$test_directory/presentation-regressions" "$@"
fi
