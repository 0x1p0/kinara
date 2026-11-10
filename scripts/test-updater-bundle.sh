#!/bin/bash
set -euo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
cd "$project_directory"
source_bundle="${1:-$project_directory/build/Kinara.app}"
test -f "$source_bundle/Contents/Info.plist"
test_directory="$(mktemp -d /tmp/sway-updater-smoke.XXXXXX)"
test_bundle="$test_directory/Updater Smoke.app"
mkdir -p "$test_bundle/Contents/MacOS" "$test_bundle/Contents/Frameworks"
cp "$source_bundle/Contents/Info.plist" "$test_bundle/Contents/Info.plist"
plist_tool=/usr/libexec/PlistBuddy
"$plist_tool" -c "Set :CFBundleIdentifier com.sway.updater-smoke.$(uuidgen)" "$test_bundle/Contents/Info.plist"
"$plist_tool" -c 'Set :CFBundleExecutable UpdaterSmoke' "$test_bundle/Contents/Info.plist"
"$plist_tool" -c 'Set :CFBundleName Updater Smoke' "$test_bundle/Contents/Info.plist"
ditto "$source_bundle/Contents/Frameworks/Sparkle.framework" "$test_bundle/Contents/Frameworks/Sparkle.framework"
xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
    -module-cache-path "$test_directory/ModuleCache" \
    -F "$test_bundle/Contents/Frameworks" -framework Sparkle -framework AppKit \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Tests/updater_smoke.swift -o "$test_bundle/Contents/MacOS/UpdaterSmoke"
codesign --force --sign - --options runtime --timestamp=none \
    --entitlements Sway/Sway.entitlements "$test_bundle"
codesign --verify --deep --strict "$test_bundle"
bash scripts/verify-runtime.sh "$test_bundle"
"$test_bundle/Contents/MacOS/UpdaterSmoke"
