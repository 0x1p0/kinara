#!/bin/bash
# Build a local, ad-hoc signed app without changing an installed copy of Kinara.
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
output_directory="$project_directory/build"
build_arch="${SWAY_ARCH:-$(uname -m)}"
build_method="${1:---xcode}"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"

if [[ "${sdk_version%%.*}" -lt 26 ]]; then
    printf 'Building Kinara requires Xcode 26 or later (macOS 26 SDK). The built app still supports macOS 13+.\n' >&2
    exit 2
fi

case "$build_arch" in
    arm64|x86_64)
        xcode_archs="$build_arch"
        xcode_destination="platform=macOS,arch=$build_arch"
        only_active_arch=YES
        ;;
    universal)
        if [[ "$build_method" != "--xcode" ]]; then
            printf 'Universal builds require the Xcode build path.\n' >&2
            exit 2
        fi
        xcode_archs="arm64 x86_64"
        xcode_destination="generic/platform=macOS"
        only_active_arch=NO
        ;;
    *) printf 'Unsupported architecture: %s\n' "$build_arch" >&2; exit 2 ;;
esac

mkdir -p "$output_directory"
cd "$project_directory"
package_directory="$(mktemp -d "$output_directory/Package.XXXXXX")"
bundle_directory="$package_directory/Kinara.app"
sparkle_directory="$(bash scripts/setup-sparkle.sh)"
sparkle_frameworks="$sparkle_directory/Sparkle.xcframework/macos-arm64_x86_64"

if [[ "$build_method" == "--xcode" ]]; then
    xcodebuild -quiet -project Sway.xcodeproj -scheme Sway \
        -configuration Release -destination "$xcode_destination" \
        -derivedDataPath "$output_directory/DerivedData" \
        -clonedSourcePackagesDirPath "$output_directory/SourcePackages" \
        -onlyUsePackageVersionsFromResolvedFile \
        ARCHS="$xcode_archs" ONLY_ACTIVE_ARCH="$only_active_arch" \
        CODE_SIGNING_ALLOWED=NO \
        GCC_TREAT_WARNINGS_AS_ERRORS=YES SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build
    ditto "$output_directory/DerivedData/Build/Products/Release/Kinara.app" \
        "$bundle_directory"
elif [[ "$build_method" == "--direct" ]]; then
    # Useful when an installed Xcode build service is broken. This still uses
    # the selected Xcode SDK and compiler, including its normal macro sandbox.
    sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
    intermediate_directory="$output_directory/Direct"
    mkdir -p "$intermediate_directory/ModuleCache" \
        "$bundle_directory/Contents/MacOS" "$bundle_directory/Contents/Resources"

    xcrun clang -target "$build_arch-apple-macos13.0" -isysroot "$sdk_path" \
        -Wall -Wextra -Werror -c Sway/MultitouchBridge.c \
        -o "$intermediate_directory/MultitouchBridge.o"
    xcrun swiftc -target "$build_arch-apple-macos13.0" -sdk "$sdk_path" \
        -swift-version 5 -warnings-as-errors -O -module-name Sway \
        -module-cache-path "$intermediate_directory/ModuleCache" \
        -import-objc-header Sway/Sway-Bridging-Header.h \
        Sway/*.swift "$intermediate_directory/MultitouchBridge.o" \
        -framework AppKit -framework SwiftUI -framework CoreAudio \
        -framework IOKit -framework Carbon -framework ServiceManagement \
        -F "$sparkle_frameworks" -framework Sparkle \
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
        -o "$bundle_directory/Contents/MacOS/Kinara"

    mkdir -p "$bundle_directory/Contents/Frameworks"
    ditto "$sparkle_frameworks/Sparkle.framework" "$bundle_directory/Contents/Frameworks/Sparkle.framework"

    cp Sway/Info.plist "$bundle_directory/Contents/Info.plist"
    plist_tool=/usr/libexec/PlistBuddy
    "$plist_tool" -c 'Set :CFBundleDevelopmentRegion en' "$bundle_directory/Contents/Info.plist"
    "$plist_tool" -c 'Set :CFBundleExecutable Kinara' "$bundle_directory/Contents/Info.plist"
    "$plist_tool" -c 'Set :CFBundleIdentifier com.trackpadcontrol.app' "$bundle_directory/Contents/Info.plist"
    "$plist_tool" -c 'Set :CFBundleName Kinara' "$bundle_directory/Contents/Info.plist"
    "$plist_tool" -c 'Set :CFBundlePackageType APPL' "$bundle_directory/Contents/Info.plist"
    "$plist_tool" -c 'Set :LSMinimumSystemVersion 13.0' "$bundle_directory/Contents/Info.plist"
    "$plist_tool" -c 'Set :CFBundleIconFile AppIcon' "$bundle_directory/Contents/Info.plist"

    icon_directory="$intermediate_directory/AppIcon.iconset"
    icon_source=Sway/Assets.xcassets/AppIcon.appiconset
    mkdir -p "$icon_directory"
    for size in 16 32 128 256 512; do
        double_size=$((size * 2))
        cp "$icon_source/icon_${size}x${size}.png" "$icon_directory/icon_${size}x${size}.png"
        cp "$icon_source/icon_${double_size}x${double_size}.png" "$icon_directory/icon_${size}x${size}@2x.png"
    done
    iconutil --convert icns "$icon_directory" \
        --output "$bundle_directory/Contents/Resources/AppIcon.icns"
else
    printf 'Usage: bash scripts/build.sh [--xcode|--direct]\n' >&2
    exit 2
fi

# Remove embedded debug information before signing distributable binaries.
# Xcode's unsigned embed step removes sealed headers/modules. Restore the
# complete, upstream-signed framework instead of shipping that invalid seal.
mkdir -p "$bundle_directory/Contents/Frameworks"
ditto "$sparkle_frameworks/Sparkle.framework" "$bundle_directory/Contents/Frameworks/Sparkle.framework"
codesign --verify --deep --strict "$bundle_directory/Contents/Frameworks/Sparkle.framework"
test -f "$bundle_directory/Contents/Frameworks/Sparkle.framework/Sparkle"
cp "$sparkle_directory/LICENSE" "$bundle_directory/Contents/Resources/Sparkle-LICENSE.txt"
xcrun strip -S "$bundle_directory/Contents/MacOS/Kinara"
codesign --force --sign - --options runtime --timestamp=none \
    --entitlements Sway/Sway.entitlements "$bundle_directory"
codesign --verify --deep --strict "$bundle_directory"
bash scripts/verify-runtime.sh "$bundle_directory"
plutil -lint "$bundle_directory/Contents/Info.plist"

# Replace the generated bundle as a whole, so a Release build cannot inherit a
# stale Debug dylib or obsolete resources. Preserve the previous local build.
if [[ -e "$output_directory/Kinara.app" ]]; then
    previous_directory="$(mktemp -d "$output_directory/Previous.XXXXXX")"
    mv "$output_directory/Kinara.app" "$previous_directory/Kinara.app"
fi
mv "$bundle_directory" "$output_directory/Kinara.app"
rmdir "$package_directory"
printf '\nBuilt %s app: %s\n' "$build_arch" "$output_directory/Kinara.app"
