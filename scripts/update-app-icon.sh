#!/bin/bash
# Draw Sway's app icon into every size the macOS asset catalog references.
# With no argument, Design/render-icon.swift renders the 1024 master and the
# bolder small renditions (16, 32, 64) from geometry; 128-512 are downsampled
# from the master. Pass a square PNG to package external artwork instead.
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
asset_directory="$project_directory/Sway/Assets.xcassets/AppIcon.appiconset"
master="$asset_directory/icon_1024x1024.png"
renderer="$project_directory/Design/render-icon.swift"

if [[ $# -eq 0 ]]; then
    swift "$renderer" "$master" 1024 >/dev/null
    for size in 128 256 512; do
        sips -z "$size" "$size" "$master" --out "$asset_directory/icon_${size}x${size}.png" >/dev/null
    done
    for size in 16 32 64; do
        swift "$renderer" "$asset_directory/icon_${size}x${size}.png" "$size" >/dev/null
    done
    sips -z 512 512 "$master" --out "$project_directory/website/assets/sway-icon.png" >/dev/null
    printf 'Rendered AppIcon from geometry: 16, 32, 64 (small renditions), 128, 256, 512, 1024, plus the website icon.\n'
    exit 0
fi

source_image="$1"
if [[ ! -f "$source_image" ]]; then
    printf 'Icon source does not exist: %s\n' "$source_image" >&2
    exit 2
fi
width="$(sips -g pixelWidth "$source_image" | awk '/pixelWidth:/ {print $2}')"
height="$(sips -g pixelHeight "$source_image" | awk '/pixelHeight:/ {print $2}')"
if [[ "$width" != "$height" || "$width" -lt 1024 ]]; then
    printf 'Provide a square PNG at least 1024 pixels wide.\n' >&2
    exit 2
fi
format="$(sips -g format "$source_image" | awk '/format:/ {print $2}')"
if [[ "$format" != "png" ]]; then
    printf 'Provide PNG artwork to preserve transparency.\n' >&2
    exit 2
fi
sips -z 1024 1024 "$source_image" --out "$master" >/dev/null
for size in 16 32 64 128 256 512; do
    sips -z "$size" "$size" "$master" --out "$asset_directory/icon_${size}x${size}.png" >/dev/null
done
printf 'Updated AppIcon from %s: 16, 32, 64, 128, 256, 512, and 1024 pixels.\n' "$source_image"
