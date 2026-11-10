#!/bin/bash
set -euo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
test_directory="$(mktemp -d /tmp/kinara-signing-tests.XXXXXX)"
cd "$project_directory"
xcrun swiftc -swift-version 5 -warnings-as-errors \
    -module-cache-path "$test_directory/ModuleCache" \
    scripts/verify-update-feed.swift -o "$test_directory/verify-update-feed"
xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
    -module-cache-path "$test_directory/ModuleCache" \
    Tests/update_signing_regressions.swift -o "$test_directory/update-signing-tests"
"$test_directory/update-signing-tests" "$test_directory/verify-update-feed" "$test_directory"
xcrun swiftc -swift-version 5 -warnings-as-errors \
    -module-cache-path "$test_directory/ModuleCache" \
    scripts/sign-update.swift -o "$test_directory/sign-update"
xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
    -module-cache-path "$test_directory/ModuleCache" \
    Tests/signing_boundary_regressions.swift -o "$test_directory/signing-boundary-tests"
arguments=("$test_directory/sign-update" "$test_directory/verify-update-feed" "$test_directory")
sparkle_tool="$project_directory/build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
if [[ -x "$sparkle_tool" ]]; then arguments+=("$sparkle_tool"); fi
"$test_directory/signing-boundary-tests" "${arguments[@]}"
