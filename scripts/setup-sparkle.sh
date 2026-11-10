#!/bin/bash
# Resolve the pinned, checksum-verified Swift package, never a floating download.
set -euo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
sparkle_directory="$project_directory/build/SourcePackages/artifacts/sparkle/Sparkle"
cd "$project_directory"
if [[ ! -x "$sparkle_directory/bin/generate_appcast" ]]; then
    xcodebuild -resolvePackageDependencies -project Kinara.xcodeproj -scheme Kinara \
        -clonedSourcePackagesDirPath "$project_directory/build/SourcePackages" \
        -onlyUsePackageVersionsFromResolvedFile >&2
fi
test -x "$sparkle_directory/bin/generate_appcast"
test -d "$sparkle_directory/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
printf '%s\n' "$sparkle_directory"
