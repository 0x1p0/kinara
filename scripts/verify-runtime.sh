#!/bin/bash
set -euo pipefail
bundle="${1:?Pass an app bundle}"
metadata="$(codesign -d --verbose=2 "$bundle" 2>&1)"
if [[ "$metadata" != *"runtime)"* ]]; then
    printf 'Hardened Runtime is missing from the app signature.\n' >&2
    exit 1
fi
entitlements="$(codesign -d --entitlements :- "$bundle" 2>/dev/null)"
# plutil ships with macOS; package-manager tools are not guaranteed on CI.
# Compare the complete parsed dictionary, not a blacklist of known exceptions.
entitlements_json="$(printf '%s' "$entitlements" | /usr/bin/plutil -convert json -o - -)"
# plutil keeps dictionary order, so sort the top-level pairs before comparing.
# Keys contain no commas; a nested or non-boolean value cannot match a pair.
canonical="$(printf '%s' "$entitlements_json" | /usr/bin/sed -e 's/^{//' -e 's/}$//' | /usr/bin/tr ',' '\n' | LC_ALL=C /usr/bin/sort | /usr/bin/tr '\n' ',')"
expected='"com.apple.security.automation.apple-events":true,"com.apple.security.cs.disable-library-validation":true,"com.apple.security.device.audio-input":true,'
if [[ "$canonical" != "$expected" ]]; then
    printf 'Expected only the documented library-validation, Apple Events and audio-input entitlements, each with boolean true.\n' >&2
    exit 1
fi
printf 'Hardened Runtime verified; only the documented library-validation, Apple Events and audio-input entitlements are present.\n'
