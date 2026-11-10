#!/bin/bash
# Compile a separate render executable. It never launches Kinara's AppDelegate.
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
render_directory="$project_directory/build/UIRender"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
render_arch="$(uname -m)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
if [[ "${sdk_version%%.*}" -lt 26 ]]; then
    printf 'Rendering Kinara requires Xcode 26 or later (macOS 26 SDK).\n' >&2
    exit 2
fi
mkdir -p "$render_directory/ModuleCache"
cd "$project_directory"

xcrun clang -target "$render_arch-apple-macos13.0" -isysroot "$sdk_path" \
    -Wall -Wextra -Werror -c Sway/MultitouchBridge.c \
    -o "$render_directory/MultitouchBridge.o"

sources=()
for source in Sway/*.swift; do
    if [[ "$source" != "Sway/SwayApp.swift" ]]; then
        sources+=("$source")
    fi
done

xcrun swiftc -target "$render_arch-apple-macos13.0" -sdk "$sdk_path" \
    -swift-version 5 -warnings-as-errors -parse-as-library \
    -module-cache-path "$render_directory/ModuleCache" \
    -import-objc-header Sway/Sway-Bridging-Header.h \
    "${sources[@]}" Tests/RenderUI.swift "$render_directory/MultitouchBridge.o" \
    -framework AppKit -framework SwiftUI -framework CoreAudio \
    -framework IOKit -framework Carbon -framework ServiceManagement \
    -o "$render_directory/RenderUI"

"$render_directory/RenderUI" "$render_directory"

# A separate, safe app bundle makes the native NSPopover fixture inspectable
# through normal macOS accessibility tools. It never launches production Kinara.
preview_bundle="$render_directory/Kinara UI Preview.app"
mkdir -p "$preview_bundle/Contents/MacOS"
cp "$render_directory/RenderUI" "$preview_bundle/Contents/MacOS/RenderUI"
preview_plist="$preview_bundle/Contents/Info.plist"
plutil -create xml1 "$preview_plist"
plutil -insert CFBundleIdentifier -string com.sway.uipreview "$preview_plist"
plutil -insert CFBundleName -string 'Kinara UI Preview' "$preview_plist"
plutil -insert CFBundleExecutable -string RenderUI "$preview_plist"
plutil -insert CFBundlePackageType -string APPL "$preview_plist"
plutil -insert LSUIElement -bool YES "$preview_plist"
plutil -insert LSMinimumSystemVersion -string 13.0 "$preview_plist"
codesign --force --sign - "$preview_bundle"

# Actual nonactivating OSD windows, each with the production NSGlassEffectView
# hierarchy, over light and dark backdrops. This app is also preview-only.
indicator_bundle="$render_directory/Kinara Indicator Preview.app"
mkdir -p "$indicator_bundle/Contents/MacOS"
cp "$render_directory/RenderUI" "$indicator_bundle/Contents/MacOS/RenderUI"
indicator_plist="$indicator_bundle/Contents/Info.plist"
plutil -create xml1 "$indicator_plist"
plutil -insert CFBundleIdentifier -string com.sway.osdpreview "$indicator_plist"
plutil -insert CFBundleName -string 'Kinara Indicator Preview' "$indicator_plist"
plutil -insert CFBundleExecutable -string RenderUI "$indicator_plist"
plutil -insert CFBundlePackageType -string APPL "$indicator_plist"
plutil -insert LSUIElement -bool YES "$indicator_plist"
plutil -insert LSMinimumSystemVersion -string 13.0 "$indicator_plist"
codesign --force --sign - "$indicator_bundle"
