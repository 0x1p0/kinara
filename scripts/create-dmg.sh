#!/bin/bash
# Create and verify a read-only drag-to-Applications installer. Never opens Finder
# or launches the app; verification mounts only our newly created image.
set -euo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
if [[ "$#" -ne 2 || ! -d "$1/Contents" || "$2" != *.dmg ]]; then
    printf 'Usage: bash scripts/create-dmg.sh /path/to/Kinara.app /path/to/output.dmg\n' >&2
    exit 2
fi
bundle="$(cd -- "$1" && pwd)"
if [[ -e "$2" || -L "$2" ]]; then
    printf 'Refusing to overwrite an existing disk image: %s\n' "$2" >&2
    exit 2
fi
codesign --verify --deep --strict "$bundle"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Invalid app version.\n' >&2
    exit 2
fi
mkdir -p "$(dirname -- "$2")"
output_directory="$(cd -- "$(dirname -- "$2")" && pwd)"
disk_image="$output_directory/$(basename -- "$2")"
mkdir -p "$project_directory/build"
staging="$(mktemp -d "$project_directory/build/DiskImage.XXXXXX")"
mountpoint="$staging/mount"
mounted=false
detach_if_needed() {
    if [[ "$mounted" == true ]]; then
        hdiutil detach "$mountpoint" -quiet ||
            printf 'Could not eject verification volume: %s\n' "$mountpoint" >&2
    fi
}
trap detach_if_needed EXIT
mkdir -p "$staging/artwork" "$mountpoint"
bash "$script_directory/setup-dmg-tools.sh"
xcrun swiftc -O -warnings-as-errors "$script_directory/render-dmg.swift" -o "$staging/render-dmg"
"$staging/render-dmg" "$staging/artwork" "$bundle"
"$project_directory/build/DmgTools/bin/dmgbuild" \
    -s "$script_directory/dmg-settings.py" \
    -D "app=$bundle" \
    -D "instructions=$project_directory/releases/INSTALL.txt" \
    -D "background=$staging/artwork/Installer.tiff" \
    "Kinara $version" "$disk_image"
hdiutil verify "$disk_image"
hdiutil attach "$disk_image" -readonly -nobrowse -noautoopen -mountpoint "$mountpoint" -quiet
mounted=true
codesign --verify --deep --strict "$mountpoint/Kinara.app"
cmp "$bundle/Contents/MacOS/Kinara" "$mountpoint/Kinara.app/Contents/MacOS/Kinara"
cmp "$bundle/Contents/Info.plist" "$mountpoint/Kinara.app/Contents/Info.plist"
[[ "$(readlink "$mountpoint/Applications")" == "/Applications" ]]
cmp "$project_directory/releases/INSTALL.txt" "$mountpoint/First Launch.txt"
cmp "$staging/artwork/Installer.tiff" "$mountpoint/.background.tiff"
"$project_directory/build/DmgTools/bin/python" "$script_directory/verify-dmg-layout.py" "$mountpoint"
hdiutil detach "$mountpoint" -quiet
mounted=false
trap - EXIT
printf 'Verified disk image, app signature, executable, instructions, and Finder layout: %s\n' "$disk_image"
printf 'Installer layout proof (not a Finder screenshot): %s\n' "$staging/artwork/Installer-preview.png"
