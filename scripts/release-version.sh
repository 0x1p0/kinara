#!/bin/bash
# Info.plist is the package version source of truth.
set -euo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_directory/Kinara/Info.plist")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Release version must be numeric major.minor.patch.\n' >&2
    exit 2
fi
if [[ -n "${1:-}" && "$1" != "v$version" ]]; then
    printf 'Tag %s does not match app version v%s.\n' "$1" "$version" >&2
    exit 2
fi
printf '%s\n' "$version"
