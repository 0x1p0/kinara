#!/bin/bash
# Sign a COPY of a built Kinara.app with a Developer ID Application identity,
# notarize it with Apple, staple the ticket, and verify Gatekeeper accepts it.
# This removes the "Apple could not verify Kinara" first-launch warning.
#
# Requires an Apple Developer Program membership. One-time setup:
#   1. Create a "Developer ID Application" certificate in your developer
#      account and install it in your login Keychain.
#   2. Store notary credentials (an app-specific password or API key):
#        xcrun notarytool store-credentials kinara-notary --apple-id <you> --team-id <TEAM>
#
# Then:
#   KINARA_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   KINARA_NOTARY_PROFILE=kinara-notary bash scripts/notarize.sh [build/Kinara.app]
#
# The input app is never modified. Read scripts/signing/README.md first:
# switching from the persistent self-signed identity changes Kinara's code
# identity, so users re-grant Accessibility once after that update.
set -euo pipefail

source_app="${1:-build/Kinara.app}"
identity="${KINARA_DEVELOPER_ID:-}"
profile="${KINARA_NOTARY_PROFILE:-}"
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
entitlements="$project_directory/Kinara/Kinara.entitlements"

if [[ -z "$identity" || -z "$profile" ]]; then
    printf 'Set KINARA_DEVELOPER_ID and KINARA_NOTARY_PROFILE first (see the top of this script).\n' >&2
    exit 2
fi
if [[ "$identity" != "Developer ID Application:"* ]]; then
    printf 'KINARA_DEVELOPER_ID must name a "Developer ID Application" identity. Apple Development certificates cannot be notarized for distribution.\n' >&2
    exit 2
fi
if [[ ! -d "$source_app/Contents/MacOS" ]]; then
    printf 'No app bundle at %s. Build one first with: bash scripts/build.sh\n' "$source_app" >&2
    exit 2
fi
if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq "\"$identity\""; then
    printf 'That signing identity is not in your Keychain.\n' >&2
    exit 2
fi

output_directory="$project_directory/build/Notarized"
mkdir -p "$output_directory"
work="$(mktemp -d "$output_directory/Work.XXXXXX")"
app="$work/Kinara.app"
/usr/bin/ditto "$source_app" "$app"

sign() { /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$@"; }

# Inside out, as Sparkle's documentation describes. Re-signing Sparkle with the
# same team identity is what makes the library-validation exception removable
# once every release uses Developer ID; it stays for now so self-signed and
# Developer ID builds share one entitlement policy.
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
sign --entitlements "$entitlements" "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
bash "$script_directory/verify-runtime.sh" "$app"

archive="$work/Kinara-notarization.zip"
/usr/bin/ditto -c -k --keepParent "$app" "$archive"
printf 'Submitting to Apple’s notary service. This usually takes a few minutes.\n'
/usr/bin/xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
/usr/bin/xcrun stapler staple "$app"
/usr/bin/xcrun stapler validate "$app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$app"

final="$output_directory/Kinara.app"
if [[ -e "$final" ]]; then
    printf 'Keeping the existing %s; the new notarized app is at %s\n' "$final" "$app"
else
    /usr/bin/ditto "$app" "$final"
    printf 'Notarized and stapled: %s\n' "$final"
fi
